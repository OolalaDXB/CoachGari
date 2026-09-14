/* Web Push — VAPID (RFC 8292) + aes128gcm payload encryption (RFC 8188 / RFC 8291).

   Written against Web Crypto only: no npm package, nothing vendored. The two Node
   libraries that do this reach for node:crypto and node:https, which is not what the
   Edge runtime wants, and a push sender is small enough to own.

   What leaves the server: the payload is encrypted end to end with keys only the
   subscribed browser holds, so the push service (Google, Apple, Mozilla) relays bytes
   it cannot read. It still lands on a lock screen, though, which is why the caller
   sends a kind and never a name, an address, a reference or an amount.

   Proven by scripts/test-push.mjs, which plays the browser: it generates a
   subscription keypair, has this module encrypt to it, decrypts with the private half
   and compares — and verifies the VAPID signature against the public key. */

const enc = new TextEncoder();

export type Subscription = { endpoint: string; p256dh: string; auth: string };
export type Vapid = { publicKey: string; privateKey: string; subject: string };

/* ---------- base64url ---------- */
export function b64uToBytes(s: string): Uint8Array {
  const p = s.replace(/-/g, "+").replace(/_/g, "/") + "===".slice((s.length + 3) % 4);
  return Uint8Array.from(atob(p), (c) => c.charCodeAt(0));
}
export function bytesToB64u(b: ArrayBuffer | Uint8Array): string {
  const u = b instanceof Uint8Array ? b : new Uint8Array(b);
  let s = ""; for (const x of u) s += String.fromCharCode(x);
  return btoa(s).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}
function cat(...parts: Uint8Array[]): Uint8Array {
  const out = new Uint8Array(parts.reduce((n, p) => n + p.length, 0));
  let o = 0; for (const p of parts) { out.set(p, o); o += p.length; }
  return out;
}

/* ---------- HKDF, one call: Web Crypto extracts and expands together ---------- */
async function hkdf(salt: Uint8Array, ikm: Uint8Array, info: Uint8Array, bytes: number): Promise<Uint8Array> {
  const key = await crypto.subtle.importKey("raw", ikm, "HKDF", false, ["deriveBits"]);
  const bits = await crypto.subtle.deriveBits({ name: "HKDF", hash: "SHA-256", salt, info }, key, bytes * 8);
  return new Uint8Array(bits);
}

/* ---------- RFC 8291: encrypt a payload to one subscription ---------- */
export async function encryptPayload(plaintext: string, p256dh: string, auth: string): Promise<Uint8Array> {
  const uaPublic = b64uToBytes(p256dh);            // 65 bytes, uncompressed P-256 point
  const authSecret = b64uToBytes(auth);            // 16 bytes
  if (uaPublic.length !== 65 || uaPublic[0] !== 0x04) throw new Error("bad p256dh");
  if (authSecret.length !== 16) throw new Error("bad auth secret");

  const as = await crypto.subtle.generateKey({ name: "ECDH", namedCurve: "P-256" }, true, ["deriveBits"]);
  const asPublic = new Uint8Array(await crypto.subtle.exportKey("raw", as.publicKey));
  const uaKey = await crypto.subtle.importKey("raw", uaPublic, { name: "ECDH", namedCurve: "P-256" }, false, []);
  const shared = new Uint8Array(await crypto.subtle.deriveBits({ name: "ECDH", public: uaKey }, as.privateKey, 256));

  // IKM binds the two public keys, so a record cannot be replayed at another subscription
  const keyInfo = cat(enc.encode("WebPush: info"), new Uint8Array([0]), uaPublic, asPublic);
  const ikm = await hkdf(authSecret, shared, keyInfo, 32);

  const salt = crypto.getRandomValues(new Uint8Array(16));
  const cek = await hkdf(salt, ikm, cat(enc.encode("Content-Encoding: aes128gcm"), new Uint8Array([0])), 16);
  const nonce = await hkdf(salt, ikm, cat(enc.encode("Content-Encoding: nonce"), new Uint8Array([0])), 12);

  const aes = await crypto.subtle.importKey("raw", cek, "AES-GCM", false, ["encrypt"]);
  const record = cat(enc.encode(plaintext), new Uint8Array([0x02]));   // 0x02: this is the last record
  const ct = new Uint8Array(await crypto.subtle.encrypt({ name: "AES-GCM", iv: nonce, tagLength: 128 }, aes, record));

  const rs = new Uint8Array(4); new DataView(rs.buffer).setUint32(0, 4096);
  return cat(salt, rs, new Uint8Array([asPublic.length]), asPublic, ct);   // RFC 8188 header || ciphertext
}

/* ---------- RFC 8292: the Authorization header proving who is sending ---------- */
export async function vapidHeader(endpoint: string, v: Vapid, ttlSeconds = 12 * 3600): Promise<string> {
  const aud = new URL(endpoint).origin;
  const pub = b64uToBytes(v.publicKey);
  if (pub.length !== 65) throw new Error("bad vapid public key");
  const jwk: JsonWebKey = {
    kty: "EC", crv: "P-256", ext: true, d: v.privateKey,
    x: bytesToB64u(pub.slice(1, 33)), y: bytesToB64u(pub.slice(33, 65)),
  };
  const key = await crypto.subtle.importKey("jwk", jwk, { name: "ECDSA", namedCurve: "P-256" }, false, ["sign"]);
  const header = bytesToB64u(enc.encode(JSON.stringify({ typ: "JWT", alg: "ES256" })));
  const claims = bytesToB64u(enc.encode(JSON.stringify({
    aud, exp: Math.floor(Date.now() / 1000) + ttlSeconds, sub: v.subject,
  })));
  const signed = `${header}.${claims}`;
  const sig = await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, key, enc.encode(signed));
  return `vapid t=${signed}.${bytesToB64u(sig)}, k=${v.publicKey}`;
}

/* ---------- send one ----------
   Returns the push service's status so the caller can act on it: 404 and 410 mean the
   subscription is gone for good and should be deleted, 429 and 5xx are worth retrying. */
export async function sendPush(sub: Subscription, payload: string, v: Vapid, ttl = 3600): Promise<Response> {
  const body = await encryptPayload(payload, sub.p256dh, sub.auth);
  return await fetch(sub.endpoint, {
    method: "POST",
    headers: {
      "Authorization": await vapidHeader(sub.endpoint, v),
      "Content-Encoding": "aes128gcm",
      "Content-Type": "application/octet-stream",
      "TTL": String(ttl),
      "Urgency": "normal",
    },
    body,
  });
}

export const GONE = (status: number) => status === 404 || status === 410;

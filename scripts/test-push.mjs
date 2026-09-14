#!/usr/bin/env node
/* Web Push sender — offline suite, no network.

   The point of this file is that the crypto is not taken on trust. It plays the
   browser: generates a subscription keypair the way a browser does, hands the public
   half to the sender, then decrypts the record with the private half and compares it
   to what went in. If the key derivation were wrong in any of its five steps, the
   decryption fails and this suite goes red.

   It also verifies the VAPID signature against the public key, and asserts that a
   push payload never carries a name, an address, a reference or an amount — a
   notification lands on a lock screen, which is not a private place.

   Run: node --experimental-strip-types scripts/test-push.mjs                       */
import { webcrypto as crypto } from "node:crypto";
import { readFileSync } from "node:fs";

const { subtle } = crypto;
const enc = new TextEncoder();
const dec = new TextDecoder();
let ok = 0, fail = 0;
const check = (name, cond, extra = "") => {
  if (cond) { ok++; console.log("PASS ", name); }
  else { fail++; console.log("FAIL ", name, extra ? "— " + extra : ""); }
};

const mod = new URL("../supabase/functions/_shared/webpush.ts", import.meta.url);
const { encryptPayload, vapidHeader, b64uToBytes, bytesToB64u, GONE } = await import(mod);

/* ---------- helpers mirroring the sender, used only to verify ---------- */
const cat = (...p) => { const o = new Uint8Array(p.reduce((n, x) => n + x.length, 0)); let i = 0; for (const x of p) { o.set(x, i); i += x.length; } return o; };
async function hkdf(salt, ikm, info, bytes) {
  const k = await subtle.importKey("raw", ikm, "HKDF", false, ["deriveBits"]);
  return new Uint8Array(await subtle.deriveBits({ name: "HKDF", hash: "SHA-256", salt, info }, k, bytes * 8));
}

/* ---------- 1. a browser subscribes ---------- */
const ua = await subtle.generateKey({ name: "ECDH", namedCurve: "P-256" }, true, ["deriveBits"]);
const uaPublic = new Uint8Array(await subtle.exportKey("raw", ua.publicKey));
const authSecret = crypto.getRandomValues(new Uint8Array(16));
const p256dh = bytesToB64u(uaPublic);
const auth = bytesToB64u(authSecret);

/* ---------- 2. the server encrypts to it ---------- */
const MESSAGE = JSON.stringify({ t: "New booking request", u: "/admin/#bookings" });
const body = await encryptPayload(MESSAGE, p256dh, auth);

check("the record carries the aes128gcm header (salt, record size, sender key)", body.length > 16 + 4 + 1 + 65 + 16);
const salt = body.slice(0, 16);
const rs = new DataView(body.buffer, body.byteOffset + 16, 4).getUint32(0);
const idlen = body[20];
check("record size is announced as 4096", rs === 4096, String(rs));
check("the key id is a 65-byte uncompressed P-256 point", idlen === 65 && body[21] === 0x04);
const asPublic = body.slice(21, 21 + 65);
const ciphertext = body.slice(21 + 65);

/* ---------- 3. the browser decrypts, exactly as a real one would ---------- */
const asKey = await subtle.importKey("raw", asPublic, { name: "ECDH", namedCurve: "P-256" }, false, []);
const shared = new Uint8Array(await subtle.deriveBits({ name: "ECDH", public: asKey }, ua.privateKey, 256));
const keyInfo = cat(enc.encode("WebPush: info"), new Uint8Array([0]), uaPublic, asPublic);
const ikm = await hkdf(authSecret, shared, keyInfo, 32);
const cek = await hkdf(salt, ikm, cat(enc.encode("Content-Encoding: aes128gcm"), new Uint8Array([0])), 16);
const nonce = await hkdf(salt, ikm, cat(enc.encode("Content-Encoding: nonce"), new Uint8Array([0])), 12);
const aes = await subtle.importKey("raw", cek, "AES-GCM", false, ["decrypt"]);

let plain = null, threw = null;
try {
  const out = new Uint8Array(await subtle.decrypt({ name: "AES-GCM", iv: nonce, tagLength: 128 }, aes, ciphertext));
  check("the last-record delimiter 0x02 closes the plaintext", out[out.length - 1] === 0x02, String(out[out.length - 1]));
  plain = dec.decode(out.slice(0, -1));
} catch (e) { threw = e; }
check("the subscribed browser decrypts the record", plain !== null, threw ? String(threw) : "");
check("what comes out is exactly what went in", plain === MESSAGE, String(plain));

/* ---------- 4. a different subscription cannot read it ---------- */
const other = await subtle.generateKey({ name: "ECDH", namedCurve: "P-256" }, true, ["deriveBits"]);
let otherRead = false;
try {
  const sh2 = new Uint8Array(await subtle.deriveBits({ name: "ECDH", public: asKey }, other.privateKey, 256));
  const ikm2 = await hkdf(authSecret, sh2, keyInfo, 32);
  const cek2 = await hkdf(salt, ikm2, cat(enc.encode("Content-Encoding: aes128gcm"), new Uint8Array([0])), 16);
  const n2 = await hkdf(salt, ikm2, cat(enc.encode("Content-Encoding: nonce"), new Uint8Array([0])), 12);
  const a2 = await subtle.importKey("raw", cek2, "AES-GCM", false, ["decrypt"]);
  await subtle.decrypt({ name: "AES-GCM", iv: n2, tagLength: 128 }, a2, ciphertext);
  otherRead = true;
} catch { otherRead = false; }
check("another browser's keys cannot decrypt the same record", !otherRead);

/* ---------- 5. two sends of the same text differ (fresh salt and ephemeral key) ---------- */
const again = await encryptPayload(MESSAGE, p256dh, auth);
check("every send is freshly salted, so two identical messages differ on the wire",
  bytesToB64u(again.slice(0, 16)) !== bytesToB64u(salt) && bytesToB64u(again) !== bytesToB64u(body));

/* ---------- 6. VAPID ---------- */
const kp = await subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"]);
const pubRaw = new Uint8Array(await subtle.exportKey("raw", kp.publicKey));
const jwk = await subtle.exportKey("jwk", kp.privateKey);
const vapid = { publicKey: bytesToB64u(pubRaw), privateKey: jwk.d, subject: "mailto:letsgo@coachgari28.com" };
const header = await vapidHeader("https://fcm.googleapis.com/fcm/send/abc123", vapid);

check("the header is the vapid scheme with t and k", /^vapid t=[\w-]+\.[\w-]+\.[\w-]+, k=[\w-]+$/.test(header), header.slice(0, 40));
const t = header.match(/t=([^,]+)/)[1];
const [h64, c64, s64] = t.split(".");
const claims = JSON.parse(Buffer.from(c64.replace(/-/g, "+").replace(/_/g, "/"), "base64").toString());
check("the audience is the push service origin, not the endpoint path", claims.aud === "https://fcm.googleapis.com", claims.aud);
check("the subject is a contactable mailto", /^mailto:/.test(claims.sub), claims.sub);
check("the token expires, and within 24h as the spec requires", claims.exp > Date.now() / 1000 && claims.exp < Date.now() / 1000 + 86400);
const valid = await subtle.verify({ name: "ECDSA", hash: "SHA-256" }, kp.publicKey,
  b64uToBytes(s64), enc.encode(`${h64}.${c64}`));
check("the signature verifies against the VAPID public key", valid);
const tampered = await subtle.verify({ name: "ECDSA", hash: "SHA-256" }, kp.publicKey,
  b64uToBytes(s64), enc.encode(`${h64}.${c64}x`));
check("a tampered token does not verify", !tampered);
check("k carries the same public key the signature verifies against", header.endsWith("k=" + vapid.publicKey));

/* ---------- 7. malformed subscriptions are refused, not sent ---------- */
for (const [name, p, a] of [
  ["a short p256dh", bytesToB64u(new Uint8Array(64)), auth],
  ["a compressed point", bytesToB64u(cat(new Uint8Array([0x02]), uaPublic.slice(1))), auth],
  ["a short auth secret", p256dh, bytesToB64u(new Uint8Array(8))],
]) {
  let rejected = false;
  try { await encryptPayload("x", p, a); } catch { rejected = true; }
  check(`refuses ${name} instead of sending a broken record`, rejected);
}

/* ---------- 8. gone means gone ---------- */
check("404 and 410 mark a subscription gone; 429 and 500 do not",
  GONE(404) && GONE(410) && !GONE(429) && !GONE(500) && !GONE(201));

/* ---------- 9. the payload the back-office actually sends carries no personal data ---------- */
const fn = readFileSync(new URL("../supabase/functions/push/index.ts", import.meta.url), "utf8");
const texts = [...fn.matchAll(/t:\s*"([^"]+)"/g)].map((m) => m[1]);
check("the notification texts are fixed strings, not built from a row", texts.length > 0, String(texts.length));
check("no notification text interpolates a value", !/t:\s*`/.test(fn));
const forbidden = /\b(customer_name|customer_contact|to_address|email|reference|amount|payload\.[a-z_]+)\b/;
const pushBlock = fn.slice(fn.indexOf("const TEXT"), fn.indexOf("const TEXT") + 1200);
check("the text table names no column carrying personal data", !forbidden.test(pushBlock), pushBlock.match(forbidden)?.[0] ?? "");

console.log(`\nPUSH_TESTS ok=${ok} fail=${fail}`);
process.exit(fail ? 1 : 0);

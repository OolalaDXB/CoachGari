/* =============================================================
   Coach Gari — client IP derivation, shared by every function that
   hashes an IP (rate-limit identity in contact, consent evidence).

   Which IP can be trusted here — verified, not assumed (2026-09-09):
   - Supabase Edge Functions sit behind Cloudflare and the Supabase gateway. Supabase staff
     confirmed the platform populates X-Forwarded-For with the client IP
     (github.com/orgs/supabase/discussions/7884, laktek). Nothing in the Supabase docs
     promises a header the client cannot influence.
   - A client-sent X-Forwarded-For is NOT replaced: the platform APPENDS the connecting IP,
     so the value becomes "<spoofed>, <real>" (observed in discussions/34647, and the standard
     Cloudflare behaviour). The LEFT-most hop is therefore attacker-controlled; the RIGHT-most
     hop is the one the trusted edge added.
   - cf-connecting-ip is set by Cloudflare from the TCP connection and cannot be supplied by
     the caller: a probe against the contact function that carried its own CF-Connecting-IP
     header was refused at the edge with Cloudflare error 1000 before reaching the function.
   Order of trust: cf-connecting-ip → right-most X-Forwarded-For hop → x-real-ip → "unknown".
   This stays best-effort (no documented guarantee): callers that rate-limit keep an
   identity-independent back-stop, and evidence records only a salted hash, never the IP.
   ============================================================= */

export function clientIp(req: Request): string {
  const cf = req.headers.get("cf-connecting-ip")?.trim();
  if (cf) return cf;
  const xff = req.headers.get("x-forwarded-for");
  if (xff) {
    const hops = xff.split(",").map((h) => h.trim()).filter(Boolean);
    if (hops.length) return hops[hops.length - 1];              // the hop appended by the trusted edge, not the client's
  }
  return req.headers.get("x-real-ip")?.trim() || "unknown";
}

/* number of X-Forwarded-For hops — a safe diagnostic (a count, never a value) */
export function xffHops(req: Request): number {
  return (req.headers.get("x-forwarded-for") ?? "").split(",").filter((h) => h.trim()).length;
}

export async function sha256hex(s: string): Promise<string> {
  const buf = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(s));
  return Array.from(new Uint8Array(buf)).map((b) => b.toString(16).padStart(2, "0")).join("");
}

/* Salted IP hash for a rate-limit / evidence identity — FAIL-CLOSED.
   With no salt secret set we do NOT hash: this returns null (and calls
   onMissing), so an IP is never hashed under a salt that ships in the repo —
   a known salt would make the hash reproducible and the IP brute-forceable.
   An "unknown" IP is not hashed either. This is the consent function's rule,
   shared here so no caller can drift back to a hardcoded fallback. The salt is
   read from `saltEnv` (an owner-set secret, e.g. IP_HASH_SALT / CONSENT_IP_SALT)
   and never from the service-role key. */
export async function saltedIpHash(
  req: Request,
  saltEnv: string,
  onMissing?: () => void,
): Promise<string | null> {
  const salt = (Deno.env.get(saltEnv) ?? "").trim();
  if (!salt) { onMissing?.(); return null; }
  const ip = clientIp(req);
  if (ip === "unknown") return null;
  return await sha256hex(salt + "|" + ip);
}

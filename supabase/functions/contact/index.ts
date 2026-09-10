/* =============================================================
   CG-001 — contact
   Public Edge Function that receives the enquiry form.

   Flow: CORS check → method/size guard → parse → honeypot/timing
   → validation → rate limit → duplicate guard → insert into
   public.contacts → (optional) Resend notification → 200.

   Secrets: none in code. The platform injects SUPABASE_URL and
   SUPABASE_SERVICE_ROLE_KEY. RESEND_API_KEY is a Supabase secret
   set by the operator; when absent the lead is still saved and
   the notification is skipped with a log line.

   Logs never contain the message, the contact or the raw IP.

   Rate-limit identity (see clientIp): derived from the hop the platform sets,
   never from the client-supplied left-most X-Forwarded-For value. Because
   Supabase does not document a guaranteed client-IP header, the per-IP limiter
   is best-effort, and a GLOBAL back-stop (all callers, short window) caps the
   insert rate whatever identity a caller presents.
   ============================================================= */
import { createClient } from "npm:@supabase/supabase-js@2.116.0";
import { originAllowed, corsHeaders } from "../_shared/cors.ts";   // one allowlist for every browser-facing function
import { drainOutbox } from "../_shared/email.ts";                  // lead notification to letsgo@ + acknowledgement to the customer
import { xffHops, saltedIpHash } from "../_shared/client-ip.ts";   // trusted-hop IP derivation + fail-closed salted hash, shared with consent / booking

/* ---- configuration (not secrets) -------------------------- */
const env = (name: string) => Deno.env.get(name);

const RATE_WINDOW_MIN = 10;   // per IP hash
const RATE_MAX        = 5;    // submissions per window
const GLOBAL_WINDOW_MIN = 10; // back-stop, all callers together (identity-independent)
const GLOBAL_MAX        = 40; // legitimate traffic is a few enquiries a day; 40 in 10 min is a flood
const DUP_WINDOW_MIN  = 2;    // same contact + message from same IP → duplicate
const MIN_FILL_MS     = 2000; // faster than this from page load = bot
const MAX_BODY_BYTES  = 16 * 1024;

const LIMITS = {
  name: 120, contact: 160, location: 160, interest: 80, message: 2000,
  utm: 200, url: 1000, ua: 300, page: 200,
};

/* ---- helpers ---------------------------------------------- */
function json(status: number, body: unknown, origin: string | null, allowed: boolean): Response {
  return new Response(JSON.stringify(body), { status, headers: corsHeaders(origin, allowed) });
}

function str(v: unknown, max: number): string | null {
  if (typeof v !== "string") return null;
  const s = v.replace(/\s+/g, " ").trim();
  if (!s) return null;
  return s.length > max ? s.slice(0, max) : s;
}

function text(v: unknown, max: number): string | null {
  if (typeof v !== "string") return null;
  const s = v.replace(/\r\n/g, "\n").trim();
  if (!s) return null;
  return s.length > max ? s.slice(0, max) : s;
}

function isEmail(s: string): boolean {
  return /^[^\s@]+@[^\s@]+\.[^\s@]{2,}$/.test(s);
}
function looksLikePhone(s: string): boolean {
  return (s.match(/\d/g) ?? []).length >= 7;
}
function isUuid(s: unknown): s is string {
  return typeof s === "string" && /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(s);
}

function splitLocation(raw: string | null): { city: string | null; country: string | null } {
  if (!raw) return { city: null, country: null };
  const i = raw.lastIndexOf(",");
  if (i === -1) return { city: raw, country: null };
  const city = raw.slice(0, i).trim() || null;
  const country = raw.slice(i + 1).trim() || null;
  return { city, country };
}

/* IP trust order (cf-connecting-ip → right-most X-Forwarded-For hop → x-real-ip → "unknown")
   and the evidence behind it live in _shared/client-ip.ts. It stays best-effort (no documented
   guarantee), hence the global back-stop below. */

function log(event: string, data: Record<string, unknown> = {}): void {
  console.log(JSON.stringify({ fn: "contact", event, ...data }));
}

/* ---- handler ---------------------------------------------- */
Deno.serve(async (req: Request) => {
  const origin = req.headers.get("origin");
  const allowed = originAllowed(origin);

  if (req.method === "OPTIONS") {
    return new Response(null, { status: allowed ? 204 : 403, headers: corsHeaders(origin, allowed) });
  }
  if (!allowed) { log("origin_rejected"); return json(403, { ok: false, error: "origin_not_allowed" }, origin, false); }
  if (req.method !== "POST") return json(405, { ok: false, error: "method_not_allowed" }, origin, allowed);

  const declared = Number(req.headers.get("content-length") ?? 0);
  if (declared > MAX_BODY_BYTES) return json(413, { ok: false, error: "payload_too_large" }, origin, allowed);
  const raw = await req.text();
  if (raw.length > MAX_BODY_BYTES) return json(413, { ok: false, error: "payload_too_large" }, origin, allowed);

  let body: Record<string, unknown>;
  try { body = JSON.parse(raw); } catch { return json(400, { ok: false, error: "invalid_json" }, origin, allowed); }
  if (!body || typeof body !== "object") return json(400, { ok: false, error: "invalid_json" }, origin, allowed);

  // Honeypot + timing: accept silently (200, no id) so bots learn nothing.
  if (typeof body.website === "string" && body.website.trim() !== "") {
    log("honeypot"); return json(200, { ok: true }, origin, allowed);
  }
  if (typeof body.ts === "number" && Number.isFinite(body.ts) && Date.now() - body.ts < MIN_FILL_MS) {
    log("too_fast"); return json(200, { ok: true }, origin, allowed);
  }

  // Validation
  const name     = str(body.name, LIMITS.name);
  const contact  = str(body.contact ?? body.email, LIMITS.contact);
  const location = str(body.location, LIMITS.location);
  const interest = str(body.interest, LIMITS.interest);
  const message  = text(body.message ?? body.detail, LIMITS.message);
  const errors: string[] = [];
  if (!name) errors.push("name");
  if (!contact || !(isEmail(contact) || looksLikePhone(contact))) errors.push("contact");
  if (errors.length) return json(400, { ok: false, error: "validation", fields: errors }, origin, allowed);

  const submissionId = isUuid(body.submission_id) ? body.submission_id : crypto.randomUUID();
  const attr = (body.attribution && typeof body.attribution === "object" ? body.attribution : {}) as Record<string, unknown>;
  const firstVisit = typeof attr.first_visit_at === "string" && !Number.isNaN(Date.parse(attr.first_visit_at))
    ? new Date(attr.first_visit_at).toISOString() : null;
  const { city, country } = splitLocation(location);
  // Rate-limit identity: a salted hash of the trusted-hop IP. Fail-closed — with no
  // IP_HASH_SALT secret set the hash is null (never a hash under a repo-known salt),
  // and the per-IP checks below are skipped; the global back-stop still applies.
  const ipHash = await saltedIpHash(req, "IP_HASH_SALT", () => log("ip_salt_missing"));
  // diagnostic only: whether the caller supplied its own X-Forwarded-For chain (never the value, never an identity)
  const hops = xffHops(req);

  const supabase = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
    { auth: { persistSession: false } },
  );

  // Rate limit per IP hash (skipped when the IP could not be identified/hashed)
  if (ipHash) {
    const since = new Date(Date.now() - RATE_WINDOW_MIN * 60_000).toISOString();
    const { count: recent, error: rlErr } = await supabase
      .from("contacts").select("id", { count: "exact", head: true })
      .eq("ip_hash", ipHash).gte("created_at", since);
    if (rlErr) log("rate_limit_query_failed", { code: rlErr.code });
    if ((recent ?? 0) >= RATE_MAX) {
      log("rate_limited", { submission_id: submissionId, xff_hops: hops });
      return json(429, { ok: false, error: "rate_limited" }, origin, allowed);
    }
  }
  // Global back-stop, independent of any identity the caller presents: total inserts in a short window, all callers.
  // Far above legitimate traffic; a flood that rotates identities still hits this wall. Honeypot, timing and the
  // submission_id / content dedup above and below stay unchanged.
  const gSince = new Date(Date.now() - GLOBAL_WINDOW_MIN * 60_000).toISOString();
  const { count: globalRecent, error: gErr } = await supabase
    .from("contacts").select("id", { count: "exact", head: true }).gte("created_at", gSince);
  if (gErr) log("global_limit_query_failed", { code: gErr.code });
  if ((globalRecent ?? 0) >= GLOBAL_MAX) {
    log("rate_limited_global", { submission_id: submissionId, window_min: GLOBAL_WINDOW_MIN, xff_hops: hops });
    return json(429, { ok: false, error: "rate_limited" }, origin, allowed);
  }

  // Duplicate guard 1: same submission_id (double click / retry) → return the existing row
  const { data: existing } = await supabase
    .from("contacts").select("id, notified_at").eq("submission_id", submissionId).maybeSingle();
  if (existing) {
    log("duplicate_submission_id", { id: existing.id });
    return json(200, { ok: true, id: existing.id, duplicate: true, notified: !!existing.notified_at }, origin, allowed);
  }

  // Duplicate guard 2: same contact + message from the same IP within a short window
  // (needs an IP identity; skipped when ip_hash is null — the submission_id guard above still holds)
  if (ipHash) {
    const dupSince = new Date(Date.now() - DUP_WINDOW_MIN * 60_000).toISOString();
    const { data: near } = await supabase
      .from("contacts").select("id, notified_at")
      .eq("ip_hash", ipHash).eq("contact", contact).gte("created_at", dupSince)
      .order("created_at", { ascending: false }).limit(5);
    const nearDup = (near ?? []).find(() => true); // any recent identical-contact row from this IP
    if (nearDup && message !== null) {
      const { data: same } = await supabase
        .from("contacts").select("id, notified_at").eq("id", nearDup.id).eq("message", message).maybeSingle();
      if (same) {
        log("duplicate_content", { id: same.id });
        return json(200, { ok: true, id: same.id, duplicate: true, notified: !!same.notified_at }, origin, allowed);
      }
    }
  }

  // Insert
  const row = {
    submission_id: submissionId,
    name, contact, country, city, location_raw: location, interest, message,
    utm_source:   str(attr.utm_source, LIMITS.utm),
    utm_medium:   str(attr.utm_medium, LIMITS.utm),
    utm_campaign: str(attr.utm_campaign, LIMITS.utm),
    utm_content:  str(attr.utm_content, LIMITS.utm),
    utm_term:     str(attr.utm_term, LIMITS.utm),
    referrer:     str(attr.referrer, LIMITS.url),
    landing_page: str(attr.landing_page, LIMITS.url),
    first_visit_at: firstVisit,
    page: str(body.page, LIMITS.page),
    source: "web",
    ip_hash: ipHash,
    user_agent: str(req.headers.get("user-agent"), LIMITS.ua),
  };

  const { data: inserted, error: insErr } = await supabase
    .from("contacts").insert(row)
    .select("id, interest, utm_source")
    .single();

  if (insErr) {
    if (insErr.code === "23505") { // unique violation on submission_id — a concurrent duplicate
      const { data: again } = await supabase
        .from("contacts").select("id, notified_at").eq("submission_id", submissionId).maybeSingle();
      log("duplicate_race", { id: again?.id });
      return json(200, { ok: true, id: again?.id, duplicate: true, notified: !!again?.notified_at }, origin, allowed);
    }
    log("insert_failed", { code: insErr.code });
    return json(500, { ok: false, error: "storage_failed" }, origin, allowed);
  }

  log("created", { id: inserted.id, interest: inserted.interest, has_utm: !!inserted.utm_source });

  // Outbox: the database queues lead_notification (owner) + enquiry_received (customer); this request sends them now.
  // notified_at records that the owner's copy left; a send failure stays a retryable outbox row and never fails the enquiry.
  let notified = false;
  const { error: qErr } = await supabase.rpc("email_on_enquiry", { p_contact_id: inserted.id });
  if (qErr) log("email_queue_failed", { id: inserted.id, code: qErr.code });
  else {
    const r = await drainOutbox(supabase, env, { contact_id: inserted.id }, (event, data) => log(event, { id: inserted.id, ...data }));
    const { data: lead } = await supabase.from("email_events").select("status").eq("contact_id", inserted.id).eq("kind", "lead_notification").maybeSingle();
    notified = lead?.status === "sent";
    if (notified) await supabase.from("contacts").update({ notified_at: new Date().toISOString() }).eq("id", inserted.id);
    log(notified ? "notify_sent" : "notify_pending", { id: inserted.id, ...r });
  }

  // Server-issued upload credential (CG-006): 256-bit, 30 minutes, tied to this enquiry only.
  // Only the creating response carries it; duplicates / retries never re-issue it.
  let uploadToken: string | null = null;
  const { data: tok, error: tokErr } = await supabase.rpc("issue_upload_token", { p_contact_id: inserted.id });
  if (tokErr) log("upload_token_failed", { code: tokErr.code }); else uploadToken = tok as string;

  return json(200, { ok: true, id: inserted.id, notified, upload_token: uploadToken, upload_expires_in: uploadToken ? 1800 : 0 }, origin, allowed);
});

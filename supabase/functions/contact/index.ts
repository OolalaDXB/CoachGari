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
   ============================================================= */
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "npm:@supabase/supabase-js@2";

/* ---- configuration (not secrets) -------------------------- */
const ALLOWED_ORIGINS = new Set([
  "https://coachgari.com",
  "https://www.coachgari.com",
]);
// Vercel previews + local dev. Tighten the Vercel pattern to the
// project's own preview domain once it is known.
const ALLOWED_ORIGIN_PATTERNS: RegExp[] = [
  /^https:\/\/[a-z0-9-]+\.vercel\.app$/i,
  /^http:\/\/localhost(:\d+)?$/i,
  /^http:\/\/127\.0\.0\.1(:\d+)?$/i,
];

const LEAD_TO   = Deno.env.get("LEAD_TO_EMAIL") ?? "letsgo@coachgari.com";
const MAIL_FROM = Deno.env.get("MAIL_FROM") ?? "Coach Gari <yoursession@coachgari.com>";
const IP_SALT   = Deno.env.get("IP_HASH_SALT") ?? "coachgari-cg001";

const RATE_WINDOW_MIN = 10;   // per IP hash
const RATE_MAX        = 5;    // submissions per window
const DUP_WINDOW_MIN  = 2;    // same contact + message from same IP → duplicate
const MIN_FILL_MS     = 2000; // faster than this from page load = bot
const MAX_BODY_BYTES  = 16 * 1024;

const LIMITS = {
  name: 120, contact: 160, location: 160, interest: 80, message: 2000,
  utm: 200, url: 1000, ua: 300, page: 200,
};

/* ---- helpers ---------------------------------------------- */
function originAllowed(origin: string | null): boolean {
  if (!origin) return true; // non-browser callers (curl, tests); CORS is a browser concern
  if (ALLOWED_ORIGINS.has(origin)) return true;
  return ALLOWED_ORIGIN_PATTERNS.some((re) => re.test(origin));
}

function corsHeaders(origin: string | null, allowed: boolean): HeadersInit {
  const h: Record<string, string> = {
    "Content-Type": "application/json; charset=utf-8",
    "Cache-Control": "no-store",
    "Vary": "Origin",
  };
  if (origin && allowed) {
    h["Access-Control-Allow-Origin"] = origin;
    h["Access-Control-Allow-Methods"] = "POST, OPTIONS";
    h["Access-Control-Allow-Headers"] = "Content-Type";
    h["Access-Control-Max-Age"] = "86400";
  }
  return h;
}

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

async function sha256hex(s: string): Promise<string> {
  const buf = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(s));
  return Array.from(new Uint8Array(buf)).map((b) => b.toString(16).padStart(2, "0")).join("");
}

function clientIp(req: Request): string {
  const xff = req.headers.get("x-forwarded-for");
  if (xff) return xff.split(",")[0].trim();
  return req.headers.get("cf-connecting-ip") ?? req.headers.get("x-real-ip") ?? "unknown";
}

function log(event: string, data: Record<string, unknown> = {}): void {
  console.log(JSON.stringify({ fn: "contact", event, ...data }));
}

function escapeHtml(s: string): string {
  return s.replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]!));
}

/* ---- Resend notification (optional) ----------------------- */
type Row = {
  id: string; name: string; contact: string; country: string | null; city: string | null;
  location_raw: string | null; interest: string | null; message: string | null;
  utm_source: string | null; utm_medium: string | null; utm_campaign: string | null;
  referrer: string | null; landing_page: string | null; page: string | null; created_at: string;
};

async function notifyLead(row: Row): Promise<boolean> {
  const key = Deno.env.get("RESEND_API_KEY");
  if (!key) { log("notify_skipped", { id: row.id, reason: "RESEND_API_KEY not configured" }); return false; }

  const where = [row.city, row.country].filter(Boolean).join(", ") || row.location_raw || "—";
  const attribution = [
    row.utm_source && `source: ${row.utm_source}`,
    row.utm_medium && `medium: ${row.utm_medium}`,
    row.utm_campaign && `campaign: ${row.utm_campaign}`,
    row.referrer && `referrer: ${row.referrer}`,
    row.landing_page && `landing: ${row.landing_page}`,
  ].filter(Boolean).join(" · ") || "direct";

  const subject = `New enquiry — ${row.interest ?? "General"} — ${row.name}`;
  const lines = [
    `Name: ${row.name}`,
    `Contact: ${row.contact}`,
    `Where: ${where}`,
    `Interest: ${row.interest ?? "—"}`,
    ``,
    row.message ?? "(no message)",
    ``,
    `Attribution: ${attribution}`,
    `Submitted from: ${row.page ?? "—"} at ${row.created_at}`,
    `Record: ${row.id}`,
  ];
  const html = `<div style="font-family:system-ui,sans-serif;font-size:15px;line-height:1.55;color:#0A0A0B">
    <p style="margin:0 0 14px;font-size:12px;letter-spacing:.08em;text-transform:uppercase;color:#6C6C78">New enquiry · coachgari.com</p>
    <p><b>${escapeHtml(row.name)}</b><br>${escapeHtml(row.contact)}<br>${escapeHtml(where)}</p>
    <p><b>Interest:</b> ${escapeHtml(row.interest ?? "—")}</p>
    <p style="white-space:pre-wrap;border-left:3px solid #1540E8;padding-left:12px">${escapeHtml(row.message ?? "(no message)")}</p>
    <p style="font-size:13px;color:#6C6C78">Attribution: ${escapeHtml(attribution)}<br>From ${escapeHtml(row.page ?? "—")} · ${escapeHtml(row.created_at)}<br>Record ${row.id}</p>
  </div>`;

  const payload: Record<string, unknown> = {
    from: MAIL_FROM, to: [LEAD_TO], subject, text: lines.join("\n"), html,
    headers: { "X-Entity-Ref-ID": row.id },
  };
  if (isEmail(row.contact)) payload.reply_to = row.contact;

  try {
    const res = await fetch("https://api.resend.com/emails", {
      method: "POST",
      headers: { Authorization: `Bearer ${key}`, "Content-Type": "application/json" },
      body: JSON.stringify(payload),
    });
    if (!res.ok) { log("notify_failed", { id: row.id, status: res.status }); return false; }
    log("notify_sent", { id: row.id });
    return true;
  } catch (e) {
    log("notify_error", { id: row.id, error: (e as Error).message });
    return false;
  }
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
  const ipHash = await sha256hex(IP_SALT + clientIp(req));

  const supabase = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
    { auth: { persistSession: false } },
  );

  // Rate limit per IP hash
  const since = new Date(Date.now() - RATE_WINDOW_MIN * 60_000).toISOString();
  const { count: recent, error: rlErr } = await supabase
    .from("contacts").select("id", { count: "exact", head: true })
    .eq("ip_hash", ipHash).gte("created_at", since);
  if (rlErr) log("rate_limit_query_failed", { code: rlErr.code });
  if ((recent ?? 0) >= RATE_MAX) {
    log("rate_limited", { submission_id: submissionId });
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
    .select("id, name, contact, country, city, location_raw, interest, message, utm_source, utm_medium, utm_campaign, referrer, landing_page, page, created_at")
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

  const notified = await notifyLead(inserted as Row);
  if (notified) {
    await supabase.from("contacts").update({ notified_at: new Date().toISOString() }).eq("id", inserted.id);
  }

  return json(200, { ok: true, id: inserted.id, notified }, origin, allowed);
});

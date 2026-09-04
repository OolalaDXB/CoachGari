/* =============================================================
   CG-002 — booking
   Public Edge Function in front of the booking RPCs.

   GET  ?action=services      — the public catalogue (active + listed), the only
                                source of the Route C cards and the picker (CG-007)
   GET  ?action=tour_stops
   GET  ?action=slots&service=<slug>&from=YYYY-MM-DD&to=YYYY-MM-DD&tz=<IANA>
   GET  ?action=state&ref=<CG-XXXXXX>&token=<manage_token>
   POST {action:"hold", service, start_at, participants?, idempotency_key,
         name, contact, tour_stop?, notes?}
   POST {action:"cancel", ref, token, reason?}

   All business rules live in PostgreSQL (available_slots, create_hold,
   cancel_booking …). This layer does CORS, shape validation, rate
   limiting and PII-free logging. Secrets: none in code — the platform
   injects SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY.
   ============================================================= */
import { createClient } from "npm:@supabase/supabase-js@2";

const ALLOWED_ORIGINS = new Set(["https://coachgari.com", "https://www.coachgari.com"]);
const ALLOWED_ORIGIN_PATTERNS: RegExp[] = [
  /^https:\/\/[a-z0-9-]+\.vercel\.app$/i,
  /^http:\/\/localhost(:\d+)?$/i,
  /^http:\/\/127\.0\.0\.1(:\d+)?$/i,
];
const IP_SALT = Deno.env.get("IP_HASH_SALT") ?? "coachgari-cg001";
const HOLD_RATE_WINDOW_MIN = 10;
const HOLD_RATE_MAX = 10;
const MAX_BODY_BYTES = 8 * 1024;

function originAllowed(o: string | null) {
  if (!o) return true;
  return ALLOWED_ORIGINS.has(o) || ALLOWED_ORIGIN_PATTERNS.some((r) => r.test(o));
}
function cors(origin: string | null, allowed: boolean): HeadersInit {
  const h: Record<string, string> = {
    "Content-Type": "application/json; charset=utf-8", "Cache-Control": "no-store", "Vary": "Origin",
  };
  if (origin && allowed) {
    h["Access-Control-Allow-Origin"] = origin;
    h["Access-Control-Allow-Methods"] = "GET, POST, OPTIONS";
    h["Access-Control-Allow-Headers"] = "Content-Type";
    h["Access-Control-Max-Age"] = "86400";
  }
  return h;
}
const json = (status: number, body: unknown, origin: string | null, allowed: boolean) =>
  new Response(JSON.stringify(body), { status, headers: cors(origin, allowed) });

function str(v: unknown, max: number): string | null {
  if (typeof v !== "string") return null;
  const s = v.replace(/\s+/g, " ").trim();
  return s ? s.slice(0, max) : null;
}
const isEmail = (s: string) => /^[^\s@]+@[^\s@]+\.[^\s@]{2,}$/.test(s);
const looksLikePhone = (s: string) => (s.match(/\d/g) ?? []).length >= 7;
const isUuid = (s: unknown): s is string =>
  typeof s === "string" && /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(s);
const isDate = (s: unknown): s is string => typeof s === "string" && /^\d{4}-\d{2}-\d{2}$/.test(s);
const isSlug = (s: unknown): s is string => typeof s === "string" && /^[a-z0-9-]{2,80}$/.test(s);
const isTz = (s: unknown): s is string => typeof s === "string" && /^[A-Za-z_]+(\/[A-Za-z0-9_+-]+){0,2}$|^UTC$/.test(s);

async function sha256hex(s: string) {
  const buf = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(s));
  return Array.from(new Uint8Array(buf)).map((b) => b.toString(16).padStart(2, "0")).join("");
}
function clientIp(req: Request) {
  const xff = req.headers.get("x-forwarded-for");
  if (xff) return xff.split(",")[0].trim();
  return req.headers.get("cf-connecting-ip") ?? req.headers.get("x-real-ip") ?? "unknown";
}
const log = (event: string, data: Record<string, unknown> = {}) =>
  console.log(JSON.stringify({ fn: "booking", event, ...data }));

// Map PostgreSQL error codes raised by the RPCs to HTTP.
function rpcError(e: { code?: string; message?: string }, origin: string | null, allowed: boolean) {
  const msg = e.message ?? "error";
  if (e.code === "P0002") return json(404, { ok: false, error: "not_found", message: msg }, origin, allowed);
  if (e.code === "P0003") return json(409, { ok: false, error: "conflict", message: msg }, origin, allowed);
  if (e.code === "22023") return json(400, { ok: false, error: "validation", message: msg }, origin, allowed);
  log("rpc_failed", { code: e.code, message: (e.message ?? "").slice(0, 160) });
  return json(500, { ok: false, error: "server_error", code: e.code ?? null }, origin, allowed);
}

/* Credential: the platform-injected SUPABASE_SERVICE_ROLE_KEY, a static
   string passed to createClient as the apikey and as the Bearer token for
   every PostgREST request. No session, no refresh, no token cache: a new
   client carries the same credential. Diagnostics below log only the
   token's public claims (role / iat / exp), never the token. */
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
function keyClaims() {
  try {
    const parts = SERVICE_KEY.split(".");
    if (parts.length !== 3) return { kind: SERVICE_KEY.startsWith("sb_secret_") ? "sb_secret" : "opaque", jwt: false };
    const payload = JSON.parse(atob(parts[1].replace(/-/g, "+").replace(/_/g, "/")));
    return { kind: "jwt", jwt: true, role: payload.role, iss: payload.iss, iat: payload.iat, exp: payload.exp, now: Math.floor(Date.now() / 1000) };
  } catch { return { kind: "unparseable", jwt: false }; }
}
log("boot", { credential: keyClaims() });

const db = () => createClient(Deno.env.get("SUPABASE_URL")!, SERVICE_KEY, {
  auth: { persistSession: false },
});

/* Transient PostgREST failures (PGRST303 "JWT expired / not yet valid" seen
   intermittently on the first request after a cold boot — cause not
   established, see docs/DECISIONS.md — PGRST301, connection errors) are
   retried up to twice before surfacing a 500. The retry re-sends the same
   static credential; it only helps because the failure is transient on the
   gateway/PostgREST side. Business errors (P0002/P0003/22023) never retry. */
const TRANSIENT = new Set(["PGRST301", "PGRST303", "PGRST000", "PGRST001", "PGRST002"]);
type DbResult<T> = { data: T | null; error: { code?: string; message?: string } | null };
async function withRetry<T>(label: string, run: (c: ReturnType<typeof db>) => PromiseLike<DbResult<T>>): Promise<DbResult<T>> {
  let last: DbResult<T> = { data: null, error: { message: "no attempt" } };
  for (let attempt = 1; attempt <= 3; attempt++) {
    try { last = await run(db()); }
    catch (e) { last = { data: null, error: { code: "FETCH", message: (e as Error).message } }; }
    const code = last.error?.code ?? "";
    if (!last.error || !(TRANSIENT.has(code) || code === "FETCH")) return last;
    log("transient_retry", { label, code, attempt, message: (last.error?.message ?? "").slice(0, 160), isolate_time: new Date().toISOString(), credential: keyClaims() });
    await new Promise((r) => setTimeout(r, 150 * attempt));
  }
  return last;
}


Deno.serve(async (req: Request) => {
  const origin = req.headers.get("origin");
  const allowed = originAllowed(origin);
  if (req.method === "OPTIONS") return new Response(null, { status: allowed ? 204 : 403, headers: cors(origin, allowed) });
  if (!allowed) { log("origin_rejected"); return json(403, { ok: false, error: "origin_not_allowed" }, origin, false); }

  const url = new URL(req.url);
  const supabase = db();

  /* ---------------- GET ---------------- */
  if (req.method === "GET") {
    const action = url.searchParams.get("action");

    if (action === "services") {
      const { data, error } = await withRetry("services", (c) => c.from("services")
        .select("slug, title, category, tagline, description, long_description, duration_minutes, price_amount, currency, price_unit, delivery_mode, default_capacity, booking_mode, features, featured, cta_label, sort_order")
        .eq("active", true).eq("listed", true).order("sort_order"));
      if (error) return rpcError(error, origin, allowed);
      return json(200, { ok: true, services: data }, origin, allowed);
    }

    if (action === "tour_stops") {
      const { data, error } = await withRetry("tour_stops", (c) => c.from("tour_stops")
        .select("slug, city, country, timezone, start_at, end_at, booking_opens_at, booking_closes_at, venue, location_notes, tour_stop_services(services(slug))")
        .eq("status", "open").gte("end_at", new Date().toISOString()).order("start_at"));
      if (error) return rpcError(error, origin, allowed);
      const stops = (data ?? []).map((t: Record<string, unknown>) => ({
        ...t,
        services: ((t.tour_stop_services as { services: { slug: string } }[]) ?? []).map((x) => x.services?.slug).filter(Boolean),
        tour_stop_services: undefined,
      }));
      return json(200, { ok: true, tour_stops: stops }, origin, allowed);
    }

    if (action === "slots") {
      const service = url.searchParams.get("service"), from = url.searchParams.get("from"),
            to = url.searchParams.get("to"), tz = url.searchParams.get("tz") ?? "UTC";
      if (!isSlug(service) || !isDate(from) || !isDate(to) || !isTz(tz)) {
        return json(400, { ok: false, error: "validation", fields: ["service", "from", "to", "tz"] }, origin, allowed);
      }
      const { data, error } = await withRetry("slots", (c) => c.rpc("available_slots", { p_service_slug: service, p_from: from, p_to: to, p_tz: tz }));
      if (error) return rpcError(error, origin, allowed);
      return json(200, { ok: true, service, tz, slots: data }, origin, allowed);
    }

    if (action === "state") {
      const ref = url.searchParams.get("ref"), token = url.searchParams.get("token");
      if (!ref || !token) return json(400, { ok: false, error: "validation", fields: ["ref", "token"] }, origin, allowed);
      const { data, error } = await withRetry("state", (c) => c.rpc("get_booking", { p_reference: ref, p_manage_token: token }));
      if (error) return rpcError(error, origin, allowed);
      return json(200, { ok: true, booking: data }, origin, allowed);
    }

    return json(400, { ok: false, error: "unknown_action" }, origin, allowed);
  }

  /* ---------------- POST --------------- */
  if (req.method !== "POST") return json(405, { ok: false, error: "method_not_allowed" }, origin, allowed);
  const raw = await req.text();
  if (raw.length > MAX_BODY_BYTES) return json(413, { ok: false, error: "payload_too_large" }, origin, allowed);
  let body: Record<string, unknown>;
  try { body = JSON.parse(raw); } catch { return json(400, { ok: false, error: "invalid_json" }, origin, allowed); }
  if (!body || typeof body !== "object") return json(400, { ok: false, error: "invalid_json" }, origin, allowed);

  if (body.action === "hold") {
    // Shape validation only — price, duration, capacity, availability are decided by the database.
    const fields: string[] = [];
    const service = isSlug(body.service) ? body.service : null; if (!service) fields.push("service");
    const startAt = typeof body.start_at === "string" && !Number.isNaN(Date.parse(body.start_at)) ? new Date(body.start_at).toISOString() : null;
    if (!startAt) fields.push("start_at");
    const key = isUuid(body.idempotency_key) ? body.idempotency_key : null; if (!key) fields.push("idempotency_key");
    const name = str(body.name, 120); if (!name) fields.push("name");
    const contact = str(body.contact, 160); if (!contact || !(isEmail(contact) || looksLikePhone(contact))) fields.push("contact");
    const participants = body.participants === undefined ? 1 : Number(body.participants);
    if (!Number.isInteger(participants) || participants < 1 || participants > 100) fields.push("participants");
    const tourStop = body.tour_stop === undefined || body.tour_stop === null || body.tour_stop === "" ? null
                   : (isSlug(body.tour_stop) ? body.tour_stop : (fields.push("tour_stop"), null));
    const notes = str(body.notes, 500);
    if (fields.length) return json(400, { ok: false, error: "validation", fields }, origin, allowed);

    const ipHash = await sha256hex(IP_SALT + clientIp(req));
    const since = new Date(Date.now() - HOLD_RATE_WINDOW_MIN * 60_000).toISOString();
    const { count } = await supabase.from("bookings").select("id", { count: "exact", head: true })
      .eq("ip_hash", ipHash).gte("created_at", since);
    if ((count ?? 0) >= HOLD_RATE_MAX) { log("rate_limited"); return json(429, { ok: false, error: "rate_limited" }, origin, allowed); }

    const { data, error } = await supabase.rpc("create_hold", {
      p_service_slug: service, p_start_at: startAt, p_participants: participants, p_idempotency_key: key,
      p_customer_name: name, p_customer_contact: contact, p_tour_stop_slug: tourStop, p_notes: notes, p_ip_hash: ipHash,
    });
    if (error) return rpcError(error, origin, allowed);
    log("hold", { reference: data?.reference, service, tour: !!tourStop, participants });
    return json(200, { ok: true, booking: data }, origin, allowed);
  }

  if (body.action === "cancel") {
    const ref = str(body.ref, 20), token = str(body.token, 80), reason = str(body.reason, 300);
    if (!ref || !token) return json(400, { ok: false, error: "validation", fields: ["ref", "token"] }, origin, allowed);
    const { data, error } = await supabase.rpc("cancel_booking", { p_reference: ref, p_manage_token: token, p_reason: reason });
    if (error) return rpcError(error, origin, allowed);
    log("cancelled", { reference: ref });
    return json(200, { ok: true, booking: data }, origin, allowed);
  }

  return json(400, { ok: false, error: "unknown_action" }, origin, allowed);
});

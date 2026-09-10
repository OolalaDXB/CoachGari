/* =============================================================
   Coach Gari — Collaborations
     POST {action:"intake", ...}                      public brand / partnership enquiry
          → {ok, public_ref, token}                    creates a deal + a private room
     POST {action:"room",   token}                    the private deal room (no admin internals)
          → {ok, ...deal}                              latest proposal, history, considerations, payments
     POST {action:"counter",token, ...}               counterparty counter-offer → new immutable version
     POST {action:"accept", token, version}           explicit acceptance → freezes that version
     POST {action:"decline",token, reason?}
     POST {action:"pay",    token, country}           start embedded card checkout for the requested payment
          → {ok, ui:"embedded", client_secret, publishable_key, expires_at, reference, amount, currency}
   The room polls action:"room" after checkout; payment status is read live
   from the order (order_status), never cached-only.
   The private room is reached only with the 256-bit token; an invalid or
   revoked token reveals nothing. Monetary and non-cash consideration stay
   separate — non-cash is never a payment. Only the verified Stripe webhook
   moves a payment to paid. No proposal amount or PII reaches analytics.
   ============================================================= */
import { createClient } from "npm:@supabase/supabase-js@2.116.0";
import { stripe } from "../../../beau-ph/providers/stripe/adapter.ts";
import { originAllowed, corsHeaders as cors } from "../_shared/cors.ts";
import { xffHops, saltedIpHash } from "../_shared/client-ip.ts";

const env = (name: string) => Deno.env.get(name);
const SITE_URL = (env("SITE_URL") ?? "https://coachgari28.com").replace(/\/$/, "");
const json = (status: number, body: unknown, origin: string | null, allowed: boolean) => new Response(JSON.stringify(body), { status, headers: cors(origin, allowed) });
const log = (event: string, data: Record<string, unknown> = {}) => console.log(JSON.stringify({ fn: "collab", event, ...data }));
const SECRET_VALUE_RE = /(sk|rk)_(live|test)_[A-Za-z0-9]{8,}|whsec_[A-Za-z0-9]{8,}/;
const isToken = (s: unknown): s is string => typeof s === "string" && /^[0-9a-f]{64}$/.test(s);

const GLOBAL_WINDOW_MIN = 10;   // intake back-stop, all callers (identity-independent)
const GLOBAL_MAX = 60;          // raised: the per-IP quota below is now the first line, this is the wall
const IP_WINDOW_MIN = 10;       // per-IP intake quota (fail-closed: no salt -> no identity -> global only)
const IP_MAX = 5;               // a real sender submits once; 5 in 10 min is already generous
const MIN_FILL_MS = 2000;
const MAX_BODY_BYTES = 32 * 1024;   // a room holds a negotiation, not a payload store
const MAX_CONSIDERATIONS = 20;
const TERM_KEYS = ["deliverables", "timing", "usage_rights", "exclusivity", "territory", "payment_terms", "additional"];
const str = (v: unknown, max: number) => (typeof v === "string" ? v.replace(/\s+/g, " ").trim().slice(0, max) || null : null);
const text = (v: unknown, max: number) => (typeof v === "string" ? v.replace(/\r\n/g, "\n").trim().slice(0, max) || null : null);
const isEmail = (s: string) => /^[^\s@]+@[^\s@]+\.[^\s@]{2,}$/.test(s);
const looksLikePhone = (s: string) => (s.match(/\d/g) ?? []).length >= 7;

function rpcHttp(error: { code?: string; message?: string }, origin: string | null, allowed: boolean) {
  if (error.code === "P0002") return json(404, { ok: false, error: "not_found", message: "This link is not valid." }, origin, allowed);
  if (error.code === "P0003") return json(410, { ok: false, error: "unavailable", message: error.message || "This is no longer available." }, origin, allowed);
  if (error.code === "22023") return json(400, { ok: false, error: "validation", message: error.message }, origin, allowed);
  log("rpc_failed", { code: error.code }); return json(500, { ok: false, error: "server_error" }, origin, allowed);
}

Deno.serve(async (req: Request) => {
  const origin = req.headers.get("origin"); const allowed = originAllowed(origin);
  if (req.method === "OPTIONS") return new Response(null, { status: allowed ? 204 : 403, headers: cors(origin, allowed) });
  if (!allowed) { log("origin_rejected"); return json(403, { ok: false, error: "origin_not_allowed" }, origin, false); }
  if (req.method !== "POST") return json(405, { ok: false, error: "method_not_allowed" }, origin, allowed);

  // Bound the body before parsing it: an unbounded JSON.parse is the cheapest way to burn a worker.
  if (Number(req.headers.get("content-length") ?? 0) > MAX_BODY_BYTES) return json(413, { ok: false, error: "payload_too_large" }, origin, allowed);
  const raw = await req.text();
  if (raw.length > MAX_BODY_BYTES) return json(413, { ok: false, error: "payload_too_large" }, origin, allowed);

  let body: Record<string, unknown>;
  try { body = JSON.parse(raw); } catch { return json(400, { ok: false, error: "invalid_json" }, origin, allowed); }
  const sb = createClient(env("SUPABASE_URL")!, env("SUPABASE_SERVICE_ROLE_KEY")!, { auth: { persistSession: false } });
  const action = body.action;

  /* ---------- public intake ---------- */
  if (action === "intake") {
    // honeypot + minimum fill time (bots answer instantly / fill the hidden field)
    if (typeof body.website === "string" && body.website.trim() !== "") { log("honeypot"); return json(200, { ok: true }, origin, allowed); }
    const ts = Number(body.ts); if (Number.isFinite(ts) && Date.now() - ts < MIN_FILL_MS) { log("too_fast"); return json(200, { ok: true }, origin, allowed); }
    /* Per-IP quota first (the identity a real sender has), then the identity-independent
       back-stop that a caller rotating its X-Forwarded-For still hits. Fail-closed: with no
       IP_HASH_SALT there is no identity, the per-IP check is skipped and the global wall stands. */
    const ipHash = await saltedIpHash(req, "IP_HASH_SALT", () => log("ip_salt_missing"));
    if (ipHash) {
      const iSince = new Date(Date.now() - IP_WINDOW_MIN * 60_000).toISOString();
      const { count: iCount } = await sb.from("collaboration_deals").select("id", { count: "exact", head: true })
        .eq("ip_hash", ipHash).gte("created_at", iSince);
      if ((iCount ?? 0) >= IP_MAX) { log("rate_limited_ip", { window_min: IP_WINDOW_MIN, xff_hops: xffHops(req) }); return json(429, { ok: false, error: "rate_limited", message: "Please try again shortly." }, origin, allowed); }
    }
    const gSince = new Date(Date.now() - GLOBAL_WINDOW_MIN * 60_000).toISOString();
    const { count: gCount } = await sb.from("collaboration_deals").select("id", { count: "exact", head: true }).gte("created_at", gSince);
    if ((gCount ?? 0) >= GLOBAL_MAX) { log("rate_limited_global", { window_min: GLOBAL_WINDOW_MIN, xff_hops: xffHops(req) }); return json(429, { ok: false, error: "rate_limited", message: "Please try again shortly." }, origin, allowed); }

    const name = str(body.name, 120);
    const email = str(body.email, 160);
    const phone = str(body.phone, 60);
    if (!name) return json(400, { ok: false, error: "validation", fields: ["name"] }, origin, allowed);
    if (!(email && isEmail(email)) && !(phone && looksLikePhone(phone))) return json(400, { ok: false, error: "validation", fields: ["email"], message: "Add an email or phone so we can reply." }, origin, allowed);
    const payload = {
      name, company: str(body.company, 160), email: email && isEmail(email) ? email : null,
      phone: phone && looksLikePhone(phone) ? phone : null, url: str(body.url, 300),
      type: str(body.type, 40), title: str(body.title, 200), initial_request: text(body.initial_request, 4000),
      date_from: str(body.date_from, 10), date_to: str(body.date_to, 10), location: str(body.location, 200),
      budget_amount: Number.isInteger(body.budget_amount) && Number(body.budget_amount) >= 0 ? Number(body.budget_amount) : null,
      budget_currency: typeof body.budget_currency === "string" && /^[A-Za-z]{3}$/.test(body.budget_currency) ? body.budget_currency.toUpperCase() : null,
      offer: text(body.offer, 2000),
      ip_hash: ipHash,   // salted hash only; the raw IP never leaves this function
    };
    const { data, error } = await sb.rpc("collab_intake", { p: payload });
    if (error) return rpcHttp(error, origin, allowed);
    log("intake", { public_ref: (data as Record<string, unknown>).public_ref, xff_hops: xffHops(req) });
    return json(200, { ok: true, public_ref: (data as Record<string, unknown>).public_ref, token: (data as Record<string, unknown>).token }, origin, allowed);
  }

  /* ---------- everything else is token-gated ---------- */
  if (!isToken(body.token)) return json(400, { ok: false, error: "validation", fields: ["token"] }, origin, allowed);
  const token = String(body.token);

  if (action === "room") {
    const { data, error } = await sb.rpc("collab_room", { p_token: token });
    if (error) return rpcHttp(error, origin, allowed);
    if (SECRET_VALUE_RE.test(JSON.stringify(data))) { log("public_guard_tripped"); return json(500, { ok: false, error: "server_error" }, origin, allowed); }
    return json(200, data, origin, allowed);
  }

  if (action === "counter") {
    const p = {
      intro: text(body.intro, 4000),
      monetary_amount: Number.isInteger(body.monetary_amount) && Number(body.monetary_amount) >= 0 ? Number(body.monetary_amount) : null,
      currency: typeof body.currency === "string" && /^[A-Za-z]{3}$/.test(body.currency) ? body.currency.toUpperCase() : null,
      // bounded and shaped: a capped number of considerations, each field trimmed, and only
      // the known term keys. The same caps are enforced again in collab_counter.
      considerations: (Array.isArray(body.considerations) ? body.considerations : []).slice(0, MAX_CONSIDERATIONS)
        .filter((c: unknown) => c && typeof c === "object")
        .map((c: Record<string, unknown>) => ({
          type: c.type === "monetary" ? "monetary" : "non_cash",
          description: str(c.description, 200),
          amount: Number.isInteger(c.amount) && Number(c.amount) >= 0 ? Number(c.amount) : null,
          currency: typeof c.currency === "string" && /^[A-Za-z]{3}$/.test(c.currency) ? c.currency.toUpperCase() : null,
        })),
      terms: Object.fromEntries(TERM_KEYS
        .map((k) => [k, text((body.terms as Record<string, unknown> | undefined)?.[k], 2000)])
        .filter(([, v]) => v !== null)),
    };
    const { data, error } = await sb.rpc("collab_counter", { p_token: token, p });
    if (error) return rpcHttp(error, origin, allowed);
    log("counter", { version: (data as Record<string, unknown>).version });
    return json(200, data, origin, allowed);
  }

  if (action === "accept") {
    const version = Number.isInteger(body.version) ? Number(body.version) : NaN;
    if (!Number.isFinite(version)) return json(400, { ok: false, error: "validation", fields: ["version"] }, origin, allowed);
    // Fail-closed salted IP hash for acceptance evidence (null when CONSENT_IP_SALT is unset).
    const evidence = {
      method: "room_link",
      ip_hash: await saltedIpHash(req, "CONSENT_IP_SALT", () => log("consent_ip_salt_missing")),
      user_agent: (req.headers.get("user-agent") || "").slice(0, 200) || null,
    };
    const { data, error } = await sb.rpc("collab_accept", { p_token: token, p_version: version, p_evidence: evidence });
    if (error) return rpcHttp(error, origin, allowed);
    log("accepted", { version });
    return json(200, data, origin, allowed);
  }

  if (action === "decline") {
    const { data, error } = await sb.rpc("collab_decline", { p_token: token, p_reason: text(body.reason, 300) });
    if (error) return rpcHttp(error, origin, allowed);
    log("declined");
    return json(200, data, origin, allowed);
  }

  if (action === "pay") {
    const country = typeof body.country === "string" && /^[A-Za-z]{2}$/.test(body.country) ? body.country.toUpperCase() : "";
    if (!country) return json(400, { ok: false, error: "validation", fields: ["country"], message: "Choose your country." }, origin, allowed);
    const rt = stripe.runtime(env); const runtime = { stripe: rt };
    if (!rt.configured || !rt.embedded) { log("not_configured", { mode: rt.mode ?? null }); return json(503, { ok: false, error: "payments_not_configured" }, origin, allowed); }
    const { data, error } = await sb.rpc("collab_pay_start", { p_token: token, p_country: country, p_runtime: runtime });
    if (error) return rpcHttp(error, origin, allowed);
    const { request, order } = data as { request: Record<string, unknown>; order: Record<string, unknown> };
    const created = await stripe.createPaymentRequest!({
      requestId: String(request.id), publicReference: String(request.public_reference), externalReference: String(request.external_reference),
      amount: Number(request.amount), currency: String(request.currency),           // trusted DB row, never the body
      description: `Collaboration (${request.public_reference})`,
      customerEmail: undefined,
      uiMode: "embedded", hostApp: "coach_gari", merchantKey: "coach_gari",
      returnUrls: { success: `${SITE_URL}/c/${token}?paid=1&session_id={CHECKOUT_SESSION_ID}`, cancel: `${SITE_URL}/c/${token}?cancelled=1` },
      attempt: 1,
    }, env);
    if (created.kind !== "embedded") { log("stripe_failed", { reason: created.kind === "unavailable" ? created.reason : created.kind }); return json(502, { ok: false, error: "payment_provider_error" }, origin, allowed); }
    const { error: aErr } = await sb.rpc("attach_checkout", { p_order_reference: order.reference, p_session_id: created.providerReference, p_url: null, p_expires_at: created.expiresAt });
    if (aErr) { log("attach_failed", { code: aErr.code }); return json(409, { ok: false, error: "conflict" }, origin, allowed); }
    const reply = { ok: true, ui: "embedded", client_secret: created.clientSecret, publishable_key: created.publicConfig.publishable_key, expires_at: created.expiresAt,
                    reference: order.reference, amount: request.amount, currency: request.currency };
    if (SECRET_VALUE_RE.test(JSON.stringify({ ...reply, client_secret: "" }))) { log("public_guard_tripped"); return json(500, { ok: false, error: "server_error" }, origin, allowed); }
    log("pay_session", { reference: order.reference, public_reference: request.public_reference, amount: request.amount, currency: request.currency, mode: rt.mode });
    return json(200, reply, origin, allowed);
  }

  return json(400, { ok: false, error: "validation", fields: ["action"] }, origin, allowed);
});

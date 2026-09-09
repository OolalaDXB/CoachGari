/* =============================================================
   Support Coach Gari — a generic BEAU PH payment (intent "support")
     POST {action:"create", amount, currency, message?}
          → {ok, ui:"embedded", client_secret, publishable_key, expires_at, reference, token, amount, currency}
            The browser PROPOSES an amount; support_create() validates the
            merchant, the intent, the currency BEAU PH can offer, the floor /
            ceiling and the rail before creating the order + BEAU PH request.
            The Checkout Session is created from the DB row, never the body.
     POST {action:"state", reference, token}
          → {ok, support:{reference, status, amount, currency, paid_at}}
            Only the verified Stripe webhook moves this to paid.
   Not a booking, not a package: nothing here can confirm a session or
   consume a credit. No name, contact, note or health data reaches Stripe —
   the description carries the public reference only.
   ============================================================= */
import { createClient } from "npm:@supabase/supabase-js@2";
import { stripe } from "../../../beau-ph/providers/stripe/adapter.ts";
import { originAllowed, corsHeaders as cors } from "../_shared/cors.ts";

const env = (name: string) => Deno.env.get(name);
const SITE_URL = (env("SITE_URL") ?? "https://coachgari28.com").replace(/\/$/, "");
const json = (status: number, body: unknown, origin: string | null, allowed: boolean) => new Response(JSON.stringify(body), { status, headers: cors(origin, allowed) });
const log = (event: string, data: Record<string, unknown> = {}) => console.log(JSON.stringify({ fn: "support", event, ...data }));
const SECRET_VALUE_RE = /(sk|rk)_(live|test)_[A-Za-z0-9]{8,}|whsec_[A-Za-z0-9]{8,}/;

Deno.serve(async (req: Request) => {
  const origin = req.headers.get("origin"); const allowed = originAllowed(origin);
  if (req.method === "OPTIONS") return new Response(null, { status: allowed ? 204 : 403, headers: cors(origin, allowed) });
  if (!allowed) return json(403, { ok: false, error: "origin_not_allowed" }, origin, false);
  if (req.method !== "POST") return json(405, { ok: false, error: "method_not_allowed" }, origin, allowed);

  let body: Record<string, unknown>;
  try { body = JSON.parse(await req.text()); } catch { return json(400, { ok: false, error: "invalid_json" }, origin, allowed); }
  const sb = createClient(env("SUPABASE_URL")!, env("SUPABASE_SERVICE_ROLE_KEY")!, { auth: { persistSession: false } });

  if (body.action === "state") {
    const reference = typeof body.reference === "string" ? body.reference.slice(0, 20) : "";
    const token = typeof body.token === "string" && /^[0-9a-f]{64}$/.test(body.token) ? body.token : "";
    if (!reference || !token) return json(400, { ok: false, error: "validation", fields: ["reference", "token"] }, origin, allowed);
    const { data, error } = await sb.rpc("support_state", { p_reference: reference, p_token: token });
    if (error) return json(error.code === "P0002" ? 404 : 500, { ok: false, error: error.code === "P0002" ? "not_found" : "server_error" }, origin, allowed);
    return json(200, { ok: true, support: data }, origin, allowed);
  }

  if (body.action === "create") {
    const rt = stripe.runtime(env);
    if (!rt.configured || !rt.embedded) { log("not_configured", { mode: rt.mode ?? null, reason: rt.reason ?? null }); return json(503, { ok: false, error: "payments_not_configured" }, origin, allowed); }
    const amount = Number.isInteger(body.amount) ? Number(body.amount) : NaN;
    const currency = typeof body.currency === "string" && /^[A-Za-z]{3}$/.test(body.currency) ? body.currency.toUpperCase() : "";
    const message = typeof body.message === "string" ? body.message.slice(0, 500) : "";
    if (!(amount > 0) || !currency) return json(400, { ok: false, error: "validation", fields: ["amount", "currency"], message: "Choose an amount." }, origin, allowed);

    const runtime = { stripe: rt };   // presence + mode, never a value
    const { data, error } = await sb.rpc("support_create", { p_amount: amount, p_currency: currency, p_message: message, p_runtime: runtime });
    if (error) {
      if (error.code === "22023") return json(400, { ok: false, error: "validation", message: error.message }, origin, allowed);
      if (error.code === "P0003") return json(409, { ok: false, error: "unavailable", message: error.message }, origin, allowed);
      log("rpc_failed", { code: error.code }); return json(500, { ok: false, error: "server_error" }, origin, allowed);
    }
    const { request, order, token } = data as { request: Record<string, unknown>; order: Record<string, unknown>; token: string };
    const created = await stripe.createPaymentRequest!({
      requestId: String(request.id), publicReference: String(request.public_reference), externalReference: String(request.external_reference),
      amount: Number(request.amount), currency: String(request.currency),           // trusted: the validated DB row, never the body
      description: `Support Coach Gari (${request.public_reference})`,
      customerEmail: undefined,
      uiMode: "embedded", hostApp: "coach_gari", merchantKey: "coach_gari",
      returnUrls: { success: `${SITE_URL}/?support=${order.reference}&t=${token}&paid=1&session_id={CHECKOUT_SESSION_ID}`, cancel: `${SITE_URL}/?support=${order.reference}&t=${token}&cancelled=1` },
      attempt: 1,
    }, env);
    if (created.kind !== "embedded") { log("stripe_failed", { reason: created.kind === "unavailable" ? created.reason : created.kind }); return json(502, { ok: false, error: "payment_provider_error" }, origin, allowed); }
    const { error: aErr } = await sb.rpc("attach_checkout", { p_order_reference: order.reference, p_session_id: created.providerReference, p_url: null, p_expires_at: created.expiresAt });
    if (aErr) { log("attach_failed", { code: aErr.code }); return json(409, { ok: false, error: "conflict" }, origin, allowed); }
    const reply = { ok: true, ui: "embedded", client_secret: created.clientSecret, publishable_key: created.publicConfig.publishable_key, expires_at: created.expiresAt,
                    reference: order.reference, token, amount: request.amount, currency: request.currency };
    if (SECRET_VALUE_RE.test(JSON.stringify({ ...reply, client_secret: "" }))) { log("public_guard_tripped"); return json(500, { ok: false, error: "server_error" }, origin, allowed); }
    log("session_created", { reference: order.reference, public_reference: request.public_reference, amount: request.amount, currency: request.currency, mode: rt.mode });
    return json(200, reply, origin, allowed);
  }

  return json(400, { ok: false, error: "validation", fields: ["action"] }, origin, allowed);
});

/* =============================================================
   A payment link the coach issued — label, amount, one URL.

     POST {action:"open", reference, token, country?}
          → {ok, state:"payable", label, amount, currency, reference,
             ui:"embedded", client_secret, publishable_key, expires_at}
          → {ok, state:"paid"|"expired"|"closed", label, reference, …}
            payment_link_open() decides the state and mints the BEAU PH
            request on the first open. The Checkout Session is built from the
            row it returns, never from the body: the browser cannot name its
            own amount here, which is the whole difference between this and
            the support widget.

     POST {action:"state", reference, token}
          → {ok, link:{state, label, amount, currency, reference, paid_at}}
            Only the verified Stripe webhook moves a link to paid.

   Not a booking, not a package: nothing here can confirm a session or
   consume a credit. Stripe receives the public reference and the label the
   coach wrote — no name, no contact, no CRM content.
   ============================================================= */
import { createClient } from "npm:@supabase/supabase-js@2.116.0";
import { stripe } from "../../../beau-ph/providers/stripe/adapter.ts";
import { originAllowed, corsHeaders as cors } from "../_shared/cors.ts";

const env = (name: string) => Deno.env.get(name);
const SITE_URL = (env("SITE_URL") ?? "https://coachgari28.com").replace(/\/$/, "");
const json = (status: number, body: unknown, origin: string | null, allowed: boolean) =>
  new Response(JSON.stringify(body), { status, headers: cors(origin, allowed) });
const log = (event: string, data: Record<string, unknown> = {}) => console.log(JSON.stringify({ fn: "paylink", event, ...data }));
const SECRET_VALUE_RE = /(sk|rk)_(live|test)_[A-Za-z0-9]{8,}|whsec_[A-Za-z0-9]{8,}/;

const REF_RE = /^PL-[A-Z0-9]{6}$/;
const TOK_RE = /^[0-9a-f]{64}$/;

Deno.serve(async (req: Request) => {
  const origin = req.headers.get("origin"); const allowed = originAllowed(origin);
  if (req.method === "OPTIONS") return new Response(null, { status: allowed ? 204 : 403, headers: cors(origin, allowed) });
  if (!allowed) return json(403, { ok: false, error: "origin_not_allowed" }, origin, false);
  if (req.method !== "POST") return json(405, { ok: false, error: "method_not_allowed" }, origin, allowed);

  let body: Record<string, unknown>;
  try { body = JSON.parse(await req.text()); } catch { return json(400, { ok: false, error: "invalid_json" }, origin, allowed); }

  const reference = typeof body.reference === "string" && REF_RE.test(body.reference) ? body.reference : "";
  const token = typeof body.token === "string" && TOK_RE.test(body.token) ? body.token : "";
  if (!reference || !token) return json(400, { ok: false, error: "validation", fields: ["reference", "token"] }, origin, allowed);

  const sb = createClient(env("SUPABASE_URL")!, env("SUPABASE_SERVICE_ROLE_KEY")!, { auth: { persistSession: false } });

  /* `state` re-reads a link the payer already holds — after a redirect back from
     Stripe, or on a reload. It mints nothing. */
  if (body.action === "state") {
    const { data, error } = await sb.rpc("payment_link_open", { p_reference: reference, p_token: token, p_runtime: {} });
    if (error) return json(error.code === "P0002" ? 404 : 500,
      { ok: false, error: error.code === "P0002" ? "not_found" : "server_error" }, origin, allowed);
    const d = data as Record<string, unknown>;
    return json(200, { ok: true, link: { state: d.state, label: d.label, amount: d.amount, currency: d.currency, reference: d.reference, paid_at: d.paid_at } }, origin, allowed);
  }

  if (body.action !== "open") return json(400, { ok: false, error: "validation", fields: ["action"] }, origin, allowed);

  const rt = stripe.runtime(env);
  if (!rt.configured || !rt.embedded) {
    log("not_configured", { mode: rt.mode ?? null, reason: rt.reason ?? null });
    return json(503, { ok: false, error: "payments_not_configured" }, origin, allowed);
  }

  const { data, error } = await sb.rpc("payment_link_open", { p_reference: reference, p_token: token, p_runtime: { stripe: rt } });
  if (error) {
    if (error.code === "P0002") return json(404, { ok: false, error: "not_found" }, origin, allowed);
    if (error.code === "P0003") return json(409, { ok: false, error: "unavailable", message: error.message }, origin, allowed);
    log("rpc_failed", { code: error.code });
    return json(500, { ok: false, error: "server_error" }, origin, allowed);
  }

  const d = data as Record<string, unknown>;
  // a settled, withdrawn or lapsed link is an answer, not an error
  if (d.state !== "payable") {
    return json(200, { ok: true, state: d.state, label: d.label, amount: d.amount, currency: d.currency, reference: d.reference, paid_at: d.paid_at }, origin, allowed);
  }

  const request = d.request as Record<string, unknown>;

  /* A link is opened more than once — reloaded, re-sent, finished on the phone
     after being started on the laptop. The session already attached to it is
     resumed when Stripe still holds it open; a new one is minted only when it
     does not. Creating one per open would be wrong twice over: it would leave a
     trail of open sessions at Stripe, and — because the Idempotency-Key is built
     from the attempt number — re-sending the same key with a freshly computed
     `expires_at` is exactly what Stripe refuses with 400 idempotency_error. */
  const attached = typeof d.session_id === "string" ? d.session_id : "";
  if (attached) {
    const resumed = await stripe.resumePaymentRequest!(attached, env);
    if (resumed.kind === "embedded") {
      const reply = {
        ok: true, state: "payable", ui: "embedded",
        client_secret: resumed.clientSecret, publishable_key: resumed.publicConfig.publishable_key,
        expires_at: resumed.expiresAt, reference, label: d.label, amount: d.amount, currency: d.currency,
      };
      if (SECRET_VALUE_RE.test(JSON.stringify({ ...reply, client_secret: "" }))) { log("public_guard_tripped"); return json(500, { ok: false, error: "server_error" }, origin, allowed); }
      log("session_resumed", { reference });
      return json(200, reply, origin, allowed);
    }
    log("resume_declined", { reference, reason: resumed.kind === "unavailable" ? resumed.reason : resumed.kind });
  }

  // never a key that has been used before: the attempt counter only ever goes up
  const attempt = Number(d.attempts ?? 0) + 1;
  const created = await stripe.createPaymentRequest!({
    requestId: String(request.id), publicReference: String(request.public_reference), externalReference: String(request.external_reference),
    amount: Number(request.amount), currency: String(request.currency),      // trusted: the validated DB row, never the body
    description: `${String(d.label).slice(0, 80)} (${request.public_reference})`,
    customerEmail: undefined,
    uiMode: "embedded", hostApp: "coach_gari", merchantKey: "coach_gari",
    statementSuffix: undefined,
    returnUrls: {
      success: `${SITE_URL}/pay/${reference}/${token}?paid=1&session_id={CHECKOUT_SESSION_ID}`,
      cancel: `${SITE_URL}/pay/${reference}/${token}?cancelled=1`,
    },
    attempt,
  }, env);
  if (created.kind !== "embedded") {
    log("stripe_failed", { reason: created.kind === "unavailable" ? created.reason : created.kind, attempt });
    return json(502, { ok: false, error: "payment_provider_error" }, origin, allowed);
  }

  /* payment_link_attach, not attach_checkout: the latter writes the Stripe
     session's expiry over checkout_expires_at, which for a link is the validity
     window the coach chose — a 30-day link would lapse with its first session. */
  const { error: aErr } = await sb.rpc("payment_link_attach", { p_reference: reference, p_session_id: created.providerReference });
  if (aErr) { log("attach_failed", { code: aErr.code }); return json(409, { ok: false, error: "conflict" }, origin, allowed); }

  const reply = {
    ok: true, state: "payable", ui: "embedded",
    client_secret: created.clientSecret, publishable_key: created.publicConfig.publishable_key,
    expires_at: created.expiresAt, reference, label: d.label, amount: d.amount, currency: d.currency,
  };
  if (SECRET_VALUE_RE.test(JSON.stringify({ ...reply, client_secret: "" }))) { log("public_guard_tripped"); return json(500, { ok: false, error: "server_error" }, origin, allowed); }
  log("session_created", { reference, amount: d.amount, currency: d.currency, mode: rt.mode });
  return json(200, reply, origin, allowed);
});

/* =============================================================
   CG-003 — checkout  (on BEAU PH since the productisation step)
   POST {ref, token} → held booking → trusted order (amount from the DB) →
   BEAU PH payment request → EMBEDDED Stripe Checkout Session via the Stripe
   adapter → attempt recorded → {client_secret, publishable_key}. The page
   mounts Stripe's surface in place (the customer stays on coachgari28.com).
   Neither the browser's completion callback nor the return URL is
   authoritative: only the signature-verified webhook (stripe-webhook) marks
   anything paid; the page polls the booking state until then.

   Secrets / config (Supabase secrets, never in git):
     PAYMENTS_MODE       — test | live. The adapter refuses a key whose mode
                           differs, and refuses everything when it is unset.
     STRIPE_SECRET_KEY   — sk_test_… under test, sk_live_… under live.
     STRIPE_PUBLISHABLE_KEY — pk_ of the same mode; public, mode-checked.
     SITE_URL            — return origin for the rare redirect flows
                           (default: https://coachgari28.com).
   The browser never supplies an amount; any such field is ignored.
   ============================================================= */
import { createClient } from "npm:@supabase/supabase-js@2";
import { providers, runtimeMap } from "../../../beau-ph/core/registry.ts";
import type { CreateRequestResult } from "../../../beau-ph/contracts/provider.ts";
import { requestForBooking, attachCheckout, siteUrl, HOST_APP, MERCHANT_KEY } from "../../../beau-ph/host-adapters/coach-gari/adapter.ts";
import { originAllowed, corsHeaders as cors } from "../_shared/cors.ts";   // one allowlist for every browser-facing function

const env = (name: string) => Deno.env.get(name);
const SITE_URL = siteUrl(env);   // https://coachgari28.com unless SITE_URL overrides (dev / preview only)

const json = (status: number, body: unknown, origin: string | null, allowed: boolean) => new Response(JSON.stringify(body), { status, headers: cors(origin, allowed) });
const log = (event: string, data: Record<string, unknown> = {}) => console.log(JSON.stringify({ fn: "checkout", event, ...data }));

function rpcError(e: { code?: string; message?: string }, origin: string | null, allowed: boolean) {
  if (e.code === "P0002") return json(404, { ok: false, error: "not_found", message: e.message }, origin, allowed);
  if (e.code === "P0003") return json(409, { ok: false, error: "conflict", message: e.message }, origin, allowed);
  log("rpc_failed", { code: e.code }); return json(500, { ok: false, error: "server_error" }, origin, allowed);
}

Deno.serve(async (req: Request) => {
  const origin = req.headers.get("origin"); const allowed = originAllowed(origin);
  if (req.method === "OPTIONS") return new Response(null, { status: allowed ? 204 : 403, headers: cors(origin, allowed) });
  if (!allowed) return json(403, { ok: false, error: "origin_not_allowed" }, origin, false);
  if (req.method !== "POST") return json(405, { ok: false, error: "method_not_allowed" }, origin, allowed);

  const runtime = runtimeMap(env);
  const rt = runtime.stripe!;
  if (!rt.configured || !rt.embedded) {
    // payment-mode gate: PAYMENTS_MODE unset, a key whose mode differs from it, or no publishable key — refuse, never guess
    log("not_configured", { mode: rt.mode ?? null, reason: rt.reason ?? null, embedded: !!rt.embedded });
    return json(503, { ok: false, error: "payments_not_configured", mode: rt.mode ?? null, reason: rt.reason ?? null }, origin, allowed);
  }

  let body: Record<string, unknown>;
  try { body = JSON.parse(await req.text()); } catch { return json(400, { ok: false, error: "invalid_json" }, origin, allowed); }
  const ref = typeof body.ref === "string" ? body.ref.trim().toUpperCase() : "";
  const token = typeof body.token === "string" ? body.token.trim() : "";
  if (!/^CG-[0-9A-F]{6}$/.test(ref) || !token) return json(400, { ok: false, error: "validation", fields: ["ref", "token"] }, origin, allowed);

  const supabase = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, { auth: { persistSession: false } });

  // held booking → trusted order → BEAU PH request (eligibility + amount enforced server-side)
  const { data: rp, error } = await requestForBooking(supabase, ref, token, "stripe", runtime);
  if (error || !rp) return rpcError(error ?? { code: "P0003", message: "unavailable" }, origin, allowed);
  const { request, order } = rp;

  const reply = (c: Extract<CreateRequestResult, { kind: "embedded" }>, reused: boolean) =>
    json(200, { ok: true, ui: "embedded", client_secret: c.clientSecret, publishable_key: c.publicConfig.publishable_key, expires_at: c.expiresAt, order: order.reference, reused }, origin, allowed);

  // Re-open a still-valid Checkout Session instead of creating a second one.
  const a = request.attempt;
  if (a?.provider_reference && a.expires_at && Date.parse(a.expires_at) - Date.now() > 60_000) {
    const resumed = await providers.stripe.resumePaymentRequest!(a.provider_reference, env);
    if (resumed.kind === "embedded") { log("session_resumed", { order: order.reference, session: resumed.providerReference }); return reply(resumed, true); }
  }

  const bref = order.booking?.reference ?? ref;
  const created = await providers.stripe.createPaymentRequest!({
    requestId: request.id, publicReference: request.public_reference, externalReference: request.external_reference,
    amount: request.amount, currency: request.currency,                                        // trusted, from the DB
    description: `${order.booking?.service_title ?? "Coaching session"} (${bref})`,
    customerEmail: order.customer_contact,
    uiMode: "embedded", hostApp: HOST_APP, merchantKey: MERCHANT_KEY,
    // only reached when Stripe itself must redirect (bank / 3DS flows); the page then polls the booking state
    returnUrls: {
      success: `${SITE_URL}/?booking=${bref}&t=${encodeURIComponent(token)}&paid=1&session_id={CHECKOUT_SESSION_ID}#book`,
      cancel:  `${SITE_URL}/?booking=${bref}&t=${encodeURIComponent(token)}&cancelled=1#book`,
    },
    attempt: (request.attempts ?? 0) + 1,
  }, env);
  if (created.kind !== "embedded") { log("stripe_failed", { reason: created.kind === "unavailable" ? created.reason : created.kind }); return json(502, { ok: false, error: "payment_provider_error" }, origin, allowed); }

  const { error: attachErr } = await attachCheckout(supabase, order.reference, created.providerReference, null, created.expiresAt);
  if (attachErr) return rpcError(attachErr, origin, allowed);

  log("session_created", { order: order.reference, request_id: request.id, session: created.providerReference, mode: rt.mode, ui: "embedded" });
  return reply(created, false);
});

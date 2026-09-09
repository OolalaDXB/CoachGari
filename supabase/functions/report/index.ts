/* =============================================================
   CG-012 — report  (on BEAU PH since the productisation step)
   Serves the secure client session-recap / payment page (/r/<token>).
     POST {action:"view",     token, currency?}
          → {ok, recap, pay_ref, currency, methods[], card_enabled, aani, bank,
             payment:{pricing_amount, pricing_currency, currency, amount, fx, options[]}}
            currency = an optional payment currency; the options list is what
                      BEAU FX can quote right now (fresh rate, eligible rail).
            recap   = authoritative pack recap (NEVER any body metric, BMI,
                      health or private note)
            methods = the AUTHORITATIVE eligible-method list computed
                      server-side by BEAU PH (merchant config × customer
                      country × currency × adapter readiness). The page
                      renders exactly this list — no country logic in JS.
     POST {action:"pay_card", token, currency?}
          → {ok, ui:"embedded", client_secret, publishable_key, expires_at}
                        BEAU PH request (amount from the DB order) → EMBEDDED
                        Stripe Checkout Session via the Stripe adapter (mode =
                        PAYMENTS_MODE; a key of another mode, or no mode, is
                        refused) → attempt recorded. The page mounts Stripe's
                        surface in place; the customer stays on coachgari28.com.
                        A still-open session is re-used, never duplicated.
                        Neither the browser's completion callback nor the
                        ?paid=1 return is authoritative: only the verified
                        webhook marks paid; the page re-reads `view` until then.
   Authorisation = the report token only (256-bit, sha256 stored, revocable,
   expiring). No JWT, no CRM/admin access. This function never marks anything
   paid — only a verified Stripe webhook (card) or an authorised operator
   (manual rails) can. Logs carry only action/status, never contact data.
   ============================================================= */
import { createClient } from "npm:@supabase/supabase-js@2";
import { providers, runtimeMap, assertPublic } from "../../../beau-ph/core/registry.ts";
import type { CreateRequestResult } from "../../../beau-ph/contracts/provider.ts";
import { reportView, requestForPack, packIdForToken, attachCheckout, siteUrl, HOST_APP, MERCHANT_KEY } from "../../../beau-ph/host-adapters/coach-gari/adapter.ts";
import { originAllowed, corsHeaders as cors } from "../_shared/cors.ts";   // one allowlist for every browser-facing function

const env = (name: string) => Deno.env.get(name);
const SITE_URL = siteUrl(env);   // https://coachgari28.com unless SITE_URL overrides (dev / preview only)

const json = (status: number, body: unknown, origin: string | null, allowed: boolean) => new Response(JSON.stringify(body), { status, headers: cors(origin, allowed) });
const log = (event: string, data: Record<string, unknown> = {}) => console.log(JSON.stringify({ fn: "report", event, ...data }));
const isToken = (s: unknown) => typeof s === "string" && /^[0-9a-f]{64}$/.test(s);

function rpcError(e: { code?: string; message?: string }, origin: string | null, allowed: boolean, conflictStatus = 410) {
  if (e.code === "P0002") return json(404, { ok: false, error: "invalid_token", message: "This link is not valid." }, origin, allowed);
  if (e.code === "P0003") return json(conflictStatus, { ok: false, error: conflictStatus === 410 ? "unavailable" : "conflict", message: e.message || "This link is no longer available." }, origin, allowed);
  log("rpc_failed", { code: e.code }); return json(500, { ok: false, error: "server_error" }, origin, allowed);
}

Deno.serve(async (req: Request) => {
  const origin = req.headers.get("origin"); const allowed = originAllowed(origin);
  if (req.method === "OPTIONS") return new Response(null, { status: allowed ? 204 : 403, headers: cors(origin, allowed) });
  if (!allowed) return json(403, { ok: false, error: "origin_not_allowed" }, origin, false);
  if (req.method !== "POST") return json(405, { ok: false, error: "method_not_allowed" }, origin, allowed);

  let body: Record<string, unknown>;
  try { body = JSON.parse(await req.text()); } catch { return json(400, { ok: false, error: "invalid_json" }, origin, allowed); }
  if (!isToken(body.token)) return json(400, { ok: false, error: "validation", fields: ["token"] }, origin, allowed);
  const token = String(body.token);
  const supabase = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, { auth: { persistSession: false } });
  const runtime = runtimeMap(env);   // adapter readiness (secret presence + mode) — never secret values
  // the only card surface on this page is the embedded one: without its public configuration, card is not offered at all
  if (runtime.stripe && !runtime.stripe.embedded) runtime.stripe = { configured: false, mode: runtime.stripe.mode, reason: runtime.stripe.reason ?? "embedded checkout not configured" };

  // optional payment currency (ISO 4217); the server decides whether it can be offered — an unknown choice falls back to the pricing currency
  const currency = typeof body.currency === "string" && /^[A-Za-z]{3}$/.test(body.currency) ? body.currency.toUpperCase() : null;

  if (body.action === "view") {
    const { data, error } = await reportView(supabase, token, runtime, currency);
    if (error) return rpcError(error, origin, allowed);
    const methods: Array<{ provider: string }> = data.methods ?? [];
    const out = { ok: true, recap: data.recap, pay_ref: data.pay_ref, currency: data.currency, methods,
                  card_enabled: methods.some((m) => m.provider === "stripe"), aani: data.aani, bank: data.bank, payment: data.payment ?? null };
    try { assertPublic({ methods: out.methods, aani: out.aani, bank: out.bank, payment: out.payment }); }
    catch (e) { log("public_guard_tripped", { reason: (e as Error).message }); return json(500, { ok: false, error: "server_error" }, origin, allowed); }
    log("viewed", { status: "ok", methods: methods.map((m) => m.provider) });
    return json(200, out, origin, allowed);
  }

  if (body.action === "pay_card") {
    const rt = runtime.stripe!;
    if (!rt.configured || !rt.embedded) {
      // fail closed: no mode, a key of the wrong mode, or no publishable key for the in-page surface
      log("not_configured", { mode: rt.mode ?? null, reason: rt.reason ?? null, embedded: !!rt.embedded });
      return json(503, { ok: false, error: "payments_not_configured", mode: rt.mode ?? null, reason: rt.reason ?? null }, origin, allowed);
    }
    // the token scopes everything: it resolves to exactly one pack, whose order carries the authoritative amount
    const { data: packId, error: rErr } = await packIdForToken(supabase, token);
    if (rErr) return rpcError(rErr, origin, allowed);
    // BEAU PH request for the pack's order (amount from the DB, eligibility enforced server-side) in the chosen payment currency: another currency than the pack's needs a BEAU FX quote (server-side, expiring)
    const { data: rp, error: oErr } = await requestForPack(supabase, packId, "stripe", runtime, currency);
    if (oErr || !rp) return rpcError(oErr ?? { code: "P0003", message: "unavailable" }, origin, allowed, 409);
    const { request, order } = rp;
    const reply = (c: Extract<CreateRequestResult, { kind: "embedded" }>, reused: boolean) =>
      json(200, { ok: true, ui: "embedded", client_secret: c.clientSecret, publishable_key: c.publicConfig.publishable_key, expires_at: c.expiresAt, reused }, origin, allowed);

    // re-open a still-valid attempt (same Checkout Session) instead of creating a second one
    const a = request.attempt;
    if (a?.provider_reference && a.expires_at && Date.parse(a.expires_at) - Date.now() > 60_000) {
      const resumed = await providers.stripe.resumePaymentRequest!(a.provider_reference, env);
      if (resumed.kind === "embedded") { log("session_resumed", { request_id: request.id, session: resumed.providerReference }); return reply(resumed, true); }
    }
    const created = await providers.stripe.createPaymentRequest!({
      requestId: request.id, publicReference: request.public_reference, externalReference: request.external_reference,
      amount: request.amount, currency: request.currency,                       // trusted: the order snapshot, never the browser
      description: `Coach Gari coaching package (${request.public_reference})`,
      customerEmail: order.customer_contact,
      uiMode: "embedded", hostApp: HOST_APP, merchantKey: MERCHANT_KEY,
      // only reached when Stripe itself must redirect (bank / 3DS flows); the page then re-reads the authoritative state
      returnUrls: { success: `${SITE_URL}/r/${token}?paid=1&session_id={CHECKOUT_SESSION_ID}`, cancel: `${SITE_URL}/r/${token}?cancelled=1` },
      attempt: (request.attempts ?? 0) + 1,
    }, env);
    if (created.kind !== "embedded") { log("stripe_failed", { reason: created.kind === "unavailable" ? created.reason : created.kind }); return json(502, { ok: false, error: "payment_provider_error" }, origin, allowed); }

    const { error: aErr } = await attachCheckout(supabase, order.reference, created.providerReference, null, created.expiresAt);
    if (aErr) return rpcError(aErr, origin, allowed, 409);
    log("session_created", { status: "ok", request_id: request.id, public_reference: request.public_reference, session: created.providerReference, mode: rt.mode, ui: "embedded" });
    return reply(created, false);
  }

  return json(400, { ok: false, error: "validation", fields: ["action"] }, origin, allowed);
});

/* =============================================================
   CG-012 — report  (on BEAU PH since the productisation step)
   Serves the secure client session-recap / payment page (/r/<token>).
     POST {action:"view",     token}
          → {ok, recap, pay_ref, currency, methods[], card_enabled, aani, bank}
            recap   = authoritative pack recap (NEVER any body metric, BMI,
                      health or private note)
            methods = the AUTHORITATIVE eligible-method list computed
                      server-side by BEAU PH (merchant config × customer
                      country × currency × adapter readiness). The page
                      renders exactly this list — no country logic in JS.
     POST {action:"pay_card", token}
          → {ok, url}   BEAU PH request (amount from the DB order) → Stripe
                        Checkout via the Stripe adapter (TEST mode only —
                        CHECK-LICENCE-001) → attempt recorded.
   Authorisation = the report token only (256-bit, sha256 stored, revocable,
   expiring). No JWT, no CRM/admin access. This function never marks anything
   paid — only a verified Stripe webhook (card) or an authorised operator
   (manual rails) can. Logs carry only action/status, never contact data.
   ============================================================= */
import { createClient } from "npm:@supabase/supabase-js@2";
import { providers, runtimeMap, assertPublic } from "../../../beau-ph/core/registry.ts";
import { reportView, requestForPack, packIdForToken, attachCheckout } from "../../../beau-ph/host-adapters/coach-gari/adapter.ts";

const ALLOWED_ORIGINS = new Set(["https://coachgari.com", "https://www.coachgari.com"]);
const ALLOWED_ORIGIN_PATTERNS: RegExp[] = [/^https:\/\/[a-z0-9-]+\.vercel\.app$/i, /^http:\/\/localhost(:\d+)?$/i, /^http:\/\/127\.0\.0\.1(:\d+)?$/i];
const SITE_URL = (Deno.env.get("SITE_URL") ?? "https://coachgariv0.vercel.app").replace(/\/$/, "");
const env = (name: string) => Deno.env.get(name);

const originAllowed = (o: string | null) => !o || ALLOWED_ORIGINS.has(o) || ALLOWED_ORIGIN_PATTERNS.some((r) => r.test(o));
function cors(origin: string | null, allowed: boolean): HeadersInit {
  const h: Record<string, string> = { "Content-Type": "application/json; charset=utf-8", "Cache-Control": "no-store", "Vary": "Origin" };
  if (origin && allowed) { h["Access-Control-Allow-Origin"] = origin; h["Access-Control-Allow-Methods"] = "POST, OPTIONS"; h["Access-Control-Allow-Headers"] = "Content-Type"; h["Access-Control-Max-Age"] = "86400"; }
  return h;
}
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

  if (body.action === "view") {
    const { data, error } = await reportView(supabase, token, runtime);
    if (error) return rpcError(error, origin, allowed);
    const methods: Array<{ provider: string }> = data.methods ?? [];
    const out = { ok: true, recap: data.recap, pay_ref: data.pay_ref, currency: data.currency, methods,
                  card_enabled: methods.some((m) => m.provider === "stripe"), aani: data.aani, bank: data.bank };
    try { assertPublic({ methods: out.methods, aani: out.aani, bank: out.bank }); }
    catch (e) { log("public_guard_tripped", { reason: (e as Error).message }); return json(500, { ok: false, error: "server_error" }, origin, allowed); }
    log("viewed", { status: "ok", methods: methods.map((m) => m.provider) });
    return json(200, out, origin, allowed);
  }

  if (body.action === "pay_card") {
    const rt = runtime.stripe!;
    if (!rt.configured) {
      log(rt.mode === "live" ? "live_key_refused" : "not_configured");
      return json(503, { ok: false, error: rt.mode === "live" ? "live_mode_blocked" : "payments_not_configured" }, origin, allowed);
    }
    const { data: packId, error: rErr } = await packIdForToken(supabase, token);
    if (rErr) return rpcError(rErr, origin, allowed);
    // BEAU PH request for the pack's order: amount/currency from the DB; eligibility enforced server-side
    const { data: rp, error: oErr } = await requestForPack(supabase, packId, "stripe", runtime);
    if (oErr || !rp) return rpcError(oErr ?? { code: "P0003", message: "unavailable" }, origin, allowed, 409);
    const { request, order } = rp;

    // reuse a still-valid attempt instead of creating a second Checkout Session
    const a = request.attempt;
    if (a?.redirect_url && a.expires_at && Date.parse(a.expires_at) - Date.now() > 60_000) {
      return json(200, { ok: true, url: a.redirect_url, reused: true }, origin, allowed);
    }
    const created = await providers.stripe.createPaymentRequest!({
      requestId: request.id, publicReference: request.public_reference, externalReference: request.external_reference,
      amount: request.amount, currency: request.currency,
      description: `Coach Gari coaching package — ${request.public_reference}`,
      customerEmail: order.customer_contact,
      returnUrls: { success: `${SITE_URL}/r/${token}?paid=1`, cancel: `${SITE_URL}/r/${token}?cancelled=1` },
      attempt: (request.attempts ?? 0) + 1,
    }, env);
    if (created.kind !== "redirect") { log("stripe_failed", { reason: created.kind === "unavailable" ? created.reason : created.kind }); return json(502, { ok: false, error: "payment_provider_error" }, origin, allowed); }

    const { error: aErr } = await attachCheckout(supabase, order.reference, created.providerReference, created.url, created.expiresAt);
    if (aErr) return rpcError(aErr, origin, allowed, 409);
    log("session_created", { status: "ok", mode: "test" });
    return json(200, { ok: true, url: created.url }, origin, allowed);
  }

  return json(400, { ok: false, error: "validation", fields: ["action"] }, origin, allowed);
});

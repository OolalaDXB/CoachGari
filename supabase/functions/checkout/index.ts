/* =============================================================
   CG-003 — checkout  (on BEAU PH since the productisation step)
   POST {ref, token} → held booking → trusted order (amount from the DB) →
   BEAU PH payment request → Stripe Checkout Session via the Stripe adapter
   → attempt recorded → {url}. The success redirect is NEVER authoritative:
   only the signature-verified webhook (stripe-webhook) marks anything paid.

   Secrets / config (Supabase secrets, never in git):
     PAYMENTS_MODE       — test | live. The adapter refuses a key whose mode
                           differs, and refuses everything when it is unset.
     STRIPE_SECRET_KEY   — sk_test_… under test, sk_live_… under live.
     SITE_URL            — where Stripe sends the customer back
                           (default: the Vercel production alias).
   The browser never supplies an amount; any such field is ignored.
   ============================================================= */
import { createClient } from "npm:@supabase/supabase-js@2";
import { providers, runtimeMap } from "../../../beau-ph/core/registry.ts";
import { requestForBooking, attachCheckout } from "../../../beau-ph/host-adapters/coach-gari/adapter.ts";

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
  if (!rt.configured) {
    // payment-mode gate: PAYMENTS_MODE unset, or a key whose mode differs from it — refuse, never guess
    log("not_configured", { mode: rt.mode ?? null, reason: rt.reason ?? null });
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

  // Reuse a still-valid Checkout Session instead of creating a second one.
  const a = request.attempt;
  if (a?.redirect_url && a.expires_at && Date.parse(a.expires_at) - Date.now() > 60_000) {
    return json(200, { ok: true, url: a.redirect_url, order: order.reference, reused: true }, origin, allowed);
  }

  const created = await providers.stripe.createPaymentRequest!({
    requestId: request.id, publicReference: request.public_reference, externalReference: request.external_reference,
    amount: request.amount, currency: request.currency,                                        // trusted, from the DB
    description: `${order.booking?.service_title ?? "Coaching session"} — ${order.booking?.reference ?? request.public_reference}`,
    customerEmail: order.customer_contact,
    returnUrls: {
      success: `${SITE_URL}/?booking=${order.booking?.reference ?? ref}&t=${encodeURIComponent(token)}&paid=1#book`,
      cancel:  `${SITE_URL}/?booking=${order.booking?.reference ?? ref}&t=${encodeURIComponent(token)}&cancelled=1#book`,
    },
    attempt: (request.attempts ?? 0) + 1,
  }, env);
  if (created.kind !== "redirect") { log("stripe_failed", { reason: created.kind === "unavailable" ? created.reason : created.kind }); return json(502, { ok: false, error: "payment_provider_error" }, origin, allowed); }

  const { error: attachErr } = await attachCheckout(supabase, order.reference, created.providerReference, created.url, created.expiresAt);
  if (attachErr) return rpcError(attachErr, origin, allowed);

  log("session_created", { order: order.reference, request_id: request.id, session: created.providerReference, mode: rt.mode });
  return json(200, { ok: true, url: created.url, order: order.reference }, origin, allowed);
});

/* =============================================================
   CG-012 — report
   Serves the secure client session-recap / payment page (/r/<token>).
     POST {action:"view",     token}
          → {ok, recap, aani, pay_ref}   (recap = authoritative pack recap;
             NEVER any body metric, BMI, health or private note)
     POST {action:"pay_card", token}
          → {ok, url}                     (Stripe Checkout, amount from the
             DB order, TEST mode only — CHECK-LICENCE-001)
   Authorisation = the report token only (256-bit, sha256 stored, revocable,
   expiring). No JWT, no CRM/admin access. The card amount and currency come
   from the pack's order (create_order_for_pack), never from the client.
   Aani is a static/manual option shown by the page; this function never
   marks anything paid — only the Stripe webhook (card) or an authorised
   operator (manual) can. Logs carry only action/status, never contact data.
   ============================================================= */
import { createClient } from "npm:@supabase/supabase-js@2";

const ALLOWED_ORIGINS = new Set(["https://coachgari.com", "https://www.coachgari.com"]);
const ALLOWED_ORIGIN_PATTERNS: RegExp[] = [/^https:\/\/[a-z0-9-]+\.vercel\.app$/i, /^http:\/\/localhost(:\d+)?$/i, /^http:\/\/127\.0\.0\.1(:\d+)?$/i];
const SITE_URL = (Deno.env.get("SITE_URL") ?? "https://coachgariv0.vercel.app").replace(/\/$/, "");
const CHECKOUT_MINUTES = 30;

const originAllowed = (o: string | null) => !o || ALLOWED_ORIGINS.has(o) || ALLOWED_ORIGIN_PATTERNS.some((r) => r.test(o));
function cors(origin: string | null, allowed: boolean): HeadersInit {
  const h: Record<string, string> = { "Content-Type": "application/json; charset=utf-8", "Cache-Control": "no-store", "Vary": "Origin" };
  if (origin && allowed) { h["Access-Control-Allow-Origin"] = origin; h["Access-Control-Allow-Methods"] = "POST, OPTIONS"; h["Access-Control-Allow-Headers"] = "Content-Type"; h["Access-Control-Max-Age"] = "86400"; }
  return h;
}
const json = (status: number, body: unknown, origin: string | null, allowed: boolean) => new Response(JSON.stringify(body), { status, headers: cors(origin, allowed) });
const log = (event: string, data: Record<string, unknown> = {}) => console.log(JSON.stringify({ fn: "report", event, ...data }));
const isToken = (s: unknown) => typeof s === "string" && /^[0-9a-f]{64}$/.test(s);
const isEmail = (s: string) => /^[^\s@]+@[^\s@]+\.[^\s@]{2,}$/.test(s);

function rpcError(e: { code?: string; message?: string }, origin: string | null, allowed: boolean) {
  if (e.code === "P0002") return json(404, { ok: false, error: "invalid_token", message: "This link is not valid." }, origin, allowed);
  if (e.code === "P0003") return json(410, { ok: false, error: "unavailable", message: e.message || "This link is no longer available." }, origin, allowed);
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

  if (body.action === "view") {
    const { data, error } = await supabase.rpc("report_view", { p_token: token });
    if (error) return rpcError(error, origin, allowed);
    log("viewed", { status: "ok" });
    // whether card payment can be offered at all (Stripe configured in test mode)
    const cardEnabled = (Deno.env.get("STRIPE_SECRET_KEY") ?? "").startsWith("sk_test_");
    return json(200, { ok: true, recap: data.recap, aani: data.aani, pay_ref: data.pay_ref, card_enabled: cardEnabled }, origin, allowed);
  }

  if (body.action === "pay_card") {
    const key = Deno.env.get("STRIPE_SECRET_KEY") ?? "";
    if (!key) return json(503, { ok: false, error: "payments_not_configured" }, origin, allowed);
    if (!key.startsWith("sk_test_")) { log("live_key_refused"); return json(503, { ok: false, error: "live_mode_blocked" }, origin, allowed); }

    // resolve the token → pack, then create/reuse the pack's order (amount from the DB)
    const { data: packId, error: rErr } = await supabase.rpc("report_pack_id", { p_token: token });
    if (rErr) return rpcError(rErr, origin, allowed);
    const { data: order, error: oErr } = await supabase.rpc("create_order_for_pack", { p_pack_id: packId });
    if (oErr) return rpcError(oErr, origin, allowed);

    if (order.checkout_url && order.checkout_expires_at && Date.parse(order.checkout_expires_at) - Date.now() > 60_000) {
      return json(200, { ok: true, url: order.checkout_url, reused: true }, origin, allowed);
    }

    const expiresAt = Math.floor(Date.now() / 1000) + CHECKOUT_MINUTES * 60;
    const params = new URLSearchParams();
    params.set("mode", "payment");
    params.set("client_reference_id", order.reference);
    params.set("line_items[0][quantity]", "1");
    params.set("line_items[0][price_data][currency]", String(order.currency).toLowerCase());
    params.set("line_items[0][price_data][unit_amount]", String(order.gross_amount));   // trusted, from the DB
    params.set("line_items[0][price_data][product_data][name]", `Coach Gari coaching package — ${order.reference}`);
    params.set("metadata[order_reference]", order.reference);
    params.set("payment_intent_data[metadata][order_reference]", order.reference);
    params.set("expires_at", String(expiresAt));
    params.set("success_url", `${SITE_URL}/r/${token}?paid=1`);
    params.set("cancel_url", `${SITE_URL}/r/${token}?cancelled=1`);
    if (order.customer_contact && isEmail(order.customer_contact)) params.set("customer_email", order.customer_contact);

    const res = await fetch("https://api.stripe.com/v1/checkout/sessions", {
      method: "POST",
      headers: { Authorization: `Bearer ${key}`, "Content-Type": "application/x-www-form-urlencoded",
                 "Idempotency-Key": `${order.reference}:${(order.checkout_attempts ?? 0) + 1}` },
      body: params.toString(),
    });
    const session = await res.json().catch(() => null);
    if (!res.ok || !session?.url) { log("stripe_failed", { status: res.status, type: session?.error?.type }); return json(502, { ok: false, error: "payment_provider_error" }, origin, allowed); }

    const { error: aErr } = await supabase.rpc("attach_checkout", {
      p_order_reference: order.reference, p_session_id: session.id, p_url: session.url, p_expires_at: new Date(expiresAt * 1000).toISOString(),
    });
    if (aErr) return rpcError(aErr, origin, allowed);
    log("session_created", { status: "ok", mode: "test" });
    return json(200, { ok: true, url: session.url }, origin, allowed);
  }

  return json(400, { ok: false, error: "validation", fields: ["action"] }, origin, allowed);
});

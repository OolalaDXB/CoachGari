/* =============================================================
   CG-003 — checkout
   POST {ref, token} → trusted order (amount from the DB) → Stripe
   Checkout Session (TEST MODE) → {url}.

   Secrets (Supabase secrets, never in git):
     STRIPE_SECRET_KEY   — must be a TEST key (sk_test_…). A live key is
                           refused in code: CHECK-LICENCE-001.
     SITE_URL            — where Stripe sends the customer back
                           (default: the Vercel production alias).
   The browser never supplies an amount; any such field is ignored.
   ============================================================= */
import { createClient } from "npm:@supabase/supabase-js@2";

const ALLOWED_ORIGINS = new Set(["https://coachgari.com", "https://www.coachgari.com"]);
const ALLOWED_ORIGIN_PATTERNS: RegExp[] = [/^https:\/\/[a-z0-9-]+\.vercel\.app$/i, /^http:\/\/localhost(:\d+)?$/i, /^http:\/\/127\.0\.0\.1(:\d+)?$/i];
const SITE_URL = (Deno.env.get("SITE_URL") ?? "https://coachgariv0.vercel.app").replace(/\/$/, "");
const CHECKOUT_MINUTES = 30; // Stripe minimum

const originAllowed = (o: string | null) => !o || ALLOWED_ORIGINS.has(o) || ALLOWED_ORIGIN_PATTERNS.some((r) => r.test(o));
function cors(origin: string | null, allowed: boolean): HeadersInit {
  const h: Record<string, string> = { "Content-Type": "application/json; charset=utf-8", "Cache-Control": "no-store", "Vary": "Origin" };
  if (origin && allowed) { h["Access-Control-Allow-Origin"] = origin; h["Access-Control-Allow-Methods"] = "POST, OPTIONS"; h["Access-Control-Allow-Headers"] = "Content-Type"; h["Access-Control-Max-Age"] = "86400"; }
  return h;
}
const json = (status: number, body: unknown, origin: string | null, allowed: boolean) => new Response(JSON.stringify(body), { status, headers: cors(origin, allowed) });
const log = (event: string, data: Record<string, unknown> = {}) => console.log(JSON.stringify({ fn: "checkout", event, ...data }));
const isEmail = (s: string) => /^[^\s@]+@[^\s@]+\.[^\s@]{2,}$/.test(s);

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

  const key = Deno.env.get("STRIPE_SECRET_KEY") ?? "";
  if (!key) { log("not_configured"); return json(503, { ok: false, error: "payments_not_configured" }, origin, allowed); }
  if (!key.startsWith("sk_test_")) {
    // CHECK-LICENCE-001: live collection is blocked. This function only ever runs in test mode.
    log("live_key_refused"); return json(503, { ok: false, error: "live_mode_blocked" }, origin, allowed);
  }

  let body: Record<string, unknown>;
  try { body = JSON.parse(await req.text()); } catch { return json(400, { ok: false, error: "invalid_json" }, origin, allowed); }
  const ref = typeof body.ref === "string" ? body.ref.trim().toUpperCase() : "";
  const token = typeof body.token === "string" ? body.token.trim() : "";
  if (!/^CG-[0-9A-F]{6}$/.test(ref) || !token) return json(400, { ok: false, error: "validation", fields: ["ref", "token"] }, origin, allowed);

  const supabase = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, { auth: { persistSession: false } });

  const { data: order, error } = await supabase.rpc("create_order_for_booking", { p_reference: ref, p_manage_token: token });
  if (error) return rpcError(error, origin, allowed);

  // Reuse a still-valid Checkout Session instead of creating a second one.
  if (order.checkout_url && order.checkout_expires_at && Date.parse(order.checkout_expires_at) - Date.now() > 60_000) {
    return json(200, { ok: true, url: order.checkout_url, order: order.reference, reused: true }, origin, allowed);
  }

  const expiresAt = Math.floor(Date.now() / 1000) + CHECKOUT_MINUTES * 60;
  const params = new URLSearchParams();
  params.set("mode", "payment");
  params.set("client_reference_id", order.reference);
  params.set("line_items[0][quantity]", "1");
  params.set("line_items[0][price_data][currency]", String(order.currency).toLowerCase());
  params.set("line_items[0][price_data][unit_amount]", String(order.gross_amount));          // trusted, from the DB
  params.set("line_items[0][price_data][product_data][name]", `${order.booking.service_title} — ${order.booking.reference}`);
  params.set("metadata[order_id]", "");   // filled below with the DB id via a second lookup-free path: use reference
  params.set("metadata[order_reference]", order.reference);
  params.set("metadata[booking_reference]", order.booking.reference);
  params.set("payment_intent_data[metadata][order_reference]", order.reference);
  params.set("payment_intent_data[metadata][booking_reference]", order.booking.reference);
  params.set("expires_at", String(expiresAt));
  params.set("success_url", `${SITE_URL}/?booking=${order.booking.reference}&t=${encodeURIComponent(token)}&paid=1#book`);
  params.set("cancel_url", `${SITE_URL}/?booking=${order.booking.reference}&t=${encodeURIComponent(token)}&cancelled=1#book`);
  if (isEmail(order.customer_contact)) params.set("customer_email", order.customer_contact);
  params.delete("metadata[order_id]");

  const res = await fetch("https://api.stripe.com/v1/checkout/sessions", {
    method: "POST",
    headers: { Authorization: `Bearer ${key}`, "Content-Type": "application/x-www-form-urlencoded",
               "Idempotency-Key": `${order.reference}:${(order.checkout_attempts ?? 0) + 1}` },
    body: params.toString(),
  });
  const session = await res.json().catch(() => null);
  if (!res.ok || !session?.url) { log("stripe_failed", { status: res.status, type: session?.error?.type }); return json(502, { ok: false, error: "payment_provider_error" }, origin, allowed); }

  const { error: attachErr } = await supabase.rpc("attach_checkout", {
    p_order_reference: order.reference, p_session_id: session.id, p_url: session.url, p_expires_at: new Date(expiresAt * 1000).toISOString(),
  });
  if (attachErr) return rpcError(attachErr, origin, allowed);

  log("session_created", { order: order.reference, mode: "test" });
  return json(200, { ok: true, url: session.url, order: order.reference }, origin, allowed);
});

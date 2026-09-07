/* =============================================================
   BEAU PH provider — Stripe (online, webhook-confirmed)

   createPaymentRequest → hosted Checkout Session (redirect). The amount and
   currency come from the BEAU PH request (i.e. the host's order); the payer
   never supplies them. TEST MODE ONLY: a live key is refused in code
   (CHECK-LICENCE-001) and `runtime()` reports it as not configured.
   verifyWebhook → Stripe's own signing scheme (signature.js), raw body,
   300 s tolerance; a live-mode event is refused for a test merchant.
   enrich → adds the Stripe fee / charge / balance transaction as evidence
   before the DB normalizer (beau_ph.normalize_stripe_event) runs.
   Secrets: STRIPE_SECRET_KEY (sk_test_…), STRIPE_WEBHOOK_SECRET (whsec_…).
   ============================================================= */
import type { CreateRequestInput, CreateRequestResult, EnvReader, ProviderAdapter, ProviderCapabilities, RuntimeReadiness, VerifiedEvent } from "../../contracts/provider.ts";
import { verifyStripeSignature } from "./signature.js";

const DEFAULT_EXPIRES_S = 30 * 60; // Stripe minimum for Checkout expiry

export const stripe: ProviderAdapter = {
  key: "stripe",

  capabilities(): ProviderCapabilities {
    return {
      key: "stripe", displayName: "Card (Stripe)", kind: "online", confirmation: "provider_event", readiness: "available",
      supports: { checkout: true, instructions: false, webhook: true, statusPoll: true, cancel: true, refundEvents: true },
      countries: null, currencies: null,
      secrets: ["STRIPE_SECRET_KEY", "STRIPE_WEBHOOK_SECRET"],
    };
  },

  runtime(env: EnvReader): RuntimeReadiness {
    const key = env("STRIPE_SECRET_KEY") ?? "";
    if (!key) return { configured: false, reason: "STRIPE_SECRET_KEY missing" };
    if (key.startsWith("sk_test_")) return { configured: true, mode: "test" };
    if (key.startsWith("sk_live_")) return { configured: false, mode: "live", reason: "live key refused (CHECK-LICENCE-001)" };
    return { configured: false, reason: "unrecognised key format" };
  },

  async createPaymentRequest(input: CreateRequestInput, env: EnvReader): Promise<CreateRequestResult> {
    const rt = stripe.runtime(env);
    if (!rt.configured) return { kind: "unavailable", reason: rt.reason ?? "not configured" };
    const key = env("STRIPE_SECRET_KEY")!;
    const expiresAt = Math.floor(Date.now() / 1000) + (input.expiresInSeconds ?? DEFAULT_EXPIRES_S);
    const params = new URLSearchParams();
    params.set("mode", "payment");
    params.set("client_reference_id", input.externalReference);
    params.set("line_items[0][quantity]", "1");
    params.set("line_items[0][price_data][currency]", input.currency.toLowerCase());
    params.set("line_items[0][price_data][unit_amount]", String(input.amount));            // trusted: from the BEAU PH request
    params.set("line_items[0][price_data][product_data][name]", input.description);
    params.set("metadata[order_reference]", input.externalReference);
    params.set("metadata[public_reference]", input.publicReference);
    params.set("metadata[beau_ph_request_id]", input.requestId);
    params.set("payment_intent_data[metadata][order_reference]", input.externalReference);
    params.set("payment_intent_data[metadata][beau_ph_request_id]", input.requestId);
    params.set("expires_at", String(expiresAt));
    params.set("success_url", input.returnUrls.success);
    params.set("cancel_url", input.returnUrls.cancel);
    if (input.customerEmail && /^[^\s@]+@[^\s@]+\.[^\s@]{2,}$/.test(input.customerEmail)) params.set("customer_email", input.customerEmail);

    const res = await fetch("https://api.stripe.com/v1/checkout/sessions", {
      method: "POST",
      headers: { Authorization: `Bearer ${key}`, "Content-Type": "application/x-www-form-urlencoded",
                 "Idempotency-Key": `${input.externalReference}:${input.attempt}` },
      body: params.toString(),
    });
    const session = await res.json().catch(() => null);
    if (!res.ok || !session?.url || !session?.id) {
      return { kind: "unavailable", reason: `stripe ${res.status} ${session?.error?.type ?? ""}`.trim() };
    }
    return { kind: "redirect", providerReference: session.id, url: session.url, expiresAt: new Date(expiresAt * 1000).toISOString() };
  },

  async getStatus(providerReference: string, env: EnvReader) {
    const key = env("STRIPE_SECRET_KEY") ?? "";
    if (!key.startsWith("sk_test_")) return { providerStatus: "unavailable", status: null };
    const r = await fetch(`https://api.stripe.com/v1/checkout/sessions/${encodeURIComponent(providerReference)}`, { headers: { Authorization: `Bearer ${key}` } });
    const s = await r.json().catch(() => null);
    if (!r.ok || !s) return { providerStatus: `error ${r.status}`, status: null };
    const status = s.payment_status === "paid" ? "paid" : s.status === "expired" ? "expired" : s.status === "open" ? "requires_action" : null;
    return { providerStatus: `${s.status}/${s.payment_status}`, status, evidence: { checkout_session: s.id, payment_intent: s.payment_intent ?? null } };
  },

  async cancel(providerReference: string, env: EnvReader) {
    const key = env("STRIPE_SECRET_KEY") ?? "";
    if (!key.startsWith("sk_test_")) return { ok: false, reason: "not configured" };
    const r = await fetch(`https://api.stripe.com/v1/checkout/sessions/${encodeURIComponent(providerReference)}/expire`, { method: "POST", headers: { Authorization: `Bearer ${key}` } });
    return r.ok ? { ok: true } : { ok: false, reason: `stripe ${r.status}` };
  },

  async verifyWebhook(req: { headers: Headers; rawBody: string }, env: EnvReader): Promise<VerifiedEvent> {
    const secret = env("STRIPE_WEBHOOK_SECRET");
    if (!secret) return { ok: false, reason: "webhook_not_configured" };
    const sig = await verifyStripeSignature(req.headers.get("stripe-signature"), req.rawBody, secret);
    if (!sig.ok) return { ok: false, reason: `bad_signature:${sig.reason}` };
    let event: Record<string, unknown>;
    try { event = JSON.parse(req.rawBody); } catch { return { ok: false, reason: "invalid_json" }; }
    if (typeof event.id !== "string" || typeof event.type !== "string") return { ok: false, reason: "malformed_event" };
    if (event.livemode === true && stripe.runtime(env).mode !== "live") return { ok: false, reason: "live_mode_blocked" };
    return { ok: true, providerEventId: event.id, eventType: event.type, payload: event };
  },

  async enrich(event: Record<string, unknown>, env: EnvReader) {
    if (event.type !== "checkout.session.completed") return event;
    const key = env("STRIPE_SECRET_KEY") ?? "";
    // deno-lint-ignore no-explicit-any
    const pi = (event as any).data?.object?.payment_intent;
    if (!key.startsWith("sk_test_") || typeof pi !== "string") return event;
    try {
      const r = await fetch(`https://api.stripe.com/v1/payment_intents/${pi}?expand[]=latest_charge.balance_transaction`, { headers: { Authorization: `Bearer ${key}` } });
      const p = await r.json();
      const ch = p?.latest_charge; const bt = ch?.balance_transaction;
      if (!ch?.id) return event;
      return { ...event, _enrich: { charge_id: ch.id, balance_transaction_id: bt?.id ?? null, fee_amount: typeof bt?.fee === "number" ? bt.fee : null } };
    } catch { return event; }
  },
};

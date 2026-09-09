/* =============================================================
   BEAU PH provider — Stripe (online, webhook-confirmed)

   createPaymentRequest → Checkout Session. uiMode "embedded" (default for
   the Coach Gari customer surfaces) creates an `ui_mode=embedded` session
   whose client secret the host page mounts with Stripe.js, so the payer
   stays on the host domain; `redirect_on_completion=if_required` +
   `return_url` cover the rare bank/3DS flows Stripe must redirect for.
   uiMode "hosted" keeps the classic redirect session. Either way the
   amount, currency and line item come from the BEAU PH request (i.e. the
   host's order) as dynamic `price_data` + `product_data`: the host catalogue
   stays authoritative and no Stripe Product/Price is required. Metadata
   carries reconciliation identifiers only, never personal data.
   resumePaymentRequest → re-open a still-open embedded session (same
   Checkout Session, fresh client secret fetch) instead of creating another.

   PAYMENT MODE GATE (replaces CHECK-LICENCE-001's categorical live refusal):
     PAYMENTS_MODE=test  → sk_test_ allowed, sk_live_ refused
     PAYMENTS_MODE=live  → sk_live_ allowed, sk_test_ refused
     PAYMENTS_MODE unset / unknown → refused (never guessed)
   `runtime()` reports only {configured, mode, reason}: never a key, never a
   prefix beyond the mode word. Every other call in this adapter (create,
   status, cancel, enrich) is gated on `runtime().configured`.

   verifyWebhook → Stripe's own signing scheme (signature.js), raw body,
   300 s tolerance; an event whose `livemode` does not match PAYMENTS_MODE is
   refused (mode_mismatch). The DB core independently refuses evidence whose
   livemode does not match the merchant's mode.
   enrich → adds the Stripe fee / charge / balance transaction as evidence
   before the DB normalizer (beau_ph.normalize_stripe_event) runs.
   Secrets: STRIPE_SECRET_KEY, STRIPE_WEBHOOK_SECRET; config: PAYMENTS_MODE,
   STRIPE_PUBLISHABLE_KEY (public by design, still mode-checked: a pk_ of the
   wrong mode refuses; missing pk_ disables the embedded surface only).
   ============================================================= */
import type { CreateRequestInput, CreateRequestResult, EnvReader, ProviderAdapter, ProviderCapabilities, RuntimeReadiness, VerifiedEvent } from "../../contracts/provider.ts";
import { verifyStripeSignature } from "./signature.js";

const DEFAULT_EXPIRES_S = 30 * 60; // Stripe minimum for Checkout expiry

/** The deployment's declared payment mode, or null when unset / unknown. Safe to log. */
export function paymentsMode(env: EnvReader): "test" | "live" | null {
  const m = (env("PAYMENTS_MODE") ?? "").trim().toLowerCase();
  return m === "test" || m === "live" ? m : null;
}

function keyMode(key: string): "test" | "live" | null {
  if (key.startsWith("sk_test_") || key.startsWith("rk_test_")) return "test";
  if (key.startsWith("sk_live_") || key.startsWith("rk_live_")) return "live";
  return null;
}
function publishableMode(key: string): "test" | "live" | null {
  if (key.startsWith("pk_test_")) return "test";
  if (key.startsWith("pk_live_")) return "live";
  return null;
}

/** Reconciliation-only metadata: identifiers, never names, contacts or notes. */
const METADATA_KEYS = ["order_reference", "public_reference", "beau_ph_request_id", "host_app", "merchant_key"] as const;
function metadata(input: CreateRequestInput): Record<string, string> {
  const m: Record<string, string> = {
    order_reference: input.externalReference, public_reference: input.publicReference, beau_ph_request_id: input.requestId,
  };
  if (input.hostApp) m.host_app = input.hostApp;
  if (input.merchantKey) m.merchant_key = input.merchantKey;
  for (const k of Object.keys(m)) if (!(METADATA_KEYS as readonly string[]).includes(k)) delete m[k];
  return m;
}

/** The exact form body sent to POST /v1/checkout/sessions (exported so tests can assert it without a network). */
export function checkoutSessionParams(input: CreateRequestInput, expiresAt: number): URLSearchParams {
  const params = new URLSearchParams();
  params.set("mode", "payment");
  params.set("client_reference_id", input.externalReference);
  params.set("line_items[0][quantity]", "1");
  params.set("line_items[0][price_data][currency]", input.currency.toLowerCase());
  params.set("line_items[0][price_data][unit_amount]", String(input.amount));            // trusted: from the BEAU PH request
  params.set("line_items[0][price_data][product_data][name]", input.description);
  for (const [k, v] of Object.entries(metadata(input))) { params.set(`metadata[${k}]`, v); params.set(`payment_intent_data[metadata][${k}]`, v); }
  params.set("expires_at", String(expiresAt));
  if (input.uiMode === "embedded") {
    params.set("ui_mode", "embedded");
    params.set("redirect_on_completion", "if_required");     // stay in-page; redirect only when a bank / 3DS flow demands it
    params.set("return_url", input.returnUrls.success);
  } else {
    params.set("success_url", input.returnUrls.success);
    params.set("cancel_url", input.returnUrls.cancel);
  }
  if (input.customerEmail && /^[^\s@]+@[^\s@]+\.[^\s@]{2,}$/.test(input.customerEmail)) params.set("customer_email", input.customerEmail);
  return params;
}

export const stripe: ProviderAdapter = {
  key: "stripe",

  capabilities(): ProviderCapabilities {
    return {
      key: "stripe", displayName: "Card (Stripe)", kind: "online", confirmation: "provider_event", readiness: "available",
      capabilities: [
        { capability: "online_checkout", readiness: "available", confirmation: "provider_event", platforms: null, initiatedBy: "customer", handoff: false, notes: "Hosted Checkout, webhook-confirmed. Mode follows PAYMENTS_MODE." },
        { capability: "payment_link", readiness: "not_configured", confirmation: "provider_event", platforms: null, initiatedBy: "merchant", handoff: false, notes: "Stripe Payment Links — not implemented." },
      ],
      supports: { checkout: true, instructions: false, webhook: true, statusPoll: true, cancel: true, refundEvents: true },
      countries: null, currencies: null,
      secrets: ["STRIPE_SECRET_KEY", "STRIPE_WEBHOOK_SECRET"],
    };
  },

  runtime(env: EnvReader): RuntimeReadiness {
    const mode = paymentsMode(env);
    if (!mode) return { configured: false, reason: "payments_mode_unset" };            // never guess a mode
    const key = env("STRIPE_SECRET_KEY") ?? "";
    if (!key) return { configured: false, mode, reason: "STRIPE_SECRET_KEY missing" };
    const km = keyMode(key);
    if (!km) return { configured: false, mode, reason: "unrecognised key format" };
    if (km !== mode) return { configured: false, mode, reason: "key_mode_mismatch" };   // the key's mode ≠ PAYMENTS_MODE
    const pk = env("STRIPE_PUBLISHABLE_KEY") ?? "";
    if (pk && publishableMode(pk) !== mode) return { configured: false, mode, reason: "publishable_key_mode_mismatch" };
    return pk ? { configured: true, mode, embedded: true } : { configured: true, mode, embedded: false, reason: "STRIPE_PUBLISHABLE_KEY missing" };
  },

  async createPaymentRequest(input: CreateRequestInput, env: EnvReader): Promise<CreateRequestResult> {
    const rt = stripe.runtime(env);
    if (!rt.configured) return { kind: "unavailable", reason: rt.reason ?? "not configured" };
    const key = env("STRIPE_SECRET_KEY")!;
    const embedded = input.uiMode === "embedded";
    if (embedded && !rt.embedded) return { kind: "unavailable", reason: rt.reason ?? "embedded checkout not configured" };
    const expiresAt = Math.floor(Date.now() / 1000) + (input.expiresInSeconds ?? DEFAULT_EXPIRES_S);
    const params = checkoutSessionParams(input, expiresAt);

    const res = await fetch("https://api.stripe.com/v1/checkout/sessions", {
      method: "POST",
      headers: { Authorization: `Bearer ${key}`, "Content-Type": "application/x-www-form-urlencoded",
                 "Idempotency-Key": `${input.externalReference}:${input.attempt}:${embedded ? "embedded" : "hosted"}` },
      body: params.toString(),
    });
    const session = await res.json().catch(() => null);
    if (!res.ok || !session?.id) return { kind: "unavailable", reason: `stripe ${res.status} ${session?.error?.type ?? ""}`.trim() };
    const expiresIso = new Date(expiresAt * 1000).toISOString();
    if (embedded) {
      if (typeof session.client_secret !== "string") return { kind: "unavailable", reason: "stripe embedded session without client_secret" };
      return { kind: "embedded", providerReference: session.id, clientSecret: session.client_secret, expiresAt: expiresIso,
               publicConfig: { publishable_key: env("STRIPE_PUBLISHABLE_KEY")! } };
    }
    if (!session.url) return { kind: "unavailable", reason: "stripe hosted session without url" };
    return { kind: "redirect", providerReference: session.id, url: session.url, expiresAt: expiresIso };
  },

  async resumePaymentRequest(providerReference: string, env: EnvReader): Promise<CreateRequestResult> {
    const rt = stripe.runtime(env);
    if (!rt.configured || !rt.embedded) return { kind: "unavailable", reason: rt.reason ?? "not configured" };
    const key = env("STRIPE_SECRET_KEY")!;
    const r = await fetch(`https://api.stripe.com/v1/checkout/sessions/${encodeURIComponent(providerReference)}`, { headers: { Authorization: `Bearer ${key}` } });
    const s = await r.json().catch(() => null);
    if (!r.ok || !s?.id) return { kind: "unavailable", reason: `stripe ${r.status}` };
    if (s.status !== "open" || s.ui_mode !== "embedded" || typeof s.client_secret !== "string") return { kind: "unavailable", reason: `session ${s.status ?? "unknown"}` };
    const exp = typeof s.expires_at === "number" ? new Date(s.expires_at * 1000).toISOString() : new Date(Date.now() + DEFAULT_EXPIRES_S * 1000).toISOString();
    return { kind: "embedded", providerReference: s.id, clientSecret: s.client_secret, expiresAt: exp, publicConfig: { publishable_key: env("STRIPE_PUBLISHABLE_KEY")! } };
  },

  async getStatus(providerReference: string, env: EnvReader) {
    if (!stripe.runtime(env).configured) return { providerStatus: "unavailable", status: null };
    const key = env("STRIPE_SECRET_KEY")!;
    const r = await fetch(`https://api.stripe.com/v1/checkout/sessions/${encodeURIComponent(providerReference)}`, { headers: { Authorization: `Bearer ${key}` } });
    const s = await r.json().catch(() => null);
    if (!r.ok || !s) return { providerStatus: `error ${r.status}`, status: null };
    const status = s.payment_status === "paid" ? "paid" : s.status === "expired" ? "expired" : s.status === "open" ? "requires_action" : null;
    return { providerStatus: `${s.status}/${s.payment_status}`, status, evidence: { checkout_session: s.id, payment_intent: s.payment_intent ?? null } };
  },

  async cancel(providerReference: string, env: EnvReader) {
    if (!stripe.runtime(env).configured) return { ok: false, reason: "not configured" };
    const key = env("STRIPE_SECRET_KEY")!;
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
    // the event's mode must match the deployment's declared mode — in both directions; an unset mode refuses everything
    const mode = paymentsMode(env);
    if (!mode) return { ok: false, reason: "payments_mode_unset" };
    if ((event.livemode === true) !== (mode === "live")) return { ok: false, reason: "mode_mismatch" };
    return { ok: true, providerEventId: event.id, eventType: event.type, payload: event };
  },

  async enrich(event: Record<string, unknown>, env: EnvReader) {
    if (event.type !== "checkout.session.completed") return event;
    if (!stripe.runtime(env).configured) return event;
    const key = env("STRIPE_SECRET_KEY")!;
    // deno-lint-ignore no-explicit-any
    const pi = (event as any).data?.object?.payment_intent;
    if (typeof pi !== "string") return event;
    try {
      const r = await fetch(`https://api.stripe.com/v1/payment_intents/${pi}?expand[]=latest_charge.balance_transaction`, { headers: { Authorization: `Bearer ${key}` } });
      const p = await r.json();
      const ch = p?.latest_charge; const bt = ch?.balance_transaction;
      if (!ch?.id) return event;
      return { ...event, _enrich: { charge_id: ch.id, balance_transaction_id: bt?.id ?? null, fee_amount: typeof bt?.fee === "number" ? bt.fee : null } };
    } catch { return event; }
  },
};

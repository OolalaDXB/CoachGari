/* =============================================================
   CG-003 — stripe-webhook  (on BEAU PH since the productisation step)
   1. The Stripe ADAPTER verifies the signature (Stripe's own scheme, raw
      body, 300 s tolerance) and refuses an event whose livemode does not
      match PAYMENTS_MODE (test | live; unset → everything refused).
   2. The adapter enriches checkout.session.completed with fee / charge /
      balance-transaction evidence.
   3. The Coach Gari HOST ADAPTER (process_stripe_event) hands the verified
      event to BEAU PH — evidence kept verbatim, request normalized — and
      reconciles a normalized "paid" event into the authoritative ledger
      exactly once (idempotent on the Stripe event id and on the BEAU PH
      payment event).
   4. The emails the database queued for that order (customer confirmation
      or receipt, support thank-you, owner notice) are sent through the
      outbox if Resend is configured — after the ledger is committed, never
      before; a send failure is a retryable outbox row, never a 500 here.

   Secrets (Supabase secrets): STRIPE_WEBHOOK_SECRET (whsec_…),
   STRIPE_SECRET_KEY (for fee enrichment), PAYMENTS_MODE, RESEND_API_KEY +
   EMAIL_FROM + EMAIL_REPLY_TO (email; optional). Logs carry only event id / type, order reference, BEAU PH
   request id, Checkout Session id, normalized outcome — never secrets or
   card data. Subscribe the endpoint to: checkout.session.completed,
   checkout.session.expired, refund.created, refund.updated,
   charge.dispute.created, charge.dispute.updated, charge.dispute.closed,
   payment_intent.succeeded, payment_intent.payment_failed (the last two carry
   the recurring rail's off-session charges; any other PaymentIntent event is
   recognised and ignored rather than settled a second time).
   ============================================================= */
import { createClient } from "npm:@supabase/supabase-js@2.116.0";
import { providers } from "../../../beau-ph/core/registry.ts";
import { processStripeEvent } from "../../../beau-ph/host-adapters/coach-gari/adapter.ts";
import { feeEvidence } from "../../../beau-ph/providers/stripe/adapter.ts";
import { mandateFromSession } from "../../../beau-ph/providers/stripe/recurring.ts";
import { drainOutbox } from "../_shared/email.ts";   // host concern: the outbox (queued by the DB when the payment reconciled)

const env = (name: string) => Deno.env.get(name);
const log = (event: string, data: Record<string, unknown> = {}) => console.log(JSON.stringify({ fn: "stripe-webhook", event, ...data }));
const reply = (status: number, body: unknown) => new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });

Deno.serve(async (req: Request) => {
  if (req.method !== "POST") return reply(405, { ok: false });
  const raw = await req.text();                      // exact raw bytes — never re-serialised before verification

  // 1. provider adapter: verification (only a verified event may reach BEAU PH)
  const verified = await providers.stripe.verifyWebhook!({ headers: req.headers, rawBody: raw }, env);
  if (!verified.ok) {
    const notConfigured = verified.reason === "webhook_not_configured";
    log(notConfigured ? "not_configured" : verified.reason.startsWith("bad_signature") ? "bad_signature" : verified.reason, { reason: verified.reason });
    return reply(notConfigured ? 503 : 400, { ok: false, error: notConfigured ? "webhook_not_configured" : verified.reason.split(":")[0] });
  }

  // 2. provider adapter: evidence enrichment (fees) — never changes state
  const event = await providers.stripe.enrich!(verified.payload, env);
  const supabase = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, { auth: { persistSession: false } });

  /* 2b. RECURRING: an off-session charge is a PaymentIntent, not a Checkout
     session, so it gets its own reconciler — the same separation the PayPal
     rail has. Only PaymentIntents this system created off-session are handled:
     the marker is set by chargeOffSession and nothing else sets it, so an
     ordinary Checkout PaymentIntent falls through and is never settled twice.
     The fee lives on the balance transaction here exactly as it does there. */
  // deno-lint-ignore no-explicit-any
  const pio = (event as any).data?.object ?? {};
  if (String(event.type ?? "").startsWith("payment_intent.") && pio?.metadata?.cg_source === "subscription_auto") {
    let enrich: Record<string, unknown> = {};
    if (event.type === "payment_intent.succeeded" && typeof pio.id === "string") {
      enrich = await feeEvidence(pio.id, String(pio.currency ?? ""), Deno.env.get("STRIPE_SECRET_KEY")!) as unknown as Record<string, unknown>;
    }
    const { data: cd, error: cErr } = await supabase.rpc("process_stripe_charge_event", { p_event: { ...event, _enrich: enrich } });
    if (cErr) { log("charge_process_failed", { event_id: event.id, type: event.type, code: cErr.code }); return reply(500, { ok: false, error: "processing_failed" }); }
    log("charge_processed", { event_id: event.id, type: event.type, ...(cd ?? {}) });
    // the receipt and the owner notice were queued by the reconciler, like any other paid order
    if (cd?.status === "processed" && cd?.order && !cd?.duplicate) {
      try {
        const { data: o } = await supabase.from("orders").select("id").eq("reference", cd.order).single();
        if (o?.id) log("emails", { order: cd.order, ...(await drainOutbox(supabase, env, { order_id: o.id }, log)) });
      } catch (e) { log("emails_error", { message: (e as Error).message.slice(0, 120) }); }
    }
    return reply(200, { ok: true, ...cd });
  }

  // 3. host adapter → BEAU PH → authoritative ledger (idempotent; Stripe retries on 500)
  const { data, error } = await processStripeEvent(supabase, event);
  // deno-lint-ignore no-explicit-any
  const obj = (event as any).data?.object ?? {};
  const safe = { event_id: event.id, type: event.type, livemode: event.livemode === true, session: typeof obj.id === "string" && obj.id.startsWith("cs_") ? obj.id : null };
  if (error) { log("process_failed", { ...safe, code: error.code }); return reply(500, { ok: false, error: "processing_failed" }); }
  log("processed", { ...safe, status: data?.status, duplicate: !!data?.duplicate, order: data?.order ?? null, request_id: data?.beau_ph?.request_id ?? null,
                     beau_ph: data?.beau_ph?.outcome ?? data?.beau_ph ?? null, note: data?.note ?? null });

  /* 3b. RECURRING: a session that was told to keep the card has left a mandate
     behind. Read after the ledger is committed, never before — a mandate is
     worth nothing if the payment it came with did not land — and a failure
     here is logged rather than raised: losing a mandate costs one month of
     manual invoicing, while failing the webhook would cost the payment. */
  if (event.type === "checkout.session.completed" && data?.status === "processed" && data?.order && !data?.duplicate) {
    try {
      const sid = typeof obj.id === "string" && obj.id.startsWith("cs_") ? obj.id : null;
      if (sid && obj.customer) {
        const m = await mandateFromSession(sid, env);
        if (m) {
          const { data: rec } = await supabase.rpc("subscription_mandate_record", {
            p_order_reference: data.order,
            p: { customer_id: m.customerId, payment_method_id: m.paymentMethodId, brand: m.brand, last4: m.last4, exp_month: m.expMonth, exp_year: m.expYear },
          });
          // never the ids, never anything that could be replayed: only that a card is now on file
          log("mandate", { order: data.order, recorded: rec?.ok === true, reason: rec?.reason ?? null, brand: m.brand, last4: m.last4 });
        }
      }
    } catch (e) { log("mandate_error", { message: (e as Error).message.slice(0, 120) }); }
  }

  // 4. host concern: the emails queued for this order (idempotent rows; a replayed event finds nothing pending)
  if (event.type === "checkout.session.completed" && data?.status === "processed" && data?.order && !data?.duplicate) {
    try {
      const { data: o } = await supabase.from("orders").select("id").eq("reference", data.order).single();
      if (o?.id) log("emails", { order: data.order, ...(await drainOutbox(supabase, env, { order_id: o.id }, log)) });
    } catch (e) { log("emails_error", { message: (e as Error).message.slice(0, 120) }); }   // never fails the webhook
  }
  return reply(200, { ok: true, ...data });
});

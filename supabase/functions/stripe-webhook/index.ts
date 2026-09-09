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
   charge.dispute.created, charge.dispute.updated, charge.dispute.closed.
   ============================================================= */
import { createClient } from "npm:@supabase/supabase-js@2.116.0";
import { providers } from "../../../beau-ph/core/registry.ts";
import { processStripeEvent } from "../../../beau-ph/host-adapters/coach-gari/adapter.ts";
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

  // 3. host adapter → BEAU PH → authoritative ledger (idempotent; Stripe retries on 500)
  const supabase = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, { auth: { persistSession: false } });
  const { data, error } = await processStripeEvent(supabase, event);
  // deno-lint-ignore no-explicit-any
  const obj = (event as any).data?.object ?? {};
  const safe = { event_id: event.id, type: event.type, livemode: event.livemode === true, session: typeof obj.id === "string" && obj.id.startsWith("cs_") ? obj.id : null };
  if (error) { log("process_failed", { ...safe, code: error.code }); return reply(500, { ok: false, error: "processing_failed" }); }
  log("processed", { ...safe, status: data?.status, duplicate: !!data?.duplicate, order: data?.order ?? null, request_id: data?.beau_ph?.request_id ?? null,
                     beau_ph: data?.beau_ph?.outcome ?? data?.beau_ph ?? null, note: data?.note ?? null });

  // 4. host concern: the emails queued for this order (idempotent rows; a replayed event finds nothing pending)
  if (event.type === "checkout.session.completed" && data?.status === "processed" && data?.order && !data?.duplicate) {
    try {
      const { data: o } = await supabase.from("orders").select("id").eq("reference", data.order).single();
      if (o?.id) log("emails", { order: data.order, ...(await drainOutbox(supabase, env, { order_id: o.id }, log)) });
    } catch (e) { log("emails_error", { message: (e as Error).message.slice(0, 120) }); }   // never fails the webhook
  }
  return reply(200, { ok: true, ...data });
});

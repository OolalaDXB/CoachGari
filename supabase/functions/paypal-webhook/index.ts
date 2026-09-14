/* =============================================================
   paypal-webhook — a PayPal event reaching the Coach Gari ledger

   1. The PayPal ADAPTER verifies the signature by asking PayPal itself
      (/v1/notifications/verify-webhook-signature) with the transmission
      headers, the raw body and the configured webhook id. Only a SUCCESS
      verification continues. The adapter stamps the deployment mode onto the
      verified event, because PayPal publishes no livemode flag and the mode of
      the credentials that verified it is the only honest source.
   2. The Coach Gari HOST ADAPTER (process_paypal_event) hands the verified
      event to BEAU PH — evidence verbatim, request normalized — and reconciles
      a normalized "paid" event into the ledger exactly once, idempotent on the
      PayPal event id and on the BEAU PH payment event.
   3. The emails the database queued for that order are drained afterwards,
      never before; a send failure is a retryable outbox row, never a 500 here.

   Confirmation is this webhook and nothing else. The payer's browser returning
   from PayPal is a navigation, not a receipt, and no return URL marks anything
   paid.

   Secrets: PAYPAL_CLIENT_ID, PAYPAL_SECRET, PAYPAL_WEBHOOK_ID, PAYMENTS_MODE.
   Subscribe the endpoint to: PAYMENT.CAPTURE.COMPLETED, PAYMENT.CAPTURE.DENIED,
   PAYMENT.CAPTURE.REFUNDED, PAYMENT.CAPTURE.REVERSED, CHECKOUT.ORDER.APPROVED.
   Logs carry the event id and type, the order reference and the normalized
   outcome — never a credential, never a payer's details.
   ============================================================= */
import { createClient } from "npm:@supabase/supabase-js@2.116.0";
import { providers } from "../../../beau-ph/core/registry.ts";
import { drainOutbox } from "../_shared/email.ts";

const env = (name: string) => Deno.env.get(name);
const log = (event: string, data: Record<string, unknown> = {}) => console.log(JSON.stringify({ fn: "paypal-webhook", event, ...data }));
const reply = (status: number, body: unknown) => new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });

Deno.serve(async (req: Request) => {
  if (req.method !== "POST") return reply(405, { ok: false });
  const raw = await req.text();                 // exact bytes — PayPal verifies against what it sent

  const verified = await providers.paypal.verifyWebhook!({ headers: req.headers, rawBody: raw }, env);
  if (!verified.ok) {
    const notConfigured = verified.reason === "not_configured";
    log(notConfigured ? "not_configured" : verified.reason, { reason: verified.reason });
    // 503 while unconfigured so PayPal retries once the secrets are set; 400 for a bad signature, which retrying cannot fix.
    return reply(notConfigured ? 503 : 400, { ok: false, error: notConfigured ? "webhook_not_configured" : "invalid_event" });
  }

  const supabase = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, { auth: { persistSession: false } });
  const { data, error } = await supabase.rpc("process_paypal_event", { p_event: verified.payload });

  const safe = { event_id: verified.providerEventId, type: verified.eventType };
  if (error) { log("process_failed", { ...safe, code: error.code }); return reply(500, { ok: false, error: "processing_failed" }); }
  log("processed", { ...safe, status: data?.status, duplicate: !!data?.duplicate, order: data?.order ?? null,
                     note: data?.note ?? null, beau_ph: data?.beau_ph?.outcome ?? null });

  if (verified.eventType === "PAYMENT.CAPTURE.COMPLETED" && data?.status === "processed" && data?.order && !data?.duplicate) {
    try {
      const { data: o } = await supabase.from("orders").select("id").eq("reference", data.order).single();
      if (o?.id) log("emails", { order: data.order, ...(await drainOutbox(supabase, env, { order_id: o.id }, log)) });
    } catch (e) { log("emails_error", { message: (e as Error).message.slice(0, 120) }); }   // never fails the webhook
  }
  return reply(200, { ok: true, ...data });
});

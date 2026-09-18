/* =============================================================
   Recurring billing — collecting from a card that is already on file

     POST {action:"charge"}   header x-outbox-key: <key held in outbox_keys>

   WHAT IT DOES, AND THE ORDER MATTERS. For each invoice the database says is
   chargeable it: makes (or finds) the order through the ordinary RPC, charges
   the stored card off-session, and records the API's answer. It does NOT mark
   anything paid. The signature-verified webhook does that, exactly as it does
   for a card the client typed in themselves, so there is ONE path by which a
   payment can come into existence and one place to look when a figure is
   disputed. What this function returns is a promise from Stripe; what the
   webhook receives is the fact.

   WHY IT IS NOT ALLOWED TO DECIDE ANYTHING. The list of what may be charged,
   the amount and the currency all come from the database, which checks — every
   run — that the plan is on auto, that a mandate exists, that the period has
   started, that the invoice is still open, and that the package has not been
   paid on some other rail in the meantime. This function does no arithmetic
   and reads no price. A bug here can fail to collect; it cannot collect the
   wrong thing from the wrong person.

   IDEMPOTENCY IS NOT OPTIONAL. Every charge carries the BEAU PH charge row id
   as Stripe's idempotency key, and there is one charge row per cycle for ever
   (a unique index says so). A retry, a duplicated cron tick or a redeployment
   mid-flight returns the original PaymentIntent rather than making a second
   one. Charging a coaching client twice for the same month is the single worst
   thing this system could do, so it is guarded in three independent places:
   the queue, the key, and the amount check in the webhook.

   A DECLINE IS ORDINARY. Cards expire and banks say no. The invoice stays
   open, the client keeps the pay link they already have, and they can settle
   by transfer, PayPal or cash like anybody else. Nothing is cancelled and
   nobody is locked out of their sessions. After three consecutive failures the
   database drops the mandate and the plan goes back to being invoiced — and
   the client is told, once, in plain language.

   Secrets: STRIPE_SECRET_KEY, PAYMENTS_MODE (a key whose mode differs from it
   refuses to charge anything). Logs carry a charge id, an outcome and a
   decline code — never a card, a customer id, a payment-method id or an
   amount tied to a name.
   ============================================================= */
import { createClient } from "npm:@supabase/supabase-js@2.116.0";
import { stripe } from "../../../beau-ph/providers/stripe/adapter.ts";
import { chargeOffSession } from "../../../beau-ph/providers/stripe/recurring.ts";

const env = (n: string) => Deno.env.get(n);
const json = (status: number, body: unknown) => new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });
const log = (event: string, data: Record<string, unknown> = {}) => console.log(JSON.stringify({ fn: "subscription-charge", event, ...data }));

type Due = {
  charge_id: string; cycle_id: string; amount: number; currency: string; attempt: number;
  customer_id: string | null; payment_method_id: string | null;
  order_reference: string | null; description: string | null; customer_email: string | null;
};

Deno.serve(async (req: Request) => {
  if (req.method !== "POST") return json(405, { ok: false, error: "method_not_allowed" });
  const sb = createClient(env("SUPABASE_URL")!, env("SUPABASE_SERVICE_ROLE_KEY")!, { auth: { persistSession: false } });

  const key = req.headers.get("x-outbox-key") ?? "";
  const { data: authorized } = await sb.rpc("subscription_charge_authorize", { p_key: key });
  if (authorized !== true) { log("unauthorized"); return json(401, { ok: false, error: "unauthorized" }); }

  let body: Record<string, unknown> = {};
  try { body = JSON.parse(await req.text() || "{}"); } catch { return json(400, { ok: false, error: "invalid_json" }); }
  if (body.action !== "charge" && body.action !== undefined) return json(400, { ok: false, error: "validation", fields: ["action"] });

  /* Fail closed on configuration. Nothing is claimed, so the queue is exactly
     where it was when the key is fixed — an unconfigured deployment loses no
     invoices, it simply collects none. */
  const rt = stripe.runtime(env);
  if (!rt.configured) { log("not_configured", { reason: rt.reason ?? null }); return json(200, { ok: true, configured: false, charged: 0 }); }

  const limit = Math.min(Math.max(Number(body.limit ?? 5) || 5, 1), 20);
  const { data: due, error: dueErr } = await sb.rpc("subscription_charge_claim", { p_limit: limit });
  if (dueErr) { log("claim_failed", { code: dueErr.code }); return json(500, { ok: false, error: "server_error" }); }
  const rows = (Array.isArray(due) ? due : []) as Due[];

  let charged = 0, declined = 0, skipped = 0;
  for (const r of rows) {
    try {
      if (!r.customer_id || !r.payment_method_id) {
        // the mandate went between the enqueue and now — not a decline, nothing to report to the client
        await sb.rpc("subscription_charge_result", { p_charge_id: r.charge_id, p_ok: false, p_error: "no card on file", p_decline_code: "no_mandate" });
        skipped++; continue;
      }

      /* The order comes from the same RPC a client's own payment uses, so an
         auto charge and a manual one land on one row with one set of guards.
         It returns the existing pending order when there is one — which is
         exactly what happens when a client opened the pay link and did not
         finish. */
      let reference = r.order_reference;
      if (!reference) {
        const { data: o, error: oErr } = await sb.rpc("subscription_charge_order", { p_cycle_id: r.cycle_id });
        if (oErr || !o?.reference) {
          await sb.rpc("subscription_charge_result", { p_charge_id: r.charge_id, p_ok: false, p_error: `no order: ${oErr?.message ?? "unknown"}`.slice(0, 200), p_decline_code: "no_order" });
          skipped++; continue;
        }
        reference = o.reference as string;
      }

      const res = await chargeOffSession({
        chargeId: r.charge_id, customerId: r.customer_id, paymentMethodId: r.payment_method_id,
        amount: r.amount, currency: r.currency,                          // trusted: the cycle's snapshot
        description: r.description ?? "Coach Gari coaching",
        orderReference: reference, customerEmail: r.customer_email,
      }, env);

      if (res.ok) {
        await sb.rpc("subscription_charge_result", { p_charge_id: r.charge_id, p_ok: true, p_provider_reference: res.paymentIntentId });
        charged++;
        log("charged", { charge_id: r.charge_id, attempt: r.attempt });   // no amount, no name, no card
      } else {
        await sb.rpc("subscription_charge_result", {
          p_charge_id: r.charge_id, p_ok: false, p_provider_reference: res.paymentIntentId,
          p_error: res.reason, p_decline_code: res.declineCode, p_retryable: res.retryable,
        });
        declined++;
        log("declined", { charge_id: r.charge_id, attempt: r.attempt, decline_code: res.declineCode, retryable: res.retryable });
      }
    } catch (e) {
      /* An exception leaves the row 'sent' with its lease running. The next
         enqueue revives it once the lease expires — safe only because the
         charge is idempotent on the row id, so a revived row cannot become a
         second charge. */
      skipped++;
      log("charge_error", { charge_id: r.charge_id, error: String(e).slice(0, 120) });
    }
  }

  log("run", { seen: rows.length, charged, declined, skipped });
  return json(200, { ok: true, configured: true, seen: rows.length, charged, declined, skipped });
});

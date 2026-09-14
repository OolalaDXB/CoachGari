/* =============================================================
   The Stripe fee, fetched after the fact

     POST {action:"sweep"}   header x-outbox-key: <key held in outbox_keys>

   WHY IT EXISTS. The commission is 10 % of the NET — gross minus the provider's
   fee. Stripe creates the balance transaction that carries that fee
   asynchronously, and the webhook cannot wait for it: the adapter retries three
   times over about 1.6 seconds and then gives up, which is right, because a
   webhook that waits minutes is a webhook that times out. What was missing is
   anything that went back for it. Until it lands, `fee_known` is false, the
   ledger marks the earning 'fee_pending', and it cannot be paid out — so the
   only cost of a late fee is a delayed payout, never a wrong one.

   This asks Stripe again, on a schedule, for exactly the payments the database
   says are still waiting. It records the fee through payment_fee_record(),
   which refuses a fee in the wrong currency, refuses to overwrite one already
   known, and recomputes the earning on the true net.

   It reads the fee through the same adapter function the webhook uses
   (feeEvidence), so there is one implementation of "what does Stripe say this
   cost", not two that can drift.
   ============================================================= */
import { createClient } from "npm:@supabase/supabase-js@2.116.0";
import { feeEvidence, stripe } from "../../../beau-ph/providers/stripe/adapter.ts";

const env = (n: string) => Deno.env.get(n);
const json = (status: number, body: unknown) => new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });
const log = (event: string, data: Record<string, unknown> = {}) => console.log(JSON.stringify({ fn: "stripe-fees", event, ...data }));

type Row = { payment_id: string; provider: string; currency: string; amount: number; payment_intent: string; paid_at: string | null };

Deno.serve(async (req: Request) => {
  if (req.method !== "POST") return json(405, { ok: false, error: "method_not_allowed" });
  const sb = createClient(env("SUPABASE_URL")!, env("SUPABASE_SERVICE_ROLE_KEY")!, { auth: { persistSession: false } });

  const key = req.headers.get("x-outbox-key") ?? "";
  const { data: authorized } = await sb.rpc("stripe_fees_authorize", { p_key: key });
  if (authorized !== true) { log("unauthorized"); return json(401, { ok: false, error: "unauthorized" }); }

  let body: Record<string, unknown> = {};
  try { body = JSON.parse(await req.text() || "{}"); } catch { return json(400, { ok: false, error: "invalid_json" }); }
  if (body.action !== "sweep" && body.action !== undefined) return json(400, { ok: false, error: "validation", fields: ["action"] });

  if (!stripe.runtime(env).configured) { log("not_configured"); return json(200, { ok: true, configured: false, recorded: 0 }); }

  const limit = Math.min(Math.max(Number(body.limit ?? 20) || 20, 1), 100);
  const { data: due, error: dueErr } = await sb.rpc("payments_awaiting_fee", { p_limit: limit });
  if (dueErr) { log("due_failed", { code: dueErr.code }); return json(500, { ok: false, error: "server_error" }); }
  const rows = (Array.isArray(due) ? due : []) as Row[];

  let recorded = 0, stillWaiting = 0, failed = 0;
  for (const r of rows) {
    try {
      /* One attempt per payment per run. The retry here is the schedule, not a
         loop: a fee that has not landed after ten minutes will not land because
         we asked three times in a row. */
      const fee = await feeEvidence(r.payment_intent, r.currency, env("STRIPE_SECRET_KEY")!, { attempts: 1 });
      if (typeof fee.fee_amount !== "number") { stillWaiting++; continue; }
      const { error } = await sb.rpc("payment_fee_record", {
        p_payment_id: r.payment_id, p_fee_amount: fee.fee_amount, p_fee_currency: fee.fee_currency ?? r.currency,
        p_charge_id: fee.charge_id, p_balance_transaction_id: fee.balance_transaction_id,
      });
      if (error) { failed++; log("record_failed", { code: error.code }); continue; }   // never the reference, never the amount
      recorded++;
    } catch (e) {
      failed++;
      log("stripe_failed", { error: String(e).slice(0, 120) });   // a status, never a payment intent
    }
  }
  log("swept", { seen: rows.length, recorded, still_waiting: stillWaiting, failed });
  return json(200, { ok: true, configured: true, seen: rows.length, recorded, still_waiting: stillWaiting, failed });
});

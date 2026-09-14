/* =============================================================
   BEAU PH — close superseded requests at the provider

     POST {action:"drain"}   header x-outbox-key: <key held in outbox_keys>

   WHY IT EXISTS. When a request is superseded — the client paid by bank
   transfer, the coach took cash — the hub marks it cancelled and the ledger is
   right, but a Stripe Checkout session stays open for 24 hours and its URL is
   already in the client's inbox. The webhook for a second payment is correctly
   refused by the state machine, so no double ledger entry is possible; the
   money still reaches Stripe and has to be refunded by hand. This closes the
   door instead of proving it was locked afterwards.

   The database records the fact (beau_ph.provider_cancellations) and this
   function delivers it, because cancelling is an HTTP call and the code that
   supersedes a request is SQL the back-office runs directly. A slow provider
   must never hold the transaction that has already done the real work.

   WHAT IT WILL NOT DO. It cancels only what the queue hands it, by the
   provider's own reference. It never reads a request by order, never takes a
   reference from the request body, and never cancels a request that is paid —
   the queue only ever contains requests the database has already ended.

   The clear key lives in the Vault and is presented by pg_cron as x-outbox-key;
   this function only hands it back for a constant-time comparison.
   ============================================================= */
import { createClient } from "npm:@supabase/supabase-js@2.116.0";
import { adapter } from "../../../beau-ph/core/registry.ts";

const env = (n: string) => Deno.env.get(n);
const json = (status: number, body: unknown) => new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });
const log = (event: string, data: Record<string, unknown> = {}) => console.log(JSON.stringify({ fn: "ph-cancel", event, ...data }));

type Row = { id: string; merchant: string; provider: string; provider_reference: string; attempts: number; mode: string };

Deno.serve(async (req: Request) => {
  if (req.method !== "POST") return json(405, { ok: false, error: "method_not_allowed" });
  const sb = createClient(env("SUPABASE_URL")!, env("SUPABASE_SERVICE_ROLE_KEY")!, { auth: { persistSession: false } });

  const key = req.headers.get("x-outbox-key") ?? "";
  const { data: authorized } = await sb.rpc("ph_cancel_authorize", { p_key: key });
  if (authorized !== true) { log("unauthorized"); return json(401, { ok: false, error: "unauthorized" }); }

  let body: Record<string, unknown> = {};
  try { body = JSON.parse(await req.text() || "{}"); } catch { return json(400, { ok: false, error: "invalid_json" }); }
  if (body.action !== "drain" && body.action !== undefined) return json(400, { ok: false, error: "validation", fields: ["action"] });

  const limit = Math.min(Math.max(Number(body.limit ?? 20) || 20, 1), 100);
  const { data: due, error: dueErr } = await sb.rpc("cancellations_due", { p_limit: limit });
  if (dueErr) { log("due_failed", { code: dueErr.code }); return json(500, { ok: false, error: "server_error" }); }
  const rows = (Array.isArray(due) ? due : []) as Row[];

  let done = 0, skipped = 0, failed = 0;
  for (const r of rows) {
    const a = adapter(r.provider);
    /* A rail with no cancel, or one whose deployment secrets are absent, cannot
       be retried into working. Mark it skipped with the reason so the queue says
       what happened, instead of counting to five and calling it a failure. */
    if (!a || typeof a.cancel !== "function") {
      await sb.rpc("cancellation_mark", { p_id: r.id, p_ok: false, p_skip: true, p_error: `no cancel on ${r.provider}` });
      skipped++; continue;
    }
    if (!a.runtime(env).configured) {
      await sb.rpc("cancellation_mark", { p_id: r.id, p_ok: false, p_skip: true, p_error: `${r.provider} not configured in this deployment` });
      skipped++; continue;
    }
    try {
      const res = await a.cancel(r.provider_reference, env);
      if (res.ok) { await sb.rpc("cancellation_mark", { p_id: r.id, p_ok: true }); done++; }
      else {
        /* The provider saying "already gone" is success: an expired or already
           cancelled session is exactly the state we were asking for. */
        const reason = String(res.reason ?? "");
        if (/\b(404|410)\b/.test(reason)) { await sb.rpc("cancellation_mark", { p_id: r.id, p_ok: true }); done++; }
        else { await sb.rpc("cancellation_mark", { p_id: r.id, p_ok: false, p_error: reason.slice(0, 200) }); failed++; }
      }
    } catch (e) {
      const m = String(e).slice(0, 200);
      await sb.rpc("cancellation_mark", { p_id: r.id, p_ok: false, p_error: m });
      failed++;
      log("cancel_failed", { provider: r.provider, error: m });   // never the provider reference
    }
  }
  log("drained", { done, skipped, failed });
  return json(200, { ok: true, done, skipped, failed });
});

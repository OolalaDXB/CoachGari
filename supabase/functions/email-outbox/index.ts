/* =============================================================
   Coach Gari — email-outbox
     POST {action:"drain"}   header x-outbox-key: <database-issued key>
          → {ok, claimed, sent, retry, failed}
            Sends the due rows of public.email_events (the ones no request
            drained on the spot: coach-side cancels / reschedules from the
            admin, retries after a Resend outage). pg_cron calls this every
            two minutes through pg_net (public.email_outbox_kick) with the
            key it holds in public.outbox_keys — no secret to paste anywhere.
     POST {action:"status"}  same header
          → {ok, configured, missing[], from, reply_to, domain, domain_status}
            Presence of the Resend configuration and the sending domain's
            verification state as Resend reports it. Never a value.
   Not browser-facing (no CORS); an unknown or missing key is a 401.
   ============================================================= */
import { createClient } from "npm:@supabase/supabase-js@2.116.0";
import { drainOutbox, emailStatus } from "../_shared/email.ts";

const env = (name: string) => Deno.env.get(name);
const log = (event: string, data: Record<string, unknown> = {}) => console.log(JSON.stringify({ fn: "email-outbox", event, ...data }));
const json = (status: number, body: unknown) => new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });

Deno.serve(async (req: Request) => {
  if (req.method !== "POST") return json(405, { ok: false, error: "method_not_allowed" });
  const sb = createClient(env("SUPABASE_URL")!, env("SUPABASE_SERVICE_ROLE_KEY")!, { auth: { persistSession: false } });
  const key = req.headers.get("x-outbox-key") ?? "";
  const { data: authorized } = await sb.rpc("email_outbox_authorize", { p_key: key });
  if (authorized !== true) { log("unauthorized"); return json(401, { ok: false, error: "unauthorized" }); }

  let body: Record<string, unknown> = {};
  try { body = JSON.parse(await req.text() || "{}"); } catch { return json(400, { ok: false, error: "invalid_json" }); }

  if (body.action === "status") {
    const s = await emailStatus(env);
    log("status", { configured: s.configured, domain_status: s.domain_status });
    return json(200, { ok: true, ...s });
  }
  if (body.action === "drain" || body.action === undefined) {
    const limit = Number.isInteger(body.limit) ? Math.min(Math.max(Number(body.limit), 1), 100) : 50;
    const r = await drainOutbox(sb, env, { limit }, log);
    log("drained", r);
    return json(200, { ok: true, ...r });
  }
  return json(400, { ok: false, error: "validation", fields: ["action"] });
});

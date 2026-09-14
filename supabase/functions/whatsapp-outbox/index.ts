/* Coach Gari — the WhatsApp outbox drain (CG-019).

     POST {action:"drain"}    header x-outbox-key: <key held in outbox_keys>
     POST {action:"status"}   same header — is a number connected? presence only.

   Sends the session reminder through the WhatsApp Cloud API. Business-initiated
   WhatsApp may only be a template approved in the Meta console, so a row carries
   a template name and its positional parameters, never free prose written here.

   When no number is connected — no token, no phone id — a due row is marked
   SKIPPED with the reason rather than left pending. A reminder is time-bound:
   holding it until the owner connects an account next month would deliver
   "see you tomorrow" about a session that happened in the past. The email was
   already sent on its own row, so nothing the client needed is lost.

   The clear key lives in Vault and is presented by pg_cron as x-outbox-key; this
   function only hands it back to the database for a constant-time comparison. */
import { createClient } from "npm:@supabase/supabase-js@2.116.0";

const env = (n: string) => Deno.env.get(n);
const log = (event: string, data: Record<string, unknown> = {}) => console.log(JSON.stringify({ fn: "whatsapp-outbox", event, ...data }));
const json = (status: number, body: unknown) => new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });
const GRAPH = "https://graph.facebook.com/v21.0";

type Row = { id: string; to_phone: string; template: string; params: unknown; language: string };

/* One template message. Returns the provider's message id, or throws with a
   status — never with the provider's body, which echoes the recipient's number. */
export async function sendTemplate(token: string, phoneId: string, r: Row, fetchImpl: typeof fetch = fetch): Promise<string> {
  const params = (Array.isArray(r.params) ? r.params : []).map((t) => ({ type: "text", text: String(t) }));
  const body = {
    messaging_product: "whatsapp",
    to: r.to_phone,
    type: "template",
    template: {
      name: r.template,
      language: { code: r.language || "en" },
      ...(params.length ? { components: [{ type: "body", parameters: params }] } : {}),
    },
  };
  const res = await fetchImpl(`${GRAPH}/${encodeURIComponent(phoneId)}/messages`, {
    method: "POST",
    headers: { Authorization: `Bearer ${token}`, "Content-Type": "application/json" },
    body: JSON.stringify(body),
  });
  if (!res.ok) throw new Error(`whatsapp ${res.status}`);
  const j = await res.json() as { messages?: { id?: string }[] };
  return j.messages?.[0]?.id ?? "";
}

Deno.serve(async (req: Request) => {
  if (req.method !== "POST") return json(405, { ok: false, error: "method_not_allowed" });
  const sb = createClient(env("SUPABASE_URL")!, env("SUPABASE_SERVICE_ROLE_KEY")!, { auth: { persistSession: false } });

  const key = req.headers.get("x-outbox-key") ?? "";
  const { data: authorized } = await sb.rpc("whatsapp_outbox_authorize", { p_key: key });
  if (authorized !== true) { log("unauthorized"); return json(401, { ok: false, error: "unauthorized" }); }

  let body: Record<string, unknown> = {};
  try { body = JSON.parse(await req.text() || "{}"); } catch { return json(400, { ok: false, error: "invalid_json" }); }

  const token = (env("WHATSAPP_TOKEN") ?? "").trim();
  const phoneId = (env("WHATSAPP_PHONE_NUMBER_ID") ?? "").trim();
  const configured = !!token && !!phoneId;

  if (body.action === "status") { log("status", { configured }); return json(200, { ok: true, configured }); }
  if (body.action !== "drain" && body.action !== undefined) return json(400, { ok: false, error: "validation", fields: ["action"] });

  const limit = Math.min(Math.max(Number(body.limit ?? 20) || 20, 1), 100);
  const { data: due, error: dueErr } = await sb.rpc("whatsapp_due", { p_limit: limit });
  if (dueErr) { log("due_failed", { code: dueErr.code }); return json(500, { ok: false, error: "server_error" }); }
  const rows = (Array.isArray(due) ? due : []) as Row[];

  if (!configured) {
    for (const r of rows) await sb.rpc("whatsapp_mark", { p_id: r.id, p_status: "skipped", p_error: "WhatsApp is not connected" });
    log("not_configured", { skipped: rows.length });
    return json(200, { ok: true, configured: false, skipped: rows.length });
  }

  let sent = 0, failed = 0;
  for (const r of rows) {
    try {
      const id = await sendTemplate(token, phoneId, r);
      await sb.rpc("whatsapp_mark", { p_id: r.id, p_status: "sent", p_provider_id: id });
      sent++;
    } catch (e) {
      const m = String(e).slice(0, 120);
      await sb.rpc("whatsapp_mark", { p_id: r.id, p_status: "failed", p_error: m });
      failed++;
      log("send_failed", { error: m });   // a status, never the number and never the body
    }
  }
  log("drained", { sent, failed });
  return json(200, { ok: true, configured: true, sent, failed });
});

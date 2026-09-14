/* Back-office push notifications — the sender.

     POST {action:"drain"}    header x-outbox-key: <key held in outbox_keys>
       Called by pg_cron through pg_net, the same way the email outbox is. Takes the
       pending events, sends one notification per live subscription, retires the
       subscriptions the push service reports as gone.

     POST {action:"status"}   same header
       Says whether VAPID is configured and how many subscriptions are live. Never
       returns a key, an endpoint or an email.

   The text of every notification is chosen here, from a fixed table keyed by the
   event kind. Nothing is interpolated: a push lands on a lock screen, so it says
   "New booking request", never who from. Whoever taps it opens the back-office and
   signs in as usual — the notification carries no access of its own. */
import { createClient } from "npm:@supabase/supabase-js@2.116.0";
import { sendPush, GONE, type Subscription, type Vapid } from "../_shared/webpush.ts";

const env = (n: string) => Deno.env.get(n);
const log = (event: string, data: Record<string, unknown> = {}) => console.log(JSON.stringify({ fn: "push", event, ...data }));
const json = (status: number, body: unknown) => new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });

/* One fixed sentence per kind. No value from the row ever reaches this text. */
const TEXT: Record<string, { t: string; u: string }> = {
  lead_notification:  { t: "New enquiry",             u: "/admin/#crm" },
  booking_confirmed:  { t: "New booking",             u: "/admin/#bookings" },
  payment_received:   { t: "Payment received",        u: "/admin/#finance" },
  booking_cancelled:  { t: "A booking was cancelled", u: "/admin/#bookings" },
  reschedule:         { t: "A session moved",         u: "/admin/#schedule" },
  collab_request:     { t: "New collaboration enquiry", u: "/admin/#collaborations" },
  collab_accepted:    { t: "A collaboration was accepted", u: "/admin/#collaborations" },
  collab_counter:     { t: "A counter-offer came in",  u: "/admin/#collaborations" },
  collab_declined:    { t: "A collaboration was declined", u: "/admin/#collaborations" },
  collab_reminder:    { t: "A collaboration is waiting on you", u: "/admin/#collaborations" },
  support_thanks:     { t: "Someone sent support",    u: "/admin/#finance" },
};
const FALLBACK = { t: "New activity in the back-office", u: "/admin/" };

const BACKOFF_MINUTES = [1, 5, 20, 60];
const MAX_ATTEMPTS = 5;

Deno.serve(async (req: Request) => {
  if (req.method !== "POST") return json(405, { ok: false, error: "method_not_allowed" });
  const sb = createClient(env("SUPABASE_URL")!, env("SUPABASE_SERVICE_ROLE_KEY")!, { auth: { persistSession: false } });

  const key = req.headers.get("x-outbox-key") ?? "";
  const { data: authorized } = await sb.rpc("push_outbox_authorize", { p_key: key });
  if (authorized !== true) { log("unauthorized"); return json(401, { ok: false, error: "unauthorized" }); }

  let body: Record<string, unknown> = {};
  try { body = JSON.parse(await req.text() || "{}"); } catch { return json(400, { ok: false, error: "invalid_json" }); }

  const { data: cfgRows } = await sb.rpc("push_sender_config");
  const cfg = Array.isArray(cfgRows) ? cfgRows[0] : cfgRows;
  const configured = !!(cfg?.vapid_public && cfg?.vapid_private);

  if (body.action === "status") {
    const { count } = await sb.from("push_subscriptions").select("id", { count: "exact", head: true }).is("disabled_at", null);
    const { count: pending } = await sb.from("push_events").select("id", { count: "exact", head: true }).eq("status", "pending");
    log("status", { configured, subscriptions: count ?? 0, pending: pending ?? 0 });
    return json(200, { ok: true, configured, subscriptions: count ?? 0, pending: pending ?? 0 });
  }

  if (body.action !== "drain" && body.action !== undefined) {
    return json(400, { ok: false, error: "validation", fields: ["action"] });
  }

  if (!configured) {
    log("not_configured");
    return json(200, { ok: true, configured: false, sent: 0, note: "VAPID keys are not set in push_config" });
  }
  const vapid: Vapid = { publicKey: cfg.vapid_public, privateKey: cfg.vapid_private, subject: cfg.subject };

  const { data: events } = await sb.from("push_events")
    .select("id,kind,attempts").eq("status", "pending").lte("next_attempt_at", new Date().toISOString())
    .order("id").limit(20);
  if (!events?.length) return json(200, { ok: true, configured: true, sent: 0 });

  const { data: subs } = await sb.from("push_subscriptions")
    .select("id,endpoint,p256dh,auth").is("disabled_at", null);

  let sent = 0, gone = 0;
  for (const ev of events) {
    if (!subs?.length) {                                    // nobody is listening: close the row, do not retry forever
      await sb.from("push_events").update({ status: "skipped", error: "no subscriptions", sent_at: new Date().toISOString() }).eq("id", ev.id);
      continue;
    }
    const msg = TEXT[ev.kind] ?? FALLBACK;
    const payload = JSON.stringify(msg);
    let delivered = 0; const failures: string[] = [];

    for (const s of subs) {
      try {
        const res = await sendPush(s as Subscription, payload, vapid);
        if (res.ok) { delivered++; await sb.from("push_subscriptions").update({ last_sent_at: new Date().toISOString(), failures: 0 }).eq("id", s.id); }
        else if (GONE(res.status)) { gone++; await sb.from("push_subscriptions").delete().eq("id", s.id); }
        else { failures.push(String(res.status)); }
      } catch (e) {
        failures.push(String(e).slice(0, 40));
      }
    }
    sent += delivered;

    if (delivered > 0 || !failures.length) {
      await sb.from("push_events").update({ status: "sent", sent_at: new Date().toISOString(), delivered, attempts: ev.attempts + 1 }).eq("id", ev.id);
    } else {
      const attempts = ev.attempts + 1;
      const done = attempts >= MAX_ATTEMPTS;
      const wait = BACKOFF_MINUTES[Math.min(attempts - 1, BACKOFF_MINUTES.length - 1)];
      await sb.from("push_events").update({
        status: done ? "failed" : "pending",
        attempts,
        next_attempt_at: new Date(Date.now() + wait * 60000).toISOString(),
        error: failures.join(",").slice(0, 120),
      }).eq("id", ev.id);
    }
  }

  log("drained", { events: events.length, sent, gone });
  return json(200, { ok: true, configured: true, events: events.length, sent, gone });
});

/* =============================================================
   CG-003 — stripe-webhook  (on BEAU PH since the productisation step)
   1. The Stripe ADAPTER verifies the signature (Stripe's own scheme, raw
      body, 300 s tolerance) and refuses live-mode events for a test merchant.
   2. The adapter enriches checkout.session.completed with fee / charge /
      balance-transaction evidence.
   3. The Coach Gari HOST ADAPTER (process_stripe_event) hands the verified
      event to BEAU PH — evidence kept verbatim, request normalized — and
      reconciles a normalized "paid" event into the authoritative ledger
      exactly once (idempotent on the Stripe event id and on the BEAU PH
      payment event).
   4. Queued transactional emails are sent if Resend is configured.

   Secrets (Supabase secrets): STRIPE_WEBHOOK_SECRET (whsec_…),
   STRIPE_SECRET_KEY (test, for fee enrichment), RESEND_API_KEY
   (optional). Subscribe the endpoint to: checkout.session.completed,
   checkout.session.expired, refund.created, refund.updated,
   charge.dispute.created, charge.dispute.updated, charge.dispute.closed.
   ============================================================= */
import { createClient } from "npm:@supabase/supabase-js@2";
import { providers } from "../../../beau-ph/core/registry.ts";
import { processStripeEvent } from "../../../beau-ph/host-adapters/coach-gari/adapter.ts";

const LEAD_TO = Deno.env.get("LEAD_TO_EMAIL") ?? "letsgo@coachgari.com";
const MAIL_FROM = Deno.env.get("MAIL_FROM") ?? "Coach Gari <yoursession@coachgari.com>";
const env = (name: string) => Deno.env.get(name);
const log = (event: string, data: Record<string, unknown> = {}) => console.log(JSON.stringify({ fn: "stripe-webhook", event, ...data }));
const reply = (status: number, body: unknown) => new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });

function esc(s: string) { return s.replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]!)); }
function fmt(iso: string, tz: string) {
  try { return new Intl.DateTimeFormat("en-GB", { dateStyle: "full", timeStyle: "short", timeZone: tz }).format(new Date(iso)) + ` (${tz})`; } catch { return iso; }
}

// Host concern (Coach Gari emails) — untouched by the BEAU PH boundary.
// deno-lint-ignore no-explicit-any
async function sendQueuedEmails(supabase: any, orderId: string) {
  const key = Deno.env.get("RESEND_API_KEY");
  const { data: events } = await supabase.from("email_events").select("id, kind, to_address, booking_id").eq("order_id", orderId).eq("status", "pending");
  if (!events?.length) return;
  if (!key) { log("emails_skipped", { reason: "RESEND_API_KEY not configured", count: events.length }); return; }
  const { data: b } = await supabase.from("bookings").select("reference, customer_name, customer_contact, start_at, session_timezone, services(title), tour_stops(city, country, venue)").eq("id", events[0].booking_id).single();
  if (!b) return;
  const when = fmt(b.start_at, b.session_timezone);
  const where = b.tour_stops ? `${b.tour_stops.city}, ${b.tour_stops.country}${b.tour_stops.venue ? " · " + b.tour_stops.venue : ""}` : "Online";
  for (const ev of events) {
    let subject: string, html: string, to: string;
    if (ev.kind === "booking_confirmed") {
      to = ev.to_address; subject = `You're booked — ${b.services.title}, ${when}`;
      html = `<div style="font-family:system-ui,sans-serif;font-size:16px;line-height:1.6;color:#0A0A0B;max-width:560px;margin:0 auto;padding:32px 24px">
        <p style="margin:0 0 20px;font-size:12px;letter-spacing:.08em;text-transform:uppercase;color:#6C6C78">Coach Gari · Confirmation</p>
        <h1 style="margin:0 0 16px;font-size:26px;letter-spacing:-.02em;line-height:1.15">You're booked, ${esc(b.customer_name)}.</h1>
        <p><b>${esc(b.services.title)}</b><br>${esc(when)}<br>${esc(where)}<br>Reference ${b.reference}</p>
        <p style="font-size:14px;color:#6C6C78">Need to move it? Reply to this email — it reaches Coach Gari directly.</p></div>`;
    } else if (ev.kind === "payment_received") {
      to = LEAD_TO; subject = `Payment received — ${b.reference} — ${b.customer_name}`;
      html = `<div style="font-family:system-ui,sans-serif;font-size:15px;line-height:1.55;color:#0A0A0B"><p><b>${esc(b.customer_name)}</b> · ${esc(b.customer_contact)}</p><p>${esc(b.services.title)} · ${esc(when)} · ${esc(where)}</p><p>Booking ${b.reference} is confirmed and paid (Stripe test mode).</p></div>`;
    } else { continue; }
    try {
      const r = await fetch("https://api.resend.com/emails", { method: "POST", headers: { Authorization: `Bearer ${key}`, "Content-Type": "application/json" },
        body: JSON.stringify({ from: MAIL_FROM, to: [to], reply_to: "letsgo@coachgari.com", subject, html, headers: { "X-Entity-Ref-ID": `${b.reference}:${ev.kind}` } }) });
      const j = await r.json().catch(() => ({}));
      await supabase.from("email_events").update({ status: r.ok ? "sent" : "failed", sent_at: r.ok ? new Date().toISOString() : null, provider_message_id: j?.id ?? null, error: r.ok ? null : `resend ${r.status}`, attempts: 1 }).eq("id", ev.id);
      log(r.ok ? "email_sent" : "email_failed", { kind: ev.kind, status: r.status });
    } catch (e) {
      await supabase.from("email_events").update({ status: "failed", error: (e as Error).message, attempts: 1 }).eq("id", ev.id);
    }
  }
}

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
  if (error) { log("process_failed", { type: event.type, code: error.code }); return reply(500, { ok: false, error: "processing_failed" }); }
  log("processed", { type: event.type, status: data?.status, duplicate: !!data?.duplicate, beau_ph: data?.beau_ph?.outcome ?? data?.beau_ph ?? null });

  // 4. host concern: queued emails
  if (event.type === "checkout.session.completed" && data?.status === "processed" && data?.order) {
    const { data: o } = await supabase.from("orders").select("id").eq("reference", data.order).single();
    if (o?.id) await sendQueuedEmails(supabase, o.id);
  }
  return reply(200, { ok: true, ...data });
});

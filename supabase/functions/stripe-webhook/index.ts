/* =============================================================
   CG-003 — stripe-webhook
   Verifies the Stripe signature, enriches checkout.session.completed
   with the Stripe fee (balance transaction), hands the event to
   process_stripe_event (idempotent, transactional), then sends any
   queued transactional emails if Resend is configured.

   Secrets (Supabase secrets): STRIPE_WEBHOOK_SECRET (whsec_…),
   STRIPE_SECRET_KEY (test, for fee enrichment), RESEND_API_KEY
   (optional). Subscribe the endpoint to: checkout.session.completed,
   checkout.session.expired, refund.created, refund.updated,
   charge.dispute.created, charge.dispute.updated, charge.dispute.closed.
   ============================================================= */
import { createClient } from "npm:@supabase/supabase-js@2";
// Stripe's signing scheme (t + "." + raw body, HMAC-SHA256, v1, 300 s tolerance) — shared with the Node unit test.
import { verifyStripeSignature } from "./signature.js";

const LEAD_TO = Deno.env.get("LEAD_TO_EMAIL") ?? "letsgo@coachgari.com";
const MAIL_FROM = Deno.env.get("MAIL_FROM") ?? "Coach Gari <yoursession@coachgari.com>";
const log = (event: string, data: Record<string, unknown> = {}) => console.log(JSON.stringify({ fn: "stripe-webhook", event, ...data }));

async function enrichFee(key: string, paymentIntent: string) {
  try {
    const r = await fetch(`https://api.stripe.com/v1/payment_intents/${paymentIntent}?expand[]=latest_charge.balance_transaction`, { headers: { Authorization: `Bearer ${key}` } });
    const pi = await r.json();
    const ch = pi?.latest_charge; const bt = ch?.balance_transaction;
    if (!ch?.id) return null;
    return { charge_id: ch.id, balance_transaction_id: bt?.id ?? null, fee_amount: typeof bt?.fee === "number" ? bt.fee : null };
  } catch { return null; }
}

function esc(s: string) { return s.replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]!)); }
function fmt(iso: string, tz: string) {
  try { return new Intl.DateTimeFormat("en-GB", { dateStyle: "full", timeStyle: "short", timeZone: tz }).format(new Date(iso)) + ` (${tz})`; } catch { return iso; }
}

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
  if (req.method !== "POST") return new Response(JSON.stringify({ ok: false }), { status: 405, headers: { "Content-Type": "application/json" } });
  const secret = Deno.env.get("STRIPE_WEBHOOK_SECRET");
  if (!secret) { log("not_configured"); return new Response(JSON.stringify({ ok: false, error: "webhook_not_configured" }), { status: 503, headers: { "Content-Type": "application/json" } }); }

  const raw = await req.text();                      // exact raw bytes — never re-serialised before verification
  const sig = await verifyStripeSignature(req.headers.get("stripe-signature"), raw, secret);
  if (!sig.ok) {
    log("bad_signature", { reason: sig.reason }); return new Response(JSON.stringify({ ok: false, error: "bad_signature", reason: sig.reason }), { status: 400, headers: { "Content-Type": "application/json" } });
  }
  let event: Record<string, unknown>;
  try { event = JSON.parse(raw); } catch { return new Response(JSON.stringify({ ok: false, error: "invalid_json" }), { status: 400, headers: { "Content-Type": "application/json" } }); }
  if (event.livemode === true) { log("livemode_event_refused"); return new Response(JSON.stringify({ ok: false, error: "live_mode_blocked" }), { status: 400, headers: { "Content-Type": "application/json" } }); }

  const supabase = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, { auth: { persistSession: false } });

  if (event.type === "checkout.session.completed") {
    const key = Deno.env.get("STRIPE_SECRET_KEY") ?? "";
    // deno-lint-ignore no-explicit-any
    const pi = (event as any).data?.object?.payment_intent;
    if (key.startsWith("sk_test_") && typeof pi === "string") {
      const enrich = await enrichFee(key, pi);
      if (enrich) (event as Record<string, unknown>)._enrich = enrich;
    }
  }

  const { data, error } = await supabase.rpc("process_stripe_event", { p_event: event });
  if (error) {
    log("process_failed", { type: event.type, code: error.code });
    return new Response(JSON.stringify({ ok: false, error: "processing_failed" }), { status: 500, headers: { "Content-Type": "application/json" } }); // Stripe retries; processing is idempotent
  }
  log("processed", { type: event.type, status: data?.status, duplicate: !!data?.duplicate });

  if (event.type === "checkout.session.completed" && data?.status === "processed") {
    const { data: o } = await supabase.from("orders").select("id").eq("reference", data.order).single();
    if (o?.id) await sendQueuedEmails(supabase, o.id);
  }
  return new Response(JSON.stringify({ ok: true, ...data }), { status: 200, headers: { "Content-Type": "application/json" } });
});

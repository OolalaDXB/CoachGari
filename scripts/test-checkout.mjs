/* CG-003 — Stripe TEST-mode round trip from a laptop.

   Usage:
     node scripts/test-checkout.mjs            # creates a hold + Checkout session, prints the URL
     node scripts/test-checkout.mjs --wait     # …then polls until the booking is confirmed by the webhook

   Requires the owner-side secrets on Supabase: STRIPE_SECRET_KEY (sk_test_…),
   STRIPE_WEBHOOK_SECRET (Stripe → Developers → Webhooks → endpoint
   https://<ref>.supabase.co/functions/v1/stripe-webhook). Pay with test card
   4242 4242 4242 4242, any future date, any CVC.

   Proves: hold → trusted order (forged amount ignored) → Checkout URL →
   (after paying) webhook → exactly one paid order, one confirmed booking, and
   the state endpoint reflects it. Ledger/idempotency/refund maths are covered
   by supabase/tests/cg003_payments.sql. */
import { CONFIG } from '../config.js';
import { randomUUID } from 'node:crypto';

const BOOKING = process.env.BOOKING_ENDPOINT || CONFIG.BOOKING_ENDPOINT;
const CHECKOUT = process.env.CHECKOUT_ENDPOINT || CONFIG.CHECKOUT_ENDPOINT;
const ORIGIN = process.env.BOOKING_ORIGIN || 'https://coachgari.com';
const SERVICE = process.env.BOOKING_SERVICE || 'conversation';
const wait = process.argv.includes('--wait');
const H = { 'Content-Type': 'application/json', Origin: ORIGIN };
const j = async (r) => ({ status: r.status, body: await r.json().catch(() => null) });
const day = (o) => { const d = new Date(); d.setUTCDate(d.getUTCDate() + o); return d.toISOString().slice(0, 10); };
function fail(msg) { console.error('FAIL  ' + msg); process.exit(1); }

const svc = (await j(await fetch(`${BOOKING}?action=services`, { headers: H }))).body?.services?.find((s) => s.slug === SERVICE);
if (!svc || svc.price_amount === null) fail(`service ${SERVICE} not payable`);

let slot = null;
for (let i = 1; i <= 14 && !slot; i++) {
  const r = await j(await fetch(`${BOOKING}?action=slots&service=${SERVICE}&from=${day(i)}&to=${day(i)}&tz=UTC`, { headers: H }));
  slot = r.body?.slots?.[0] ?? null;
}
if (!slot) fail('no slot in the next 14 days');

const hold = await j(await fetch(BOOKING, { method: 'POST', headers: H, body: JSON.stringify({
  action: 'hold', service: SERVICE, start_at: slot.start_at, idempotency_key: randomUUID(),
  name: 'Checkout Test', contact: process.env.TEST_EMAIL || 'checkout-test@coachgari.com', notes: 'CG-003 test — safe to cancel' }) }));
if (hold.status !== 200) fail(`hold ${hold.status} ${JSON.stringify(hold.body)}`);
const b = hold.body.booking;
console.log(`PASS  hold ${b.reference} at ${b.start_at} (${b.session_timezone}) — ${b.price_amount} ${b.currency}`);

// forged amount fields must be ignored
const co = await j(await fetch(CHECKOUT, { method: 'POST', headers: H, body: JSON.stringify({ ref: b.reference, token: b.manage_token, amount: 1, gross_amount: 1, currency: 'EUR' }) }));
if (co.status === 503) { console.log(`INFO  checkout not configured yet (${co.body?.error}). Owner action: set STRIPE_SECRET_KEY (sk_test_…) on Supabase.`); process.exit(0); }
if (co.status !== 200 || !co.body?.url) fail(`checkout ${co.status} ${JSON.stringify(co.body)}`);
console.log(`PASS  Checkout session created for order ${co.body.order}`);

const st = await j(await fetch(`${BOOKING}?action=state&ref=${b.reference}&token=${b.manage_token}`, { headers: H }));
if (st.body?.booking?.order?.gross_amount !== svc.price_amount) fail(`order amount ${st.body?.booking?.order?.gross_amount} ≠ service price ${svc.price_amount}`);
console.log(`PASS  order amount is the service price (${svc.price_amount} ${svc.currency}), forged fields ignored; booking is ${st.body.booking.status}`);
console.log(`\nPay here with 4242 4242 4242 4242:\n${co.body.url}\n`);

if (wait) {
  process.stdout.write('Waiting for the webhook to confirm');
  for (let i = 0; i < 120; i++) {
    await new Promise((r) => setTimeout(r, 5000));
    const s = await j(await fetch(`${BOOKING}?action=state&ref=${b.reference}&token=${b.manage_token}`, { headers: H }));
    const bk = s.body?.booking;
    if (bk?.status === 'confirmed' && bk.order?.status === 'paid') { console.log(`\nPASS  booking ${bk.reference} confirmed, order ${bk.order.reference} paid at ${bk.order.paid_at}`); process.exit(0); }
    if (bk?.status === 'expired') fail('hold expired before payment');
    process.stdout.write('.');
  }
  fail('timed out waiting for confirmation');
}

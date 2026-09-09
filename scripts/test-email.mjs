#!/usr/bin/env node
/* Transactional email — sender-side suite (Node, no network, no secrets).
   Imports the shared module the Edge Functions use (supabase/functions/_shared/email.ts) and proves:
     configuration presence: ready only with RESEND_API_KEY; EMAIL_FROM / EMAIL_REPLY_TO defaults are the canonical identities
     rendering: every wired kind renders; copy says "Coach Gari" (never "Gari" alone); Support copy carries none of the forbidden words;
                confirmation carries service, date, time, timezone, reference; HTML is escaped
     sending: Resend called once per row with Idempotency-Key = dedupe key, from/reply_to from the config, the key only in the
              Authorization header; a 500 → retry state; a network error → retry state; a success → sent with the provider id;
              the API key never appears in logs or in results; not configured → nothing claimed, nothing sent
   Run: node scripts/test-email.mjs  (exit 1 on any failure). Prints EMAIL_TESTS ok=… fail=…   */
import { emailConfig, render, drainOutbox, emailStatus, normaliseFrom, DEFAULT_FROM, DEFAULT_REPLY_TO } from '../supabase/functions/_shared/email.ts';

let ok = 0, fail = 0;
const check = (name, cond, extra = '') => { if (cond) ok++; else fail++; console.log(`${cond ? 'PASS' : 'FAIL'}  ${name}${cond ? '' : ' ' + extra}`); };
const KEY = 're_test_' + 'x'.repeat(24);
const envWith = (o) => (n) => o[n];

/* ---- 1. configuration presence ---- */
{
  const none = emailConfig(envWith({}));
  check('no key → not ready, all three names reported missing', !none.ready && none.missing.join(',') === 'RESEND_API_KEY,EMAIL_FROM,EMAIL_REPLY_TO', JSON.stringify(none.missing));
  check('defaults are the canonical identities', none.from === DEFAULT_FROM && none.replyTo === DEFAULT_REPLY_TO && DEFAULT_FROM === 'Coach Gari <yoursession@coachgari28.com>' && DEFAULT_REPLY_TO === 'letsgo@coachgari28.com');
  const full = emailConfig(envWith({ RESEND_API_KEY: KEY, EMAIL_FROM: 'Coach Gari <yoursession@coachgari28.com>', EMAIL_REPLY_TO: 'letsgo@coachgari28.com' }));
  check('all three set → ready, nothing missing', full.ready && full.missing.length === 0);
  check('config object never carries the key value', !JSON.stringify(full).includes(KEY));
  check('EMAIL_FROM stored without its display name (shell artefact) still yields "Coach Gari <addr>"',
    normaliseFrom('yoursession@coachgari28.com>') === 'Coach Gari <yoursession@coachgari28.com>' && normaliseFrom('yoursession@coachgari28.com') === 'Coach Gari <yoursession@coachgari28.com>'
    && normaliseFrom('Coach Gari <YourSession@coachgari28.com>') === 'Coach Gari <yoursession@coachgari28.com>' && normaliseFrom('garbage') === DEFAULT_FROM,
    normaliseFrom('yoursession@coachgari28.com>'));
  const odd = emailConfig(envWith({ RESEND_API_KEY: KEY, EMAIL_FROM: 'yoursession@coachgari28.com>', EMAIL_REPLY_TO: '<letsgo@coachgari28.com>' }));
  check('odd secret shapes → canonical from / reply_to', odd.from === 'Coach Gari <yoursession@coachgari28.com>' && odd.replyTo === 'letsgo@coachgari28.com' && odd.ready);
}

/* ---- 2. rendering ---- */
const booking = { name: 'Amina Test', reference: 'CG-ABC123', service_title: 'The Conversation', start_at: '2026-10-05T07:00:00+00:00', end_at: '2026-10-05T08:00:00+00:00',
                  timezone: 'Asia/Dubai', duration_minutes: 60, where: 'Online', order_reference: 'OR-1', amount: 10000, currency: 'USD', paid_at: '2026-10-01T10:00:00Z', method: 'stripe' };
const FORBIDDEN = /donat|charit|fundrais|tax[- ]deductible|contribution to a cause/i;
{
  const r = render('booking_confirmed', booking);
  check('booking_confirmed: service, date, time, timezone, reference present', /The Conversation/.test(r.html) && /Monday,? 5 October 2026/.test(r.html) && /11:00/.test(r.html) && /Asia\/Dubai/.test(r.html) && /CG-ABC123/.test(r.html) && /CG-ABC123/.test(r.text), r.subject);
  check('booking_confirmed: subject names the service and the date', /^You're booked — The Conversation, Monday,? 5 October 2026$/.test(r.subject), r.subject);
  const rs = render('reschedule', { ...booking, previous_start_at: '2026-10-03T07:00:00+00:00', previous_timezone: 'Asia/Dubai' });
  check('reschedule: carries the previous and the new time', /Saturday,? 3 October 2026/.test(rs.html) && /Monday,? 5 October 2026/.test(rs.html) && /Now/.test(rs.html));
  const rc = render('booking_cancelled', { ...booking, cancelled_by: 'coach' });
  check('booking_cancelled (coach): apologises and invites a rebook', /had to cancel/.test(rc.html) && /Cancelled — The Conversation/.test(rc.subject));
  const rc2 = render('booking_cancelled', { ...booking, cancelled_by: 'customer' });
  check('booking_cancelled (customer): "as requested"', /as requested/.test(rc2.html));
  const pc = render('payment_confirmed', { name: 'Omar', pack_title: '10-session pack', sessions: 10, amount: 300000, currency: 'AED', paid_amount: 300000, paid_currency: 'AED', paid_at: '2026-10-01T10:00:00Z', method: 'aani', public_ref: 'PK-XYZ', order_reference: 'OR-2' });
  check('payment_confirmed: package, amount, method, reference', /10-session pack/.test(pc.html) && /AED/.test(pc.html) && /3,000/.test(pc.html) && /Aani/.test(pc.html) && /PK-XYZ/.test(pc.html));
  const st = render('support_thanks', { amount: 5000, currency: 'AED', paid_amount: 5000, paid_currency: 'AED', public_ref: 'SUP-1A2B3C', order_reference: 'OR-3', method: 'stripe' });
  check('support_thanks: subject is "Thank you for supporting Coach Gari"', st.subject === 'Thank you for supporting Coach Gari', st.subject);
  check('support_thanks: amount + reference, no forbidden vocabulary', /SUP-1A2B3C/.test(st.html) && /AED/.test(st.html) && !FORBIDDEN.test(st.html + st.text + st.subject));
  check('support_thanks: no session / package / credit language', !/session|package|credit|entitle/i.test(st.html + st.text));
  const en = render('enquiry_received', { name: 'Lee', interest: 'Padel coaching' });
  check('enquiry_received: acknowledges and names the interest', /Got it, Lee/.test(en.html) && /Padel coaching/.test(en.html));
  const ln = render('lead_notification', { name: 'Lee <b>x</b>', contact: 'lee@example.com', where: 'Dubai, AE', interest: 'Padel', message: 'Hi <script>', attribution: 'direct', page: '/', created_at: '2026-10-01', record: 'r1' });
  check('lead_notification: html escaped, text complete', /&lt;script&gt;/.test(ln.html) && !/<script>/.test(ln.html) && /Contact: lee@example.com/.test(ln.text));
  const pr = render('payment_received', { ...booking, type: 'booking', contact: 'amina@example.com' });
  check('payment_received (owner): who, what, amount', /Amina Test/.test(pr.html) && /CG-ABC123/.test(pr.html) && /US\$100\.00|\$100\.00/.test(pr.html), pr.html);
  const all = ['booking_confirmed', 'reschedule', 'booking_cancelled', 'payment_confirmed', 'support_thanks', 'enquiry_received', 'lead_notification', 'payment_received']
    .map((k) => render(k, { ...booking, previous_start_at: booking.start_at, cancelled_by: 'coach', pack_title: 'P', sessions: 5, type: 'booking', contact: 'a@b.co', record: 'r' }));
  const bareGari = all.map((r) => (r.html + ' ' + r.text + ' ' + r.subject).match(/(?<!Coach )\bGari\b/g) || []).flat();
  check('every template says "Coach Gari", never "Gari" alone', bareGari.length === 0, JSON.stringify(bareGari));
  check('customer templates end with the reply line (Reply-To reaches Coach Gari)', ['booking_confirmed', 'reschedule', 'booking_cancelled', 'payment_confirmed', 'support_thanks', 'enquiry_received'].every((k) => /reply to this email/i.test(render(k, { ...booking, previous_start_at: booking.start_at, pack_title: 'P' }).text)));
  let threw = false; try { render('reminder', {}); } catch { threw = true; }
  check('an unwired kind does not render (fails closed)', threw);
}

/* ---- 3. sending through a fake outbox + fake Resend ---- */
function fakeDb(rows) {
  const state = new Map(rows.map((r) => [r.id, { ...r, attempts: 0, status: 'pending' }]));
  const calls = [];
  return { calls, state, rpc: async (fn, args) => {
    calls.push({ fn, args });
    if (fn === 'email_outbox_claim') {
      const due = [...state.values()].filter((r) => r.status === 'pending' && (!args.p_order_id || r.order_id === args.p_order_id)).slice(0, args.p_limit);
      due.forEach((r) => { r.attempts++; });
      return { data: due.map((r) => ({ ...r })), error: null };
    }
    if (fn === 'email_outbox_result') {
      const r = state.get(args.p_id);
      if (args.p_ok) { r.status = 'sent'; r.provider_message_id = args.p_provider_message_id; return { data: { id: r.id, status: 'sent' }, error: null }; }
      r.error = args.p_error; if (r.attempts >= 6) r.status = 'failed';
      return { data: { id: r.id, status: r.status, attempts: r.attempts }, error: null };
    }
    return { data: null, error: { code: 'unknown' } };
  } };
}
const ENV = envWith({ RESEND_API_KEY: KEY, EMAIL_FROM: 'Coach Gari <yoursession@coachgari28.com>', EMAIL_REPLY_TO: 'letsgo@coachgari28.com' });
{
  const rows = [
    { id: 'e1', order_id: 'o1', kind: 'booking_confirmed', to_address: 'amina@example.com', payload: booking, dedupe_key: 'order:o1:booking_confirmed' },
    { id: 'e2', order_id: 'o1', kind: 'payment_received', to_address: 'letsgo@coachgari28.com', payload: { ...booking, type: 'booking', contact: 'amina@example.com' }, dedupe_key: 'order:o1:payment_received' },
    { id: 'e3', order_id: 'o2', kind: 'support_thanks', to_address: 'fan@example.com', payload: { amount: 2500, currency: 'AED', public_ref: 'SUP-1' }, dedupe_key: 'order:o2:support_thanks' },
  ];
  const db = fakeDb(rows); const sent = []; const logs = [];
  const fetchOk = async (url, init) => { sent.push({ url, init }); return new Response(JSON.stringify({ id: 'msg_' + sent.length }), { status: 200 }); };
  const r = await drainOutbox(db, ENV, { order_id: 'o1' }, (e, d) => logs.push({ e, d }), fetchOk);
  check('drain(order o1): claims and sends exactly the two rows of that order', r.claimed === 2 && r.sent === 2 && sent.length === 2 && db.state.get('e3').status === 'pending', JSON.stringify(r));
  const b1 = JSON.parse(sent[0].init.body);
  check('Resend payload: from / reply_to from the config, one recipient, subject + html + text', b1.from === 'Coach Gari <yoursession@coachgari28.com>' && b1.reply_to === 'letsgo@coachgari28.com' && b1.to.length === 1 && b1.to[0] === 'amina@example.com' && b1.subject && b1.html && b1.text);
  check('Idempotency-Key = the row dedupe key', sent[0].init.headers['Idempotency-Key'] === 'order:o1:booking_confirmed' && sent[1].init.headers['Idempotency-Key'] === 'order:o1:payment_received');
  check('the key travels only in the Authorization header', sent[0].init.headers.Authorization === `Bearer ${KEY}` && !sent[0].init.body.includes(KEY));
  check('provider message id recorded on the row', db.state.get('e1').provider_message_id === 'msg_1' && db.state.get('e1').status === 'sent');
  check('logs never carry the key or an address', !JSON.stringify(logs).includes(KEY) && !JSON.stringify(logs).includes('amina@example.com') && logs.some((l) => l.e === 'email_sent'));
  const again = await drainOutbox(db, ENV, { order_id: 'o1' }, () => {}, fetchOk);
  check('replay: a second drain of the same order sends nothing (rows already sent)', again.claimed === 0 && sent.length === 2, JSON.stringify(again));
}
{
  const db = fakeDb([{ id: 'e9', order_id: 'o9', kind: 'booking_confirmed', to_address: 'x@example.com', payload: booking, dedupe_key: 'order:o9:booking_confirmed' }]);
  const fetch500 = async () => new Response(JSON.stringify({ name: 'internal_server_error', message: 'boom' }), { status: 500 });
  const r = await drainOutbox(db, ENV, { order_id: 'o9' }, () => {}, fetch500);
  check('Resend 500 → row stays pending for retry (attempt recorded, short error)', r.retry === 1 && db.state.get('e9').status === 'pending' && db.state.get('e9').attempts === 1 && db.state.get('e9').error === 'resend 500 internal_server_error', JSON.stringify(db.state.get('e9')));
  const fetchNet = async () => { throw new Error('ECONNRESET'); };
  const r2 = await drainOutbox(db, ENV, { order_id: 'o9' }, () => {}, fetchNet);
  check('network error → still pending, error text short, no exception escapes', r2.retry === 1 && db.state.get('e9').status === 'pending' && /^network/.test(db.state.get('e9').error));
  for (let i = 0; i < 4; i++) await drainOutbox(db, ENV, { order_id: 'o9' }, () => {}, fetch500);
  check('after the maximum attempts the row is failed (visible, retryable by the operator)', db.state.get('e9').status === 'failed' && db.state.get('e9').attempts === 6, JSON.stringify(db.state.get('e9')));
}
{
  const db = fakeDb([{ id: 'e5', order_id: 'o5', kind: 'booking_confirmed', to_address: 'x@example.com', payload: booking, dedupe_key: 'k' }]);
  let called = 0; const r = await drainOutbox(db, envWith({}), { order_id: 'o5' }, () => {}, async () => { called++; return new Response('{}'); });
  check('not configured → nothing claimed, Resend never called, row untouched', r.skipped === 'not_configured' && called === 0 && db.state.get('e5').attempts === 0 && db.calls.every((c) => c.fn !== 'email_outbox_claim'));
}
{
  const db = fakeDb([{ id: 'e6', order_id: 'o6', kind: 'reminder', to_address: 'x@example.com', payload: {}, dedupe_key: 'k6' }]);
  let called = 0; const r = await drainOutbox(db, ENV, { order_id: 'o6' }, () => {}, async () => { called++; return new Response('{}'); });
  check('a row of an unwired kind is recorded as a render failure, never sent half-rendered', r.failed === 1 && called === 0 && /^render/.test(db.state.get('e6').error));
}
{
  const db = fakeDb([{ id: 'e7', contact_id: 'c7', kind: 'lead_notification', to_address: 'letsgo@coachgari28.com', payload: { name: 'Lee', contact: 'lee@example.com', message: 'hi' }, dedupe_key: 'contact:c7:lead_notification' }]);
  const sent = []; await drainOutbox(db, ENV, {}, () => {}, async (u, i) => { sent.push(JSON.parse(i.body)); return new Response('{"id":"m"}'); });
  check('lead notification to the owner replies to the customer', sent[0].reply_to === 'lee@example.com' && sent[0].to[0] === 'letsgo@coachgari28.com');
}

/* ---- 4. status: presence only ---- */
{
  const s = await emailStatus(ENV, async (url) => new Response(JSON.stringify({ data: [{ name: 'coachgari28.com', status: 'verified' }] }), { status: 200 }));
  check('status reports the sending domain as Resend sees it, without any value', s.configured && s.domain === 'coachgari28.com' && s.domain_status === 'verified' && !JSON.stringify(s).includes(KEY));
  const s2 = await emailStatus(envWith({}));
  check('status without a key: configured=false, missing names listed, no API call', s2.configured === false && s2.missing.includes('RESEND_API_KEY') && s2.domain_status === null);
}

console.log(`\nEMAIL_TESTS ok=${ok} fail=${fail}`);
process.exit(fail ? 1 : 0);

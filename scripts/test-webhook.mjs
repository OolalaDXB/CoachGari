/* CG-003 — live probe of the deployed stripe-webhook function (run from a laptop).
   Sends requests signed exactly the way Stripe signs them and checks the
   function's answers. Needs the endpoint's signing secret in the environment
   (never in git):
     STRIPE_WEBHOOK_SECRET=whsec_... node scripts/test-webhook.mjs
   Every event sent is of an unhandled type or unknown session, so nothing
   is confirmed or paid; accepted events are recorded as `ignored`.
   Full end-to-end (real Stripe → real signature) is `node scripts/test-checkout.mjs --wait`
   or `stripe trigger checkout.session.completed` with the Stripe CLI. */
import { signForTest } from '../supabase/functions/stripe-webhook/signature.js';
import { randomUUID } from 'node:crypto';

const URL = process.env.WEBHOOK_URL || 'https://acrjrlgeeyseyolmofuq.supabase.co/functions/v1/stripe-webhook';
const SECRET = process.env.STRIPE_WEBHOOK_SECRET;
if (!SECRET) { console.error('Set STRIPE_WEBHOOK_SECRET (the endpoint signing secret from the Stripe dashboard).'); process.exit(2); }
let ok = 0, fail = 0;
const ev = (over = {}) => JSON.stringify({ id: 'evt_probe_' + randomUUID().slice(0, 8), object: 'event', type: 'customer.created', livemode: false, data: { object: { id: 'cus_probe' } }, ...over });
async function send(name, body, header, expectStatus, expectField) {
  const r = await fetch(URL, { method: 'POST', headers: { 'Content-Type': 'application/json', ...(header === null ? {} : { 'stripe-signature': header }) }, body });
  const j = await r.json().catch(() => ({}));
  const pass = r.status === expectStatus && (!expectField || JSON.stringify(j).includes(expectField));
  pass ? ok++ : fail++;
  console.log(`${pass ? 'PASS' : 'FAIL'}  ${name} → ${r.status} ${JSON.stringify(j)}`);
}
const now = Math.floor(Date.now() / 1000);
let b = ev();
await send('valid signature, unhandled type → 200 ignored', b, await signForTest(b, SECRET, now), 200, '"ignored"');
b = ev(); const good = await signForTest(b, SECRET, now);
await send('tampered payload (livemode flipped after signing) → 400', b.replace('"livemode":false', '"livemode":true'), good, 400, 'bad_signature');
await send('tampered payload (one byte appended) → 400', b + ' ', good, 400, 'bad_signature');
await send('wrong secret → 400', b, await signForTest(b, 'whsec_wrong', now), 400, 'signature_mismatch');
await send('stale timestamp (10 min old) → 400', b, await signForTest(b, SECRET, now - 600), 400, 'timestamp_out_of_tolerance');
await send('future timestamp (+10 min) → 400', b, await signForTest(b, SECRET, now + 600), 400, 'timestamp_out_of_tolerance');
await send('missing Stripe-Signature header → 400', b, null, 400, 'missing_header');
await send('malformed header → 400', b, 't=abc,v1=', 400, 'malformed_header');
await send('v0-only header → 400', b, good.replace('v1=', 'v0='), 400, 'malformed_header');
const live = ev({ livemode: true });
await send('correctly signed LIVE-mode event → 400 live_mode_blocked', live, await signForTest(live, SECRET, now), 400, 'live_mode_blocked');
const unknown = ev({ type: 'checkout.session.completed', data: { object: { id: 'cs_probe_unknown', payment_status: 'paid', amount_total: 1, currency: 'usd' } } });
await send('signed completed event for an unknown session → 200 ignored, nothing confirmed', unknown, await signForTest(unknown, SECRET, now), 200, '"ignored"');
const dup = ev(); const dupSig = await signForTest(dup, SECRET, now);
await send('same event id twice: first → 200', dup, dupSig, 200, '"ignored"');
await send('same event id twice: second → 200 duplicate (idempotent)', dup, dupSig, 200, 'duplicate');
console.log(`\nWEBHOOK_LIVE_TESTS ok=${ok} fail=${fail}`);
process.exit(fail ? 1 : 0);

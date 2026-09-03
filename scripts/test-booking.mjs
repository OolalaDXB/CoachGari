/* CG-002 — reproducible API test of the booking Edge Function (run from a laptop).

   Usage:
     node scripts/test-booking.mjs
     BOOKING_ENDPOINT=https://... BOOKING_ORIGIN=https://coachgari.com node scripts/test-booking.mjs

   Proves against the live API: services list, slots for the next bookable day,
   hold creation, idempotent retry, the concurrent capacity-1 race (two parallel
   holds → exactly one wins), state by reference, wrong token rejected, cancel
   releases the slot, and that the caller cannot forge price/duration/capacity
   (extra fields are ignored). Every hold uses a test name and is cancelled at
   the end. Complements supabase/tests/cg002_booking.sql (DB-level suite). */
import { CONFIG } from '../config.js';
import { randomUUID } from 'node:crypto';

const ENDPOINT = process.env.BOOKING_ENDPOINT || CONFIG.BOOKING_ENDPOINT;
const ORIGIN = process.env.BOOKING_ORIGIN || 'https://coachgari.com';
const SERVICE = process.env.BOOKING_SERVICE || 'conversation';
let passed = 0;
function check(name, cond, detail) {
  console.log(`${cond ? 'PASS' : 'FAIL'}  ${name}${detail ? ' — ' + detail : ''}`);
  if (!cond) { console.error('\nStopped on first failure.'); process.exit(1); }
  passed++;
}
async function get(qs) {
  const r = await fetch(`${ENDPOINT}?${qs}`, { headers: { Origin: ORIGIN } });
  return { status: r.status, body: await r.json().catch(() => null) };
}
async function post(body, origin = ORIGIN) {
  const r = await fetch(ENDPOINT, { method: 'POST', headers: { 'Content-Type': 'application/json', Origin: origin }, body: JSON.stringify(body) });
  return { status: r.status, body: await r.json().catch(() => null) };
}
const day = (offset) => { const d = new Date(); d.setUTCDate(d.getUTCDate() + offset); return d.toISOString().slice(0, 10); };

console.log(`Endpoint: ${ENDPOINT}\nOrigin:   ${ORIGIN}\nService:  ${SERVICE}\n`);

// 1. services
const s = await get('action=services');
check('services listed', s.status === 200 && Array.isArray(s.body?.services) && s.body.services.some((x) => x.slug === SERVICE), `${s.body?.services?.length} service(s)`);
const svc = s.body.services.find((x) => x.slug === SERVICE);

// 2. slots — find the first day in the next 14 with at least 2 free slots
let slots = [], from = null;
for (let i = 1; i <= 14 && slots.length < 2; i++) {
  const r = await get(`action=slots&service=${SERVICE}&from=${day(i)}&to=${day(i)}&tz=Africa/Johannesburg`);
  if (r.status === 200 && r.body?.slots?.length >= 2) { slots = r.body.slots; from = day(i); }
}
check('slots available within 14 days', slots.length >= 2, `${slots.length} slot(s) on ${from}`);
check('slot carries session timezone + local time', !!slots[0].session_timezone && /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}$/.test(slots[0].local_start), `${slots[0].local_start} (${slots[0].session_timezone})`);

// 3. forged fields are ignored: price/duration/capacity come from the server
const key1 = randomUUID();
const h1 = await post({ action: 'hold', service: SERVICE, start_at: slots[0].start_at, idempotency_key: key1,
  name: 'Test Runner', contact: 'test-booking@coachgari.com', notes: 'CG-002 API test — safe to cancel',
  price_amount: 1, duration_minutes: 5, participants: 1, capacity: 99 });
check('hold created', h1.status === 200 && h1.body?.ok && h1.body.booking?.status === 'hold', `ref ${h1.body?.booking?.reference}`);
const b1 = h1.body.booking;
check('price comes from the service, not the request', b1.price_amount === svc.price_amount, `${b1.price_amount} vs forged 1`);
check('duration comes from the service, not the request', (new Date(b1.end_at) - new Date(b1.start_at)) / 60000 === svc.duration_minutes, `${svc.duration_minutes} min`);

// 4. idempotent retry
const h1b = await post({ action: 'hold', service: SERVICE, start_at: slots[0].start_at, idempotency_key: key1, name: 'Test Runner', contact: 'test-booking@coachgari.com' });
check('retry with same idempotency_key returns the same booking', h1b.status === 200 && h1b.body.booking.reference === b1.reference);

// 5. the held slot is gone; another visitor cannot take it
const again = await get(`action=slots&service=${SERVICE}&from=${from}&to=${from}&tz=Africa/Johannesburg`);
check('held slot no longer listed', !again.body.slots.some((x) => x.start_at === slots[0].start_at));
const steal = await post({ action: 'hold', service: SERVICE, start_at: slots[0].start_at, idempotency_key: randomUUID(), name: 'Other Person', contact: 'other@coachgari.com' });
check('second hold on a held slot refused (409)', steal.status === 409, `status ${steal.status}`);

// 6. concurrent race on the second free slot: exactly one winner
const target = slots[1].start_at;
const [ra, rb] = await Promise.all([
  post({ action: 'hold', service: SERVICE, start_at: target, idempotency_key: randomUUID(), name: 'Racer A', contact: 'racer-a@coachgari.com' }),
  post({ action: 'hold', service: SERVICE, start_at: target, idempotency_key: randomUUID(), name: 'Racer B', contact: 'racer-b@coachgari.com' }),
]);
const winners = [ra, rb].filter((r) => r.status === 200 && r.body?.ok);
check('concurrent race: exactly one hold wins', winners.length === 1 && [ra, rb].some((r) => r.status === 409), `statuses ${ra.status}/${rb.status}`);
const b2 = winners[0].body.booking;

// 7. state by reference, wrong token
const st = await get(`action=state&ref=${b1.reference}&token=${b1.manage_token}`);
check('state readable with reference + token', st.status === 200 && st.body.booking.reference === b1.reference && st.body.booking.status === 'hold');
const bad = await get(`action=state&ref=${b1.reference}&token=nope`);
check('wrong token rejected', bad.status === 404, `status ${bad.status}`);

// 8. cancel releases the slot
const c1 = await post({ action: 'cancel', ref: b1.reference, token: b1.manage_token, reason: 'test clean-up' });
check('cancel accepted', c1.status === 200 && c1.body.booking.status === 'cancelled');
const back = await get(`action=slots&service=${SERVICE}&from=${from}&to=${from}&tz=Africa/Johannesburg`);
check('cancelled slot listed again', back.body.slots.some((x) => x.start_at === slots[0].start_at));
const c2 = await post({ action: 'cancel', ref: b2.reference, token: b2.manage_token, reason: 'test clean-up' });
check('race winner cancelled (clean-up)', c2.status === 200);

// 9. validation + origin
const v = await post({ action: 'hold', service: SERVICE, start_at: 'not-a-date', idempotency_key: 'x', name: '', contact: 'nope' });
check('validation errors reported', v.status === 400 && Array.isArray(v.body?.fields), JSON.stringify(v.body?.fields));
const o = await post({ action: 'hold' }, 'https://evil.example');
check('foreign origin rejected', o.status === 403);

console.log(`\nAll ${passed} checks passed.`);

#!/usr/bin/env node
/* Public booking picker — browser behaviour suite (Playwright + Chromium, no network).
   Serves the repo, answers the booking Edge Function with a canned catalogue and records every
   request it receives, then proves the information architecture and the loading discipline:
     initial step        → exactly The Conversation · Personal training · Padel, in that order, no price, no currency
     The Conversation    → availability loads (one slots request, for `conversation`)
     Personal training   → In person / Online children; In person → `personal-training-dubai`, Online → `personal-training-online`
     Padel               → NO slots request; the other two choices leave the layout; One-to-one / Group session appear
     Padel › One-to-one  → slots for `padel-one-to-one`;  Padel › Group session → `padel-group-session`
     ← Back              → the three top-level choices are back, no reload, the picked date survives
     availability error  → no time buttons, an error with Retry; retry success → times, no error
     390 px              → same hierarchy, no horizontal overflow, buttons stack
     reduced motion      → children appear immediately
   Run: node scripts/test-booking-picker.mjs  (exit 1 on any failure). Prints BOOKING_PICKER_TESTS ok=… fail=…   */
import { createRequire } from 'node:module';
const chromium = await (async () => {
  try { return (await import('playwright')).chromium; }
  catch { const { execSync } = await import('node:child_process'); const g = execSync('npm root -g').toString().trim(); return createRequire(g + '/').call(null, 'playwright').chromium; }
})();
import { createServer } from 'node:http';
import { readFile } from 'node:fs/promises';
import { extname, join, normalize } from 'node:path';

const ROOT = new URL('..', import.meta.url).pathname;
const MIME = { '.html': 'text/html', '.js': 'text/javascript', '.mjs': 'text/javascript', '.css': 'text/css', '.json': 'application/json', '.svg': 'image/svg+xml', '.png': 'image/png', '.jpg': 'image/jpeg', '.webp': 'image/webp', '.ico': 'image/x-icon' };
const server = createServer(async (req, res) => {
  let p = decodeURIComponent(new URL(req.url, 'http://x').pathname);
  if (p.endsWith('/')) p += 'index.html';
  const f = normalize(join(ROOT, p));
  try { const body = await readFile(f); res.writeHead(200, { 'Content-Type': MIME[extname(f)] || 'application/octet-stream' }); res.end(body); }
  catch { res.writeHead(404); res.end('not found'); }
});
await new Promise((r) => server.listen(0, '127.0.0.1', r));
const base = `http://127.0.0.1:${server.address().port}`;

let ok = 0, fail = 0; const log = [];
const check = (name, cond, extra = '') => { if (cond) ok++; else { fail++; log.push(`FAIL ${name} ${extra}`); } console.log(`${cond ? 'PASS' : 'FAIL'}  ${name}${cond ? '' : ' ' + extra}`); };

/* ---- canned booking API (shapes mirror the Edge Function) ---- */
const BOOKABLE = [
  { slug: 'conversation', title: 'The Conversation', duration_minutes: 60, price_amount: 10000, currency: 'USD', delivery_mode: 'online', default_capacity: 1, sort_order: 10 },
  { slug: 'personal-training-dubai', title: 'Personal training in Dubai', duration_minutes: 60, price_amount: null, currency: 'USD', delivery_mode: 'onsite', default_capacity: 1, sort_order: 40 },
  { slug: 'personal-training-online', title: 'Personal training online', duration_minutes: 60, price_amount: null, currency: 'USD', delivery_mode: 'online', default_capacity: 1, sort_order: 39 },
  { slug: 'padel-one-to-one', title: 'Padel one-to-one', duration_minutes: 60, price_amount: null, currency: 'USD', delivery_mode: 'onsite', default_capacity: 1, sort_order: 41 },
  { slug: 'padel-group-session', title: 'Padel group session', duration_minutes: 60, price_amount: null, currency: 'USD', delivery_mode: 'onsite', default_capacity: 1, sort_order: 42 },
];
const day = new Date(Date.now() + 86400000).toISOString().slice(0, 10);
const slotsFor = (service) => [0, 1, 2].map((i) => ({ start_at: `${day}T0${5 + i}:00:00+00:00`, end_at: `${day}T0${6 + i}:00:00+00:00`, session_timezone: 'Asia/Dubai', remaining: 1, local_start: `${day}T0${9 + i}:00`, tour_stop_id: null, service }));

const calls = [];
let slotsMode = 'ok';   // 'ok' | 'fail'
async function run(viewport, reducedMotion) {
  const browser = await chromium.launch();
  const page = await browser.newPage({ viewport, hasTouch: viewport.width < 600, reducedMotion: reducedMotion ? 'reduce' : 'no-preference' });
  await page.route('**/fonts.googleapis.com/**', (r) => r.abort());
  await page.route('**/plausible.io/**', (r) => r.abort());
  await page.route('**/js.stripe.com/**', (r) => r.abort());
  await page.route('**/functions/v1/booking**', (r) => {
    const u = new URL(r.request().url()); const action = u.searchParams.get('action');
    calls.push({ action, service: u.searchParams.get('service') });
    if (action === 'bookable') return r.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify({ ok: true, services: BOOKABLE }) });
    if (action === 'services') return r.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify({ ok: true, services: BOOKABLE.filter((s) => s.slug === 'conversation') }) });
    if (action === 'tour_stops') return r.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify({ ok: true, tour_stops: [] }) });
    if (action === 'slots') {
      if (slotsMode === 'fail') return r.fulfill({ status: 500, contentType: 'application/json', body: JSON.stringify({ ok: false, error: 'server_error' }) });
      return r.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify({ ok: true, service: u.searchParams.get('service'), tz: 'UTC', slots: slotsFor(u.searchParams.get('service')) }) });
    }
    r.fulfill({ status: 400, contentType: 'application/json', body: JSON.stringify({ ok: false, error: 'unknown_action' }) });
  });
  await page.route('**/functions/v1/contact**', (r) => r.fulfill({ status: 200, body: '{}' }));
  await page.goto(`${base}/`);
  await page.waitForSelector('[data-booking] .bk-service');
  return { browser, page };
}
const slotsCalls = () => calls.filter((c) => c.action === 'slots');
const visibleChoices = (page) => page.$$eval('[data-booking] .bk-level .bk-service', (els) => els.filter((e) => !e.hidden && getComputedStyle(e).display !== 'none').map((e) => e.querySelector('b').textContent));
const pickerText = (page) => page.$eval('[data-booking] .bk-level', (e) => e.textContent);
const timeButtons = (page) => page.$$('[data-booking] .bk-slot');
const noOverflow = (page) => page.evaluate(() => document.documentElement.scrollWidth <= document.documentElement.clientWidth + 1);

/* ================= desktop ================= */
{
  const { browser, page } = await run({ width: 1280, height: 900 }, false);
  const tag = 'desktop';
  check(`${tag}: initial step shows exactly The Conversation · Personal training · Padel, in order`, JSON.stringify(await visibleChoices(page)) === JSON.stringify(['The Conversation', 'Personal training', 'Padel']));
  const txt = await pickerText(page);
  check(`${tag}: no price, no currency, no duration on the initial choices`, !/USD|\$|\d+\s*min|100/.test(txt), txt);
  check(`${tag}: no availability requested before a final service is chosen`, slotsCalls().length === 0);
  check(`${tag}: choices are real buttons with an accessible pressed state`, await page.$$eval('[data-booking] .bk-level button.bk-service[aria-pressed]', (e) => e.length) === 3);

  // The Conversation → the other choices collapse, it stays as context, availability loads
  await page.click('[data-choice="conversation"]');
  await page.waitForSelector('[data-booking] .bk-slot');
  await page.waitForFunction(() => document.querySelectorAll('[data-booking] .bk-level > .bk-services .bk-service[hidden]').length === 2);
  check(`${tag}: The Conversation loads availability for conversation`, slotsCalls().length === 1 && slotsCalls()[0].service === 'conversation');
  check(`${tag}: times shown, no error`, (await timeButtons(page)).length === 3 && !(await page.$('[data-booking] .bk-error')));
  check(`${tag}: the other two choices collapsed, The Conversation stays as context with Back`, JSON.stringify(await visibleChoices(page)) === JSON.stringify(['The Conversation']) && !!(await page.$('[data-booking] .bk-back')));
  check(`${tag}: The Conversation has no child choices`, (await page.$$('[data-booking] .bk-children .bk-service')).length === 0);

  // pick a time: step 4 shows no price (price belongs to the recap / payment stage)
  await page.click('[data-booking] .bk-slot');
  const summary = await page.$eval('[data-booking] .bk-summary', (e) => e.textContent);
  check(`${tag}: the details step names the service and time, not the price`, /The Conversation/.test(summary) && !/USD|100/.test(summary), summary);

  // Back, then Personal training → a family: In person / Online, no availability until a child is picked
  await page.click('[data-booking] .bk-back');
  await page.waitForFunction(() => document.querySelectorAll('[data-booking] .bk-level .bk-service:not([hidden])').length === 3 && !document.querySelector('[data-booking] .bk-children'));
  check(`${tag}: Back after a final choice restores the three and clears the steps below`, !(await page.$('[data-booking] .bk-slot')) && !(await page.$('[data-booking] .bk-form')));
  const ptBefore = slotsCalls().length;
  await page.click('[data-choice="personal-training"]');
  await page.waitForSelector('[data-booking] .bk-children .bk-service');
  await page.waitForFunction(() => !document.querySelector('[data-booking] .bk-children').classList.contains('bk-enter'));
  check(`${tag}: Personal training expands to In person / Online, no availability yet`, slotsCalls().length === ptBefore && !(await page.$('[data-booking] .bk-slot')) && JSON.stringify(await visibleChoices(page)) === JSON.stringify(['Personal training', 'In person', 'Online']));
  // In person → the canonical Dubai (onsite) service
  await page.click('[data-choice="personal-training-in-person"]');
  await page.waitForSelector('[data-booking] .bk-slot');
  check(`${tag}: Personal training › In person loads availability for personal-training-dubai`, slotsCalls().slice(-1)[0].service === 'personal-training-dubai');
  // Online → the online service
  await page.click('[data-choice="personal-training-online"]');
  await page.waitForFunction((n) => document.querySelectorAll('[data-booking] .bk-slot').length === 3 && window.__x !== n, slotsCalls().length);
  check(`${tag}: Personal training › Online loads availability for personal-training-online`, slotsCalls().slice(-1)[0].service === 'personal-training-online');
  await page.click('[data-booking] .bk-back');
  await page.waitForFunction(() => document.querySelectorAll('[data-booking] .bk-level .bk-service:not([hidden])').length === 3 && !document.querySelector('[data-booking] .bk-children'));

  // Padel → family, no availability
  const before = slotsCalls().length;
  await page.click('[data-choice="padel"]');
  await page.waitForSelector('[data-booking] .bk-children .bk-service');
  await page.waitForFunction(() => !document.querySelector('[data-booking] .bk-children').classList.contains('bk-enter'));
  await page.waitForFunction(() => document.querySelectorAll('[data-booking] .bk-level > .bk-services .bk-service[hidden]').length === 2);
  check(`${tag}: Padel loads no availability`, slotsCalls().length === before && !(await page.$('[data-booking] .bk-slot')));
  check(`${tag}: the other top-level choices left the layout, Padel stays as context`, JSON.stringify(await visibleChoices(page)) === JSON.stringify(['Padel', 'One-to-one', 'Group session']));
  check(`${tag}: hidden choices are not tabbable`, await page.$$eval('[data-booking] .bk-level > .bk-services .bk-service[hidden]', (els) => els.every((e) => e.getAttribute('tabindex') === '-1')));
  check(`${tag}: Padel is announced as expanded/selected`, await page.$eval('[data-choice="padel"]', (e) => e.getAttribute('aria-expanded') === 'true' && e.getAttribute('aria-pressed') === 'true'));
  check(`${tag}: focus moved to the first child choice`, await page.evaluate(() => document.activeElement && document.activeElement.getAttribute('data-choice') === 'padel-one-to-one'));
  check(`${tag}: a Back control is present`, !!(await page.$('[data-booking] .bk-back')));

  // the context button itself goes back; re-opening never stacks a second children row
  await page.click('[data-choice="padel"]');
  await page.waitForFunction(() => document.querySelectorAll('[data-booking] .bk-level .bk-service:not([hidden])').length === 3 && !document.querySelector('[data-booking] .bk-children'));
  check(`${tag}: clicking the Padel context goes back`, JSON.stringify(await visibleChoices(page)) === JSON.stringify(['The Conversation', 'Personal training', 'Padel']));
  await page.click('[data-choice="padel"]');
  await page.waitForSelector('[data-booking] .bk-children .bk-service');
  await page.waitForFunction(() => document.querySelectorAll('[data-booking] .bk-level > .bk-services .bk-service[hidden]').length === 2);
  check(`${tag}: exactly one children row after re-opening Padel`, (await page.$$('[data-booking] .bk-children')).length === 1 && (await page.$$('[data-booking] .bk-back')).length === 1);

  // Padel › One-to-one → availability

  await page.click('[data-choice="padel-one-to-one"]');
  await page.waitForSelector('[data-booking] .bk-slot');
  check(`${tag}: Padel one-to-one loads availability for padel-one-to-one`, slotsCalls().slice(-1)[0].service === 'padel-one-to-one');
  // Padel › Group session → availability
  await page.click('[data-choice="padel-group"]');
  await page.waitForFunction((n) => document.querySelectorAll('[data-booking] .bk-slot').length === 3 && window.__x !== n, slotsCalls().length);
  check(`${tag}: Padel group session loads availability for padel-group-session`, slotsCalls().slice(-1)[0].service === 'padel-group-session');

  // date survives Back; Back restores the three choices without a reload
  await page.fill('[data-booking] .bk-date', day);
  const marker = await page.evaluate(() => { window.__noReload = true; return true; });
  await page.click('[data-booking] .bk-back');
  await page.waitForFunction(() => document.querySelectorAll('[data-booking] .bk-level .bk-service:not([hidden])').length === 3 && !document.querySelector('[data-booking] .bk-children'));
  check(`${tag}: Back restores the three top-level choices`, marker && JSON.stringify(await visibleChoices(page)) === JSON.stringify(['The Conversation', 'Personal training', 'Padel']));
  check(`${tag}: Back did not reload the page`, await page.evaluate(() => window.__noReload === true));
  check(`${tag}: focus returned to Padel`, await page.evaluate(() => document.activeElement && document.activeElement.getAttribute('data-choice') === 'padel'));
  check(`${tag}: no availability shown while back at the family level`, !(await page.$('[data-booking] .bk-slot')));

  // availability error: never times + error together; retry recovers
  slotsMode = 'fail';
  await page.click('[data-choice="conversation"]');
  await page.waitForSelector('[data-booking] .bk-error');
  check(`${tag}: a failed availability request shows an error and NO time buttons`, (await timeButtons(page)).length === 0 && !!(await page.$('[data-booking] .bk-retry')));
  check(`${tag}: the error is not duplicated in the status line`, (await page.$eval('[data-booking] .bk-status', (e) => e.textContent)) === '');
  slotsMode = 'ok';
  await page.click('[data-booking] .bk-retry');
  await page.waitForSelector('[data-booking] .bk-slot');
  check(`${tag}: retry loads the times and removes the error`, (await timeButtons(page)).length === 3 && !(await page.$('[data-booking] .bk-error')));
  check(`${tag}: the date picked before Back survived`, (await page.$eval('[data-booking] .bk-date', (e) => e.value)) === day);
  check(`${tag}: no horizontal overflow`, await noOverflow(page));
  await browser.close();
}

/* ================= mobile 390 px ================= */
{
  calls.length = 0;
  const { browser, page } = await run({ width: 390, height: 844 }, false);
  const tag = 'mobile';
  check(`${tag}: initial step shows the same three choices`, JSON.stringify(await visibleChoices(page)) === JSON.stringify(['The Conversation', 'Personal training', 'Padel']));
  check(`${tag}: choices stack (one column)`, await page.$$eval('[data-booking] .bk-level .bk-service', (els) => { const xs = els.map((e) => e.getBoundingClientRect().left); return xs.every((x) => Math.abs(x - xs[0]) < 1); }));
  check(`${tag}: no horizontal overflow at 390 px`, await noOverflow(page));
  await page.tap('[data-choice="padel"]');
  await page.waitForSelector('[data-booking] .bk-children .bk-service');
  await page.waitForFunction(() => document.querySelectorAll('[data-booking] .bk-level > .bk-services .bk-service[hidden]').length === 2);
  check(`${tag}: Padel reveals One-to-one / Group session without hover`, JSON.stringify(await visibleChoices(page)) === JSON.stringify(['Padel', 'One-to-one', 'Group session']));
  check(`${tag}: no availability requested for the family`, slotsCalls().length === 0);
  check(`${tag}: no horizontal overflow after the transition`, await noOverflow(page));
  await page.tap('[data-choice="padel-group"]');
  await page.waitForSelector('[data-booking] .bk-slot');
  check(`${tag}: Group session loads availability`, slotsCalls().slice(-1)[0].service === 'padel-group-session');
  await page.tap('[data-booking] .bk-back');
  await page.waitForFunction(() => document.querySelectorAll('[data-booking] .bk-level .bk-service:not([hidden])').length === 3 && !document.querySelector('[data-booking] .bk-children'));
  check(`${tag}: Back works by touch`, JSON.stringify(await visibleChoices(page)) === JSON.stringify(['The Conversation', 'Personal training', 'Padel']));
  await browser.close();
}

/* ================= reduced motion ================= */
{
  calls.length = 0;
  const { browser, page } = await run({ width: 1280, height: 900 }, true);
  await page.click('[data-choice="padel"]');
  const immediate = await page.evaluate(() => { const c = document.querySelector('[data-booking] .bk-children'); return !!c && !c.classList.contains('bk-enter') && document.querySelectorAll('[data-booking] .bk-level > .bk-services .bk-service[hidden]').length === 2; });
  check('reduced motion: children appear immediately, siblings hidden without a fade', immediate);
  await browser.close();
}

server.close();
console.log(`\nBOOKING_PICKER_TESTS ok=${ok} fail=${fail}`);
if (fail) { console.log(log.join('\n')); process.exit(1); }

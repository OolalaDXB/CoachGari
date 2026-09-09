#!/usr/bin/env node
/* Anchor navigation — functional suite (Playwright + Chromium, no network).
   Proves, for the homepage:
     every header + footer anchor resolves to a real section id (or a declared alias)
     an anchor jump lands the target BELOW the sticky header, close to it (not hidden, not far down)
     legacy ids (#enquiry, #programmes, …) still deep-link: normalised in the address bar, same landing
     #personal-training opens the booking picker on that family
     history/hash: the hash updates on click; Back returns to the previous hash
     keyboard: Enter on a focused nav link navigates; the target section is focusable (tabindex -1)
     prefers-reduced-motion: no smooth scrolling
   Run: node scripts/test-anchors.mjs  (exit 1 on any failure). Prints ANCHOR_TESTS ok=… fail=…   */
import { createRequire } from 'node:module';
const chromium = await (async () => {
  try { return (await import('playwright')).chromium; }
  catch { const { execSync } = await import('node:child_process'); const g = execSync('npm root -g').toString().trim(); return createRequire(g + '/').call(null, 'playwright').chromium; }
})();
import { createServer } from 'node:http';
import { readFile } from 'node:fs/promises';
import { extname, join, normalize } from 'node:path';

const ROOT = new URL('..', import.meta.url).pathname;
const MIME = { '.html': 'text/html', '.js': 'text/javascript', '.css': 'text/css', '.svg': 'image/svg+xml', '.jpg': 'image/jpeg', '.png': 'image/png' };
const server = createServer(async (req, res) => {
  let p = decodeURIComponent(new URL(req.url, 'http://x').pathname);
  if (p.endsWith('/')) p += 'index.html';
  try { const body = await readFile(normalize(join(ROOT, p))); res.writeHead(200, { 'Content-Type': MIME[extname(p)] || 'application/octet-stream' }); res.end(body); }
  catch { res.writeHead(404); res.end('not found'); }
});
await new Promise((r) => server.listen(0, '127.0.0.1', r));
const base = `http://127.0.0.1:${server.address().port}`;

let ok = 0, fail = 0; const jsErrors = [];
const check = (name, cond, extra = '') => { if (cond) ok++; else fail++; console.log(`${cond ? 'PASS' : 'FAIL'}  ${name}${cond ? '' : ' ' + extra}`); };

const BOOKABLE = [
  { slug: 'conversation', title: 'The Conversation', duration_minutes: 60, price_amount: 10000, currency: 'USD', delivery_mode: 'online', default_capacity: 1, sort_order: 10 },
  { slug: 'personal-training-dubai', title: 'Personal training in Dubai', duration_minutes: 60, price_amount: null, currency: 'USD', delivery_mode: 'onsite', default_capacity: 1, sort_order: 40 },
];
async function open(path, opts = {}) {
  const browser = await chromium.launch();
  const page = await browser.newPage({ viewport: opts.viewport || { width: 1280, height: 800 }, reducedMotion: opts.reduced ? 'reduce' : 'no-preference' });
  await page.route('**/fonts.googleapis.com/**', (r) => r.abort());
  await page.route('**/plausible.io/**', (r) => r.abort());
  await page.route('**/functions/v1/**', (r) => r.fulfill({ status: 200, contentType: 'application/json', body: '{"ok":true,"options":{"currencies":[]}}' }));
  await page.route('**/functions/v1/booking**', (r) => {   // registered last = matched first
    const a = new URL(r.request().url()).searchParams.get('action');
    const body = a === 'tour_stops' ? { ok: true, tour_stops: [] } : a === 'slots' ? { ok: true, tz: 'UTC', slots: [] } : { ok: true, services: BOOKABLE };
    r.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify(body) });
  });
  page.on('pageerror', (e) => { jsErrors.push(String(e)); });
  await page.goto(`${base}${path}`);
  await page.waitForSelector('[data-booking] .bk-service', { state: 'attached' });
  return { browser, page };
}
// where the target sits relative to the header, once scrolling has settled
async function landing(page, id) {
  await page.waitForFunction(() => new Promise((res) => { let last = -1, same = 0; (function tick(){ const y = scrollY; same = y === last ? same + 1 : 0; last = y; if (same >= 6) res(true); else requestAnimationFrame(tick); })(); }));
  return page.evaluate((id) => {
    const nav = document.querySelector('.nav').getBoundingClientRect();
    const t = document.getElementById(id).getBoundingClientRect();
    const maxScroll = document.documentElement.scrollHeight - innerHeight;
    return { navBottom: nav.bottom, top: t.top, gap: t.top - nav.bottom, atBottom: Math.abs(scrollY - maxScroll) < 2 };
  }, id);
}
const wellPlaced = (l) => l.atBottom || (l.gap >= 8 && l.gap <= 80);

/* ---- 1. every header + footer anchor resolves ---- */
{
  const { browser, page } = await open('/');
  const r = await page.evaluate(() => {
    const aliases = {}; (document.body.getAttribute('data-anchor-aliases') || '').split(/\s+/).forEach((p) => { const [a, b] = p.split(':'); if (a) aliases[a] = b; });
    const links = [...document.querySelectorAll('.nav a[href^="#"], footer a[href^="#"]')].map((a) => a.getAttribute('href').slice(1));
    const bad = links.filter((id) => !document.getElementById(id) && !(aliases[id] && document.getElementById(aliases[id])));
    const removed = [...document.querySelectorAll('footer a, footer h4')].map((a) => a.textContent.trim()).filter((t) => /^(Zimbabwe|Dubai one-to-one|Padel & corporate|Live events|Live group sessions|Train online|In person|More)$|letsgo@|Padel one-to-one|Group session|Replay/i.test(t));
    const cols = document.querySelectorAll('.f-top > div').length;
    const col1 = [...document.querySelectorAll('.f-top > div:nth-child(1) li a')].map((a) => a.textContent.trim());
    const col2 = [...document.querySelectorAll('.f-top > div:nth-child(2) li a')].map((a) => a.textContent.replace(/\s*→\s*$/, '').trim());
    const heads = [...document.querySelectorAll('.f-top h4')].map((h) => h.textContent.trim() + '|' + getComputedStyle(h).textTransform);
    const support = document.querySelector('.f-top > div:nth-child(2) a[data-support-open]');
    const supportInCol = !!support && !support.classList.contains('btn') && getComputedStyle(support).backgroundColor === 'rgba(0, 0, 0, 0)';
    const supportRow = !document.querySelector('footer .btn[data-support-open]');
    const external = [...document.querySelectorAll('.f-top a[href^="http"]')].map((a) => a.getAttribute('href'));
    const dupIds = (() => { const seen = new Set(), dup = []; document.querySelectorAll('[id]').forEach((e) => { if (seen.has(e.id)) dup.push(e.id); seen.add(e.id); }); return dup; })();
    const fixedIds = ['programme', 'online-coaching', 'conversation', 'padel', 'corporate', 'about', 'book', 'contact'].filter((id) => !document.getElementById(id));
    return { links: links.length, bad, removed, cols, col1, col2, heads, supportInCol, supportRow, external, dupIds, fixedIds };
  });
  check('header + footer anchors all resolve', r.bad.length === 0, JSON.stringify(r.bad));
  check('confusing footer links removed', r.removed.length === 0, JSON.stringify(r.removed));
  check('footer has exactly 3 content columns', r.cols === 3, String(r.cols));
  check('Services column: exact order, no subcategories', r.col1.join('|') === 'The Programme|Online coaching|The Conversation|Personal training|Padel|Corporate', r.col1.join('|'));
  check('Coach Gari column: Book a session … Support Coach Gari', r.col2.join('|') === 'Book a session|About Coach Gari|Contact|TikTok|Instagram|Support Coach Gari', r.col2.join('|'));
  check('column titles in sentence case, not uppercased', r.heads.join(',') === 'Services|none,Coach Gari|none,Next live session|none', r.heads.join(','));
  check('Support Coach Gari is a link in the Coach Gari column, not a button', r.supportInCol && r.supportRow);
  check('social links unchanged', r.external.join(',') === 'https://www.tiktok.com/@coach_gari28,https://www.instagram.com/coach_gari28', r.external.join(','));
  check('no duplicate ids on the page', r.dupIds.length === 0, JSON.stringify(r.dupIds));
  check('normalised section ids exist', r.fixedIds.length === 0, JSON.stringify(r.fixedIds));
  const bareGari = await page.$eval('footer', (f) => (f.textContent.match(/(?<!Coach )\bGari\b(?!\.)/g) || []).length);
  check('footer never says "Gari" alone', bareGari === 0, String(bareGari));
  await page.click('.f-top a[data-support-open]');
  const opened = await page.evaluate(() => !document.getElementById('support').hidden && location.hash !== '#book');
  check('Support Coach Gari opens the Support flow (no scroll to Booking)', opened);
  await browser.close();
}

/* ---- 2. landing position for every nav + footer target ---- */
{
  const { browser, page } = await open('/');
  const targets = await page.$$eval('.nav a[href^="#"], footer a[href^="#"]', (as) => [...new Set(as.map((a) => a.getAttribute('href').slice(1)))].filter((id) => id !== 'top' && id !== 'support'));
  for (const id of targets) {
    await page.evaluate(() => scrollTo(0, 0));
    await page.click(`footer a[href="#${id}"], .nav a[href="#${id}"]`);
    await page.waitForFunction(() => !!document.getElementById(location.hash.slice(1)));   // aliases normalise on hashchange
    const canon = await page.evaluate(() => location.hash.slice(1));
    const l = await landing(page, canon);
    check(`#${id} lands below the header (gap ${Math.round(l.gap)}px)`, l.gap >= 8 && wellPlaced(l), JSON.stringify(l));
  }
  // compact (scrolled) header: the offset follows the real height
  await page.evaluate(() => scrollTo(0, 2000));
  await page.waitForFunction(() => document.querySelector('.nav').classList.contains('scrolled'));
  await page.click('.nav a[href="#about"]');
  const l = await landing(page, 'about');
  check('scrolled (compact) header: #about still lands below it', l.gap >= 8 && wellPlaced(l), JSON.stringify(l));
  const navH = await page.evaluate(() => getComputedStyle(document.documentElement).getPropertyValue('--nav-h').trim());
  const real = await page.evaluate(() => document.querySelector('.nav').getBoundingClientRect().height + 'px');
  check('--nav-h equals the measured header height', navH === real, `${navH} vs ${real}`);
  // history
  await page.click('.nav a[href="#programme"]');
  await page.waitForFunction(() => location.hash === '#programme');
  await page.goBack();
  await page.waitForFunction(() => location.hash === '#about');
  check('history: Back returns to the previous hash', true);
  await browser.close();
}

/* ---- 3. legacy deep links (aliases) ---- */
for (const [legacy, canon] of [['enquiry', 'contact'], ['programmes', 'programme'], ['talk', 'conversation'], ['together', 'padel'], ['live', 'group-sessions'], ['online', 'online-coaching']]) {
  const { browser, page } = await open(`/#${legacy}`);
  await page.waitForFunction((c) => location.hash === '#' + c, canon);
  const l = await landing(page, canon);
  check(`/#${legacy} → #${canon}, lands below the header`, wellPlaced(l), JSON.stringify(l));
  await browser.close();
}
{
  const { browser, page } = await open('/');
  await page.evaluate(() => { location.hash = '#enquiry'; });
  await page.waitForFunction(() => location.hash === '#contact');
  check('hashchange to a legacy id is normalised in place', true);
  await browser.close();
}

/* ---- 4. #personal-training opens the picker on that family ---- */
{
  const { browser, page } = await open('/#personal-training');
  await page.waitForFunction(() => location.hash === '#book');
  await page.waitForSelector('[data-booking] .bk-service.ctx');
  const ctx = await page.$eval('[data-booking] .bk-service.ctx b', (b) => b.textContent);
  check('#personal-training → #book with Personal training selected', ctx === 'Personal training', ctx);
  const l = await landing(page, 'book');
  check('#personal-training lands on the booking section below the header', wellPlaced(l), JSON.stringify(l));
  await browser.close();
}

/* ---- 5. keyboard ---- */
{
  const { browser, page } = await open('/');
  await page.focus('.nav a[href="#about"]');
  await page.keyboard.press('Enter');
  await page.waitForFunction(() => location.hash === '#about');
  const l = await landing(page, 'about');
  check('keyboard: Enter on a nav link navigates and lands below the header', wellPlaced(l), JSON.stringify(l));
  await page.goto(`${base}/#enquiry`);
  await page.waitForFunction(() => location.hash === '#contact');
  const focused = await page.evaluate(() => document.activeElement && document.activeElement.id);
  check('alias landing moves focus to the section (keyboard continues from there)', focused === 'contact', String(focused));
  await browser.close();
}

/* ---- 6. reduced motion ---- */
{
  const { browser, page } = await open('/', { reduced: true });
  const sb = await page.evaluate(() => getComputedStyle(document.documentElement).scrollBehavior);
  check('prefers-reduced-motion: scroll-behavior auto', sb === 'auto', sb);
  await page.click('.nav a[href="#about"]');
  const l = await landing(page, 'about');
  check('reduced motion: #about lands below the header', wellPlaced(l), JSON.stringify(l));
  await browser.close();
}
{
  const { browser, page } = await open('/');
  const sb = await page.evaluate(() => getComputedStyle(document.documentElement).scrollBehavior);
  check('default: smooth scrolling preserved', sb === 'smooth', sb);
  await browser.close();
}

/* ---- 7. mobile viewport ---- */
{
  const { browser, page } = await open('/', { viewport: { width: 390, height: 800 } });
  await page.click('footer a[href="#contact"]');
  const l = await landing(page, 'contact');
  check('390px: footer Contact lands below the header', wellPlaced(l), JSON.stringify(l));
  await browser.close();
}

check('no JavaScript errors during anchor navigation', jsErrors.length === 0, JSON.stringify(jsErrors));
server.close();
console.log(`\nANCHOR_TESTS ok=${ok} fail=${fail}`);
process.exit(fail ? 1 : 0);

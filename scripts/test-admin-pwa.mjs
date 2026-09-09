#!/usr/bin/env node
/* Back-office PWA — functional suite (Playwright + Chromium, no network).
   Proves: the manifest is valid and scoped to /admin/, every icon resolves, the service worker registers with
   scope /admin/ from the admin only (the public homepage registers nothing and links no manifest), the shell is
   cached after install, a request to Supabase is never cached, the shell still opens offline, the sign-in offers
   the 6-digit code path and calls verifyOtp with type "email". Run: node scripts/test-admin-pwa.mjs   */
import { createRequire } from 'node:module';
const chromium = await (async () => {
  try { return (await import('playwright')).chromium; }
  catch { const { execSync } = await import('node:child_process'); const g = execSync('npm root -g').toString().trim(); return createRequire(g + '/').call(null, 'playwright').chromium; }
})();
import { createServer } from 'node:http';
import { readFile } from 'node:fs/promises';
import { extname, join, normalize } from 'node:path';

const ROOT = new URL('..', import.meta.url).pathname;
const MIME = { '.html': 'text/html', '.js': 'text/javascript', '.css': 'text/css', '.json': 'application/json', '.webmanifest': 'application/manifest+json', '.png': 'image/png', '.svg': 'image/svg+xml', '.jpg': 'image/jpeg' };
const server = createServer(async (req, res) => {
  let p = decodeURIComponent(new URL(req.url, 'http://x').pathname);
  if (p.endsWith('/')) p += 'index.html';
  if (!extname(p) && p !== '/admin/index.html') p += '.html';                          // clean URLs, like Vercel
  try { const body = await readFile(normalize(join(ROOT, p))); res.writeHead(200, { 'Content-Type': MIME[extname(p)] || 'application/octet-stream' }); res.end(body); }
  catch { res.writeHead(404); res.end('not found'); }
});
await new Promise((r) => server.listen(0, '127.0.0.1', r));
const base = `http://127.0.0.1:${server.address().port}`;
let ok = 0, fail = 0;
const check = (name, cond, extra = '') => { if (cond) ok++; else fail++; console.log(`${cond ? 'PASS' : 'FAIL'}  ${name}${cond ? '' : ' ' + extra}`); };

/* ---- manifest + icons ---- */
{
  const r = await fetch(`${base}/admin/manifest.webmanifest`); const m = await r.json();
  check('manifest is valid JSON with scope and start_url under /admin/', r.ok && m.scope === '/admin/' && m.start_url === '/admin/' && m.display === 'standalone' && m.name.includes('Coach Gari'));
  check('manifest has 192, 512 and a maskable icon', m.icons.some((i) => i.sizes === '192x192') && m.icons.some((i) => i.sizes === '512x512' && !i.purpose) && m.icons.some((i) => i.purpose === 'maskable'));
  for (const i of m.icons) { const ir = await fetch(base + i.src); check(`icon resolves: ${i.src}`, ir.ok && ir.headers.get('content-type') === 'image/png'); }
  const at = await fetch(`${base}/admin/icons/apple-touch-icon.png`); check('apple-touch-icon resolves', at.ok);
  const sw = await fetch(`${base}/admin/sw.js`); const swText = await sw.text();
  check('service worker never caches Supabase (data + auth go to the network)', sw.ok && /supabase\.co/.test(swText) && /return;/.test(swText.split('supabase.co')[1].slice(0, 80)));
}

/* ---- public site: nothing ---- */
{
  const html = await (await fetch(`${base}/`)).text();
  check('public homepage links no manifest and registers no service worker', !/rel="manifest"/.test(html) && !/serviceWorker/.test(html));
  const site = await (await fetch(`${base}/assets/site.js`)).text(); const booking = await (await fetch(`${base}/assets/booking.js`)).text(); const support = await (await fetch(`${base}/assets/support.js`)).text();
  check('public scripts never register a service worker', !/serviceWorker\.register/.test(site + booking + support));
}

/* ---- in the browser: registration, cache, offline, code sign-in ---- */
const browser = await chromium.launch();
const ctx = await browser.newContext({ viewport: { width: 390, height: 800 } });
const page = await ctx.newPage();
const authCalls = [];
await page.exposeFunction('__auth', (name, args) => { authCalls.push({ name, args }); });
await page.addInitScript(() => {
  window.supabase = { createClient: () => ({
    auth: { getSession: async () => ({ data: { session: null } }), onAuthStateChange: () => {},
            signInWithOtp: async (a) => { window.__auth('signInWithOtp', a); return {}; },
            verifyOtp: async (a) => { window.__auth('verifyOtp', a); return { error: null }; }, signOut: async () => ({}) },
    rpc: async () => ({ data: null, error: null }), from: () => ({ select: async () => ({ data: [], error: null }) }),
  }) };
});
await page.route('**/cdn.jsdelivr.net/**', (r) => r.fulfill({ status: 200, contentType: 'text/javascript', body: '/* stubbed */' }));
await page.route('**/fonts.googleapis.com/**', (r) => r.abort());
await page.route('**/acrjrlgeeyseyolmofuq.supabase.co/**', (r) => r.fulfill({ status: 200, contentType: 'application/json', body: '{"data":[]}' }));
await page.goto(`${base}/admin/`);
const reg = await page.evaluate(async () => { const r = await navigator.serviceWorker.ready; return { scope: r.scope, active: !!r.active }; });
check('service worker registered with scope /admin/', reg.active && reg.scope === `${base}/admin/`, JSON.stringify(reg));
check('manifest linked from the admin page', await page.$eval('link[rel=manifest]', (l) => l.getAttribute('href')) === '/admin/manifest.webmanifest');
await page.waitForFunction(async () => { const c = await caches.open('cg-admin-v1'); return (await c.keys()).length >= 8; });
const cached = await page.evaluate(async () => { const c = await caches.open('cg-admin-v1'); return (await c.keys()).map((k) => new URL(k.url).pathname); });
check('shell cached after install (html, css, js, config, manifest, icons)', ['/admin/index.html', '/admin/admin.css', '/admin/admin.js', '/admin/finance.js', '/config.js', '/assets/coach-gari.css', '/admin/manifest.webmanifest'].every((p) => cached.includes(p)), cached.join(' '));
// a data request through the page: fetched, never stored
await page.evaluate(() => fetch('https://acrjrlgeeyseyolmofuq.supabase.co/rest/v1/contacts?select=id').catch(() => {}));
const dataCached = await page.evaluate(async () => { const c = await caches.open('cg-admin-v1'); return (await c.keys()).some((k) => k.url.includes('supabase.co')); });
check('Supabase responses are never cached', !dataCached);
// offline: the shell still opens
await ctx.setOffline(true);
await page.goto(`${base}/admin/`).catch(() => {});
const offlineShell = await page.evaluate(() => !!document.querySelector('#login-form'));
check('offline: the shell opens from the cache', offlineShell);
await ctx.setOffline(false);
await page.reload();
// sign-in: link + code
await page.fill('#login-form [name=email]', 'gari@example.com');
await page.click('#login-form button[type=submit]');
await page.waitForSelector('#code-form:not([hidden])');
check('after sending the link, the 6-digit code form appears', true);
await page.fill('#code-form [name=code]', '123456');
await page.click('#code-form button[type=submit]');
await page.waitForFunction(() => document.querySelector('#login-msg').hidden);
const v = authCalls.find((c) => c.name === 'verifyOtp');
check('the code signs in with verifyOtp(email, token, type "email")', v && v.args.email === 'gari@example.com' && v.args.token === '123456' && v.args.type === 'email', JSON.stringify(v));
check('the link is still requested with the /admin/ redirect', authCalls.some((c) => c.name === 'signInWithOtp' && c.args.options.emailRedirectTo.endsWith('/admin/')));
const errs = [];
page.on('pageerror', (e) => errs.push(String(e)));
await page.reload(); await page.waitForTimeout(300);
check('no JavaScript errors on the admin shell', errs.length === 0, JSON.stringify(errs));
await browser.close();
server.close();
console.log(`\nADMIN_PWA_TESTS ok=${ok} fail=${fail}`);
process.exit(fail ? 1 : 0);

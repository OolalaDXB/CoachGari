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
  // frozen: the self-hosted supabase-js may arrive from the service-worker cache (page routes do not see worker fetches) and must not replace the stub
  Object.defineProperty(window, 'supabase', { writable: false, configurable: false, value: { createClient: () => ({
    auth: { getSession: async () => ({ data: { session: null } }), onAuthStateChange: () => {},
            signInWithOtp: async (a) => { window.__auth('signInWithOtp', a); return {}; },
            verifyOtp: async (a) => { window.__auth('verifyOtp', a); return { error: null }; }, signOut: async () => ({}) },
    rpc: async () => ({ data: null, error: null }), from: () => ({ select: async () => ({ data: [], error: null }) }),
  }) } });
});
await page.route('**/admin/vendor/**', (r) => r.fulfill({ status: 200, contentType: 'text/javascript', body: '/* stubbed: the test injects window.supabase */' }));
await page.route('**/fonts.googleapis.com/**', (r) => r.abort());
await page.route('**/acrjrlgeeyseyolmofuq.supabase.co/**', (r) => r.fulfill({ status: 200, contentType: 'application/json', body: '{"data":[]}' }));
await page.goto(`${base}/admin/`);
const reg = await page.evaluate(async () => { const r = await navigator.serviceWorker.ready; return { scope: r.scope, active: !!r.active }; });
check('service worker registered with scope /admin/', reg.active && reg.scope === `${base}/admin/`, JSON.stringify(reg));
check('manifest linked from the admin page', await page.$eval('link[rel=manifest]', (l) => l.getAttribute('href')) === '/admin/manifest.webmanifest');
/* The cache name follows the worker: read it from the source rather than pinning a
   literal here, which would quietly test a stale cache after the next bump. */
const swSrc = await readFile(join(ROOT, 'admin/sw.js'), 'utf8');
const CACHE = swSrc.match(/const VERSION = '([^']+)'/)[1];
check('the service worker names its cache version', /^cg-admin-v[0-9]+$/.test(CACHE), CACHE);
await page.waitForFunction(async (name) => { const c = await caches.open(name); return (await c.keys()).length >= 8; }, CACHE);
const cached = await page.evaluate(async (name) => { const c = await caches.open(name); return (await c.keys()).map((k) => new URL(k.url).pathname); }, CACHE);
check('shell cached after install (html, css, js, config, manifest, icons)', ['/admin/index.html', '/admin/admin.css', '/admin/admin.js', '/admin/finance.js', '/config.js', '/assets/coach-gari.css', '/admin/manifest.webmanifest'].every((p) => cached.includes(p)), cached.join(' '));
// a data request through the page: fetched, never stored
await page.evaluate(() => fetch('https://acrjrlgeeyseyolmofuq.supabase.co/rest/v1/contacts?select=id').catch(() => {}));
const dataCached = await page.evaluate(async () => { const c = await caches.open('cg-admin-v3'); return (await c.keys()).some((k) => k.url.includes('supabase.co')); });
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

/* The install invitation is for people who work here, not for anyone who reaches the URL.
   Two independent guards, so neither alone has to hold: the banner lives inside #app, which
   stays hidden until a session AND a non-empty NAV, and offerInstall() is called from exactly
   one place — render(), after my_permissions has come back. */
const inst = await page.evaluate(() => {
  const box = document.querySelector('#install');
  return { existe: !!box, cache: box ? box.hidden : null, dansApp: box ? !!box.closest('#app') : null,
           appCache: document.querySelector('#app').hidden };
});
check('the install invitation exists in the admin shell', inst.existe);
check('it sits inside #app, which is hidden until there is a session with access', inst.dansApp && inst.appCache);
check('a visitor who is not signed in is never invited to install', inst.cache === true);
const src = await readFile(join(ROOT, 'admin/admin.js'), 'utf8');
check('offerInstall() is called from one place only, after the permission check',
  (src.match(/^\s*offerInstall\(\);/gm) || []).length === 1);
check('the login screen never calls it', !/#login[\s\S]{0,400}offerInstall/.test(src));

/* Notifications: the permission prompt is shown once per browser and remembered, so
   spending it on someone who does not work here would be worse than the install
   banner. Same gate, plus the worker has to be able to receive and open one. */
const notif = await page.evaluate(() => {
  const box = document.querySelector('#notify');
  return { existe: !!box, cache: box ? box.hidden : null, dansApp: box ? !!box.closest('#app') : null };
});
check('the notifications invitation exists in the admin shell', notif.existe);
check('it sits inside #app, hidden until there is a session with access', notif.dansApp);
check('a visitor who is not signed in is never asked for notification permission', notif.cache === true);
check('offerNotifications() is called from one place only, after the permission check',
  (src.match(/^\s*offerInstall\(\); offerNotifications\(\);/gm) || []).length === 1);
check('Notification.requestPermission is only reached from that banner button',
  (src.match(/requestPermission/g) || []).length === 1 && /#notify-go[\s\S]{0,400}requestPermission/.test(src));
check('the subscription is written through push_subscribe, which pins it to the caller',
  /rpc\('push_subscribe'/.test(src) && !/from\('push_subscriptions'\)[\s\S]{0,80}insert/.test(src));
check('a failed save unsubscribes the device rather than leaving it half-registered',
  /if \(e2\)[\s\S]{0,60}unsubscribe\(\)/.test(src));

check('the worker handles push and notificationclick', /addEventListener\('push'/.test(swSrc) && /addEventListener\('notificationclick'/.test(swSrc));
check('a push with no readable payload still shows something', /New activity in the back-office/.test(swSrc));
check('the worker shows only the sentence it was sent, never a field of its own',
  /body: d\.t/.test(swSrc) && !/body:\s*`/.test(swSrc));
check('the notification stores nothing on the device', !/caches\.(open|put)[\s\S]{0,200}notification/i.test(swSrc));
check('tapping it opens the back-office, which still asks for a session',
  /clients\.openWindow/.test(swSrc) && !/token|session|jwt/i.test(swSrc.slice(swSrc.indexOf("addEventListener('push'"))));
const errs = [];
page.on('pageerror', (e) => errs.push(String(e)));
await page.reload(); await page.waitForTimeout(300);
check('no JavaScript errors on the admin shell', errs.length === 0, JSON.stringify(errs));
await browser.close();
server.close();
console.log(`\nADMIN_PWA_TESTS ok=${ok} fail=${fail}`);
process.exit(fail ? 1 : 0);

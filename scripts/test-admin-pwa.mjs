#!/usr/bin/env node
/* Back-office PWA — functional suite (Playwright + Chromium, no network).
   Proves: the manifest is valid and scoped to /admin, every icon resolves, the service worker registers with
   scope /admin from the admin only (the public homepage registers nothing and links no manifest) AND actually
   controls the page, the shell is cached after install, a request to Supabase is never cached, the shell still
   opens offline, the sign-in offers a passkey and the 6-digit code, and a browser without WebAuthn still gets
   the email form. The server mimics vercel.json (cleanUrls, trailingSlash:false), which is what makes the scope
   check meaningful. Run: node scripts/test-admin-pwa.mjs   */
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
/* Serves the repo the way vercel.json does — cleanUrls + trailingSlash:false — because
   the difference is not cosmetic here: production 308s /admin/ and /admin/index.html to
   /admin, so a worker scoped to "/admin/" would never control the page. A test server
   that happily serves /admin/ hides exactly that, and did for three versions. */
const server = createServer(async (req, res) => {
  const u = new URL(req.url, 'http://x');
  let p = decodeURIComponent(u.pathname);
  const send301 = (to) => { res.writeHead(308, { Location: to + u.search }); res.end(); };
  if (p !== '/' && p.endsWith('/')) return send301(p.replace(/\/+$/, ''));             // trailingSlash: false
  if (p.endsWith('/index.html')) return send301(p.slice(0, -'/index.html'.length) || '/');  // cleanUrls
  const tries = p === '/' ? ['/index.html'] : extname(p) ? [p] : [p + '.html', p + '/index.html'];
  for (const t of tries) {
    try {
      const body = await readFile(normalize(join(ROOT, t)));
      const headers = { 'Content-Type': MIME[extname(t)] || 'application/octet-stream' };
      if (p === '/admin/sw.js') headers['Service-Worker-Allowed'] = '/admin';           // as vercel.json sets it
      res.writeHead(200, headers); res.end(body); return;
    } catch {}
  }
  res.writeHead(404); res.end('not found');
});
await new Promise((r) => server.listen(0, '127.0.0.1', r));
const base = `http://127.0.0.1:${server.address().port}`;
let ok = 0, fail = 0;
const check = (name, cond, extra = '') => { if (cond) ok++; else fail++; console.log(`${cond ? 'PASS' : 'FAIL'}  ${name}${cond ? '' : ' ' + extra}`); };

/* ---- manifest + icons ---- */
{
  const r = await fetch(`${base}/admin/manifest.webmanifest`); const m = await r.json();
  check('manifest is valid JSON with scope and start_url under /admin', r.ok && m.scope === '/admin' && m.start_url === '/admin' && m.display === 'standalone' && m.name.includes('Coach Gari'));
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
  Object.defineProperty(window, 'supabase', { writable: false, configurable: false, value: { createClient: (url, key, opts) => (window.__auth('createClient', opts), {
    auth: { getSession: async () => ({ data: { session: null } }), onAuthStateChange: () => {},
            signInWithOtp: async (a) => { window.__auth('signInWithOtp', a); return {}; },
            // a token_hash link is verified by the page; the stub refuses it so the failure path is exercised
            verifyOtp: async (a) => { window.__auth('verifyOtp', a); return a.token_hash ? { error: { message: 'Token has expired or is invalid' } } : { error: null }; }, signOut: async () => ({}),
            signInWithPasskey: async (a) => { window.__auth('signInWithPasskey', a ?? null); return { data: {}, error: null }; },
            registerPasskey: async (a) => { window.__auth('registerPasskey', a ?? null); return { data: {}, error: null }; },
            passkey: { list: async () => ({ data: [], error: null }), delete: async (a) => { window.__auth('deletePasskey', a); return { error: null }; } } },
    rpc: async () => ({ data: null, error: null }), from: () => ({ select: async () => ({ data: [], error: null }) }),
  }) } });
});
await page.route('**/admin/vendor/**', (r) => r.fulfill({ status: 200, contentType: 'text/javascript', body: '/* stubbed: the test injects window.supabase */' }));
await page.route('**/fonts.googleapis.com/**', (r) => r.abort());
await page.route('**/acrjrlgeeyseyolmofuq.supabase.co/**', (r) => r.fulfill({ status: 200, contentType: 'application/json', body: '{"data":[]}' }));
await page.goto(`${base}/admin/`);                                // as a person would type it; production redirects
check('the back-office is served at /admin, with no trailing slash', page.url() === `${base}/admin`, page.url());
// .ready never settles when the page sits outside the worker's scope — which is the exact
// regression this section guards. Race it, so a wrong scope fails the suite instead of hanging it.
const reg = await page.evaluate(async () => Promise.race([
  navigator.serviceWorker.ready.then((r) => ({ scope: r.scope, active: !!r.active })),
  new Promise((r) => setTimeout(() => r({ scope: null, active: false, note: 'navigator.serviceWorker.ready never resolved: the page is out of scope' }), 8000)),
]));
check('service worker registered with scope /admin', reg.active && reg.scope === `${base}/admin`, JSON.stringify(reg));
/* The whole point of the worker: a page outside its scope is never controlled, so
   there is no offline shell, no push and nothing for the browser to install. */
await page.waitForFunction(() => !!navigator.serviceWorker.controller, null, { timeout: 5000 }).catch(() => {});
check('the page at /admin is actually controlled by that worker',
  await page.evaluate(() => !!navigator.serviceWorker.controller
    && new URL(navigator.serviceWorker.controller.scriptURL).pathname === '/admin/sw.js'));
{
  const m = JSON.parse(await (await fetch(`${base}/admin/manifest.webmanifest`)).text());
  check('the manifest start_url and scope match the path the worker controls',
    m.start_url === '/admin' && m.scope === '/admin' && m.id === '/admin', JSON.stringify(m.start_url + ' ' + m.scope));
}
check('manifest linked from the admin page', await page.$eval('link[rel=manifest]', (l) => l.getAttribute('href')) === '/admin/manifest.webmanifest');
/* The cache name follows the worker: read it from the source rather than pinning a
   literal here, which would quietly test a stale cache after the next bump. */
const swSrc = await readFile(join(ROOT, 'admin/sw.js'), 'utf8');
const CACHE = swSrc.match(/const VERSION = '([^']+)'/)[1];
check('the service worker names its cache version', /^cg-admin-v[0-9]+$/.test(CACHE), CACHE);
await page.waitForFunction(async (name) => { const c = await caches.open(name); return (await c.keys()).length >= 8; }, CACHE);
const cached = await page.evaluate(async (name) => { const c = await caches.open(name); return (await c.keys()).map((k) => new URL(k.url).pathname); }, CACHE);
check('shell cached after install (html, css, js, config, manifest, icons)', ['/admin', '/admin/admin.css', '/admin/admin.js', '/admin/finance.js', '/config.js', '/assets/coach-gari.css', '/admin/manifest.webmanifest'].every((p) => cached.includes(p)), cached.join(' '));
// a data request through the page: fetched, never stored
await page.evaluate(() => fetch('https://acrjrlgeeyseyolmofuq.supabase.co/rest/v1/contacts?select=id').catch(() => {}));
const dataCached = await page.evaluate(async (name) => { const c = await caches.open(name); return (await c.keys()).some((k) => k.url.includes('supabase.co')); }, CACHE);
check('Supabase responses are never cached', !dataCached);
// offline: the shell still opens
await ctx.setOffline(true);
await page.goto(`${base}/admin/`).catch(() => {});
const offlineShell = await page.evaluate(() => !!document.querySelector('#login-form'));
check('offline: the shell opens from the cache', offlineShell);
await ctx.setOffline(false);
await page.reload();

/* ---- passkeys ----------------------------------------------------------------
   The passkey is the fast way in, never the only one: the email form and the
   6-digit code below it are checked right after, unchanged. The vendor bundle is
   stubbed here (as everywhere in this suite), so what is proven is the wiring —
   the opt-in, the support gate, which call each button makes, and the rule that a
   passkey can only be enrolled from inside a session. */
{
  const created = authCalls.find((c) => c.name === 'createClient');
  check('the client opts in to the experimental passkey API', created?.args?.auth?.experimental?.passkey === true, JSON.stringify(created?.args));
  check('the passkey button is offered where the browser supports WebAuthn', await page.evaluate(() => !document.querySelector('#passkey-box').hidden));
  await page.click('#passkey-go');
  await page.waitForFunction(() => document.querySelector('#login-msg').hidden);
  check('it signs in with signInWithPasskey — no email, no code', authCalls.some((c) => c.name === 'signInWithPasskey'));
  check('the email form is still there underneath', await page.evaluate(() => !!document.querySelector('#login-form [name=email]') && !!document.querySelector('#code-form')));
}
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

/* A magic link that comes back without opening a session used to redraw the sign-in
   card and say nothing — indistinguishable from never having clicked. It must say what
   happened and offer the code, which has no tie to one browser. */
{
  await page.goto(`${base}/admin?code=not-a-real-code`);
  await page.waitForFunction(() => !document.querySelector('#code-form').hidden, null, { timeout: 5000 }).catch(() => {});
  const s = await page.evaluate(() => ({
    msg: document.querySelector('#login-msg').hidden ? '' : document.querySelector('#login-msg').textContent,
    err: document.querySelector('#login-msg').className.includes('err'),
    code: !document.querySelector('#code-form').hidden,
    asksEmail: !document.querySelector('#code-email').hidden,
    knows: document.querySelector('#code-form').dataset.email || '',
    url: location.search,
  }));
  check('a link that opens no session says so instead of silently redrawing the form', s.err && /did not open a session|did not work/i.test(s.msg), JSON.stringify(s));
  // the address was remembered from the request earlier in this suite, so it should not be asked for again
  check('it offers the 6-digit code, for the address this device last asked a link for', s.code && s.knows === 'gari@example.com' && !s.asksEmail, JSON.stringify(s));
  // and when nothing is remembered, it asks rather than presenting a form that cannot work
  await page.evaluate(() => localStorage.removeItem('cg-email'));
  await page.goto(`${base}/admin?code=not-a-real-code`);
  await page.waitForFunction(() => !document.querySelector('#code-form').hidden, null, { timeout: 5000 }).catch(() => {});
  check('with no remembered address, it asks which one the code belongs to',
    await page.evaluate(() => !document.querySelector('#code-email').hidden && !document.querySelector('#code-form').dataset.email));
  check('the spent code is stripped from the URL so a refresh does not replay it', s.url === '', s.url);

  /* The portable shape: a link built on {{ .TokenHash }} is verified by this page, with
     no PKCE exchange, so it works from a mail app's browser or a private window. */
  authCalls.length = 0;
  await page.goto(`${base}/admin?token_hash=abc123&type=magiclink`);
  await page.waitForFunction(() => !document.querySelector('#login-msg').hidden, null, { timeout: 5000 }).catch(() => {});
  const v = authCalls.find((c) => c.name === 'verifyOtp');
  check('a token_hash link is verified here, not exchanged through PKCE', v && v.args.token_hash === 'abc123' && v.args.type === 'magiclink', JSON.stringify(v));
  check('a token_hash that GoTrue rejects is reported as spent, not as a browser problem',
    await page.evaluate(() => /expired or was already used/i.test(document.querySelector('#login-msg').textContent)));
  // the type comes from a URL: anything unknown falls back rather than being passed through
  authCalls.length = 0;
  await page.goto(`${base}/admin?token_hash=abc123&type=../evil`);
  await page.waitForFunction(() => !document.querySelector('#login-msg').hidden, null, { timeout: 5000 }).catch(() => {});
  check('an unknown type in the URL is not passed through to verifyOtp',
    authCalls.find((c) => c.name === 'verifyOtp')?.args.type === 'magiclink');
  await page.goto(`${base}/admin`);
}

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
/* Enrolment needs a session: there is no way to mint a first passkey from the
   sign-in screen, or anyone could claim an address they do not own. The owner's
   email code is how a new operator gets in the first time. */
check('registerPasskey is reached only from the account menu, never from the login screen',
  /data-passkeys[\s\S]{0,200}openPasskeys/.test(src) && !/#login[\s\S]{0,600}registerPasskey/.test(src));
check('the passkey button is wired once, behind the WebAuthn support check',
  (src.match(/registerPasskey\(\)/g) || []).length === 1 && /webauthnOk\)\s*\{\s*\$\('#passkey-box'\)\.hidden = false/.test(src));
// the relying party is fixed server-side (coachgari28.com); changing it invalidates every enrolled passkey
check('the relying-party id is never set from the browser', !/\brpId\b|\brp_id\b|\brp:\s*\{/.test(src));
check('the email code is untouched as the permanent fallback',
  /signInWithOtp/.test(src) && /verifyOtp/.test(src) && /type: 'email'/.test(src));

/* A browser without WebAuthn (older Android WebViews, locked-down desktops) must
   not be shown a button that cannot work — it gets the email form only. */
{
  const ctx2 = await browser.newContext();
  await ctx2.addInitScript(() => {
    delete window.PublicKeyCredential;
    Object.defineProperty(window, 'supabase', { writable: false, configurable: false, value: { createClient: () => ({
      auth: { getSession: async () => ({ data: { session: null } }), onAuthStateChange: () => {}, signOut: async () => ({}) },
      rpc: async () => ({ data: null, error: null }), from: () => ({ select: async () => ({ data: [], error: null }) }),
    }) } });
  });
  await ctx2.route('**/admin/vendor/**', (r) => r.fulfill({ status: 200, contentType: 'text/javascript', body: '/* stubbed */' }));
  await ctx2.route('**/fonts.googleapis.com/**', (r) => r.abort());
  const p2 = await ctx2.newPage();
  await p2.goto(`${base}/admin/`);
  check('no WebAuthn: the passkey button stays hidden and the email form still works',
    await p2.evaluate(() => document.querySelector('#passkey-box').hidden === true && !!document.querySelector('#login-form [name=email]')));
  await ctx2.close();
}

const errs = [];
page.on('pageerror', (e) => errs.push(String(e)));
await page.reload(); await page.waitForTimeout(300);
check('no JavaScript errors on the admin shell', errs.length === 0, JSON.stringify(errs));
await browser.close();
server.close();
console.log(`\nADMIN_PWA_TESTS ok=${ok} fail=${fail}`);
process.exit(fail ? 1 : 0);

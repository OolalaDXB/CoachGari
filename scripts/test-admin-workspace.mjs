#!/usr/bin/env node
/* Admin Finance / BEAU PH workspace — browser behaviour suite (Playwright + Chromium, no network).
   Serves the repo, stubs window.supabase with a recording client and the ph-admin helper with a canned
   reply, then proves the loading discipline and the editor flows the spec requires:
     Finance open           → finance_transactions only (no methods, rails, fx, ledger)
     Transactions           → the default Finance tab
     Payment methods        → payment_methods_summary only (no per-method configuration)
     Edit                   → payment_method_get for THAT method only; inline editor opens
     Save changes           → one confirmation with a change summary; payment_method_set once; editor collapses
     Remove                 → confirmation copy; payment_method_remove; history preserved wording
     BEAU PH › Rails        → beau_ph_rails + one runtime probe; 11 cards; Configure loads that rail only
     BEAU PH › FX           → beau_ph_fx only
     Cache                  → returning to Transactions within the session does not refetch
     Secrets                → nothing secret-shaped is ever requested or rendered
   Run: node scripts/test-admin-workspace.mjs  (exit 1 on any failure). Prints ADMIN_WORKSPACE_TESTS ok=… fail=…   */
import { createRequire } from 'node:module';
// playwright from the project when installed, otherwise from the global prefix (`npm root -g`) — no download, no network
const chromium = await (async () => {
  try { return (await import('playwright')).chromium; }
  catch { const { execSync } = await import('node:child_process'); const g = execSync('npm root -g').toString().trim(); return createRequire(g + '/').call(null, 'playwright').chromium; }
})();
import { createServer } from 'node:http';
import { readFile } from 'node:fs/promises';
import { extname, join, normalize } from 'node:path';

const ROOT = new URL('..', import.meta.url).pathname;
const MIME = { '.html': 'text/html', '.js': 'text/javascript', '.mjs': 'text/javascript', '.css': 'text/css', '.json': 'application/json', '.svg': 'image/svg+xml', '.png': 'image/png', '.webp': 'image/webp', '.ico': 'image/x-icon' };
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

/* ---- canned server (what the RPCs return; shapes mirror the migrations) ---- */
const FIXTURES = {
  my_permissions: { email: 'grej28roux@gmail.com', display_name: 'Gari', party: 'gari', permissions: ['coach:operations', 'client_profile:view', 'finance:view', 'finance:manage', 'analytics:view', 'catalog:view'] },
  finance_transactions: [
    { reference: 'OR-1B7DDF', created_at: '2026-09-09T07:58:21Z', paid_at: '2026-09-09T07:58:34Z', public_reference: 'CG-1048', type: 'package', customer_hint: 'm***@e***.com', crm_contact_id: 'c1', item: '5-session pack', method: 'stripe', method_label: 'Card (Stripe)', method_kind: 'online', amount: 1000, currency: 'AED', pricing_amount: 1000, pricing_currency: 'AED', fx: false, status: 'refunded', order_status: 'refunded', refund_amount: 1000, chargeback_amount: 0, earning_status: 'open', fee_known: false, action: 'fee_pending', ph_reference: 'CG-1048', ph_request_id: 'r1', provider_reference: 'pi_x', reconciled: true, support_message: null },
    { reference: 'OR-AAAAAA', created_at: '2026-09-08T10:00:00Z', paid_at: null, public_reference: 'CG-1049', type: 'package', customer_hint: 'a***@b***.com', crm_contact_id: 'c2', item: '10-session pack', method: 'aani', method_label: 'Aani (UAE instant payment)', method_kind: 'manual', amount: 50000, currency: 'AED', pricing_amount: 50000, pricing_currency: 'AED', fx: false, status: 'pending', order_status: 'pending_payment', refund_amount: null, chargeback_amount: null, earning_status: null, fee_known: null, action: 'confirm_receipt', ph_reference: 'CG-1049', ph_request_id: 'r2', provider_reference: null, reconciled: false, support_message: null },
  ],
  payment_methods_summary: [
    { provider: 'stripe', display_name: 'Card (Stripe)', channel_label: 'Online · Card', kind: 'online', readiness: 'available', enabled: true, countries: ['AE', 'GB', 'ZW'], currencies: ['AED', 'USD'], intents: null, health: 'configured', hint: null, history: 2, updated_at: '2026-09-09T00:00:00Z', updated_by: 'migration' },
    { provider: 'aani', display_name: 'Aani (UAE instant payment)', channel_label: 'Manual · Instant payment (UAE)', kind: 'manual', readiness: 'available', enabled: true, countries: ['AE'], currencies: ['AED'], intents: null, health: 'configured', hint: '•••• 5065', history: 1, updated_at: '2026-09-09T00:00:00Z', updated_by: 'mickael@thestudio.mt' },
  ],
  payment_method_get: {
    provider: { key: 'aani', display_name: 'Aani (UAE instant payment)', kind: 'manual', channel_label: 'Manual · Instant payment (UAE)', readiness: 'available', confirmation: 'operator', countries: ['AE'], currencies: ['AED'], intents: null, secrets: [], onboarding: 'No API.', notes: null,
      config_schema: [{ key: 'proxy_type', label: 'Proxy type', store: 'instructions', type: 'select', options: ['mobile', 'email', 'merchant', 'qr'], public: true }, { key: 'proxy_value', label: 'Aani value (machine)', store: 'instructions', type: 'text', mask: true, public: true }, { key: 'display_value', label: 'Display value', store: 'instructions', type: 'text', public: true }, { key: 'instructions', label: 'Instructions shown to the client', store: 'instructions', type: 'textarea', public: true }],
      capabilities: [{ capability: 'manual_instructions', readiness: 'available', confirmation: 'operator', handoff: false }] },
    method: { id: 'm1', provider: 'aani', enabled: true, listed: true, currency: 'AED', countries: ['AE'], currencies: ['AED'], intents: null, capabilities: null, limits: {}, instructions: { proxy_type: 'mobile', proxy_value: '+971500005065', display_value: '+971 50 000 5065' }, settings: {}, settlement: {}, updated_by: 'x', updated_at: '2026-09-09T00:00:00Z' },
    destinations: [], intents: ['service', 'package', 'support', 'other'] },
  payment_method_set: { provider: 'aani', enabled: true },
  payment_method_remove: { provider: 'aani', removed: 'unlisted', history: 1 },
  beau_ph_fx: { base_currency: 'EUR', settings: { enabled: false, reporting_currency: 'AED', adjustment_bps: 0, quote_ttl_minutes: 15, max_age_hours: 72 }, health: { last_refresh_at: '2026-09-09T09:10:13Z', last_refresh_status: 'success', last_rate_date: '2026-09-08', in_progress: false, fresh: 4, acceptable: 0, stale: 0, missing: 0, rejected: [], source_errors: {} },
    currencies: [{ currency: 'USD', enabled: true, source: 'frankfurter', source_kind: 'frankfurter', rate: 1.1614, rate_date: '2026-09-08', fetched_at: '2026-09-09T09:10:13Z', age_hours: 1, freshness: 'fresh' }, { currency: 'AED', enabled: true, source: 'usd_peg', source_kind: 'peg', peg_currency: 'USD', peg_rate: 3.6725, rate: 4.2652, rate_date: '2026-09-08', fetched_at: '2026-09-09T09:10:13Z', age_hours: 1, freshness: 'fresh' }, { currency: 'KES', enabled: false, source: null, notes: 'No configured source.' }],
    sources: [{ key: 'frankfurter', kind: 'frankfurter', url: 'https://api.frankfurter.app/latest', enabled: true, sort: 10 }], runs: [], quotes: { active: 0, consumed_30d: 0 } },
};
const rail = (provider, display_name, kind, readiness, extra = {}) => ({ provider, display_name, kind, channel_label: kind === 'manual' ? 'Manual · x' : 'Online · x', confirmation: kind === 'manual' ? 'operator' : 'provider_event', readiness, provider_countries: null, provider_currencies: null, provider_intents: null,
  secrets: provider === 'stripe' ? ['STRIPE_SECRET_KEY', 'STRIPE_WEBHOOK_SECRET', 'STRIPE_PUBLISHABLE_KEY'] : [], onboarding: 'x', notes: null,
  capabilities: [{ capability: 'online_checkout', readiness, confirmation: 'provider_event', handoff: false }], merchant: null, activity: { requests: 0, paid: 0, last_paid_at: null, last_event_at: null, last_event_outcome: null }, ...extra });
FIXTURES.beau_ph_rails = { merchant: { key: 'coach_gari', name: 'Coach Gari', country: 'AE', default_currency: 'AED', mode: 'live' }, rails: [
  rail('stripe', 'Card (Stripe)', 'online', 'available', { merchant: { enabled: true, listed: true, countries: ['AE'], currencies: ['AED', 'USD'], intents: null, health: 'configured', limits: {} }, activity: { requests: 2, paid: 1, last_paid_at: '2026-09-09T07:58:34Z', last_event_at: '2026-09-09T07:59:36Z', last_event_outcome: 'normalized' } }),
  rail('aani', 'Aani', 'manual', 'available', { merchant: { enabled: true, listed: true, countries: ['AE'], currencies: ['AED'], intents: null, health: 'configured', limits: {} }, capabilities: [{ capability: 'manual_instructions', readiness: 'available', confirmation: 'operator', handoff: false }] }),
  rail('bank_transfer', 'Bank transfer', 'manual', 'available', { capabilities: [{ capability: 'bank_transfer', readiness: 'available', confirmation: 'operator', handoff: false }] }),
  rail('paynow', 'Paynow', 'online', 'not_configured'), rail('mpesa', 'M-PESA', 'online', 'not_configured'), rail('ozow', 'Ozow', 'online', 'not_configured'), rail('payshap', 'PayShap', 'online', 'not_configured'),
  rail('beau_wallet', 'BEAU Wallet', 'crypto', 'placeholder', { capabilities: [{ capability: 'wallet', readiness: 'placeholder', confirmation: 'unavailable', handoff: false }] }),
  rail('network_international', 'Network International', 'online', 'not_configured', { capabilities: [{ capability: 'softpos', readiness: 'available', confirmation: 'operator', handoff: true }] }),
  rail('magnati', 'Magnati', 'online', 'not_configured', { capabilities: [{ capability: 'softpos', readiness: 'available', confirmation: 'operator', handoff: true }] }),
  rail('adyen', 'Adyen', 'online', 'not_configured'),
] };
const RUNTIME = { ok: true, mode: 'live', site_url: 'set', providers: { stripe: { configured: true, mode: 'live', embedded: true, secrets: { STRIPE_SECRET_KEY: true, STRIPE_WEBHOOK_SECRET: true, STRIPE_PUBLISHABLE_KEY: true } }, aani: { configured: false, reason: 'no secret needed', secrets: {} } } };

const browser = await chromium.launch();
const page = await browser.newPage({ viewport: { width: 1280, height: 900 } });
const calls = [];                       // every rpc call the page makes, in order
await page.exposeFunction('__rpc', (name, args) => { calls.push({ name, args }); const v = FIXTURES[name]; return v === undefined ? { data: null, error: { code: 'PGRST202', message: `no fixture for ${name}` } } : { data: JSON.parse(JSON.stringify(v)), error: null }; });
await page.route('**/admin/vendor/**', (r) => r.fulfill({ status: 200, contentType: 'text/javascript', body: '/* stubbed: the test injects window.supabase */' }));
await page.route('**/fonts.googleapis.com/**', (r) => r.abort());
await page.route('**/plausible.io/**', (r) => r.abort());
await page.route('**/functions/v1/ph-admin', (r) => { calls.push({ name: 'fetch:ph-admin', args: { auth: !!r.request().headers()['authorization'] } }); r.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify(RUNTIME) }); });
await page.addInitScript(() => {
  const chain = (data) => { const c = { then: (f) => Promise.resolve({ data, error: null }).then(f) }; for (const m of ['select', 'order', 'limit', 'eq', 'in', 'or', 'maybeSingle', 'range']) c[m] = () => c; return c; };
  const session = { user: { email: 'grej28roux@gmail.com' }, access_token: 'test-jwt' };
  window.supabase = { createClient: () => ({
    auth: { getSession: async () => ({ data: { session } }), onAuthStateChange: () => {}, signInWithOtp: async () => ({}), signOut: async () => ({}) },
    rpc: (name, args) => { const p = window.__rpc(name, args || {}); p.limit = () => p; return p; },
    from: (t) => chain(t === 'partner_settlements' ? [] : []),
  }) };
  window.__prompt = window.prompt; window.confirm = () => true;
});
page.on('pageerror', (e) => { fail++; log.push('pageerror ' + e.message); console.log('PAGEERROR', e.message); });
const rpcNames = () => calls.map((c) => c.name);
const count = (n) => calls.filter((c) => c.name === n).length;

await page.goto(`${base}/admin/#finance`);
await page.waitForSelector('#nav a[data-section="finance"]');
await page.waitForFunction(() => document.querySelector('#view') && /Transactions/.test(document.querySelector('#view').innerText));
check('Finance opens on Transactions by default', (await page.evaluate(() => location.hash)) === '#finance/transactions', await page.evaluate(() => location.hash));
check('Finance open fetches transactions only', count('finance_transactions') === 1 && count('payment_methods_summary') === 0 && count('beau_ph_rails') === 0 && count('beau_ph_fx') === 0 && count('finance_orders') === 0 && count('payment_method_get') === 0, rpcNames().join(','));
check('Transaction rows render with type, method, status', await page.evaluate(() => { const t = document.querySelector('#view').innerText; return t.includes('CG-1048') && t.includes('Package') && t.includes('Card (Stripe)') && t.includes('refunded'); }));
check('Ledger is not fetched until opened', count('finance_orders') === 0);
await page.click('#tx-ledger summary');
await page.waitForFunction(() => document.querySelector('#tx-ledger-body') && /Settlements|Loading/.test(document.querySelector('#tx-ledger-body').innerText));
await page.waitForTimeout(200);
check('Ledger loads on demand', count('finance_orders') === 1);

// Payment methods tab: summaries only
await page.click('#subnav a[data-sub="methods"]');
await page.waitForSelector('.ph-row[data-method="aani"]');
check('Payment methods tab lists configured methods only', (await page.$$('.ph-row')).length === 2);
check('Payment methods fetches summaries only', count('payment_methods_summary') === 1 && count('payment_method_get') === 0 && count('beau_ph_rails') === 0);
check('Configured row is compact (name, status, countries, currencies, hint, health)', await page.evaluate(() => { const r = document.querySelector('.ph-row[data-method="aani"]').textContent; return r.includes('Active') && r.includes('United Arab Emirates') && r.includes('AED') && r.includes('•••• 5065') && r.includes('Configured'); }));
check('Actions are present but hidden until hover (no layout shift)', await page.evaluate(() => { const a = document.querySelector('.ph-row[data-method="aani"] .ph-row-acts'); return a && getComputedStyle(a).opacity === '0' && getComputedStyle(a).display !== 'none'; }));
await page.hover('.ph-row[data-method="aani"]');
await page.waitForTimeout(250);
check('Hover reveals Edit / Remove', await page.evaluate(() => getComputedStyle(document.querySelector('.ph-row[data-method="aani"] .ph-row-acts')).opacity === '1'));

// Edit: that method only
await page.click('.ph-row[data-method="aani"] [data-edit]');
await page.waitForSelector('.ph-row[data-method="aani"] form.ph-editor');
check('Edit loads only that method configuration', count('payment_method_get') === 1 && calls.find((c) => c.name === 'payment_method_get').args.p_method === 'aani');
check('Editor renders from the schema (grouped, Advanced collapsed)', await page.evaluate(() => { const f = document.querySelector('form.ph-editor'); return !!f.querySelector('[name="f:display_value"]') && !!f.querySelector('[name="f:proxy_type"]') && f.textContent.includes('Markets') && f.textContent.includes('Settlement') && f.textContent.includes('Limits') && !f.querySelector('details.ph-adv').open; }));
check('No secret value anywhere in the editor', await page.evaluate(() => !/sk_(live|test)_|whsec_|pk_(live|test)_/.test(document.body.innerHTML)));
await page.fill('form.ph-editor [name="f:display_value"]', '+971 50 000 9999');
await page.click('form.ph-editor button[type="submit"]');
await page.waitForSelector('.ph-modal');
check('Save shows ONE confirmation with a change summary', await page.evaluate(() => { const m = document.querySelector('.ph-modal').innerText; return m.includes('Confirm changes') && m.includes('Display value') && m.includes('+971 50 000 5065') && m.includes('+971 50 000 9999'); }));
check('Nothing is saved before confirming', count('payment_method_set') === 0);
await page.click('.ph-modal [data-ok]');
await page.waitForFunction(() => { const e = document.querySelector('.ph-row[data-method="aani"] [data-editor]'); return e && e.hidden; });
const setCall = calls.find((c) => c.name === 'payment_method_set');
check('Confirm saves once through payment_method_set with the schema fields', count('payment_method_set') === 1 && setCall.args.p.method === 'aani' && setCall.args.p.fields.display_value === '+971 50 000 9999' && Array.isArray(setCall.args.p.countries));
check('Editor collapses after save and the list refreshes', (await page.evaluate(() => document.querySelector('.ph-row[data-method="aani"] [data-editor]').hidden)) === true && count('payment_methods_summary') >= 2);
check('Success acknowledgement shown', await page.evaluate(() => !document.querySelector('#toast').hidden && /Saved/.test(document.querySelector('#toast').textContent)));

// Remove: confirmation copy, history preserved
await page.hover('.ph-row[data-method="aani"]');
await page.click('.ph-row[data-method="aani"] [data-remove]');
await page.waitForSelector('.ph-modal');
check('Remove asks with the expected copy', await page.evaluate(() => { const m = document.querySelector('.ph-modal').innerText; return m.includes('Remove Aani (UAE instant payment) from Coach Gari?') && m.includes('Customers will no longer be offered') && m.includes('Existing transactions and payment history will be preserved') && m.includes('Remove payment method'); }));
await page.click('.ph-modal [data-ok]');
await page.waitForTimeout(300);
check('Remove calls payment_method_remove (server decides unlist vs delete)', count('payment_method_remove') === 1);

// Add: the catalogue is fetched only on click
check('Catalogue not fetched before + Add', count('beau_ph_rails') === 0);
await page.click('#pm-add');
await page.waitForSelector('#pm-catalogue .ph-cat-row');
check('+ Add opens the BEAU PH catalogue (fetched now, once)', count('beau_ph_rails') === 1 && (await page.$$('#pm-catalogue .ph-cat-row')).length >= 5);

// BEAU PH › Rails
const before = count('beau_ph_rails');
await page.click('#nav a[data-section="beauph"]');
await page.waitForSelector('.ph-card[data-rail="stripe"]');
check('Rails default tab, 11 rails rendered', (await page.evaluate(() => location.hash)) === '#beauph/rails' && (await page.$$('.ph-card')).length === 11);
check('Rails uses the cached catalogue and one runtime probe (JWT sent)', count('beau_ph_rails') === before && count('fetch:ph-admin') === 1 && calls.find((c) => c.name === 'fetch:ph-admin').args.auth === true);
check('Rail card shows LIVE, capability vs merchant coverage, checklist', await page.evaluate(() => { const c = document.querySelector('.ph-card[data-rail="stripe"]').textContent; return c.includes('LIVE') && c.includes('Active') && c.includes('Provider coverage') && c.includes('Merchant enabled') && c.includes('Credentials') && c.includes('Webhook') && c.includes('Merchant config') && c.includes('Last activity'); }));
check('A not-onboarded rail is not pretended ready', await page.evaluate(() => { const c = document.querySelector('.ph-card[data-rail="mpesa"]').textContent; return c.includes('Not onboarded') && c.includes('Start onboarding') && !c.includes('Enable'); }));
check('Coming-soon rail exposes nothing to configure', await page.evaluate(() => document.querySelector('.ph-card[data-rail="beau_wallet"]').textContent.includes('Coming soon')));
await page.selectOption('#rf-status', 'active');
await page.waitForFunction(() => document.querySelectorAll('.ph-card').length === 2);
check('Filter by status works client-side (no refetch)', (await page.$$('.ph-card')).length === 2 && count('beau_ph_rails') === before);
await page.selectOption('#rf-status', '');
await page.waitForFunction(() => document.querySelectorAll('.ph-card').length === 11);
const getsBefore = count('payment_method_get');
await page.click('.ph-card[data-rail="aani"] [data-configure]');
await page.waitForSelector('.ph-card[data-rail="aani"] form.ph-editor');
check('Configure loads that rail only', count('payment_method_get') === getsBefore + 1 && calls.filter((c) => c.name === 'payment_method_get').pop().args.p_method === 'aani');
check('Audit trail not fetched until opened', count('beau_ph_config_audit') === 0);

// BEAU PH › FX
await page.click('#subnav a[data-sub="fx"]');
await page.waitForSelector('#fx-form');
check('FX fetches the overview only', count('beau_ph_fx') === 1);
check('FX shows health, currency rows with freshness, settings', await page.evaluate(() => { const t = document.querySelector('#view').innerText; return t.includes('Last refresh') && t.includes('USD') && t.includes('Fresh') && t.includes('USD peg') && t.includes('Merchant FX settings') && t.includes('No rate') === false; }));

// Cache: back to Finance › Transactions within the session → no refetch
const txBefore = count('finance_transactions');
await page.click('#nav a[data-section="finance"]');
await page.waitForFunction(() => /Transactions/.test(document.querySelector('#view').innerText));
check('Returning to Transactions reuses the cached list (no refetch in the same session)', count('finance_transactions') === txBefore);
check('No RPC ever asked for a secret or a provider credential', !calls.some((c) => /secret|key|credential/i.test(JSON.stringify(c.args))));

await browser.close(); server.close();
console.log(`\nADMIN_WORKSPACE_TESTS ok=${ok} fail=${fail}${log.length ? '\n' + log.join('\n') : ''}`);
process.exit(fail ? 1 : 0);

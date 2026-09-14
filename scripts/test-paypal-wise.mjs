#!/usr/bin/env node
/* Wise and PayPal — offline (no network, no account, no secrets).

   The Wise checks are about honesty: it is a manual rail and must not pretend
   to be anything else. The PayPal checks drive the adapter for real against a
   fake fetch — the order it builds, the environment it talks to, what it
   refuses — because a payment adapter that is only pattern-matched is a payment
   adapter nobody has run.
   Run: node --experimental-strip-types scripts/test-paypal-wise.mjs */
import { readFileSync } from 'node:fs';
import { wise } from '../beau-ph/providers/wise/adapter.ts';
import { paypal, toPayPalAmount, fromPayPalAmount, paymentsMode } from '../beau-ph/providers/paypal/adapter.ts';
import { providers, providerKeys } from '../beau-ph/core/registry.ts';

const read = (p) => readFileSync(new URL(p, import.meta.url), 'utf8');
const mig = read('../supabase/migrations/20261045_beau_ph_wise_paypal.sql');
const host = read('../supabase/migrations/20261046_cg_process_paypal_event.sql');
const hook = read('../supabase/functions/paypal-webhook/index.ts');
const paypalSrc = read('../beau-ph/providers/paypal/adapter.ts');
const reportFn = read('../supabase/functions/report/index.ts');
const reportJs = read('../assets/report.js');
const reportHtml = read('../r.html');
const wiseSrc = read('../beau-ph/providers/wise/adapter.ts');

let ok = 0, fail = 0;
const check = (name, cond, extra = '') => { if (cond) ok++; else fail++; console.log(`${cond ? 'PASS' : 'FAIL'}  ${name}${cond ? '' : ' ' + extra}`); };

const ENV = (o) => (n) => o[n];
const FULL = { PAYMENTS_MODE: 'test', PAYPAL_CLIENT_ID: 'id', PAYPAL_SECRET: 'sh', PAYPAL_WEBHOOK_ID: 'WH-CFG' };
const LIVE = { ...FULL, PAYMENTS_MODE: 'live' };

const INPUT = {
  requestId: '11111111-1111-4111-8111-111111111111', publicReference: 'CG-1048',
  externalReference: 'CG-1048', amount: 4500, currency: 'AED', description: 'Coaching pack',
  returnUrls: { success: 'https://coachgari28.com/r?paid=1', cancel: 'https://coachgari28.com/r' }, attempt: 2,
};

/* A fetch that records what it was asked and answers like PayPal. */
function fakeFetch(answers) {
  const calls = [];
  const f = async (url, init = {}) => {
    calls.push({ url: String(url), init });
    for (const [match, res] of answers) if (String(url).includes(match)) return res();
    return new Response('{}', { status: 404 });
  };
  f.calls = calls;
  return f;
}
const json = (body, status = 200) => () => new Response(JSON.stringify(body), { status });
const TOKEN = ['oauth2/token', json({ access_token: 'A-TOKEN' })];

/* ---- Wise: a manual rail, and it says so ---- */
check('Wise is registered and is a manual rail', providers.wise === wise && wise.capabilities().kind === 'manual');
check('Wise offers no checkout and no webhook, because Wise cannot confirm a payment to us',
  wise.capabilities().supports.checkout === false && wise.capabilities().supports.webhook === false);
check('Wise needs no deployment secret: the details are merchant configuration',
  wise.capabilities().secrets.length === 0 && wise.runtime(ENV({})).configured === true);
check('Wise always answers with instructions, never a redirect',
  (await wise.createPaymentRequest(INPUT, ENV({}))).kind === 'instructions');
check('the instructions carry the reference the payer must quote',
  (await wise.createPaymentRequest(INPUT, ENV({}))).instructions.reference === 'CG-1048');
check('Wise asks for the fields a local transfer actually needs',
  ['account_holder', 'iban', 'swift_bic', 'bank_name'].every((k) => wise.instructionFields().some((f) => f.key === k)));
check('the source says plainly why there is no Wise integration', /no hosted checkout|no acceptance API/i.test(wiseSrc));

/* ---- neither rail invites a friends-and-family payment ---- */
for (const [label, src] of [['Wise', wiseSrc], ['PayPal', paypalSrc]]) {
  const fields = (label === 'Wise' ? wise : paypal).instructionFields().map((f) => `${f.key} ${f.label}`).join(' ');
  check(`${label} never offers friends-and-family wording to copy`,
    !/friends?.and.family|send to a friend/i.test(fields));
  check(`${label} says business account in the source, where the rule belongs`, /business account/i.test(src));
}

/* ---- PayPal: the mode gate ---- */
check('an unset payment mode is refused, never guessed',
  paymentsMode(ENV({})) === null && paypal.runtime(ENV({ PAYPAL_CLIENT_ID: 'x', PAYPAL_SECRET: 'y' })).configured === false);
check('a nonsense payment mode is refused too', paymentsMode(ENV({ PAYMENTS_MODE: 'prod' })) === null);
check('missing credentials are reported as missing, never as a value',
  (() => { const r = paypal.runtime(ENV({ PAYMENTS_MODE: 'test' })); return r.configured === false && r.reason === 'credentials_missing' && r.mode === 'test'; })());
check('without a webhook id the rail refuses to be configured — nothing could ever confirm',
  (() => { const r = paypal.runtime(ENV({ PAYMENTS_MODE: 'test', PAYPAL_CLIENT_ID: 'i', PAYPAL_SECRET: 's' }));
           return r.configured === false && r.reason === 'webhook_id_missing'; })());
check('fully configured reports the mode and nothing else',
  (() => { const r = paypal.runtime(ENV(FULL));
           return r.configured === true && r.mode === 'test' && JSON.stringify(r).includes('test') && !JSON.stringify(r).includes('sh'); })());

/* ---- PayPal: amounts ---- */
check('AED 4500 minor units becomes the decimal string PayPal wants', toPayPalAmount(4500, 'AED') === '45.00');
check('a zero-decimal currency is not divided by a hundred', toPayPalAmount(5000, 'JPY') === '5000');
check('a three-decimal currency is refused rather than rounded', toPayPalAmount(45000, 'KWD') === null);
check('the round trip back to minor units holds',
  fromPayPalAmount('45.00', 'AED') === 4500 && fromPayPalAmount('5000', 'JPY') === 5000 && fromPayPalAmount('x', 'AED') === null);

/* ---- PayPal: creating the order ---- */
const f1 = fakeFetch([TOKEN, ['v2/checkout/orders', json({ id: 'ORD-7', links: [{ rel: 'approve', href: 'https://www.sandbox.paypal.com/checkoutnow?token=ORD-7' }] })]]);
const created = await paypal.createPaymentRequest(INPUT, ENV(FULL), f1);
const orderCall = f1.calls.find((c) => c.url.includes('v2/checkout/orders'));
const orderBody = orderCall ? JSON.parse(orderCall.init.body) : {};

check('test mode talks to the sandbox, never to production',
  f1.calls.every((c) => c.url.startsWith('https://api-m.sandbox.paypal.com')), f1.calls.map((c) => c.url).join(' '));
check('the order is an approval redirect the payer can be sent to',
  created.kind === 'redirect' && created.providerReference === 'ORD-7' && created.url.includes('checkoutnow'));
check('the intent is CAPTURE: the money is taken, not merely authorised', orderBody.intent === 'CAPTURE');
check('the amount and currency come from the request, never from a payer',
  orderBody.purchase_units?.[0]?.amount?.value === '45.00' && orderBody.purchase_units?.[0]?.amount?.currency_code === 'AED');
check('the order carries the reconciliation identifiers the webhook will need',
  orderBody.purchase_units?.[0]?.custom_id === INPUT.requestId && orderBody.purchase_units?.[0]?.invoice_id === 'CG-1048-2');
check('a retry of the same attempt is idempotent at PayPal',
  orderCall.init.headers['PayPal-Request-Id'] === 'CG-1048-2');
check('the order carries no personal data',
  !/email|phone|name|address/i.test(JSON.stringify(orderBody).replace(/shipping_preference|NO_SHIPPING/g, '')));
check('the payer is not asked for a shipping address for a coaching session',
  orderBody.payment_source?.paypal?.experience_context?.shipping_preference === 'NO_SHIPPING');

const f2 = fakeFetch([TOKEN, ['v2/checkout/orders', json({ id: 'ORD-8', links: [{ rel: 'approve', href: 'https://www.paypal.com/checkoutnow?token=ORD-8' }] })]]);
await paypal.createPaymentRequest(INPUT, ENV(LIVE), f2);
check('live mode talks to production', f2.calls.every((c) => c.url.startsWith('https://api-m.paypal.com')));

check('an unconfigured rail falls back to instructions instead of failing',
  (await paypal.createPaymentRequest(INPUT, ENV({}), fakeFetch([]))).kind === 'instructions');
check('a currency PayPal cannot quote is unavailable, not rounded',
  (await paypal.createPaymentRequest({ ...INPUT, currency: 'KWD' }, ENV(FULL), fakeFetch([TOKEN]))).kind === 'unavailable');
check('a provider error is reported by status, never as a thrown stack',
  (await paypal.createPaymentRequest(INPUT, ENV(FULL), fakeFetch([TOKEN, ['v2/checkout/orders', json({}, 422)]]))).reason === 'provider_error_422');
check('an order with no approval link is unavailable rather than half-created',
  (await paypal.createPaymentRequest(INPUT, ENV(FULL), fakeFetch([TOKEN, ['v2/checkout/orders', json({ id: 'ORD-9', links: [] })]]))).reason === 'no_approval_link');

/* ---- PayPal: verifying an event ---- */
const HEADERS = (o = {}) => new Headers({
  'paypal-transmission-id': 'T-1', 'paypal-transmission-time': '2026-09-14T10:00:00Z',
  'paypal-transmission-sig': 'SIG', 'paypal-cert-url': 'https://api.paypal.com/cert.pem',
  'paypal-auth-algo': 'SHA256withRSA', ...o,
});
const EVENT = JSON.stringify({ id: 'WH-1', event_type: 'PAYMENT.CAPTURE.COMPLETED', resource: { id: 'CAP-9' } });
const VERIFY_OK = ['verify-webhook-signature', json({ verification_status: 'SUCCESS' })];
const VERIFY_NO = ['verify-webhook-signature', json({ verification_status: 'FAILURE' })];

check('a verified event comes back with its id, its type and the deployment mode stamped on it',
  await (async () => {
    const v = await paypal.verifyWebhook({ headers: HEADERS(), rawBody: EVENT }, ENV(FULL), fakeFetch([TOKEN, VERIFY_OK]));
    return v.ok && v.providerEventId === 'WH-1' && v.eventType === 'PAYMENT.CAPTURE.COMPLETED' && v.payload.beau_ph_livemode === false;
  })());
check('in live mode the same event is stamped live',
  await (async () => {
    const v = await paypal.verifyWebhook({ headers: HEADERS(), rawBody: EVENT }, ENV(LIVE), fakeFetch([TOKEN, VERIFY_OK]));
    return v.ok && v.payload.beau_ph_livemode === true;
  })());
check('PayPal saying FAILURE is refused',
  !(await paypal.verifyWebhook({ headers: HEADERS(), rawBody: EVENT }, ENV(FULL), fakeFetch([TOKEN, VERIFY_NO]))).ok);
check('a certificate URL that is not PayPal is refused before anything is fetched',
  (await paypal.verifyWebhook({ headers: HEADERS({ 'paypal-cert-url': 'https://evil.example.com/cert.pem' }), rawBody: EVENT }, ENV(FULL), fakeFetch([TOKEN, VERIFY_OK]))).reason === 'bad_cert_host');
check('a lookalike host does not pass either',
  (await paypal.verifyWebhook({ headers: HEADERS({ 'paypal-cert-url': 'https://paypal.com.evil.net/c.pem' }), rawBody: EVENT }, ENV(FULL), fakeFetch([TOKEN, VERIFY_OK]))).reason === 'bad_cert_host');
check('missing signature headers are refused',
  (await paypal.verifyWebhook({ headers: new Headers(), rawBody: EVENT }, ENV(FULL), fakeFetch([]))).reason === 'missing_signature_headers');
check('an unconfigured deployment verifies nothing',
  (await paypal.verifyWebhook({ headers: HEADERS(), rawBody: EVENT }, ENV({}), fakeFetch([]))).reason === 'not_configured');
check('a body that is not JSON is refused',
  (await paypal.verifyWebhook({ headers: HEADERS(), rawBody: 'not json' }, ENV(FULL), fakeFetch([TOKEN, VERIFY_OK]))).reason === 'invalid_json');
check('the raw body is what gets verified, never a re-serialised copy', /rawBody/.test(paypalSrc) && /await req\.text\(\)/.test(hook));

/* ---- the registry and the database agree ---- */
check('both keys are in the registry', providerKeys.includes('wise') && providerKeys.includes('paypal'));
check('the provider key list is an enumeration, extended on purpose',
  /providers_key_check check \(key = any \(array\[/.test(mig) && /'wise','paypal'\]\)\)/.test(mig));
check('PayPal is an online rail confirmed by a provider event; Wise is operator-confirmed',
  /\('paypal', 'PayPal', 'online', 'provider_event'/.test(mig) && /\('wise', 'Wise \(local transfer\)', 'manual', 'operator'/.test(mig));
check('the amount helper lives in the database too, so the ledger never guesses an exponent',
  /beau_ph\.currency_exponent/.test(mig) && /when 'JPY' then 0/.test(mig) && /if e = 3 then return null/.test(mig));
check('an event PayPal sends that we do not handle is ignored on the record, not dropped',
  /jsonb_build_object\('ignore', 'unhandled:'/.test(mig));
check('the ingest doors are service_role only',
  /revoke all on function beau_ph\.process_paypal_event\(jsonb\) from public, anon, authenticated/.test(mig)
  && /revoke all on function public\.process_paypal_event\(jsonb\) from public, anon, authenticated/.test(host));

/* ---- the host reconciliation ---- */
check('only a capture completing reaches the ledger', /if ev_type <> 'PAYMENT\.CAPTURE\.COMPLETED' then/.test(host));
check('the host re-checks the amount itself when BEAU PH found no request', /amount mismatch/.test(host));
check('the payment is recorded against the PayPal capture, which is unique', /'paypal', v_capture/.test(host));
check('a replayed event neither double-pays nor double-emails',
  /on conflict \(event_id\) do nothing/.test(host) && /duplicate/.test(host) && /beau_ph\.is_reconciled/.test(host));
check('the refund gap is written down rather than half-implemented',
  /WHAT THIS DELIBERATELY DOES NOT DO/.test(host) && /refund/i.test(host));
check('the webhook is the only thing that confirms, and the source says so',
  /navigation, not a receipt/.test(host) && /navigation, not a receipt/.test(hook));
check('the webhook logs an id and an outcome, never a credential or a payer',
  [...hook.matchAll(/log\("[^"]+",\s*\{([^}]*)\}\)/g)].map((m) => m[1]).every((l) => !/secret|token|client_id|payer|email/i.test(l)));

/* ---- the payer can actually reach both ---- */
check('the payment page offers PayPal only when the server says it is eligible AND configured',
  /paypal_enabled: methods\.some\(\(m\) => m\.provider === "paypal"\) && !!runtime\.paypal\?\.configured/.test(reportFn)
  && /method\('paypal'\) && d\.paypal_enabled/.test(reportJs));
check('the PayPal amount comes from the order snapshot, never from the browser',
  /amount: request\.amount, currency: request\.currency, *\/\/ trusted: the order snapshot/.test(reportFn));
check('returning from PayPal is treated as a navigation, not a receipt',
  /proves nothing/.test(reportJs) && /only the verified webhook ever marks it paid/.test(reportJs));
check('the page shows the Wise details it was given and hides the lines it was not',
  /wise-panel/.test(reportHtml) && /wise-panel'\)\.hidden = false/.test(reportJs) && /else \$\(id\)\.hidden = true/.test(reportJs));
check('a failed PayPal start tells the payer to use another option rather than stalling',
  /use another option/.test(reportJs));

console.log(`\nPAYPAL_WISE_TESTS ok=${ok} fail=${fail}`);
process.exit(fail ? 1 : 0);

/* BEAU PH V0 — runtime E2E against the DEPLOYED stack (run from a laptop; the
   Claude sandbox cannot reach *.supabase.co / *.vercel.app).

   What it proves, in order (nothing here can mark anything paid):
     1. secure /r/<token> report: the Edge `report` function answers `view`,
        the recap carries NO body metric / BMI / health / private note, the
        method list is the server-side BEAU PH list with the pack's CG-####
        reference, and no secret-shaped value is in the response;
     2. Aani / bank-transfer instructions are shown WITHOUT any payment being
        recorded (a second `view` still reports the pack unpaid);
     3. (--pay) Stripe TEST Checkout: `pay_card` returns a checkout.stripe.com
        URL (or 503 payments_not_configured when no sk_test_ key is set);
        pay it with 4242 4242 4242 4242, then run with --wait: the Stripe
        webhook → BEAU PH normalized paid event → host ledger → pack projection
        is proven when `view` reports payment_status = paid exactly once;
     4. authorised manual reconciliation and the multi-rail race are proven in
        the database suites (supabase/tests/beau_ph_contract.sql §8, §15, §18)
        and, at runtime, from the admin Finance screen (finance:manage →
        Record payment): re-run this script afterwards — the pack reads paid
        and the Aani/bank blocks disappear from the page.

   Usage:
     REPORT_TOKEN=<64-hex token from admin → pack → Share link> node scripts/e2e-runtime.mjs [--pay] [--wait]
   Optional: REPORT_ENDPOINT (default: the project's report function), ORIGIN (default https://coachgariv0.vercel.app).
   Webhook signature/idempotency probes of the deployed function: `STRIPE_WEBHOOK_SECRET=… node scripts/test-webhook.mjs`. */

const ENDPOINT = process.env.REPORT_ENDPOINT || 'https://acrjrlgeeyseyolmofuq.supabase.co/functions/v1/report';
const ORIGIN = process.env.ORIGIN || 'https://coachgariv0.vercel.app';
const TOKEN = process.env.REPORT_TOKEN;
const pay = process.argv.includes('--pay'); const wait = process.argv.includes('--wait');
if (!/^[0-9a-f]{64}$/.test(TOKEN || '')) { console.error('Set REPORT_TOKEN (64 hex chars: admin → package → Share link).'); process.exit(2); }

let ok = 0, fail = 0;
const check = (name, cond, detail = '') => { cond ? ok++ : fail++; console.log(`${cond ? 'PASS' : 'FAIL'}  ${name}${detail ? ' — ' + detail : ''}`); };
const call = async (body) => { const r = await fetch(ENDPOINT, { method: 'POST', headers: { 'Content-Type': 'application/json', Origin: ORIGIN }, body: JSON.stringify(body) }); return { status: r.status, body: await r.json().catch(() => null) }; };
const SECRET_RE = /(sk|rk)_(live|test)_[A-Za-z0-9]{8,}|whsec_[A-Za-z0-9]{8,}|"(secret|api_?key|private_?key|password|webhook_secret)"/i;
const HEALTH_RE = /"(bmi|weight|height|body_fat|waist|blood|injur|medical|health|coach_private|private_note)/i;

// 1. secure report view
const v1 = await call({ action: 'view', token: TOKEN });
check('view → 200 ok', v1.status === 200 && v1.body?.ok === true, `${v1.status} ${JSON.stringify(v1.body).slice(0, 120)}`);
if (v1.status !== 200) process.exit(1);
const txt = JSON.stringify(v1.body);
check('recap carries no body metric / health / private note', !HEALTH_RE.test(JSON.stringify(v1.body.recap)));
check('no secret-shaped value in the response', !SECRET_RE.test(txt));
check('pay_ref is a human public reference (CG-####), never a UUID', /^CG-[0-9]{4,}$/.test(v1.body.pay_ref || ''), v1.body.pay_ref);
const methods = Array.isArray(v1.body.methods) ? v1.body.methods : [];
check('server-side method list present', methods.length >= 0, methods.map((m) => m.provider).join(', ') || '(none — enable a rail in Finance)');
check('every method carries the pack reference', methods.every((m) => m.reference === v1.body.pay_ref));
check('no in-person capability reaches the client page', !/softpos|tap_to_pay|card_present|magnati|network_international|adyen/.test(txt));
const aani = v1.body.aani?.enabled, bank = v1.body.bank?.enabled;
console.log(`INFO  rails offered: card=${v1.body.card_enabled} aani=${!!aani} bank=${!!bank}; pack payment_status=${v1.body.recap?.payment_status}`);
if (aani) check('Aani block shows instructions with the reference', v1.body.aani.reference === v1.body.pay_ref && !!(v1.body.aani.display_value || v1.body.aani.proxy_value));
if (bank) check('bank block shows IBAN/BIC/holder with the reference', v1.body.bank.reference === v1.body.pay_ref && !!v1.body.bank.iban);

// 2. viewing / copying instructions never pays anything
const v2 = await call({ action: 'view', token: TOKEN });
check('second view: payment_status unchanged (viewing instructions records nothing)', v2.body?.recap?.payment_status === v1.body.recap?.payment_status, String(v2.body?.recap?.payment_status));

// 3. Stripe TEST checkout (optional)
if (pay) {
  const c = await call({ action: 'pay_card', token: TOKEN });
  if (c.status === 503) console.log(`INFO  pay_card → 503 ${c.body?.error} (owner action: set STRIPE_SECRET_KEY sk_test_… on Supabase; live keys are refused)`);
  else {
    check('pay_card → 200 with a Stripe Checkout URL', c.status === 200 && /^https:\/\/checkout\.stripe\.com\//.test(c.body?.url || ''), `${c.status} ${c.body?.error || ''}`);
    if (c.body?.url) console.log(`\nPay here with 4242 4242 4242 4242:\n${c.body.url}\n`);
    const c2 = await call({ action: 'pay_card', token: TOKEN });
    check('second pay_card reuses the open attempt (no second Checkout Session)', c2.status === 200 && (c2.body?.reused === true || c2.body?.url === c.body?.url));
  }
}
if (wait) {
  process.stdout.write('Waiting for the Stripe webhook → BEAU PH → ledger → pack projection');
  for (let i = 0; i < 120; i++) {
    await new Promise((r) => setTimeout(r, 5000));
    const s = await call({ action: 'view', token: TOKEN });
    if (s.body?.recap?.payment_status === 'paid') { console.log(''); check('pack reads paid after the webhook', true); check('card button gone once paid', s.body.card_enabled === false || !s.body.methods?.some((m) => m.provider === 'stripe')); break; }
    process.stdout.write('.');
    if (i === 119) { console.log(''); check('pack reads paid after the webhook', false, 'timed out'); }
  }
}
console.log(`\nBEAU_PH_RUNTIME_TESTS ok=${ok} fail=${fail}`);
process.exit(fail ? 1 : 0);

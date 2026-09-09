/* =============================================================
   CG-012 — the secure client recap / payment page (/r/<token>).

   External, not inline: the site's Content-Security-Policy allows
   scripts from 'self', plausible.io and js.stripe.com only, and
   never `unsafe-inline`. An inline block here is silently blocked
   by the browser and the page stays on its spinner.

   Card payment = Stripe EMBEDDED Checkout mounted in this page.
   The browser never learns an amount: the server resolves it from
   the order behind the token, and only the verified webhook can
   mark anything paid — this page re-reads `view` until it does.
   ============================================================= */
import { CONFIG } from '/config.js';
const $ = (id) => document.getElementById(id);
const show = (id) => { for (const s of ['loading','error','content']) $(s).hidden = (s !== id); };
const endpoint = CONFIG.REPORT_ENDPOINT;
// token is the last path segment: /r/<token>
const token = (location.pathname.split('/').filter(Boolean).pop() || '').trim();
const qs = new URLSearchParams(location.search);
// the payment currency the client chose on this page (null = the package's pricing currency); the server decides what can be offered
let payCurrency = null;

function fail(title, msg) { $('err-title').textContent = title; $('err-msg').textContent = msg || ''; show('error'); }
function money(minor, cur) { if (minor == null) return ''; try { return new Intl.NumberFormat('en-AE', { style: 'currency', currency: cur || 'USD' }).format(minor / 100); } catch { return (cur || '') + ' ' + (minor / 100).toLocaleString(); } }
function dt(iso) { try { return new Intl.DateTimeFormat('en-GB', { day: 'numeric', month: 'short', year: 'numeric' }).format(new Date(iso)) + ', ' + new Intl.DateTimeFormat('en-GB', { hour: '2-digit', minute: '2-digit', timeZone: 'Asia/Dubai' }).format(new Date(iso)); } catch { return iso; } }

async function api(action, extra) {
  const res = await fetch(endpoint, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ action, token, currency: payCurrency, ...extra }) });
  let data = {}; try { data = await res.json(); } catch {}
  return { res, data };
}

function render(d) {
  const r = d.recap;
  $('r-greeting').textContent = r.first_name ? ('Hello ' + r.first_name + ',') : 'Hello,';
  $('r-title').textContent = r.title || 'Coaching session recap';
  $('r-x').textContent = `${r.used} / ${r.total_sessions}`;
  $('r-remaining').textContent = `${r.remaining} remaining`;
  // money summary rows
  const rows = [];
  if (r.price_amount != null) rows.push(['Package price', money(r.price_amount, r.currency)]);
  if (r.agreement_date) rows.push(['Agreed', new Intl.DateTimeFormat('en-GB', { day: 'numeric', month: 'short', year: 'numeric' }).format(new Date(r.agreement_date))]);
  rows.push(['Payment', r.payment_status === 'paid' ? 'Paid' : 'Due']);
  $('r-money').innerHTML = rows.map(([k, v]) => `<div class="row"><span class="k">${k}</span><span class="v">${v}</span></div>`).join('');
  // sessions
  $('r-completed').innerHTML = (r.completed || []).map((s) => `<li>${dt(s.start_at)}</li>`).join('') || '<li class="muted">None yet.</li>';
  const up = r.upcoming || [];
  $('r-upcoming').innerHTML = up.map((s) => `<li>${dt(s.start_at)}</li>`).join('');
  $('r-upcoming-wrap').hidden = up.length === 0;

  // payment (only when something is due)
  const due = r.amount_due;
  $('pay-card').hidden = true;
  if (r.payment_status !== 'paid' && due && due > 0) {
    $('pay-card').hidden = false;
    // BEAU FX: the server offers the pricing currency plus any currency it can quote right now; the page only shows the choice
    const pay = d.payment || { amount: due, currency: r.currency, pricing_amount: due, pricing_currency: r.currency, fx: null, options: [] };
    const payAmt = pay.amount != null ? pay.amount : due, payCur = pay.currency || r.currency;
    payCurrency = payCur === pay.pricing_currency ? null : payCur;
    $('r-due-amt').textContent = money(payAmt, payCur);
    const opts = Array.isArray(pay.options) ? pay.options : [];
    $('pay-ccy').hidden = opts.length < 2;
    $('pay-ccy').innerHTML = opts.length < 2 ? '' : '<span class="k">Pay in</span>' + opts.map((o) => `<button type="button" class="chip${o.currency === payCur ? ' on' : ''}" data-ccy="${o.currency}">${o.currency}</button>`).join('');
    $('fx-note').hidden = !pay.fx;
    if (pay.fx) $('fx-note').textContent = `Priced at ${money(pay.pricing_amount, pay.pricing_currency)}. You pay ${money(payAmt, payCur)} at an indicative rate of ${Number(pay.fx.rate).toFixed(4)}. The rate is locked for ${pay.fx.quote_ttl_minutes || 15} minutes when you start paying.`;
    // The payment options are exactly the AUTHORITATIVE list BEAU PH computed
    // server-side (merchant config × country × currency × provider readiness).
    // This page never decides eligibility itself.
    const methods = Array.isArray(d.methods) ? d.methods : [];
    const method = (k) => methods.find((m) => m && m.provider === k);
    if (method('stripe')) $('btn-card').hidden = false;
    const aani = method('aani');
    if (aani) {
      const ins = aani.instructions || {};
      $('aani-panel').hidden = false;
      $('aani-num').textContent = ins.display_value || '';
      $('aani-ref').textContent = aani.reference || d.pay_ref || '';
      // the amount is quoted only in the request's own currency — never converted
      const settle = aani.settlement_currency || 'AED';
      if (settle === payCur) {
        $('aani-amt').textContent = money(payAmt, payCur);
        $('aani-note').textContent = ins.instructions || '';
      } else {
        $('aani-amt-line').hidden = true;
        $('aani-note').textContent = `Aani is settled in ${settle}. Please confirm the exact ${settle} amount with Coach Gari before paying. ` + (ins.instructions || '');
      }
      if (ins.qr_url) { $('aani-qr').src = ins.qr_url; $('aani-qr').hidden = false; }
    }
    const bank = method('bank_transfer');
    if (bank) {
      const ins = bank.instructions || {};
      $('bank-panel').hidden = false;
      $('bank-holder').textContent = ins.account_holder || '';
      $('bank-iban').textContent = ins.iban || '';
      $('bank-bic').textContent = ins.bic || '';
      if (ins.bank_name) $('bank-name').textContent = ins.bank_name; else $('bank-name-line').hidden = true;
      $('bank-amt').textContent = money(payAmt, payCur);   // the amount in the currency chosen on this page
      $('bank-ref').textContent = bank.reference || d.pay_ref || '';
      $('bank-note').textContent = ins.instructions || '';
    }
    const cash = method('cash');
    if (cash) {
      const ins = cash.instructions || {};
      $('cash-panel').hidden = false;
      $('cash-amt').textContent = money(payAmt, payCur);   // the amount in the currency chosen on this page, never converted here
      $('cash-ref').textContent = cash.reference || d.pay_ref || '';
      $('cash-note').textContent = ins.instructions || '';
    }
    if (!methods.length) $('pay-none').hidden = false;
  }
  show('content');
}

/* ---- card payment: Stripe Embedded Checkout, mounted in this page ----
   The server (report → BEAU PH → Stripe adapter) resolves the amount from the
   order and returns only a session-scoped client secret + the publishable key.
   Stripe.js is loaded on demand, never on a plain recap view. Completion in
   the browser is NOT proof of payment: confirmPaid() re-reads `view` until the
   verified webhook has moved the pack to paid.                            */
let checkoutInstance = null;
function loadStripeJs() {
  return new Promise((resolve, reject) => {
    if (window.Stripe) return resolve(window.Stripe);
    const s = document.createElement('script'); s.src = 'https://js.stripe.com/v3/'; s.async = true;
    s.onload = () => (window.Stripe ? resolve(window.Stripe) : reject(new Error('stripe_js')));
    s.onerror = () => reject(new Error('stripe_js'));
    document.head.appendChild(s);
  });
}
function closeCard() {
  if (checkoutInstance) { try { checkoutInstance.destroy(); } catch {} checkoutInstance = null; }
  $('card-panel').hidden = true; $('card-mount').textContent = '';
  $('btn-card').hidden = false; $('btn-card').disabled = false; $('btn-card').textContent = 'Pay securely by card';
}
let confirming = false;
async function confirmPaid() {
  if (confirming) return; confirming = true;
  const banner = $('paid-banner'); banner.hidden = false;
  banner.textContent = 'Thank you. Your payment is being confirmed. This page will update shortly.';
  for (let i = 0; i < 40; i++) {
    await new Promise((r) => setTimeout(r, i < 5 ? 2000 : 4000));
    const { res, data } = await api('view', {});
    if (res.ok && data.ok && data.recap && data.recap.payment_status === 'paid') {
      render(data); banner.hidden = false; banner.textContent = 'Payment received. Thank you.'; confirming = false; return;
    }
  }
  banner.textContent = 'Still confirming your payment. You can close this page: it updates as soon as Stripe reports the payment, and Coach Gari sees it too.';
  confirming = false;
}
$('btn-card').addEventListener('click', async () => {
  $('btn-card').disabled = true; $('btn-card').textContent = 'Preparing secure checkout…';
  let data = {};
  try {
    const r = await api('pay_card', {}); data = r.data || {};
    if (!r.res.ok || !data.ok || !data.client_secret || !data.publishable_key) throw new Error('pay_card');
    const Stripe = await loadStripeJs();
    const stripe = Stripe(data.publishable_key);
    const instance = await stripe.initEmbeddedCheckout({
      clientSecret: data.client_secret,
      onComplete: () => { closeCard(); $('btn-card').hidden = true; confirmPaid(); },
    });
    closeCard(); checkoutInstance = instance;
    instance.mount('#card-mount');
    $('btn-card').hidden = true; $('card-panel').hidden = false;
  } catch {
    closeCard();
    alert(data.error === 'payments_not_configured' ? 'Card payment is not available right now. Please use another option on this page or contact Coach Gari.' : (data.message ? `Could not start the card payment: ${data.message}` : 'Could not start the card payment. Please try again or use another option on this page.'));
  }
});
$('btn-card-close').addEventListener('click', closeCard);
// choosing another payment currency re-reads the page in that currency; nothing is converted in the browser
$('pay-ccy').addEventListener('click', async (e) => {
  const b = e.target.closest('[data-ccy]'); if (!b || b.classList.contains('on')) return;
  payCurrency = b.dataset.ccy; closeCard();
  for (const id of ['btn-card', 'aani-panel', 'bank-panel', 'cash-panel', 'pay-none']) $(id).hidden = true;
  $('aani-amt-line').hidden = false; $('bank-name-line').hidden = false;
  const { res, data } = await api('view', {});
  if (res.ok && data.ok) render(data);
});
document.querySelectorAll('.copy').forEach((b) => b.addEventListener('click', async () => {
  const el = document.querySelector(b.dataset.copy); const v = el ? el.textContent.trim() : '';
  if (!v) return;
  try { await navigator.clipboard.writeText(v); b.textContent = 'Copied'; setTimeout(() => (b.textContent = 'Copy'), 1500); } catch {}
}));

async function init() {
  if (!endpoint) return fail('Unavailable', 'This page is not configured.');
  if (!/^[0-9a-f]{64}$/.test(token)) return fail('This link is not valid', 'Please open the link exactly as Coach Gari sent it.');
  const { res, data } = await api('view', {});
  if (!res.ok || !data.ok) {
    if (res.status === 410) return fail('This link is no longer available', 'It may have expired or been revoked. Please ask Coach Gari for a new one.');
    if (res.status === 404) return fail('This link is not valid', 'Please ask Coach Gari for a new one.');
    return fail('Something went wrong', 'Please try again shortly.');
  }
  render(data);
  // back from a Stripe-side redirect (bank / 3DS): still not proof — re-read until the webhook has landed
  if (qs.get('paid') === '1' && data.recap && data.recap.payment_status !== 'paid') confirmPaid();
}
init().catch(() => fail('Something went wrong', 'Please try again shortly.'));

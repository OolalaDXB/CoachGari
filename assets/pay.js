/* A payment link the coach issued.

   This lives in its own file rather than inside pay.html because the site's
   Content-Security-Policy is `script-src 'self'` with no 'unsafe-inline': an
   inline module is silently refused by the browser, and the page then sits on
   whatever its markup said last — which is exactly how the first real link
   looked, frozen on "Opening your payment…". Every other page here loads an
   external module for the same reason.

   The page reads its reference and token from
   the path (/pay/<reference>/<token>) and asks the server what this link is.
   It never proposes an amount: the amount is on the row the coach wrote, and
   the server builds the Checkout Session from that row. The token is a key to
   this one link — it proves no identity and opens nothing else. */
import { CONFIG } from '/config.js';

const ENDPOINT = (CONFIG.PAYLINK_ENDPOINT || '').trim();
const head = document.getElementById('head');
const mount = document.getElementById('mount');
const statusEl = document.getElementById('status');
const say = (t, err) => { statusEl.textContent = t || ''; statusEl.classList.toggle('err', !!err); };
const esc = (s) => String(s ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
const money = (minor, cur) => {
  try { return new Intl.NumberFormat(undefined, { style: 'currency', currency: cur }).format(minor / 100); }
  catch { return `${cur} ${(minor / 100).toFixed(2)}`; }
};

const parts = location.pathname.split('/').filter(Boolean);   // ['pay', reference, token]
const reference = parts[1] || '';
const token = parts[2] || '';
const q = new URLSearchParams(location.search);

function loadStripeJs() {
  if (window.Stripe) return Promise.resolve(window.Stripe);
  return new Promise((resolve, reject) => {
    const s = document.createElement('script');
    s.src = 'https://js.stripe.com/v3/'; s.onload = () => resolve(window.Stripe);
    s.onerror = () => reject(new Error('stripe_js'));
    document.head.appendChild(s);
  });
}
const api = (body) => fetch(ENDPOINT, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body) })
  .then((r) => r.json().then((j) => ({ status: r.status, body: j })));

function showHead(label, amount, currency, badge, badgeClass) {
  head.innerHTML = `<span class="state ${badgeClass || ''}">${esc(badge)}</span>
    <h1 style="margin-top:10px">${esc(label || 'Payment')}</h1>
    ${amount != null ? `<div class="amount">${esc(money(amount, currency))}</div>` : ''}
    <div class="ref">${esc(reference)}</div>`;
}

async function start() {
  if (!ENDPOINT) { head.innerHTML = '<p class="err">This page is not connected yet.</p>'; return; }
  if (!/^PL-[A-Z0-9]{6}$/.test(reference) || !/^[0-9a-f]{64}$/.test(token)) {
    head.innerHTML = '<h1>Link not recognised</h1><p class="muted">Check the link Coach Gari sent you, or ask him for a new one.</p>';
    return;
  }

  /* Back from Stripe. The redirect is not proof of anything — only the verified
     webhook moves a link to paid — so the page asks the server and shows what it
     says, which may still be pending for a moment. */
  if (q.get('paid')) {
    say('Confirming your payment…');
    const res = await api({ action: 'state', reference, token });
    const l = res.body?.link || {};
    if (l.state === 'paid') { showHead(l.label, l.amount, l.currency, 'Paid', 'ok'); say('Thank you — Coach Gari has been notified.'); return; }
    showHead(l.label, l.amount, l.currency, 'Processing', '');
    say('Your bank has taken the payment. It can take a few seconds to show as paid here.');
    return;
  }

  say('Loading…');
  const res = await api({ action: 'open', reference, token });
  say('');

  if (res.status === 404) { head.innerHTML = '<h1>Link not recognised</h1><p class="muted">Ask Coach Gari for a new one.</p>'; return; }
  if (res.status === 503) { head.innerHTML = '<h1>Payments are not available</h1><p class="muted">Please message Coach Gari.</p>'; return; }
  if (!res.body?.ok) { head.innerHTML = '<h1>Something went wrong</h1><p class="muted">Please message Coach Gari.</p>'; return; }

  const b = res.body;
  if (b.state === 'paid')    { showHead(b.label, b.amount, b.currency, 'Paid', 'ok'); say('This link has already been paid.'); return; }
  if (b.state === 'expired') { showHead(b.label, b.amount, b.currency, 'Expired', 'off'); say('This link has expired. Ask Coach Gari for a new one.'); return; }
  if (b.state === 'closed')  { showHead(b.label, null, null, 'Withdrawn', 'off'); say('This link is no longer active.'); return; }

  showHead(b.label, b.amount, b.currency, 'To pay', '');
  if (q.get('cancelled')) say('Payment cancelled — you can try again below.');
  try {
    const Stripe = await loadStripeJs();
    const instance = await Stripe(b.publishable_key).initEmbeddedCheckout({
      clientSecret: b.client_secret,
      onComplete: async () => {
        try { instance.destroy(); } catch {}
        mount.textContent = '';
        const st = await api({ action: 'state', reference, token });
        const l = st.body?.link || {};
        showHead(b.label, b.amount, b.currency, l.state === 'paid' ? 'Paid' : 'Processing', l.state === 'paid' ? 'ok' : '');
        say(l.state === 'paid' ? 'Thank you — Coach Gari has been notified.' : 'Payment received. It can take a few seconds to show as paid here.');
      },
    });
    instance.mount('#mount');
  } catch {
    say('The card form could not load. Please message Coach Gari.', true);
  }
}
/* A failure has to SAY something. The first version let a rejected fetch escape
   as an unhandled rejection, and the page kept its loading text for ever — a
   payer reading "Opening your payment…" has no way to tell a slow network from a
   dead page, and will not try again. */
start().catch(() => {
  head.innerHTML = '<h1>This page could not load</h1><p class="muted">Check your connection and reload. If it keeps happening, message Coach Gari and he will send a new link.</p>';
  say('');
});

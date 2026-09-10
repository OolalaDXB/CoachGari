/* Coach Gari — private collaboration room (/c/<token>).
   Reads the token from the path, shows the current proposal, considerations
   (monetary and non-cash kept separate), history and payment. Accept / counter /
   decline and card payment go through CONFIG.COLLAB_ENDPOINT. Card = Stripe
   Embedded Checkout; only the verified webhook marks a payment paid. */
import { CONFIG } from '/config.js';

const $ = (id) => document.getElementById(id);
const token = (location.pathname.split('/').filter(Boolean).pop() || '').trim();
const q = new URLSearchParams(location.search);
const esc = (s) => String(s == null ? '' : s).replace(/[&<>"]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]));
const money = (minor, cur) => { const n = Number(minor); if (!Number.isFinite(n) || !cur) return ''; try { return new Intl.NumberFormat('en-GB', { style: 'currency', currency: cur }).format(n / 100); } catch { return `${cur} ${(n / 100).toFixed(2)}`; } };
const TYPE = { brand_partnership: 'Brand partnership', sponsored_content: 'Sponsored content', event_appearance: 'Event appearance', corporate_activation: 'Corporate activation', padel_sport: 'Padel or sport collaboration', affiliate_ambassador: 'Affiliate or ambassador', product_collaboration: 'Product collaboration', other: 'Collaboration' };
const TERMS = [['deliverables', 'Deliverables'], ['timing', 'Timing'], ['usage_rights', 'Usage rights'], ['exclusivity', 'Exclusivity'], ['territory', 'Territory'], ['payment_terms', 'Payment terms'], ['additional', 'Additional terms']];

function fail(msg) { $('loading').hidden = true; $('content').hidden = true; const e = $('error'); e.hidden = false; e.textContent = msg; }

async function api(action, extra = {}) {
  const res = await fetch(CONFIG.COLLAB_ENDPOINT, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ action, token, ...extra }) });
  let data = {}; try { data = await res.json(); } catch { /* ignore */ }
  return { res, data };
}

let deal = null;

async function load() {
  if (!/^[0-9a-f]{64}$/.test(token)) return fail('This link is not valid.');
  const { res, data } = await api('room');
  if (res.status === 410) return fail('This collaboration link is no longer active.');
  if (res.status === 404 || !data || !data.ok) return fail('This link is not valid.');
  deal = data;
  render();
  $('loading').hidden = true; $('content').hidden = false;
  if (window.plausible) try { window.plausible('collaboration_proposal_viewed'); } catch { /* ignore */ }
}

function render() {
  const d = deal;
  $('ref').textContent = d.public_ref || '';
  const st = $('status'); st.textContent = (d.status || '').replace('_', ' '); st.className = 'cr-badge ' + (d.status || '');
  $('title').textContent = d.title || TYPE[d.collaboration_type] || 'Collaboration';
  const dates = d.proposed_date_from ? (d.proposed_date_from + (d.proposed_date_to && d.proposed_date_to !== d.proposed_date_from ? ' to ' + d.proposed_date_to : '')) : '';
  $('typeline').textContent = [TYPE[d.collaboration_type] || 'Collaboration', d.location, dates].filter(Boolean).join(' · ');
  $('request').textContent = d.initial_request || '';
  const meta = [];
  if (d.company) meta.push(['Company', d.company]);
  if (d.location) meta.push(['Location', d.location]);
  if (dates) meta.push(['Proposed dates', dates]);
  $('meta').innerHTML = meta.map(([k, v]) => `<tr><td>${esc(k)}</td><td>${esc(v)}</td></tr>`).join('');
  $('meta').hidden = !meta.length;

  renderProposal();
  renderPayment();
  renderHistory();
}

function renderProposal() {
  const d = deal, p = d.latest;
  const card = $('proposal-card');
  if (!p) { card.hidden = true; return; }
  card.hidden = false;
  $('proposal-legend').textContent = p.proposed_by === 'coach' ? `Proposal from Coach Gari (version ${p.version})` : `Your counter-offer (version ${p.version})`;
  $('prop-amt').textContent = p.monetary_amount != null ? money(p.monetary_amount, p.currency) : 'No cash component';
  $('prop-intro').textContent = p.intro || '';
  const nonCash = (p.considerations || []).filter((c) => c && c.type === 'non_cash');
  const monExtra = (p.considerations || []).filter((c) => c && c.type === 'monetary');
  let cons = '';
  if (monExtra.length) cons += `<div class="cr-by">Monetary</div><div class="cr-chips">${monExtra.map((c) => `<span class="cr-chip"><b>${esc(c.description || 'Fee')}</b>${c.amount != null && c.currency ? ' · ' + esc(money(c.amount, c.currency)) : ''}</span>`).join('')}</div>`;
  if (nonCash.length) cons += `<div class="cr-by" style="margin-top:10px">Non-cash consideration</div><div class="cr-chips">${nonCash.map((c) => `<span class="cr-chip">${esc(c.description || 'Item')}${c.estimated_value != null && c.estimated_value_currency ? ` <span style="color:var(--grey-text)">(est. ${esc(money(c.estimated_value, c.estimated_value_currency))})</span>` : ''}</span>`).join('')}</div>`;
  $('prop-considerations').innerHTML = cons;
  const terms = p.terms || {};
  $('prop-terms').innerHTML = TERMS.filter(([k]) => terms[k]).map(([k, l]) => `<tr><td>${esc(l)}</td><td style="white-space:pre-wrap">${esc(terms[k])}</td></tr>`).join('');
  const val = $('prop-validity');
  if (p.expires_at) { val.hidden = false; val.textContent = 'This proposal is valid until ' + new Date(p.expires_at).toLocaleDateString('en-GB', { day: 'numeric', month: 'long', year: 'numeric' }) + '.'; } else val.hidden = true;
  $('prop-actions').hidden = !d.can_counter;
}

function renderPayment() {
  const pays = deal.payments || [];
  const pending = pays.find((p) => (p.order_status || p.status) !== 'paid' && (p.status === 'requested' || p.status === 'checkout'));
  const paid = pays.find((p) => (p.order_status || p.status) === 'paid');
  const card = $('pay-card');
  if (!pending && !paid) { card.hidden = true; return; }
  card.hidden = false;
  const shown = paid || pending;
  $('pay-amt').textContent = money(shown.amount, shown.currency);
  $('pay-label').textContent = shown.label || 'Agreed collaboration payment';
  if (paid || q.get('paid') === '1') { $('pay-live').hidden = true; $('card-panel').hidden = true; $('pay-done').hidden = false; }
  else { $('pay-live').hidden = false; $('pay-done').hidden = true; }
}

function renderHistory() {
  const h = deal.history || [];
  $('history').innerHTML = h.map((v) => {
    const who = v.proposed_by === 'coach' ? 'Coach Gari' : 'Counterparty';
    const state = v.accepted_at ? ' · accepted' : v.declined_at ? ' · declined' : v.superseded_at ? ' · superseded' : '';
    return `<div class="cr-ver"><div class="cr-by">Version ${esc(v.version)} · ${esc(who)}${esc(state)}</div>
      <div style="margin-top:4px">${v.monetary_amount != null ? esc(money(v.monetary_amount, v.currency)) : 'No cash component'}${v.intro ? ' · ' + esc(v.intro) : ''}</div></div>`;
  }).join('') || '<p class="cr-sub">No versions yet.</p>';
}

/* ---- actions ---- */
$('content').addEventListener('click', async (e) => {
  const t = e.target;
  if (t.id === 'btn-accept') {
    t.disabled = true;
    const { res, data } = await api('accept', { version: deal.latest.version });
    if (res.status === 200 && data.ok) { if (window.plausible) try { window.plausible('collaboration_accepted'); } catch { /* ignore */ } load(); }
    else { t.disabled = false; alert(data.message || 'Could not accept. Please refresh and try again.'); }
  } else if (t.id === 'btn-counter') {
    $('counter-form').classList.remove('cr-hidden'); $('counter-form').scrollIntoView({ behavior: 'smooth' });
  } else if (t.id === 'co-cancel') {
    $('counter-form').classList.add('cr-hidden');
  } else if (t.id === 'btn-decline') {
    if (!confirm('Decline this collaboration? Coach Gari will be told.')) return;
    const { res, data } = await api('decline', {});
    if (res.status === 200 && data.ok) load(); else alert(data.message || 'Could not decline.');
  } else if (t.id === 'btn-pay') {
    startPayment();
  }
});

$('counter-form').addEventListener('submit', async (e) => {
  e.preventDefault();
  const f = e.target; const s = f.querySelector('.form-status');
  const amountRaw = f.amount.value.trim();
  const monetary = amountRaw ? Math.round(Number(amountRaw) * 100) : null;
  const noncash = f.noncash.value.trim();
  const considerations = noncash ? [{ type: 'non_cash', description: noncash.slice(0, 300) }] : [];
  s.textContent = 'Sending…';
  const { res, data } = await api('counter', { intro: f.intro.value.trim() || null, monetary_amount: Number.isFinite(monetary) ? monetary : null, currency: f.currency.value || null, considerations });
  if (res.status === 200 && data.ok) { $('counter-form').classList.add('cr-hidden'); load(); }
  else { s.textContent = data.message || 'Could not send. Please try again.'; s.className = 'form-status err'; }
});

/* ---- card payment: Stripe Embedded Checkout ---- */
let checkoutInstance = null;
function loadStripeJs() {
  return new Promise((resolve, reject) => {
    if (window.Stripe) return resolve(window.Stripe);
    const el = document.createElement('script'); el.src = 'https://js.stripe.com/v3/'; el.async = true;
    el.onload = () => (window.Stripe ? resolve(window.Stripe) : reject(new Error('stripe_js')));
    el.onerror = () => reject(new Error('stripe_js'));
    document.head.appendChild(el);
  });
}
async function startPayment() {
  const country = $('pay-country').value;
  const st = $('pay-status');
  if (!country) { st.textContent = 'Choose your country first.'; st.className = 'form-status err'; return; }
  const btn = $('btn-pay'); btn.disabled = true; btn.textContent = 'Preparing secure checkout…'; st.textContent = '';
  try {
    const { res, data } = await api('pay', { country });
    if (res.status === 503) { st.textContent = 'Card payment is not available right now.'; st.className = 'form-status err'; btn.disabled = false; btn.textContent = 'Pay by card'; return; }
    if (!res.ok || !data.ok || !data.client_secret || !data.publishable_key) {
      st.textContent = data.message || 'Could not start the payment. Please try again.'; st.className = 'form-status err'; btn.disabled = false; btn.textContent = 'Pay by card'; return;
    }
    const Stripe = await loadStripeJs();
    const stripe = Stripe(data.publishable_key);
    if (checkoutInstance) { try { checkoutInstance.destroy(); } catch { /* ignore */ } }
    checkoutInstance = await stripe.initEmbeddedCheckout({
      clientSecret: data.client_secret,
      onComplete: () => { setTimeout(load, 1500); },
    });
    $('pay-live').hidden = true; $('card-panel').hidden = false;
    checkoutInstance.mount('#card-mount');
  } catch {
    st.textContent = 'Could not load secure checkout. Please try again.'; st.className = 'form-status err'; btn.disabled = false; btn.textContent = 'Pay by card';
  }
}

load();
if (q.get('paid') === '1') setTimeout(load, 2000);

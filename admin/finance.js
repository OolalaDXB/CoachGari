/* =============================================================
   Coach Gari back-office — Finance and the embedded BEAU PH workspace

   Finance (daily business surface)
     Transactions     one list across every rail: what came in, from whom,
                      for what, status, whether anything needs action.
     Payment methods  only the methods Coach Gari added; compact rows;
                      Edit loads that one method's configuration and opens
                      an inline editor; Save shows ONE confirmation with the
                      important changes; Remove deactivates and unlists,
                      never deletes history.

   BEAU PH (temporary embedded operational workspace; leaves with the
   extraction — nothing here depends on Coach Gari business entities)
     Rails  the whole provider catalogue with the merchant's real state:
            provider capability (what a rail can do) vs merchant
            configuration (what Coach Gari chose) — eligibility is the
            intersection, computed server-side. Filters, checklist,
            Configure / Test / Enable / Start onboarding.
     FX     BEAU FX: rates health, per-currency freshness, refresh runs,
            merchant FX settings, an indicative calculator.

   Every write goes through a permission-checked RPC; the page decides
   nothing about eligibility, amounts or rates. Secrets are never fetched:
   the runtime helper (ph-admin) reports presence per secret NAME only.

   Loading discipline: Finance open → transactions only. Payment methods →
   summaries only. Edit → that method. Rails → catalogue + one runtime
   probe. FX → the overview. History / audit / events → on demand.
   Reads are cached for the admin session (60 s) and invalidated on writes.
   Editors render from the provider's config schema (data), not from
   provider-specific code.
   ============================================================= */
let C = null;   // shared helpers handed over by admin.js: sb, $, esc, money, st, fmt, table, toast, fail, has, view, config, openProfile, session

export function initFinance(ctx) { C = ctx; }

/* ---------- cache: one fetch per admin session per key unless invalidated ---------- */
const cache = new Map();
const TTL = 60_000;
async function rpc(name, args = {}, { fresh = false, ttl = TTL } = {}) {
  const key = name + ':' + JSON.stringify(args);
  const hit = cache.get(key);
  if (!fresh && hit && Date.now() - hit.t < ttl) return hit.data;
  const { data, error } = await C.sb.rpc(name, args); if (error) throw error;
  cache.set(key, { t: Date.now(), data });
  return data;
}
function invalidate(...prefixes) { for (const k of [...cache.keys()]) if (prefixes.some((p) => k.startsWith(p + ':'))) cache.delete(k); }
async function write(name, args) { const { data, error } = await C.sb.rpc(name, args); if (error) throw error; return data; }

/* ---------- reference data (display only; validation is server-side) ---------- */
const COUNTRIES = {
  AE: 'United Arab Emirates', SA: 'Saudi Arabia', QA: 'Qatar', KW: 'Kuwait', BH: 'Bahrain', OM: 'Oman', EG: 'Egypt', MA: 'Morocco', TN: 'Tunisia', DZ: 'Algeria', JO: 'Jordan', LB: 'Lebanon', TR: 'Türkiye', IL: 'Israel',
  ZW: 'Zimbabwe', ZA: 'South Africa', KE: 'Kenya', NG: 'Nigeria', GH: 'Ghana', TZ: 'Tanzania', UG: 'Uganda', RW: 'Rwanda', ET: 'Ethiopia', BW: 'Botswana', NA: 'Namibia', ZM: 'Zambia', MZ: 'Mozambique', MU: 'Mauritius', SN: 'Senegal', CI: 'Côte d’Ivoire', CM: 'Cameroon', AO: 'Angola',
  GB: 'United Kingdom', IE: 'Ireland', FR: 'France', DE: 'Germany', ES: 'Spain', PT: 'Portugal', IT: 'Italy', NL: 'Netherlands', BE: 'Belgium', LU: 'Luxembourg', CH: 'Switzerland', AT: 'Austria', SE: 'Sweden', NO: 'Norway', DK: 'Denmark', FI: 'Finland', PL: 'Poland', CZ: 'Czechia', HU: 'Hungary', RO: 'Romania', GR: 'Greece', MT: 'Malta', CY: 'Cyprus', HR: 'Croatia', BG: 'Bulgaria', SK: 'Slovakia', SI: 'Slovenia', EE: 'Estonia', LV: 'Latvia', LT: 'Lithuania', GE: 'Georgia', UA: 'Ukraine', RS: 'Serbia', IS: 'Iceland',
  US: 'United States', CA: 'Canada', MX: 'Mexico', BR: 'Brazil', AR: 'Argentina', CL: 'Chile', CO: 'Colombia', PE: 'Peru',
  IN: 'India', PK: 'Pakistan', BD: 'Bangladesh', LK: 'Sri Lanka', SG: 'Singapore', MY: 'Malaysia', TH: 'Thailand', ID: 'Indonesia', PH: 'Philippines', VN: 'Vietnam', JP: 'Japan', KR: 'South Korea', CN: 'China', HK: 'Hong Kong', TW: 'Taiwan', AU: 'Australia', NZ: 'New Zealand', KZ: 'Kazakhstan',
};
const CURRENCIES = ['AED', 'USD', 'EUR', 'GBP', 'CHF', 'SAR', 'QAR', 'KWD', 'BHD', 'OMR', 'EGP', 'MAD', 'ZAR', 'KES', 'NGN', 'GHS', 'TZS', 'UGX', 'ZWG', 'ZMW', 'BWP', 'MUR', 'XOF', 'XAF', 'GEL', 'TRY', 'INR', 'PKR', 'SGD', 'MYR', 'THB', 'IDR', 'PHP', 'JPY', 'KRW', 'CNY', 'HKD', 'AUD', 'NZD', 'CAD', 'MXN', 'BRL', 'SEK', 'NOK', 'DKK', 'PLN', 'CZK', 'HUF', 'RON', 'RUB'];
const INTENT_LABEL = { service: 'Service (a session)', package: 'Package (a session pack)', support: 'Support Coach Gari', other: 'Other' };
const TYPE_LABEL = { service: 'Service', package: 'Package', support: 'Support', collaboration: 'Collaboration', other: 'Other' };
const STATUS_LABEL = { created: 'Created', pending: 'Awaiting receipt', requires_action: 'In progress', paid: 'Paid', failed: 'Failed', expired: 'Expired', cancelled: 'Cancelled', refunded: 'Refunded' };
const READY_LABEL = { available: 'Available', not_configured: 'Not onboarded', placeholder: 'Coming soon' };
const countryName = (c) => COUNTRIES[c] || c;
const listOf = (a) => Array.isArray(a) ? a : [];
const chips = (arr, fmt = (x) => x, max = 6) => {
  const a = listOf(arr); if (!a.length) return '';
  const shown = a.slice(0, max).map((x) => `<span class="ph-chip">${C.esc(fmt(x))}</span>`).join('');
  return shown + (a.length > max ? `<span class="ph-chip ph-chip-more" title="${C.esc(a.map(fmt).join(', '))}">+${a.length - max}</span>` : '');
};
const when = (iso, opts) => iso ? C.fmt(iso, 'Asia/Dubai', opts || { dateStyle: 'medium', timeStyle: 'short' }) : '—';
const runtimeMode = (rt) => rt && rt.mode ? String(rt.mode).toUpperCase() : null;

/* ---------- modal: one confirmation before a financially material change ---------- */
function modal({ title, body, confirm = 'Confirm', danger = false, cancel = 'Cancel' }) {
  return new Promise((resolve) => {
    const host = document.createElement('div'); host.className = 'ph-modal-host';
    host.innerHTML = `<div class="ph-scrim"></div><div class="ph-modal" role="dialog" aria-modal="true"><h3>${C.esc(title)}</h3><div class="ph-modal-b">${body}</div>
      <div class="ph-modal-a"><button type="button" class="btn btn-line btn-sm" data-x>${C.esc(cancel)}</button><button type="button" class="btn ${danger ? 'btn-dark' : 'btn-accent'} btn-sm" data-ok>${C.esc(confirm)}</button></div></div>`;
    const done = (v) => { host.remove(); document.removeEventListener('keydown', onKey); resolve(v); };
    const onKey = (e) => { if (e.key === 'Escape') done(false); };
    host.querySelector('[data-x]').onclick = () => done(false);
    host.querySelector('.ph-scrim').onclick = () => done(false);
    host.querySelector('[data-ok]').onclick = () => done(true);
    document.addEventListener('keydown', onKey);
    document.body.appendChild(host);
    host.querySelector('[data-ok]').focus();
  });
}

/* =============================== FINANCE · TRANSACTIONS =============================== */
const txFilters = { q: '', type: '', method: '', status: '' };
export async function financeTransactions() {
  const { $, esc, money, st, view, has } = C;
  const rows = await rpc('finance_transactions', { p_limit: 300 });
  const manage = has('finance:manage');
  // per-currency figures: amounts are in the currency actually collected, never summed across currencies
  const byCcy = {};
  for (const r of rows) {
    const b = byCcy[r.currency] || (byCcy[r.currency] = { collected: 0, refunded: 0, open: 0 });
    if (r.status === 'paid' || r.status === 'refunded') b.collected += r.amount || 0;
    b.refunded += r.refund_amount || 0;
    if (r.status === 'pending' || r.status === 'requires_action' || r.status === 'created') b.open += r.amount || 0;
  }
  const methods = [...new Set(rows.map((r) => r.method).filter(Boolean))];
  const filtered = rows.filter((r) => (!txFilters.type || r.type === txFilters.type) && (!txFilters.method || r.method === txFilters.method) && (!txFilters.status || r.status === txFilters.status)
    && (!txFilters.q || [r.reference, r.public_reference, r.customer_hint, r.item, r.provider_reference].some((x) => String(x || '').toLowerCase().includes(txFilters.q.toLowerCase()))));
  const actionCell = (r) => {
    if (r.action === 'confirm_receipt') return r.crm_contact_id && has('coach:operations') ? `<button class="btn btn-accent btn-xs" data-open="${esc(r.crm_contact_id)}">Record receipt</button>` : '<span class="ad-muted">Awaiting receipt</span>';
    if (r.action === 'fee_pending') return '<span class="ad-muted">Fee pending</span>';
    if (r.action === 'partial_refund') return '<span class="ad-muted">Partly refunded</span>';
    return '';
  };
  view.innerHTML = `
    <div class="ad-head"><div><h1>Transactions</h1><p class="ad-muted">Every payment request across every rail, in the currency it is collected in. Status is BEAU PH's normalised state; the provider's own detail is one click away. No names, no contacts: only a masked hint.</p></div></div>
    <div class="ad-kpis">${Object.entries(byCcy).map(([c, b]) => `<div class="ad-kpi"><b>${money(b.collected, c)}</b><span>Collected (${esc(c)})${b.refunded ? ` · refunded ${money(b.refunded, c)}` : ''}${b.open ? ` · open ${money(b.open, c)}` : ''}</span></div>`).join('') || '<div class="ad-kpi"><b>—</b><span>Nothing collected yet</span></div>'}</div>
    <div class="ad-panel">
      <div class="ad-filters" style="margin-bottom:12px">
        <input id="tx-q" placeholder="Search reference, customer, item" value="${esc(txFilters.q)}">
        <select id="tx-type"><option value="">All types</option>${Object.entries(TYPE_LABEL).map(([k, l]) => `<option value="${k}" ${txFilters.type === k ? 'selected' : ''}>${l}</option>`).join('')}</select>
        <select id="tx-method"><option value="">All methods</option>${methods.map((m) => `<option value="${esc(m)}" ${txFilters.method === m ? 'selected' : ''}>${esc((rows.find((r) => r.method === m) || {}).method_label || m)}</option>`).join('')}</select>
        <select id="tx-status"><option value="">All statuses</option>${Object.entries(STATUS_LABEL).map(([k, l]) => `<option value="${k}" ${txFilters.status === k ? 'selected' : ''}>${l}</option>`).join('')}</select>
      </div>
      ${C.table(['Date', 'Reference', 'Customer', 'Type', 'Payment method', 'Amount', 'Status', 'Action'], filtered.map((r) => `<tr class="clik" data-tx="${esc(r.reference)}">
        <td>${when(r.created_at)}</td>
        <td><b>${esc(r.public_reference)}</b><div class="msg" style="font-size:12px">${esc(r.reference)}</div></td>
        <td class="ad-muted" style="font-size:12.5px">${esc(r.customer_hint || '—')}</td>
        <td>${esc(TYPE_LABEL[r.type] || r.type)}${r.item ? `<div class="msg" style="font-size:12px">${esc(r.item)}</div>` : ''}</td>
        <td>${esc(r.method_label || '—')}</td>
        <td class="num">${money(r.amount, r.currency)}${r.fx ? `<div class="msg" style="font-size:12px">priced ${money(r.pricing_amount, r.pricing_currency)}</div>` : ''}</td>
        <td>${st(r.status)}${r.refund_amount ? `<div class="msg" style="font-size:12px">refunded ${money(r.refund_amount, r.currency)}</div>` : ''}</td>
        <td class="acts">${actionCell(r)}</td></tr>`), rows.length ? 'No transaction matches these filters.' : 'No transactions yet.')}
    </div>
    <details class="ad-panel ph-details" id="tx-ledger"><summary>Ledger and settlements</summary><div id="tx-ledger-body"><p class="ad-empty">Loading…</p></div></details>`;
  const refilter = () => { txFilters.q = $('#tx-q').value; txFilters.type = $('#tx-type').value; txFilters.method = $('#tx-method').value; txFilters.status = $('#tx-status').value; financeTransactions().catch(C.fail); };
  $('#tx-q').onchange = refilter; $('#tx-type').onchange = refilter; $('#tx-method').onchange = refilter; $('#tx-status').onchange = refilter;
  view.querySelectorAll('[data-open]').forEach((b) => b.onclick = (e) => { e.stopPropagation(); C.openProfile(b.dataset.open, null, 'payments'); });
  view.querySelectorAll('tr[data-tx]').forEach((tr) => tr.onclick = () => openTransaction(tr.dataset.tx));
  let ledgerLoaded = false;
  $('#tx-ledger').addEventListener('toggle', () => { if ($('#tx-ledger').open && !ledgerLoaded) { ledgerLoaded = true; ledgerPanel($('#tx-ledger-body'), manage).catch(C.fail); } });
}

/* one transaction, everything about it, loaded on demand */
async function openTransaction(reference) {
  const { esc, money, st } = C;
  const host = document.createElement('div'); host.className = 'ph-drawer-host';
  host.innerHTML = `<div class="ph-scrim"></div><aside class="ph-drawer"><button class="ph-x" aria-label="Close">×</button><div class="ph-drawer-b"><p class="ad-empty">Loading…</p></div></aside>`;
  const close = () => { host.remove(); document.removeEventListener('keydown', onKey); };
  const onKey = (e) => { if (e.key === 'Escape') close(); };
  host.querySelector('.ph-scrim').onclick = close; host.querySelector('.ph-x').onclick = close; document.addEventListener('keydown', onKey);
  document.body.appendChild(host);
  let d;
  try { d = await rpc('finance_transaction_detail', { p_reference: reference }, { ttl: 15_000 }); } catch (e) { host.querySelector('.ph-drawer-b').innerHTML = `<p class="ad-msg err">${esc(e.message)}</p>`; return; }
  const o = d.order, kv = (rows) => `<dl class="pf-kv">${rows.filter(([, v]) => v !== undefined && v !== null && v !== '').map(([k, v]) => `<dt>${esc(k)}</dt><dd>${v}</dd>`).join('')}</dl>`;
  const req = (d.requests || [])[0];
  host.querySelector('.ph-drawer-b').innerHTML = `
    <p class="ad-eyebrow">Transaction</p><h2 style="margin:0 0 4px">${esc(req ? req.public_reference : o.reference)}</h2>
    <p class="ad-muted" style="margin:0 0 14px">${esc(o.reference)} · ${st(req ? req.status : o.status)}</p>
    ${kv([['Amount', req ? money(req.amount, req.currency) : money(o.gross_amount, o.currency)], ['Priced', req && req.pricing_currency && req.pricing_currency !== req.currency ? money(req.pricing_amount, req.pricing_currency) : undefined],
          ['Customer', esc(o.customer_hint || '—')], ['Type', esc(o.reason === 'collaboration' ? 'Collaboration' : (TYPE_LABEL[req ? req.intent : o.reason] || o.reason || '—'))], ['Item', esc(o.service_title || (d.pack && d.pack.title) || '—')],
          ['Payment method', req ? esc(req.provider) + (req.capability ? ` · ${esc(req.capability.replace(/_/g, ' '))}` : '') : '—'],
          ['Provider reference', req && req.payment_reference ? `<code>${esc(req.payment_reference)}</code>` : (req && req.provider_reference ? `<code>${esc(req.provider_reference)}</code>` : undefined)],
          ['Created', when(o.created_at)], ['Paid', o.paid_at ? when(o.paid_at) : undefined], ['Reconciled', req ? (req.reconciled ? 'Yes' : 'No') : undefined],
          ['Support message', req && req.support_message ? esc(req.support_message) : undefined]])}
    ${req && req.fx_quote ? `<div class="cg-sec"><div class="cg-sec-t">FX quote</div>${kv([['Rate', `${esc(req.fx_quote.customer_rate)} (reference ${esc(req.fx_quote.reference_rate)}, ${esc(req.fx_quote.source)})`], ['Freshness', esc(req.fx_quote.freshness)], ['Quoted', when(req.fx_quote.created_at)], ['Status', esc(req.fx_quote.status)]])}</div>` : ''}
    ${d.booking ? `<div class="cg-sec"><div class="cg-sec-t">Related session</div>${kv([['Booking', esc(d.booking.reference) + ' · ' + st(d.booking.status)], ['When', when(d.booking.start_at)], ['Service', esc(d.booking.service_title || '')]])}</div>` : ''}
    ${d.pack ? `<div class="cg-sec"><div class="cg-sec-t">Related package</div>${kv([['Package', esc(d.pack.reference) + ' · ' + st(d.pack.payment_status)], ['Title', esc(d.pack.title || '')], ['Sessions', esc(String(d.pack.total_sessions || ''))]])}</div>` : ''}
    ${d.earning ? `<div class="cg-sec"><div class="cg-sec-t">Ledger</div>${kv([['Gross', money(d.earning.gross_amount, d.earning.currency)], ['Fee', money(d.earning.stripe_fee, d.earning.currency)], ['Refunds', money(d.earning.refund_amount, d.earning.currency)], ['Net', money(d.earning.net_collected, d.earning.currency)], ['Commission', money(d.earning.oolala_commission, d.earning.currency)], ['Payable to Gari', money(d.earning.gari_payable, d.earning.currency)], ['Earning', st(d.earning.status)]])}</div>` : ''}
    ${(d.refunds || []).length ? `<div class="cg-sec"><div class="cg-sec-t">Refunds</div>${d.refunds.map((r) => `<div>${money(r.amount, r.currency)} · ${st(r.status)} · ${when(r.created_at)}${r.reason ? ` · ${esc(r.reason)}` : ''}</div>`).join('')}</div>` : ''}
    ${(d.chargebacks || []).length ? `<div class="cg-sec"><div class="cg-sec-t">Disputes</div>${d.chargebacks.map((r) => `<div>${money(r.amount, r.currency)} · ${st(r.status)} · ${when(r.created_at)}</div>`).join('')}</div>` : ''}
    <details class="pf-tech"><summary>Timeline (${(d.requests || []).reduce((n, r) => n + (r.events || []).length, 0)} events)</summary>
      ${(d.requests || []).map((r) => `<p class="ad-muted" style="font-size:12.5px;margin:8px 0 4px">${esc(r.provider)} request · ${st(r.status)} · ${when(r.created_at)}</p>
        <div class="ad-table-wrap"><table class="ad-table">${(r.events || []).map((e) => `<tr><td>${when(e.created_at, { dateStyle: 'medium', timeStyle: 'medium' })}</td><td>${esc(e.from_status || '—')} → ${esc(e.to_status)}</td><td class="ad-muted">${esc(e.actor)}${e.provider_status ? ` · ${esc(e.provider_status)}` : ''}</td></tr>`).join('')}</table></div>`).join('')}
    </details>
    ${d.pack && d.pack.crm_contact_id && C.has('coach:operations') ? `<div class="cg-actions" style="margin-top:14px"><button class="btn btn-line btn-sm" data-open="${esc(d.pack.crm_contact_id)}">Open client</button></div>` : ''}`;
  host.querySelectorAll('[data-open]').forEach((b) => b.onclick = () => { close(); C.openProfile(b.dataset.open, null, 'payments'); });
}

/* the partner ledger and settlements (Oolala → Gari), unchanged in substance, loaded only when opened */
async function ledgerPanel(host, manage) {
  const { esc, money, st, sb } = C;
  const [{ data: orders, error }, { data: settlements }] = await Promise.all([sb.rpc('finance_orders').limit(300), sb.from('partner_settlements').select('*').order('created_at', { ascending: false })]);
  if (error) throw error;
  const open = orders.filter((o) => o.earning_status === 'open');
  const sum = (arr, k) => arr.reduce((a, o) => a + (o[k] || 0), 0);
  const today = new Date(); const monthStart = new Date(Date.UTC(today.getUTCFullYear(), today.getUTCMonth(), 1));
  const isoDate = (d) => d.toISOString().slice(0, 10);
  host.innerHTML = `
    <p class="ad-muted" style="font-size:13px;margin:0 0 12px">Net after fees, refunds and chargebacks; the Oolala commission (${esc(C.config.COMMISSION_RATE)}); what is payable to Gari. Each line is in the currency it was collected in.</p>
    <p class="ad-muted" style="font-size:13px;margin:0 0 12px">Payable to Gari, not yet settled: <b>${Object.entries(open.reduce((m, o) => { m[o.ledger_currency] = (m[o.ledger_currency] || 0) + (o.gari_payable || 0); return m; }, {})).map(([c, v]) => money(v, c)).join(' · ') || '—'}</b></p>
    <h2 style="font-size:15px">Settlements</h2>
    ${C.table(['Ref', 'Period', 'Items', 'Gross', 'Fees', 'Refunds/CB', 'Net', 'Commission', 'Payable', 'Status', ''], (settlements || []).map((s) => `<tr>
      <td>${esc(s.reference)}</td><td>${s.period_start} → ${s.period_end}</td><td class="num">${(orders.filter((o) => o.settlement_id === s.id)).length}</td>
      <td class="num">${money(s.gross_amount, s.currency)}</td><td class="num">${money(s.fee_amount, s.currency)}</td><td class="num">${money(s.refund_amount + s.chargeback_amount, s.currency)}</td>
      <td class="num">${money(s.net_collected, s.currency)}</td><td class="num">${money(s.oolala_commission, s.currency)}</td><td class="num"><b>${money(s.amount_payable, s.currency)}</b></td>
      <td>${st(s.status)}${s.bank_transfer_reference ? `<div class="msg">${esc(s.bank_transfer_reference)}</div>` : ''}</td>
      <td class="acts">${manage && s.status === 'ready' ? `<button class="btn btn-accent btn-xs" data-paid="${s.reference}">Mark paid</button>` : ''}${manage && s.status === 'paid' ? `<button class="btn btn-dark btn-xs" data-recon="${s.reference}">Reconciled</button>` : ''}</td></tr>`), 'No settlement yet.')}
    ${manage ? `<form id="settle-form" class="ad-form" style="margin-top:16px"><div class="row"><label>Period from <input type="date" name="from" required value="${isoDate(monthStart)}"></label><label>to <input type="date" name="to" required value="${isoDate(today)}"></label><label>Currency <input name="currency" value="AED" pattern="[A-Z]{3}"></label></div>
      <div class="actions"><button class="btn btn-accent btn-sm" type="submit">Create settlement for open earnings</button></div></form><p class="ad-note">Creates a settlement from every open earning in that currency whose payment date falls in the period, then freezes those earnings. Pay Gari by bank transfer and record the reference with "Mark paid".</p>` : '<p class="ad-note">View only. Settlement actions need the finance:manage permission.</p>'}
    <h2 style="font-size:15px;margin-top:20px">Ledger lines</h2>
    ${C.table(['Created', 'Order', 'Booking or package', 'Item', 'Gross', 'Fee', 'Refunds', 'CB', 'Net', 'Commission', 'Payable', 'Status'], orders.map((o) => `<tr>
      <td>${when(o.created_at)}</td><td>${esc(o.reference)}<br>${st(o.status)}</td>
      <td>${o.booking_reference ? esc(o.booking_reference) + '<br>' + st(o.booking_status) : o.pack_reference ? esc(o.pack_reference) + '<br><span class="ad-muted" style="font-size:12px">Package</span>' : '—'}</td>
      <td>${esc(o.service_title || '—')}</td>
      <td class="num">${money(o.gross_amount, o.currency)}</td><td class="num">${o.earning_status && o.fee_known === false ? '<span class="ad-muted">pending</span>' : money(o.stripe_fee, o.ledger_currency)}</td><td class="num">${money(o.refund_amount, o.ledger_currency)}</td><td class="num">${money(o.chargeback_amount, o.ledger_currency)}</td>
      <td class="num">${money(o.net_collected, o.ledger_currency)}</td><td class="num">${money(o.oolala_commission, o.ledger_currency)}</td><td class="num"><b>${money(o.gari_payable, o.ledger_currency)}</b></td>
      <td>${o.earning_status ? st(o.earning_status) : '—'}${o.adjusted_at ? '<div class="msg">adjusted after settlement</div>' : ''}</td></tr>`), 'No orders yet.')}`;
  const reload = () => ledgerPanel(host, manage).catch(C.fail);
  host.querySelectorAll('[data-paid]').forEach((b) => b.onclick = async () => {
    const ref = window.prompt(`Bank transfer reference for ${b.dataset.paid}:`); if (!ref) return;
    const { error: e } = await sb.rpc('finance_mark_settlement_paid', { p_reference: b.dataset.paid, p_bank_transfer_reference: ref }); if (e) return C.fail(e); C.toast('Marked paid'); reload();
  });
  host.querySelectorAll('[data-recon]').forEach((b) => b.onclick = async () => {
    if (!(await modal({ title: 'Reconcile settlement', body: `<p>Mark ${esc(b.dataset.recon)} as reconciled with the bank statement?</p>`, confirm: 'Reconciled' }))) return;
    const { error: e } = await sb.rpc('finance_mark_settlement_reconciled', { p_reference: b.dataset.recon }); if (e) return C.fail(e); C.toast('Reconciled'); reload();
  });
  const form = host.querySelector('#settle-form');
  if (form) form.onsubmit = async (e) => {
    e.preventDefault(); const f = new FormData(form);
    const { data, error: e2 } = await sb.rpc('finance_create_settlement', { p_period_start: f.get('from'), p_period_end: f.get('to'), p_currency: (f.get('currency') || 'AED').toUpperCase() }); if (e2) return C.fail(e2);
    C.toast(`${data.reference}: ${data.items} item(s), payable ${money(data.amount_payable, data.currency)}`); invalidate('finance_transactions'); reload();
  };
}

/* =============================== FINANCE · COMMISSIONS =============================== */
/* The Oolala commission on money Oolala collected (Stripe), month × currency × type — service, package,
   support. Manual rails (Aani, bank transfer, cash) never carry a commission: that money never passed
   through Oolala. Settled = included in a settlement to Gari; open = not yet. Never summed across currencies. */
export async function financeCommissions() {
  const { esc, money, view } = C;
  const d = await rpc('finance_commissions');
  const rows = d.rows || [], totals = d.totals || [];
  const pct = Math.round(Number(d.rate || 0.1) * 10000) / 100;
  view.innerHTML = `
    <div class="ad-head"><div><h1>Oolala commissions</h1><p class="ad-muted">The ${esc(String(pct))} % commission on every payment Oolala collected for Coach Gari — sessions, packages and support alike — after Stripe fees, refunds and chargebacks. Aani, bank transfer and cash carry no commission: that money never passed through Oolala. Figures stay in the currency collected.</p></div></div>
    <div class="ad-kpis">${totals.map((t) => `<div class="ad-kpi"><b>${money(t.commission, t.currency)}</b><span>Commission (${esc(t.currency)}) · settled ${money(t.commission_settled, t.currency)} · open ${money(t.commission_open, t.currency)} · on ${money(t.net, t.currency)} net from ${t.payments} payment${t.payments === 1 ? '' : 's'}</span></div>`).join('') || '<div class="ad-kpi"><b>—</b><span>No commission yet</span></div>'}</div>
    <div class="ad-panel">
      ${C.table(['Month', 'Currency', 'Type', 'Payments', 'Gross', 'Stripe fees', 'Refunds / chargebacks', 'Net', 'Commission', 'Settled', 'Open', 'Gari payable'], rows.map((r) => `<tr>
        <td><b>${esc(r.month)}</b></td><td>${esc(r.currency)}</td><td>${esc(TYPE_LABEL[r.type] || r.type)}</td><td class="num">${r.payments}</td>
        <td class="num">${money(r.gross, r.currency)}</td><td class="num">${money(r.fees, r.currency)}</td><td class="num">${money((r.refunds || 0) + (r.chargebacks || 0), r.currency)}</td>
        <td class="num">${money(r.net, r.currency)}</td><td class="num"><b>${money(r.commission, r.currency)}</b></td><td class="num">${money(r.commission_settled, r.currency)}</td><td class="num">${money(r.commission_open, r.currency)}</td>
        <td class="num">${money(r.gari_payable, r.currency)}${r.adjusted ? `<div class="msg" style="font-size:12px">${r.adjusted} adjusted after settlement</div>` : ''}</td></tr>`), 'No commission yet.')}
    </div>`;
}

/* =============================== FINANCE · PAYMENT METHODS =============================== */
export async function financePaymentMethods() {
  const { $, esc, view, has } = C;
  const manage = has('finance:manage');
  const rows = await rpc('payment_methods_summary');
  view.innerHTML = `
    <div class="ad-head"><div><h1>Payment methods</h1><p class="ad-muted">What Coach Gari offers its clients. Only the methods added here appear on client pages, and only where their countries and currencies match. The wider BEAU PH catalogue is one click away under "Add".</p></div>
      ${manage ? '<button class="btn btn-accent btn-sm" id="pm-add">+ Add payment method</button>' : ''}</div>
    <div class="ad-panel" style="padding:8px 0"><div id="pm-list">${rows.length ? rows.map(methodRow).join('') : '<p class="ad-empty" style="padding:8px 24px">No payment method yet. Add one to start accepting payments.</p>'}</div></div>
    <div id="pm-catalogue" hidden></div>`;
  bindMethodRows($('#pm-list'), manage, 'finance');
  if (manage) $('#pm-add').onclick = () => catalogue($('#pm-catalogue'));
}

function healthBadge(m) {
  if (m.health === 'needs_configuration') return '<span class="ad-badge-warn">Needs configuration</span>';
  return m.enabled ? '<span class="ad-badge-ok">Configured</span>' : '<span class="ad-badge-rev">Configured · off</span>';
}
function methodRow(m) {
  const { esc } = C;
  const chan = (m.channel_label || '').split('·')[0].trim() || m.kind;
  return `<div class="ph-row" data-method="${esc(m.provider)}" tabindex="0">
    <div class="ph-row-main">
      <div class="ph-row-name"><b>${esc(m.display_name)}</b><span class="st st-${m.enabled ? 'open' : 'off'}">${m.enabled ? 'Active' : 'Inactive'}</span></div>
      <div class="ph-row-meta">
        <span title="${esc(listOf(m.countries).map(countryName).join(', ') || 'Needs configuration')}">${listOf(m.countries).length ? (m.countries.length <= 3 ? m.countries.map(countryName).map(esc).join(', ') : `${m.countries.length} countries`) : '<i>Countries: needs configuration</i>'}</span>
        <span>·</span><span>${listOf(m.currencies).length ? esc(m.currencies.join(', ')) : '<i>Currencies: needs configuration</i>'}</span>
        ${m.hint ? `<span>·</span><span class="ph-hint">${esc(m.hint)}</span>` : ''}
        <span>·</span><span>${esc(chan)}</span>
        <span>·</span>${healthBadge(m)}
      </div>
    </div>
    <div class="ph-row-acts"><button class="btn btn-line btn-xs" data-edit="${esc(m.provider)}">Edit</button><button class="btn btn-line btn-xs" data-remove="${esc(m.provider)}">Remove</button></div>
    <button class="ph-more" data-more="${esc(m.provider)}" aria-label="More actions">•••</button>
    <div class="ph-row-editor" data-editor="${esc(m.provider)}" hidden></div>
  </div>`;
}
function bindMethodRows(list, manage, mode) {
  list.querySelectorAll('.ph-row').forEach((row) => {
    const key = row.dataset.method;
    const edit = row.querySelector('[data-edit]'), rm = row.querySelector('[data-remove]'), more = row.querySelector('[data-more]');
    if (!manage) { edit.textContent = 'View'; rm.hidden = true; }
    edit.onclick = (e) => { e.stopPropagation(); openEditor(row.querySelector('[data-editor]'), key, { mode, manage, onClose: (why) => { if (why === 'saved') financePaymentMethods().catch(C.fail); } }); };
    rm.onclick = (e) => { e.stopPropagation(); removeMethod(key); };
    more.onclick = (e) => { e.stopPropagation(); row.classList.toggle('show-acts'); };
  });
}
async function removeMethod(key) {
  const { esc } = C;
  const rows = await rpc('payment_methods_summary');
  const m = rows.find((x) => x.provider === key) || { display_name: key, history: 0 };
  const ok = await modal({ title: `Remove ${m.display_name} from Coach Gari?`, danger: true, confirm: 'Remove payment method',
    body: `<p>Customers will no longer be offered ${esc(m.display_name)}.</p><p>${m.history > 0 ? 'Existing transactions and payment history will be preserved.' : 'This method has no transaction yet; its configuration will be deleted.'}</p>` });
  if (!ok) return;
  try { const r = await write('payment_method_remove', { p_method: key }); invalidate('payment_methods_summary', 'payment_method_get', 'beau_ph_rails'); C.toast(r.removed === 'deleted' ? 'Payment method deleted' : 'Payment method removed; history kept'); financePaymentMethods().catch(C.fail); }
  catch (e) { C.fail(e); }
}

/* "+ Add payment method": the BEAU PH catalogue, fetched only now */
async function catalogue(host) {
  const { esc } = C;
  host.hidden = false; host.innerHTML = '<div class="ad-panel"><p class="ad-empty">Loading the BEAU PH catalogue…</p></div>';
  const ov = await rpc('beau_ph_rails');
  const listed = new Set((await rpc('payment_methods_summary')).map((m) => m.provider));
  const rails = ov.rails.filter((r) => !listed.has(r.provider));
  host.innerHTML = `<div class="ad-panel"><h2>Add a payment method</h2><p class="ad-muted" style="font-size:13px;margin:0 0 12px">The BEAU PH provider catalogue. Adding a rail here lists it for Coach Gari; it stays off until it is configured and enabled. Onboarding a new provider (credentials, merchant account) is a separate step done in BEAU PH › Rails.</p>
    <div class="ph-cat">${rails.map((r) => `<div class="ph-cat-row"><div><b>${esc(r.display_name)}</b> <span class="ad-muted" style="font-size:12.5px">${esc(r.channel_label || '')}</span>
      <div class="ad-muted" style="font-size:12.5px">${esc(READY_LABEL[r.readiness] || r.readiness)}${r.provider_countries ? ` · ${r.provider_countries.map(countryName).map(esc).join(', ')}` : ' · any country'}${r.provider_currencies ? ` · ${esc(r.provider_currencies.join(', '))}` : ''}</div></div>
      <button class="btn btn-line btn-xs" data-add="${esc(r.provider)}" ${r.readiness === 'placeholder' ? 'disabled title="Coming soon"' : ''}>Add</button></div>`).join('') || '<p class="ad-empty">Every rail BEAU PH knows is already listed.</p>'}</div>
    <div class="actions" style="margin-top:12px"><button class="btn btn-line btn-xs" id="cat-close">Close</button></div></div>`;
  host.querySelector('#cat-close').onclick = () => { host.hidden = true; host.innerHTML = ''; };
  host.querySelectorAll('[data-add]').forEach((b) => b.onclick = async () => {
    try { await write('payment_method_add', { p_provider: b.dataset.add }); invalidate('payment_methods_summary', 'payment_method_get', 'beau_ph_rails'); C.toast('Added. Configure it, then enable it.');
      await financePaymentMethods(); const row = C.view.querySelector(`.ph-row[data-method="${b.dataset.add}"]`); if (row) row.querySelector('[data-edit]').click(); }
    catch (e) { C.fail(e); }
  });
}

/* =============================== THE METHOD EDITOR (shared by Finance and Rails) =============================== */
/* Renders from the provider's config schema; progressive groups; Save = one confirmation with a summary of the important changes. */
async function openEditor(host, key, { mode = 'finance', manage = true, runtime = null, onClose = null } = {}) {
  const { esc } = C;
  if (!host.hidden) { host.hidden = true; host.innerHTML = ''; if (onClose) onClose(); return; }
  host.hidden = false; host.innerHTML = '<p class="ad-empty">Loading configuration…</p>';
  let d;
  try { d = await rpc('payment_method_get', { p_method: key }, { fresh: true }); } catch (e) { host.innerHTML = `<p class="ad-msg err">${esc(e.message)}</p>`; return; }
  const p = d.provider, m = d.method || { enabled: false, countries: null, currencies: null, intents: null, limits: {}, instructions: {}, settings: {}, settlement: {}, currency: null, capabilities: null };
  const schema = listOf(p.config_schema);
  const state = {
    enabled: !!m.enabled, currency: m.currency || '', countries: listOf(m.countries), currencies: listOf(m.currencies), intents: m.intents === null || m.intents === undefined ? null : listOf(m.intents),
    limits: m.limits || {}, settlement: m.settlement || {}, capabilities: m.capabilities === null || m.capabilities === undefined ? null : listOf(m.capabilities),
    fields: Object.fromEntries(schema.map((s) => [s.key, (s.store === 'settings' ? m.settings : m.instructions)?.[s.key] || ''])),
  };
  const original = JSON.parse(JSON.stringify(state));
  const provCountries = p.countries, provCurrencies = p.currencies;
  const pickable = (all, allowed) => allowed ? all.filter((c) => allowed.includes(c)) : all;
  const countryOptions = pickable(Object.keys(COUNTRIES), provCountries).concat(listOf(provCountries).filter((c) => !COUNTRIES[c]));
  const currencyOptions = pickable(CURRENCIES, provCurrencies).concat(listOf(provCurrencies).filter((c) => !CURRENCIES.includes(c)));
  const isManual = p.kind === 'manual', isOnline = p.kind === 'online';
  const secretsList = listOf(p.secrets);
  const field = (s) => {
    const v = state.fields[s.key] || '';
    if (s.type === 'select') return `<label>${esc(s.label)} <select name="f:${esc(s.key)}">${(s.options || []).map((o) => `<option value="${esc(o)}" ${o === v ? 'selected' : ''}>${esc(o)}</option>`).join('')}</select></label>`;
    if (s.type === 'textarea') return `<label>${esc(s.label)} <textarea name="f:${esc(s.key)}">${esc(v)}</textarea></label>`;
    return `<label>${esc(s.label)} <input name="f:${esc(s.key)}" value="${esc(v)}" placeholder="${esc(s.placeholder || '')}"></label>`;
  };
  const picker = (name, selected, options, fmt) => `<div class="ph-pick" data-pick="${name}">
    <div class="ph-pick-chips">${selected.map((c) => `<span class="ph-chip">${esc(fmt(c))}<button type="button" data-del="${esc(c)}" aria-label="Remove">×</button></span>`).join('') || '<span class="ad-muted" style="font-size:12.5px">None selected</span>'}</div>
    <input list="${name}-list" placeholder="Type to add…" autocomplete="off"><datalist id="${name}-list">${options.filter((o) => !selected.includes(o)).map((o) => `<option value="${esc(o)}">${esc(fmt(o))}</option>`).join('')}</datalist>
    <button type="button" class="btn btn-line btn-xs" data-all>${selected.length === options.length ? 'Clear all' : 'Select all'}</button></div>`;
  const dest = listOf(d.destinations).filter((x) => x.active);
  const caps = listOf(p.capabilities);
  const render = () => {
    host.innerHTML = `<form class="ph-editor ad-form" ${manage ? '' : 'style="pointer-events:none;opacity:.75"'}>
      <div class="ph-ed-head"><b>${esc(p.display_name)}</b><span class="ad-muted" style="font-size:12.5px">${esc(p.channel_label || '')} · ${esc(READY_LABEL[p.readiness] || p.readiness)}</span></div>
      <div class="ph-group"><div class="ph-group-t">General</div>
        <label class="ph-inline"><input type="checkbox" name="enabled" ${state.enabled ? 'checked' : ''}> Active (offered to clients where countries and currencies match)</label>
        ${isManual || (isOnline && key !== 'stripe') ? `<label>Settlement currency <input name="currency" value="${esc(state.currency)}" maxlength="3" placeholder="AED"></label>` : ''}
        ${p.notes ? `<p class="ad-note">${esc(p.notes)}</p>` : ''}</div>
      <div class="ph-group"><div class="ph-group-t">Markets</div>
        <p class="ad-muted" style="font-size:12.5px;margin:0 0 6px">Countries served${provCountries ? ` (the provider covers ${provCountries.map(countryName).map(esc).join(', ')})` : ' (the provider has no country restriction)'}</p>
        ${picker('countries', state.countries, countryOptions, countryName)}
        <p class="ad-muted" style="font-size:12.5px;margin:10px 0 6px">Currencies enabled${provCurrencies ? ` (the provider supports ${esc(provCurrencies.join(', '))})` : ' (the provider has no currency restriction)'}</p>
        ${picker('currencies', state.currencies, currencyOptions, (c) => c)}</div>
      <div class="ph-group"><div class="ph-group-t">Payment types</div>
        <label class="ph-inline"><input type="checkbox" name="intents_all" ${state.intents === null ? 'checked' : ''}> Every type the provider supports</label>
        <div class="ph-intents" ${state.intents === null ? 'hidden' : ''}>${listOf(d.intents).map((i) => `<label class="ph-inline"><input type="checkbox" name="intent" value="${i}" ${state.intents && state.intents.includes(i) ? 'checked' : ''} ${p.intents && !p.intents.includes(i) ? 'disabled' : ''}> ${esc(INTENT_LABEL[i] || i)}</label>`).join('')}</div></div>
      ${schema.some((s) => s.public) ? `<div class="ph-group"><div class="ph-group-t">Customer experience</div><p class="ad-muted" style="font-size:12.5px;margin:0 0 6px">Shown to the client on the payment page.</p><div class="row">${schema.filter((s) => s.public).map(field).join('')}</div></div>` : ''}
      <div class="ph-group"><div class="ph-group-t">Settlement</div>
        ${state.currencies.length ? `<div class="row">${state.currencies.map((c) => `<label>${esc(c)} settles to <select name="settle:${esc(c)}"><option value="">— not set —</option>${dest.filter((x) => x.currency === c).map((x) => `<option value="${esc(x.key)}" ${state.settlement[c] === x.key ? 'selected' : ''}>${esc(x.label)}</option>`).join('')}</select></label>`).join('')}</div>` : '<p class="ad-muted" style="font-size:12.5px">Enable currencies first.</p>'}
        <p class="ad-note">Destinations (bank accounts, PSP balances) are managed in BEAU PH › Rails › Settlement destinations. A method and where its money lands stay distinct.</p></div>
      <div class="ph-group"><div class="ph-group-t">Limits</div>
        ${state.currencies.length ? `<div class="row">${state.currencies.map((c) => `<label>${esc(c)} minimum <input name="min:${esc(c)}" type="number" min="0" step="0.01" value="${state.limits[c] && state.limits[c].min != null ? (state.limits[c].min / 100).toFixed(2) : ''}"></label><label>${esc(c)} maximum <input name="max:${esc(c)}" type="number" min="0" step="0.01" value="${state.limits[c] && state.limits[c].max != null ? (state.limits[c].max / 100).toFixed(2) : ''}"></label>`).join('')}</div>` : '<p class="ad-muted" style="font-size:12.5px">Enable currencies first.</p>'}</div>
      ${schema.some((s) => !s.public) || secretsList.length ? `<div class="ph-group"><div class="ph-group-t">Provider configuration</div>
        ${schema.some((s) => !s.public) ? `<div class="row">${schema.filter((s) => !s.public).map(field).join('')}</div>` : ''}
        ${secretsList.length ? `<p class="ad-muted" style="font-size:12.5px;margin:8px 0 4px">Deployment secrets (names only; values are set in the deployment, never here)</p><div class="ph-secrets">${secretsList.map((n) => `<span class="ph-chip">${esc(n)} ${runtime && runtime.secrets ? (runtime.secrets[n] ? '<i class="ok">present</i>' : '<i class="miss">missing</i>') : '<i>checked in BEAU PH › Rails</i>'}</span>`).join('')}</div>` : ''}
        ${p.onboarding ? `<p class="ad-note">${esc(p.onboarding)}</p>` : ''}</div>` : ''}
      <details class="ph-group ph-adv"><summary class="ph-group-t">Advanced</summary>
        <label class="ph-inline"><input type="checkbox" name="caps_all" ${state.capabilities === null ? 'checked' : ''}> Every capability the provider offers</label>
        <div class="ph-intents" ${state.capabilities === null ? 'hidden' : ''}>${caps.map((c) => `<label class="ph-inline"><input type="checkbox" name="cap" value="${esc(c.capability)}" ${state.capabilities && state.capabilities.includes(c.capability) ? 'checked' : ''}> ${esc(c.capability.replace(/_/g, ' '))} <span class="ad-muted">(${esc(READY_LABEL[c.readiness] || c.readiness)})</span></label>`).join('')}</div>
        <p class="ad-note">Narrowing only: a merchant can never broaden what a provider technically supports.</p></details>
      ${manage ? `<div class="actions"><button class="btn btn-accent btn-sm" type="submit">Save changes</button><button class="btn btn-line btn-sm" type="button" data-cancel>Cancel</button></div>` : '<p class="ad-note">View only. Editing needs the finance:manage permission.</p>'}
    </form>`;
    const form = host.querySelector('form');
    const syncScalars = () => {
      state.enabled = form.enabled.checked;
      if (form.currency) state.currency = form.currency.value.trim().toUpperCase();
      state.intents = form.intents_all.checked ? null : [...form.querySelectorAll('[name=intent]:checked')].map((x) => x.value);
      state.capabilities = form.caps_all.checked ? null : [...form.querySelectorAll('[name=cap]:checked')].map((x) => x.value);
      for (const s of schema) { const el = form.elements['f:' + s.key]; if (el) state.fields[s.key] = el.value.trim(); }
      for (const c of state.currencies) {
        const sel = form.elements['settle:' + c]; if (sel) { if (sel.value) state.settlement[c] = sel.value; else delete state.settlement[c]; }
        const mn = form.elements['min:' + c], mx = form.elements['max:' + c];
        const lim = {}; if (mn && mn.value !== '') lim.min = Math.round(Number(mn.value) * 100); if (mx && mx.value !== '') lim.max = Math.round(Number(mx.value) * 100);
        if (Object.keys(lim).length) state.limits[c] = lim; else delete state.limits[c];
      }
      for (const c of Object.keys(state.settlement)) if (!state.currencies.includes(c)) delete state.settlement[c];
      for (const c of Object.keys(state.limits)) if (!state.currencies.includes(c)) delete state.limits[c];
    };
    form.intents_all.onchange = () => { form.querySelector('.ph-intents').hidden = form.intents_all.checked; };
    form.caps_all.onchange = () => { form.querySelectorAll('.ph-intents')[1].hidden = form.caps_all.checked; };
    form.querySelectorAll('[data-pick]').forEach((pk) => {
      const name = pk.dataset.pick, arr = state[name], options = name === 'countries' ? countryOptions : currencyOptions;
      const input = pk.querySelector('input');
      const add = () => { const v = input.value.trim().toUpperCase(); if (!v) return; if (!options.includes(v)) { C.toast(name === 'countries' ? 'Not a country this provider can serve' : 'Not a currency this provider supports', true); input.value = ''; return; } if (!arr.includes(v)) arr.push(v); arr.sort(); syncScalars(); render(); };
      input.onchange = add; input.onkeydown = (e) => { if (e.key === 'Enter') { e.preventDefault(); add(); } };
      pk.querySelectorAll('[data-del]').forEach((b) => b.onclick = () => { const i = arr.indexOf(b.dataset.del); if (i >= 0) arr.splice(i, 1); syncScalars(); render(); });
      pk.querySelector('[data-all]').onclick = () => { syncScalars(); state[name] = arr.length === options.length ? [] : [...options]; render(); };
    });
    const cancel = host.querySelector('[data-cancel]');
    if (cancel) cancel.onclick = () => { host.hidden = true; host.innerHTML = ''; if (onClose) onClose(); };
    form.onsubmit = async (e) => {
      e.preventDefault(); syncScalars();
      const diff = summarizeDiff(original, state, schema);
      if (!diff.length) { C.toast('No change to save'); return; }
      const ok = await modal({ title: 'Confirm changes', confirm: 'Confirm changes', body: `<p class="ad-muted" style="font-size:13px">Changing payment configuration affects what clients are offered. Review, then confirm.</p><dl class="ph-diff">${diff.map(([k, a, b]) => `<dt>${esc(k)}</dt><dd><span class="old">${esc(a)}</span> → <span class="new">${esc(b)}</span></dd>`).join('')}</dl>` });
      if (!ok) return;
      const payload = { method: key, enabled: state.enabled, countries: state.countries, currencies: state.currencies, intents: state.intents, limits: state.limits, settlement: state.settlement, capabilities: state.capabilities, fields: state.fields };
      if (form.currency) payload.currency = state.currency;
      try { await write('payment_method_set', { p: payload }); }
      catch (err) { return C.fail(err); }
      invalidate('payment_methods_summary', 'payment_method_get', 'beau_ph_rails', 'beau_ph_config_audit');
      host.hidden = true; host.innerHTML = ''; C.toast('Saved. ' + (state.enabled ? 'Clients see the change immediately.' : 'The method stays off until you enable it.'));
      if (onClose) onClose('saved');
    };
  };
  render();
}
function summarizeDiff(a, b, schema) {
  const out = [];
  const lst = (x) => x === null ? 'all' : (x && x.length ? x.join(', ') : 'none');
  if (a.enabled !== b.enabled) out.push(['Status', a.enabled ? 'Active' : 'Inactive', b.enabled ? 'Active' : 'Inactive']);
  if ((a.currency || '') !== (b.currency || '')) out.push(['Settlement currency', a.currency || '—', b.currency || '—']);
  if (lst(a.countries) !== lst(b.countries)) out.push(['Countries', lst(a.countries) === 'none' ? 'needs configuration' : lst(a.countries), lst(b.countries) === 'none' ? 'needs configuration' : lst(b.countries)]);
  if (lst(a.currencies) !== lst(b.currencies)) out.push(['Currencies', lst(a.currencies) === 'none' ? 'needs configuration' : lst(a.currencies), lst(b.currencies) === 'none' ? 'needs configuration' : lst(b.currencies)]);
  if (lst(a.intents) !== lst(b.intents)) out.push(['Payment types', lst(a.intents), lst(b.intents)]);
  if (lst(a.capabilities) !== lst(b.capabilities)) out.push(['Capabilities', lst(a.capabilities), lst(b.capabilities)]);
  if (JSON.stringify(a.limits) !== JSON.stringify(b.limits)) out.push(['Limits', JSON.stringify(a.limits), JSON.stringify(b.limits)]);
  if (JSON.stringify(a.settlement) !== JSON.stringify(b.settlement)) out.push(['Settlement', Object.entries(a.settlement).map(([c, k]) => `${c} → ${k}`).join(', ') || 'not set', Object.entries(b.settlement).map(([c, k]) => `${c} → ${k}`).join(', ') || 'not set']);
  for (const s of schema) if ((a.fields[s.key] || '') !== (b.fields[s.key] || '')) out.push([s.label, s.mask ? mask(a.fields[s.key]) : (a.fields[s.key] || '—'), s.mask ? mask(b.fields[s.key]) : (b.fields[s.key] || '—')]);
  return out;
}
const mask = (v) => v ? '•••• ' + String(v).slice(-4) : '—';

/* =============================== BEAU PH · RAILS =============================== */
const railFilters = { country: '', currency: '', status: '', channel: '' };
let runtimeCache = null;   // one probe per admin session: presence of secrets per rail, never values
async function runtimeProbe() {
  if (runtimeCache) return runtimeCache;
  try {
    const { data: { session } } = await C.sb.auth.getSession();
    if (!session) return null;
    const r = await fetch(`${C.config.SUPABASE_URL}/functions/v1/ph-admin`, { method: 'POST', headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${session.access_token}` }, body: JSON.stringify({ action: 'runtime' }) });
    const j = await r.json().catch(() => null);
    if (!r.ok || !j || !j.ok) return null;
    runtimeCache = j; return j;
  } catch { return null; }
}
function railStatus(r, rt) {
  const m = r.merchant;
  if (r.readiness === 'placeholder') return { key: 'coming_soon', label: 'Coming soon' };
  const anyAvailable = listOf(r.capabilities).some((c) => c.readiness === 'available');
  if (!anyAvailable) return { key: 'not_onboarded', label: 'Not onboarded' };
  if (!m || !m.listed) return { key: 'not_added', label: 'Not added' };
  if (m.health === 'needs_configuration') return { key: 'needs_setup', label: 'Needs setup' };
  if (m.enabled) return { key: 'active', label: 'Active' };
  return { key: 'configured', label: 'Configured' };
}
export async function phRails() {
  const { $, esc, view, has } = C;
  const manage = has('finance:manage');
  const [ov, rt] = await Promise.all([rpc('beau_ph_rails'), runtimeProbe()]);
  const rails = ov.rails;
  const allCountries = [...new Set(rails.flatMap((r) => listOf(r.provider_countries).concat(listOf(r.merchant && r.merchant.countries))))].sort();
  const allCurrencies = [...new Set(rails.flatMap((r) => listOf(r.provider_currencies).concat(listOf(r.merchant && r.merchant.currencies))))].sort();
  const channels = [...new Set(rails.map((r) => (r.channel_label || '').split('·')[0].trim()).filter(Boolean))];
  const f = railFilters;
  const shown = rails.filter((r) => {
    const s = railStatus(r, rt && rt.providers && rt.providers[r.provider]);
    if (f.status && s.key !== f.status) return false;
    if (f.channel && !(r.channel_label || '').startsWith(f.channel)) return false;
    if (f.country && !(r.provider_countries === null || listOf(r.provider_countries).includes(f.country)) ) return false;
    if (f.currency && !(r.provider_currencies === null || listOf(r.provider_currencies).includes(f.currency))) return false;
    return true;
  });
  view.innerHTML = `
    <div class="ad-head"><div><h1>Rails</h1><p class="ad-muted">Every rail BEAU PH knows. <b>Provider capability</b> is what a rail can technically do; <b>merchant configuration</b> is what Coach Gari chose; what a client is offered is the intersection with the payment context, decided server-side. Merchant: ${esc(ov.merchant.name)} · ${esc(ov.merchant.country)} · ${esc(ov.merchant.default_currency)} · <b>${esc(String(ov.merchant.mode).toUpperCase())}</b>${rt ? ` · deployment mode <b>${esc(String(rt.mode || 'unset').toUpperCase())}</b>` : ' · <i>runtime check unavailable</i>'}</p></div></div>
    <div class="ad-filters" style="margin-bottom:14px">
      <select id="rf-status"><option value="">Any status</option>${[['active', 'Active'], ['configured', 'Configured'], ['needs_setup', 'Needs setup'], ['not_added', 'Not added'], ['not_onboarded', 'Not onboarded'], ['coming_soon', 'Coming soon']].map(([k, l]) => `<option value="${k}" ${f.status === k ? 'selected' : ''}>${l}</option>`).join('')}</select>
      <select id="rf-channel"><option value="">Any channel</option>${channels.map((c) => `<option ${f.channel === c ? 'selected' : ''}>${esc(c)}</option>`).join('')}</select>
      <select id="rf-country"><option value="">Any country</option>${allCountries.map((c) => `<option value="${c}" ${f.country === c ? 'selected' : ''}>${esc(countryName(c))}</option>`).join('')}</select>
      <select id="rf-currency"><option value="">Any currency</option>${allCurrencies.map((c) => `<option ${f.currency === c ? 'selected' : ''}>${c}</option>`).join('')}</select>
      <span class="ad-muted" style="font-size:12.5px">${shown.length} of ${rails.length}</span>
    </div>
    <div class="ph-cards">${shown.map((r) => railCard(r, rt && rt.providers ? rt.providers[r.provider] : null, manage)).join('')}</div>
    <details class="ad-panel ph-details" id="rails-dest"><summary>Settlement destinations</summary><div id="rails-dest-body"><p class="ad-empty">Loading…</p></div></details>
    <details class="ad-panel ph-details" id="rails-audit"><summary>Configuration audit trail</summary><div id="rails-audit-body"><p class="ad-empty">Loading…</p></div></details>`;
  for (const id of ['status', 'channel', 'country', 'currency']) $(`#rf-${id}`).onchange = () => { railFilters[id] = $(`#rf-${id}`).value; phRails().catch(C.fail); };
  view.querySelectorAll('.ph-card').forEach((card) => {
    const key = card.dataset.rail; const rail = rails.find((r) => r.provider === key); const rtp = rt && rt.providers ? rt.providers[key] : null;
    const ed = card.querySelector('[data-editor]');
    card.querySelector('[data-configure]')?.addEventListener('click', () => openEditor(ed, key, { mode: 'rails', manage, runtime: rtp, onClose: (why) => { if (why === 'saved') phRails().catch(C.fail); } }));
    card.querySelector('[data-test]')?.addEventListener('click', () => railTest(card.querySelector('[data-out]'), rail, rtp));
    card.querySelector('[data-toggle]')?.addEventListener('click', () => railToggle(rail));
    card.querySelector('[data-onboard]')?.addEventListener('click', () => railOnboard(card.querySelector('[data-out]'), rail, rtp, manage));
    card.querySelector('[data-add]')?.addEventListener('click', async () => { try { await write('payment_method_add', { p_provider: key }); invalidate('beau_ph_rails', 'payment_methods_summary', 'payment_method_get'); C.toast('Added to Coach Gari. Configure it, then enable it.'); await phRails(); C.view.querySelector(`.ph-card[data-rail="${key}"] [data-configure]`)?.click(); } catch (e) { C.fail(e); } });
  });
  let destLoaded = false, auditLoaded = false;
  $('#rails-dest').addEventListener('toggle', () => { if ($('#rails-dest').open && !destLoaded) { destLoaded = true; destinationsPanel($('#rails-dest-body'), manage).catch(C.fail); } });
  $('#rails-audit').addEventListener('toggle', () => { if ($('#rails-audit').open && !auditLoaded) { auditLoaded = true; auditPanel($('#rails-audit-body')).catch(C.fail); } });
}
function railCard(r, rtp, manage) {
  const { esc } = C;
  const s = railStatus(r, rtp); const m = r.merchant;
  const secrets = listOf(r.secrets);
  const tick = (v) => v === true ? '<i class="ph-tick ok">✓</i>' : v === false ? '<i class="ph-tick miss">Missing</i>' : '<i class="ph-tick na">n/a</i>';
  const credentials = !secrets.length ? null : (rtp && rtp.secrets ? secrets.filter((n) => n !== 'STRIPE_WEBHOOK_SECRET').every((n) => rtp.secrets[n]) : undefined);
  const webhook = r.provider === 'stripe' ? (rtp && rtp.secrets ? !!rtp.secrets.STRIPE_WEBHOOK_SECRET : undefined) : (r.confirmation === 'operator' ? null : undefined);
  const modeBadge = r.kind === 'online' && s.key === 'active' && rtp && rtp.mode ? `<span class="ph-mode ${rtp.configured ? 'ok' : 'warn'}">${esc(runtimeMode(rtp))}${rtp.configured ? '' : ' · ' + esc(rtp.reason || 'not configured')}</span>` : '';
  const cap = (c) => `<span class="ph-chip ${c.readiness === 'available' ? 'ok' : ''}" title="${esc(c.notes || '')}">${esc(c.capability.replace(/_/g, ' '))}${c.handoff ? ' · app' : ''}${c.readiness !== 'available' ? ' · ' + esc(READY_LABEL[c.readiness] || c.readiness) : ''}</span>`;
  const last = r.activity.last_event_at || r.activity.last_paid_at;
  return `<div class="ph-card st-${s.key}" data-rail="${esc(r.provider)}">
    <div class="ph-card-h"><div><b>${esc(r.display_name)}</b><div class="ad-muted" style="font-size:12.5px">${esc(r.channel_label || '')}</div></div><div class="ph-card-badges"><span class="ph-status ${s.key}">${esc(s.label)}</span>${modeBadge}</div></div>
    <div class="ph-card-grid">
      <div><div class="ph-k">Provider coverage</div><div>${r.provider_countries ? chips(r.provider_countries, countryName, 4) : '<span class="ad-muted">Any country</span>'} ${r.provider_currencies ? chips(r.provider_currencies, (c) => c, 4) : '<span class="ad-muted">· any currency</span>'}</div></div>
      <div><div class="ph-k">Merchant enabled</div><div>${m && m.listed ? (listOf(m.countries).length ? chips(m.countries, countryName, 4) : '<span class="ad-badge-warn">Countries: needs configuration</span>') : '<span class="ad-muted">Not added</span>'}</div></div>
      <div><div class="ph-k">Currencies</div><div>${m && m.listed ? (listOf(m.currencies).length ? chips(m.currencies, (c) => c, 6) : '<span class="ad-badge-warn">Needs configuration</span>') : '<span class="ad-muted">—</span>'}</div></div>
      <div><div class="ph-k">Capabilities</div><div>${listOf(r.capabilities).map(cap).join(' ')}</div></div>
    </div>
    <div class="ph-check">
      <div><span>Credentials</span>${credentials === null ? '<i class="ph-tick na">none needed</i>' : tick(credentials)}</div>
      <div><span>${r.provider === 'stripe' ? 'Webhook' : 'Confirmation'}</span>${r.provider === 'stripe' ? tick(webhook) : (r.confirmation === 'operator' ? '<i class="ph-tick ok">operator</i>' : tick(undefined))}</div>
      <div><span>Merchant config</span>${m && m.listed ? tick(m.health === 'configured') : '<i class="ph-tick na">not added</i>'}</div>
      <div><span>Last activity</span><i class="ph-tick ${last ? 'ok' : 'na'}">${last ? esc(when(last)) : 'none'}</i></div>
    </div>
    <div class="ph-card-a">
      ${s.key === 'coming_soon' ? '<span class="ad-muted" style="font-size:12.5px">Reserved. Nothing to configure yet.</span>' : ''}
      ${s.key === 'not_onboarded' ? `<button class="btn btn-line btn-xs" data-onboard>Start onboarding</button>` : ''}
      ${s.key === 'not_added' && manage ? `<button class="btn btn-accent btn-xs" data-add>Add to Coach Gari</button>` : ''}
      ${['active', 'configured', 'needs_setup'].includes(s.key) ? `<button class="btn btn-line btn-xs" data-configure>${manage ? 'Configure' : 'View'}</button><button class="btn btn-line btn-xs" data-test>Test</button>` : ''}
      ${['active', 'configured'].includes(s.key) && manage ? `<button class="btn ${s.key === 'active' ? 'btn-line' : 'btn-accent'} btn-xs" data-toggle>${s.key === 'active' ? 'Disable' : 'Enable'}</button>` : ''}
      ${s.key !== 'coming_soon' && s.key !== 'not_onboarded' && !['active', 'configured', 'needs_setup'].includes(s.key) ? `<button class="btn btn-line btn-xs" data-onboard>Details</button>` : ''}
    </div>
    <div class="ph-card-out" data-out hidden></div>
    <div class="ph-row-editor" data-editor hidden></div>
  </div>`;
}
async function railTest(out, r, rtp) {
  const { esc, st } = C;
  out.hidden = false; out.innerHTML = '<p class="ad-empty">Checking…</p>';
  const lines = [];
  if (r.provider === 'stripe') {
    if (!rtp) lines.push('Runtime check unavailable (the helper did not answer).');
    else lines.push(`Deployment: ${rtp.configured ? 'configured' : 'NOT configured'}${rtp.mode ? ` · mode ${String(rtp.mode).toUpperCase()}` : ''}${rtp.embedded ? ' · embedded checkout ready' : ''}${rtp.reason ? ` · ${rtp.reason}` : ''}`);
  } else if (r.confirmation === 'operator') lines.push('Manual rail: nothing to call. A payment is confirmed by an authorised operator from the client\'s package.');
  else lines.push(rtp ? `Deployment: ${rtp.configured ? 'configured' : 'not configured'}${rtp.reason ? ` · ${rtp.reason}` : ''}` : 'Runtime check unavailable.');
  let events = [];
  try { events = await rpc('beau_ph_rail_events', { p_provider: r.provider, p_limit: 12 }, { fresh: true }); } catch (e) { lines.push(`Events: ${e.message}`); }
  out.innerHTML = `<p style="font-size:13px;margin:0 0 8px">${lines.map(esc).join('<br>')}</p>
    ${events.length ? `<div class="ad-table-wrap"><table class="ad-table"><thead><tr><th>Received</th><th>Event</th><th>Outcome</th><th>Ref</th></tr></thead><tbody>${events.map((e) => `<tr><td>${when(e.received_at, { dateStyle: 'medium', timeStyle: 'medium' })}</td><td>${esc(e.type)}<div class="msg" style="font-size:11.5px">${esc(e.id)}</div></td><td>${st(String(e.outcome || '').split(':')[0] || 'pending')}${String(e.outcome || '').includes(':') ? `<div class="msg" style="font-size:11.5px">${esc(e.outcome)}</div>` : ''}</td><td>${esc(e.public_reference || '—')}</td></tr>`).join('')}</tbody></table></div>` : '<p class="ad-muted" style="font-size:12.5px">No provider event recorded for this rail yet.</p>'}
    <div class="actions" style="margin-top:8px"><button class="btn btn-line btn-xs" data-close>Close</button></div>`;
  out.querySelector('[data-close]').onclick = () => { out.hidden = true; out.innerHTML = ''; };
}
async function railToggle(r) {
  const { esc } = C;
  const on = !(r.merchant && r.merchant.enabled);
  const ok = await modal({ title: `${on ? 'Enable' : 'Disable'} ${r.display_name}?`, confirm: on ? 'Enable' : 'Disable', danger: !on,
    body: on ? `<p>Clients in ${esc(listOf(r.merchant.countries).map(countryName).join(', ') || 'the configured countries')} paying in ${esc(listOf(r.merchant.currencies).join(', '))} will be offered ${esc(r.display_name)}.</p>` : `<p>Customers will no longer be offered ${esc(r.display_name)}. Existing transactions are preserved and the configuration is kept.</p>` });
  if (!ok) return;
  try { await write('payment_method_set', { p: { method: r.provider, enabled: on } }); invalidate('beau_ph_rails', 'payment_methods_summary', 'payment_method_get', 'beau_ph_config_audit'); C.toast(on ? 'Enabled' : 'Disabled'); phRails().catch(C.fail); }
  catch (e) { C.fail(e); }
}
function railOnboard(out, r, rtp, manage) {
  const { esc } = C;
  out.hidden = false;
  const secrets = listOf(r.secrets);
  out.innerHTML = `<p style="font-size:13px;margin:0 0 6px"><b>Provider capability known</b> ✓ · <b>Merchant onboarding</b> ${r.readiness === 'available' ? '✓' : 'Missing'} · <b>Credentials</b> ${secrets.length ? (rtp && rtp.secrets && secrets.every((n) => rtp.secrets[n]) ? '✓' : 'Missing') : 'none needed'}</p>
    <p class="ad-muted" style="font-size:13px;margin:0 0 6px">${esc(r.onboarding || r.notes || '')}</p>
    ${secrets.length ? `<p class="ad-muted" style="font-size:12.5px;margin:0 0 6px">Deployment secrets to set (names only): ${secrets.map((n) => `<span class="ph-chip">${esc(n)}${rtp && rtp.secrets ? (rtp.secrets[n] ? ' <i class="ok">present</i>' : ' <i class="miss">missing</i>') : ''}</span>`).join(' ')}</p>` : ''}
    <p class="ad-note">Onboarding a provider is a separate, deliberate step (merchant account, keys, callback). Nothing here fakes readiness: the rail stays "not onboarded" until its adapter is implemented and its readiness flag is set in BEAU PH.</p>
    <div class="actions" style="margin-top:8px"><button class="btn btn-line btn-xs" data-close>Close</button></div>`;
  out.querySelector('[data-close]').onclick = () => { out.hidden = true; out.innerHTML = ''; };
}
async function destinationsPanel(host, manage) {
  const { esc } = C;
  const list = await rpc('beau_ph_settlement_destinations', {}, { fresh: true });
  host.innerHTML = `<p class="ad-muted" style="font-size:13px;margin:0 0 10px">Where money lands, per currency: a bank account, a PSP balance, a wallet. A rail maps each of its currencies to one destination (in the rail's Settlement group). Details here are labels only, never credentials.</p>
    ${C.table(['Key', 'Label', 'Kind', 'Currency', 'Details', 'Used by', 'Active', ''], list.map((d) => `<tr><td><code>${esc(d.key)}</code></td><td>${esc(d.label)}</td><td>${esc(d.kind.replace('_', ' '))}</td><td>${esc(d.currency)}</td><td class="ad-muted" style="font-size:12.5px">${esc(Object.entries(d.details || {}).map(([k, v]) => `${k}: ${v}`).join(' · '))}</td><td>${esc(listOf(d.used_by).join(', ') || '—')}</td><td>${d.active ? 'Yes' : 'No'}</td><td class="acts">${manage ? `<button class="btn btn-line btn-xs" data-rm="${esc(d.key)}">Remove</button>` : ''}</td></tr>`), 'No settlement destination yet.')}
    ${manage ? `<form class="ad-form" id="dest-form" style="margin-top:14px"><div class="row"><label>Key <input name="key" required pattern="[a-z][a-z0-9_]{1,40}" placeholder="uae_aed_account"></label><label>Label <input name="label" required placeholder="UAE AED account"></label>
      <label>Kind <select name="kind"><option value="bank_account">Bank account</option><option value="psp_balance">PSP balance</option><option value="wallet">Wallet</option><option value="other">Other</option></select></label><label>Currency <input name="currency" required maxlength="3" placeholder="AED"></label></div>
      <div class="row"><label>Bank or provider (label only) <input name="bank"></label><label>Account hint (last digits only) <input name="hint" maxlength="8" placeholder="•••• 1234"></label></div>
      <div class="actions"><button class="btn btn-accent btn-sm" type="submit">Add destination</button></div></form>` : ''}`;
  host.querySelectorAll('[data-rm]').forEach((b) => b.onclick = async () => {
    if (!(await modal({ title: `Remove destination ${b.dataset.rm}?`, danger: true, confirm: 'Remove', body: '<p>A destination still mapped by a rail is deactivated rather than deleted.</p>' }))) return;
    try { await write('beau_ph_settlement_destination_remove', { p_key: b.dataset.rm }); C.toast('Removed'); destinationsPanel(host, manage); } catch (e) { C.fail(e); }
  });
  const form = host.querySelector('#dest-form');
  if (form) form.onsubmit = async (e) => {
    e.preventDefault(); const f = new FormData(form);
    const details = {}; if (f.get('bank')) details.bank = f.get('bank'); if (f.get('hint')) details.account_hint = f.get('hint');
    const ok = await modal({ title: 'Add settlement destination', confirm: 'Add', body: `<p>${esc(f.get('label'))} · ${esc(String(f.get('currency')).toUpperCase())} · ${esc(f.get('kind'))}</p>` });
    if (!ok) return;
    try { await write('beau_ph_settlement_destination_set', { p: { key: f.get('key'), label: f.get('label'), kind: f.get('kind'), currency: String(f.get('currency')).toUpperCase(), details } }); invalidate('payment_method_get'); C.toast('Destination added'); destinationsPanel(host, manage); } catch (err) { C.fail(err); }
  };
}
async function auditPanel(host) {
  const { esc } = C;
  const rows = await rpc('beau_ph_config_audit', { p_limit: 100 }, { fresh: true });
  const v = (x) => x === null || x === undefined ? '—' : typeof x === 'string' ? x : JSON.stringify(x);
  host.innerHTML = C.table(['When', 'Who', 'Area', 'Entity', 'Field', 'Before', 'After'], rows.map((a) => `<tr><td>${when(a.changed_at, { dateStyle: 'medium', timeStyle: 'short' })}</td><td>${esc(a.actor)}</td><td>${esc(a.area.replace(/_/g, ' '))}</td><td>${esc(a.entity)}</td><td>${esc(a.field)}</td><td class="msg">${esc(v(a.old_value))}</td><td class="msg">${esc(v(a.new_value))}</td></tr>`), 'No configuration change recorded yet.');
}

/* =============================== BEAU PH · FX =============================== */
export async function phFx() {
  const { $, esc, view, has } = C;
  const manage = has('finance:manage');
  const fx = await rpc('beau_ph_fx', {}, { ttl: 20_000 });
  const h = fx.health || {}, s = fx.settings || {};
  const fresh = (lvl) => `<span class="ph-fresh ${esc(lvl)}">${esc({ fresh: 'Fresh', acceptable: 'Acceptable', stale: 'Stale', missing: 'No rate' }[lvl] || lvl)}</span>`;
  view.innerHTML = `
    <div class="ad-head"><div><h1>FX</h1><p class="ad-muted">BEAU FX: reference rates against EUR (ECB via Frankfurter, USD pegs derived), refreshed daily inside the database and validated before use (positive, within 20 % of the last known rate, per-source isolation). A stale or missing rate never converts a payment: the client is offered the pricing currency instead. Quotes are immutable and expire.</p></div>
      ${manage ? `<div class="cg-actions"><button class="btn btn-accent btn-sm" id="fx-refresh" ${h.in_progress ? 'disabled' : ''}>${h.in_progress ? 'Refreshing…' : 'Refresh now'}</button></div>` : ''}</div>
    <div class="ad-kpis">
      <div class="ad-kpi"><b>${h.last_refresh_at ? esc(when(h.last_refresh_at)) : '—'}</b><span>Last refresh${h.last_refresh_status ? ` · ${esc(h.last_refresh_status)}` : ''}${h.last_rate_date ? ` · rates of ${esc(h.last_rate_date)}` : ''}</span></div>
      <div class="ad-kpi"><b>${h.fresh || 0}</b><span>Fresh (≤ 36 h)</span></div>
      <div class="ad-kpi"><b>${h.acceptable || 0}</b><span>Acceptable (36 to 72 h)</span></div>
      <div class="ad-kpi"><b>${(h.stale || 0) + (h.missing || 0)}</b><span>Stale or missing</span></div>
      <div class="ad-kpi"><b>${listOf(h.rejected).length}</b><span>Rejected anomalies (last run)</span></div>
    </div>
    <div class="ad-panel"><h2>Currencies</h2>
      ${C.table(['Currency', 'Reference rate (per 1 EUR)', 'Source', 'Rate date', 'Updated', 'Freshness', 'Status', ''], listOf(fx.currencies).map((c) => `<tr class="${c.enabled ? '' : 'ph-dim'}">
        <td><b>${esc(c.currency)}</b>${c.peg_currency ? `<div class="msg" style="font-size:11.5px">${esc(c.peg_currency)} × ${esc(String(c.peg_rate))}</div>` : ''}</td>
        <td class="num">${c.rate != null ? esc(Number(c.rate).toFixed(4)) : '—'}</td>
        <td>${esc(c.source_kind === 'peg' ? `USD peg` : (c.source || '—'))}${c.rate_source && c.rate_source !== c.source ? `<div class="msg" style="font-size:11.5px">${esc(c.rate_source)}</div>` : ''}</td>
        <td>${esc(c.rate_date || '—')}</td><td>${c.fetched_at ? esc(when(c.fetched_at)) : '—'}</td>
        <td>${c.enabled ? fresh(c.freshness) : '<span class="ad-muted">—</span>'}</td>
        <td>${c.enabled ? '<span class="ad-badge-ok">Enabled</span>' : '<span class="ad-muted">Disabled</span>'}${c.notes && !c.enabled ? `<div class="msg" style="font-size:11.5px">${esc(c.notes)}</div>` : ''}</td>
        <td class="acts">${manage ? `<button class="btn btn-line btn-xs" data-ccy="${esc(c.currency)}" data-on="${c.enabled ? '0' : '1'}" ${!c.source ? 'disabled title="No source configured"' : ''}>${c.enabled ? 'Disable' : 'Enable'}</button>` : ''}</td></tr>`), 'No currency configured.')}
      ${listOf(h.rejected).length ? `<p class="ad-msg err" style="font-size:13px">Rejected in the last run: ${listOf(h.rejected).map((r) => `${esc(r.currency)} (${esc(r.reason)})`).join(', ')}. The last valid rate stays in place.</p>` : ''}
      ${Object.keys(h.source_errors || {}).length ? `<p class="ad-msg err" style="font-size:13px">Source errors: ${Object.entries(h.source_errors).map(([k, v]) => `${esc(k)}: ${esc(v)}`).join(' · ')}</p>` : ''}
    </div>
    <div class="ad-grid2">
      <div class="ad-panel"><h2>Merchant FX settings</h2>
        <form id="fx-form" class="ad-form" ${manage ? '' : 'style="pointer-events:none;opacity:.75"'}>
          <label class="ph-inline"><input type="checkbox" name="enabled" ${s.enabled ? 'checked' : ''}> Offer clients other payment currencies than the pricing currency</label>
          <div class="row"><label>Reporting currency <input name="reporting_currency" value="${esc(s.reporting_currency || '')}" maxlength="3"></label><label>Merchant adjustment (bps, ± 1000) <input name="adjustment_bps" type="number" min="-1000" max="1000" value="${s.adjustment_bps ?? 0}"></label></div>
          <div class="row"><label>Quote validity (minutes) <input name="quote_ttl_minutes" type="number" min="1" max="120" value="${s.quote_ttl_minutes ?? 15}"></label><label>Maximum rate age (hours) <input name="max_age_hours" type="number" min="1" max="720" value="${s.max_age_hours ?? 72}"></label></div>
          <p class="ad-note">Pricing currency = the commercial offer. Payment currency = what the client chooses. Settlement currency = what a rail receives. Reporting currency = merchant reporting. The final client rate = reference rate × (1 + adjustment); a provider's own rate, when one exists, is recorded separately on the quote.</p>
          ${manage ? '<div class="actions"><button class="btn btn-accent btn-sm" type="submit">Save changes</button></div>' : ''}
        </form></div>
      <div class="ad-panel"><h2>Calculator (indicative)</h2>
        <form id="fx-calc" class="ad-form"><div class="row"><label>Amount <input name="amount" type="number" min="0.01" step="0.01" value="100"></label><label>From <input name="from" value="USD" maxlength="3"></label><label>To <input name="to" value="AED" maxlength="3"></label></div>
          <div class="actions"><button class="btn btn-line btn-sm" type="submit">Convert</button></div><p id="fx-calc-out" class="ad-muted" style="font-size:13px"></p></form>
        <p class="ad-note">Same engine as a client quote, without creating one. Quotes: ${fx.quotes ? `${fx.quotes.active} active · ${fx.quotes.consumed_30d} used in 30 days` : '—'}.</p></div>
    </div>
    <details class="ad-panel ph-details"><summary>Refresh runs</summary>
      ${C.table(['Requested', 'By', 'Status', 'Rate date', 'Updated', 'Skipped', 'Finished', 'Notes'], listOf(fx.runs).map((r) => `<tr><td>${when(r.requested_at, { dateStyle: 'medium', timeStyle: 'short' })}</td><td>${esc(r.requested_by)}</td><td>${C.st(r.status)}</td><td>${esc(r.rate_date || '—')}</td><td class="num">${r.currencies_updated}</td><td class="num">${r.currencies_skipped}</td><td>${r.finished_at ? when(r.finished_at, { dateStyle: 'medium', timeStyle: 'short' }) : '—'}</td><td class="msg">${esc([...(listOf(r.skipped).map((x) => `${x.currency}: ${x.reason}`)), ...Object.entries(r.source_errors || {}).map(([k, v]) => `${k}: ${v}`)].join(' · '))}</td></tr>`), 'No refresh run yet.')}
    </details>
    <details class="ad-panel ph-details"><summary>Sources</summary>${C.table(['Key', 'Kind', 'URL', 'Enabled', 'Notes'], listOf(fx.sources).map((x) => `<tr><td><code>${esc(x.key)}</code></td><td>${esc(x.kind)}</td><td class="msg">${esc(x.url || '—')}</td><td>${x.enabled ? 'Yes' : 'No'}</td><td class="msg">${esc(x.notes || '')}</td></tr>`))}</details>`;
  const reload = () => { invalidate('beau_ph_fx'); phFx().catch(C.fail); };
  $('#fx-refresh')?.addEventListener('click', async () => {
    const b = $('#fx-refresh'); b.disabled = true; b.textContent = 'Refreshing…';
    try { await write('beau_ph_fx_refresh', {}); } catch (e) { b.disabled = false; b.textContent = 'Refresh now'; return C.fail(e); }
    // the minute job collects the responses; poll the collector a few times so the screen updates sooner
    for (let i = 0; i < 12; i++) {
      await new Promise((r) => setTimeout(r, 3000));
      try { const out = await write('beau_ph_fx_collect', {}); if (Array.isArray(out) && out.length) break; } catch {}
    }
    C.toast('Rates refreshed'); reload();
  });
  view.querySelectorAll('[data-ccy]').forEach((b) => b.onclick = async () => {
    const on = b.dataset.on === '1';
    if (!(await modal({ title: `${on ? 'Enable' : 'Disable'} ${b.dataset.ccy}?`, confirm: on ? 'Enable' : 'Disable', body: on ? '<p>The currency will be refreshed daily and may be offered as a payment currency by eligible rails.</p>' : '<p>The currency will no longer be refreshed or offered. Existing quotes keep their rate.</p>' }))) return;
    try { await write('beau_ph_fx_currency_set', { p_currency: b.dataset.ccy, p: { enabled: on } }); C.toast(on ? 'Enabled' : 'Disabled'); reload(); } catch (e) { C.fail(e); }
  });
  $('#fx-form').onsubmit = async (e) => {
    e.preventDefault(); const f = new FormData(e.target);
    const next = { enabled: !!f.get('enabled'), reporting_currency: String(f.get('reporting_currency') || '').toUpperCase(), adjustment_bps: Number(f.get('adjustment_bps') || 0), quote_ttl_minutes: Number(f.get('quote_ttl_minutes') || 15), max_age_hours: Number(f.get('max_age_hours') || 72) };
    const diff = Object.entries(next).filter(([k, v]) => String(s[k] ?? (k === 'enabled' ? false : '')) !== String(v));
    if (!diff.length) return C.toast('No change to save');
    const ok = await modal({ title: 'Confirm FX changes', confirm: 'Confirm changes', body: `<dl class="ph-diff">${diff.map(([k, v]) => `<dt>${esc(k.replace(/_/g, ' '))}</dt><dd><span class="old">${esc(String(s[k] ?? '—'))}</span> → <span class="new">${esc(String(v))}</span></dd>`).join('')}</dl>` });
    if (!ok) return;
    try { await write('beau_ph_fx_set', { p: next }); C.toast('FX settings saved'); reload(); } catch (err) { C.fail(err); }
  };
  $('#fx-calc').onsubmit = async (e) => {
    e.preventDefault(); const f = new FormData(e.target); const out = $('#fx-calc-out');
    try {
      const q = await write('beau_ph_fx_preview', { p_amount: Math.round(Number(f.get('amount')) * 100), p_from: String(f.get('from')).toUpperCase(), p_to: String(f.get('to')).toUpperCase() });
      out.textContent = q.same_currency ? 'Same currency: no conversion.' : `${C.money(q.pricing_amount, q.pricing_currency)} → ${C.money(q.payment_amount, q.payment_currency)} at ${Number(q.customer_rate).toFixed(6)} (reference ${Number(q.reference_rate).toFixed(6)}, ${q.source}, ${q.freshness}, rates of ${q.rate_date}).`;
    } catch (err) { out.textContent = err.message; }
  };
}

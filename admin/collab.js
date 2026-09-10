/* Coach Gari — Collaborations workspace (lazy data; gated by collab:view).
   List by status, open a deal, send a proposal / counter, accept the
   counterparty's offer, set status, share the private room link, and request a
   payment for an agreed deal. Everything writes through the collab_* RPCs. */
let C = null;
export function initCollab(ctx) { C = ctx; }

const TYPE = { brand_partnership: 'Brand partnership', sponsored_content: 'Sponsored content', event_appearance: 'Event appearance', corporate_activation: 'Corporate activation', padel_sport: 'Padel / sport', affiliate_ambassador: 'Affiliate / ambassador', product_collaboration: 'Product', other: 'Other' };
const STATUSES = ['', 'new', 'reviewing', 'negotiating', 'agreed', 'declined', 'closed'];
const money = (m, c) => (m == null ? '—' : C.money(m, c));
const esc = (s) => C.esc(s);

export async function collabList() {
  const view = C.view;
  const status = view.dataset.clStatus || '';
  const search = (view.dataset.clSearch || '').trim();
  const { data, error } = await C.sb.rpc('collab_admin_list', { p_status: status || null, p_search: search || null });
  if (error) return C.fail(error);
  const rows = data || [];
  view.innerHTML = `
    <div class="ad-head"><div><h1>Collaborations</h1><p class="ad-muted">Brand and partnership enquiries. Newest activity first.</p></div>
      <div class="ad-filters">
        <input id="cl-search" placeholder="Name, company, reference" value="${esc(search)}">
        <select id="cl-status">${STATUSES.map((s) => `<option value="${s}" ${s === status ? 'selected' : ''}>${s ? s[0].toUpperCase() + s.slice(1) : 'All statuses'}</option>`).join('')}</select>
      </div></div>
    <div class="ad-panel">${C.table(['Reference', 'Who', 'Type', 'Subject', 'Status', 'Latest', 'Updated'],
      rows.map((r) => `<tr class="clik" data-id="${r.id}">
        <td><b>${esc(r.public_ref)}</b></td>
        <td>${esc(r.contact_name || '—')}${r.company ? `<br><span class="ad-muted" style="font-size:12px">${esc(r.company)}</span>` : ''}</td>
        <td>${esc(TYPE[r.collaboration_type] || r.collaboration_type)}</td>
        <td>${esc(r.title || '—')}</td>
        <td>${C.st(r.status)}</td>
        <td class="num">${r.latest_amount != null ? money(r.latest_amount, r.latest_currency) : '—'}</td>
        <td>${C.fmt(r.updated_at, 'Asia/Dubai', { dateStyle: 'medium' })}</td>
      </tr>`), 'No collaborations yet.')}</div>`;
  C.$('#cl-status').onchange = (e) => { view.dataset.clStatus = e.target.value; collabList().catch(C.fail); };
  C.$('#cl-search').onchange = (e) => { view.dataset.clSearch = e.target.value.trim(); collabList().catch(C.fail); };
  view.querySelectorAll('tr.clik').forEach((tr) => tr.onclick = () => openDeal(tr.dataset.id));
}

async function openDeal(id) {
  const { data: d, error } = await C.sb.rpc('collab_admin_get', { p_id: id });
  if (error) return C.fail(error);
  if (!d) return C.fail(new Error('Not found'));
  const view = C.view;
  const dates = d.proposed_date_from ? (d.proposed_date_from + (d.proposed_date_to && d.proposed_date_to !== d.proposed_date_from ? ' → ' + d.proposed_date_to : '')) : '';
  const latest = d.latest;
  const canPropose = !['agreed', 'declined', 'closed'].includes(d.status);
  const counterToAccept = latest && latest.proposed_by === 'counterparty' && canPropose ? latest.version : null;

  const consChips = (arr, kind) => (arr || []).filter((c) => c && c.type === kind).map((c) =>
    `<span class="cr-chip">${esc(c.description || (kind === 'monetary' ? 'Fee' : 'Item'))}${c.amount != null && c.currency ? ' · ' + esc(money(c.amount, c.currency)) : ''}</span>`).join('');

  view.innerHTML = `
    <div class="ad-head"><div><button class="btn btn-line btn-sm" id="cl-back">← Collaborations</button>
      <h1 style="margin-top:10px">${esc(d.title || TYPE[d.collaboration_type] || 'Collaboration')}</h1>
      <p class="ad-muted">${esc(d.public_ref)} · ${esc(TYPE[d.collaboration_type] || d.collaboration_type)} · ${C.st(d.status)}</p></div></div>

    <div class="ad-grid2">
      <div class="ad-panel">
        <h2>Request</h2>
        <table class="ad-table"><tbody>
          <tr><td>Contact</td><td><b>${esc(d.contact_name)}</b>${d.company ? ' · ' + esc(d.company) : ''}</td></tr>
          ${d.contact_email ? `<tr><td>Email</td><td><a href="mailto:${esc(d.contact_email)}">${esc(d.contact_email)}</a></td></tr>` : ''}
          ${d.contact_phone ? `<tr><td>Phone</td><td>${esc(d.contact_phone)}</td></tr>` : ''}
          ${d.contact_url ? `<tr><td>Link</td><td>${esc(d.contact_url)}</td></tr>` : ''}
          ${dates ? `<tr><td>Dates</td><td>${esc(dates)}</td></tr>` : ''}
          ${d.location ? `<tr><td>Location</td><td>${esc(d.location)}</td></tr>` : ''}
          ${d.intake_budget_amount != null ? `<tr><td>Budget hint</td><td>${esc(money(d.intake_budget_amount, d.intake_budget_currency))}</td></tr>` : ''}
        </tbody></table>
        ${d.initial_request ? `<p style="white-space:pre-wrap;margin:0 0 6px"><b>What they'd like to explore:</b><br>${esc(d.initial_request)}</p>` : ''}
        ${d.intake_offer ? `<p style="white-space:pre-wrap;margin:8px 0 0"><b>What they're offering:</b><br>${esc(d.intake_offer)}</p>` : ''}
        <div class="cg-actions" style="margin-top:14px">
          <button class="btn btn-line btn-sm" id="cl-link">Get private room link</button>
          ${canPropose ? `<button class="btn btn-line btn-sm" id="cl-close">Close</button>` : `<button class="btn btn-line btn-sm" id="cl-reopen">Reopen</button>`}
        </div>
        <p id="cl-linkout" class="ad-muted" style="font-size:13px;margin-top:8px"></p>
      </div>

      <div class="ad-panel">
        <h2>Current proposal</h2>
        ${latest ? `<p style="margin:0 0 6px"><span class="cr-by">Version ${esc(latest.version)} · ${latest.proposed_by === 'coach' ? 'Coach Gari' : 'Counterparty'}${latest.accepted_at ? ' · accepted' : ''}</span></p>
          <div class="cr-amt" style="font-size:26px;font-weight:800">${latest.monetary_amount != null ? esc(money(latest.monetary_amount, latest.currency)) : 'No cash component'}</div>
          ${latest.intro ? `<p style="white-space:pre-wrap;margin:8px 0 0">${esc(latest.intro)}</p>` : ''}
          ${consChips(latest.considerations, 'monetary') ? `<div class="cr-by" style="margin-top:10px">Monetary</div><div class="cr-chips">${consChips(latest.considerations, 'monetary')}</div>` : ''}
          ${consChips(latest.considerations, 'non_cash') ? `<div class="cr-by" style="margin-top:10px">Non-cash</div><div class="cr-chips">${consChips(latest.considerations, 'non_cash')}</div>` : ''}`
        : '<p class="ad-muted">No proposal yet. Send the first one below.</p>'}
        ${counterToAccept ? `<div class="cg-actions" style="margin-top:14px"><button class="btn btn-accent btn-sm" id="cl-accept" data-v="${counterToAccept}">Accept this counter-offer</button></div>` : ''}
      </div>
    </div>

    ${canPropose ? `<div class="ad-panel"><h2>${latest ? 'Send a counter / new proposal' : 'Send a proposal'}</h2>
      <form id="cl-propose" class="ad-form">
        <div class="row"><label>Amount (major units) <input name="amount" type="number" min="0" step="0.01"></label>
          <label>Currency <select name="currency"><option value="">—</option><option>AED</option><option>USD</option><option>EUR</option><option>GBP</option></select></label>
          <label>Valid until <input name="expires_at" type="date"></label></div>
        <label>Message <textarea name="intro" rows="2"></textarea></label>
        <label>Non-cash consideration (one per line) <textarea name="noncash" rows="2" placeholder="Flights&#10;Hotel&#10;Products"></textarea></label>
        <label>Deliverables <textarea name="deliverables" rows="2"></textarea></label>
        <div class="row"><label>Usage rights <input name="usage_rights"></label><label>Exclusivity <input name="exclusivity"></label></div>
        <div class="row"><label>Territory <input name="territory"></label><label>Payment terms <input name="payment_terms"></label></div>
        <label>Additional terms <textarea name="additional" rows="2"></textarea></label>
        <div class="cg-actions"><button class="btn btn-accent" type="submit">Send proposal</button></div>
      </form></div>` : ''}

    ${d.status === 'agreed' ? `<div class="ad-panel"><h2>Payment</h2>
      <p class="ad-muted">The agreed terms are frozen (version ${esc(d.accepted_version)}). Request a payment through BEAU PH. Non-cash consideration is never charged.</p>
      <form id="cl-pay" class="ad-form">
        <div class="row"><label>Amount (major units) <input name="amount" type="number" min="0" step="0.01" required></label>
          <label>Currency <select name="currency"><option>AED</option><option>USD</option><option>EUR</option><option>GBP</option></select></label>
          <label>Label <input name="label" placeholder="e.g. 30% deposit"></label></div>
        <div class="cg-actions"><button class="btn btn-accent" type="submit">Request payment</button></div>
      </form>
      ${(d.payments || []).length ? `<table class="ad-table" style="margin-top:12px"><thead><tr><th>Reference</th><th>Label</th><th class="num">Amount</th><th>Status</th></tr></thead><tbody>${d.payments.map((p) => `<tr><td>${esc(p.public_reference || '—')}</td><td>${esc(p.label || '—')}</td><td class="num">${esc(money(p.amount, p.currency))}</td><td>${C.st(p.order_status || p.status)}</td></tr>`).join('')}</tbody></table>` : ''}
    </div>` : ''}

    <div class="ad-panel"><h2>History</h2>${(d.history || []).length ? `<table class="ad-table"><thead><tr><th>Version</th><th>By</th><th class="num">Amount</th><th>State</th><th>When</th></tr></thead><tbody>${d.history.map((v) => `<tr><td>${esc(v.version)}</td><td>${v.proposed_by === 'coach' ? 'Coach Gari' : 'Counterparty'}</td><td class="num">${v.monetary_amount != null ? esc(money(v.monetary_amount, v.currency)) : '—'}</td><td>${v.accepted_at ? 'accepted' : v.declined_at ? 'declined' : v.superseded_at ? 'superseded' : 'open'}</td><td>${C.fmt(v.created_at, 'Asia/Dubai', { dateStyle: 'medium', timeStyle: 'short' })}</td></tr>`).join('')}</tbody></table>` : '<p class="ad-muted">No versions yet.</p>'}</div>`;

  C.$('#cl-back').onclick = () => collabList().catch(C.fail);
  const linkBtn = C.$('#cl-link'); if (linkBtn) linkBtn.onclick = async () => {
    if (!confirm('Generate a fresh private room link? Any previous link stops working.')) return;
    const { data: r, error: e2 } = await C.sb.rpc('collab_regenerate_token', { p_id: id });
    if (e2) return C.fail(e2);
    C.$('#cl-linkout').textContent = `${location.origin}/c/${r.token}`;
  };
  const closeBtn = C.$('#cl-close'); if (closeBtn) closeBtn.onclick = async () => { if (!confirm('Close this collaboration?')) return; const { error: e2 } = await C.sb.rpc('collab_set_status', { p_id: id, p_status: 'closed' }); if (e2) return C.fail(e2); C.toast('Closed'); openDeal(id); };
  const reopenBtn = C.$('#cl-reopen'); if (reopenBtn) reopenBtn.onclick = async () => { const { error: e2 } = await C.sb.rpc('collab_set_status', { p_id: id, p_status: 'reviewing' }); if (e2) return C.fail(e2); C.toast('Reopened'); openDeal(id); };
  const acceptBtn = C.$('#cl-accept'); if (acceptBtn) acceptBtn.onclick = async () => { if (!confirm('Accept this counter-offer? It freezes the agreed terms.')) return; const { error: e2 } = await C.sb.rpc('collab_admin_accept', { p_id: id, p_version: Number(acceptBtn.dataset.v) }); if (e2) return C.fail(e2); C.toast('Agreed'); openDeal(id); };

  const pf = C.$('#cl-propose'); if (pf) pf.onsubmit = async (e) => {
    e.preventDefault(); const f = new FormData(pf);
    const amt = String(f.get('amount') || '').trim();
    const noncash = String(f.get('noncash') || '').split('\n').map((s) => s.trim()).filter(Boolean).map((s) => ({ type: 'non_cash', description: s.slice(0, 300) }));
    const terms = {}; for (const k of ['deliverables', 'usage_rights', 'exclusivity', 'territory', 'payment_terms', 'additional']) { const v = String(f.get(k) || '').trim(); if (v) terms[k] = v; }
    const p = { intro: String(f.get('intro') || '').trim() || null, monetary_amount: amt ? Math.round(Number(amt) * 100) : null, currency: f.get('currency') || null, considerations: noncash, terms, expires_at: f.get('expires_at') || null };
    const { error: e2 } = await C.sb.rpc('collab_propose', { p_id: id, p });
    if (e2) return C.fail(e2); C.toast('Proposal sent'); openDeal(id);
  };
  const payf = C.$('#cl-pay'); if (payf) payf.onsubmit = async (e) => {
    e.preventDefault(); const f = new FormData(payf);
    const amt = String(f.get('amount') || '').trim(); if (!amt) return;
    const { error: e2 } = await C.sb.rpc('collab_payment_request', { p_id: id, p_amount: Math.round(Number(amt) * 100), p_currency: f.get('currency'), p_label: String(f.get('label') || '').trim() || null });
    if (e2) return C.fail(e2); C.toast('Payment requested'); openDeal(id);
  };
}

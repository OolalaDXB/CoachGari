/* =============================================================
   Coach Gari — back-office (CG-002.5 → CG-009)
   One cockpit at /admin: a sidebar of destinations (mobile drawer), a
   minimal top header with page context + an account menu (Sign Out lives
   inside it), and — for people — a large client-profile popup. Every
   destination is shown only when the signed-in person holds the matching
   permission:
     coach:operations → Leads, Calendar, Bookings, Availability, Exceptions, Tour stops
     catalog:view     → Services (the commercial catalogue)
     finance:view     → Finance (orders, ledger, settlements)
     analytics:view   → Analytics
     platform:admin   → Access
   Finance is a tab here, not a separate app — /finance is kept only as a
   deep link that redirects to #finance. Merging the UI does NOT merge the
   permissions: finance:view / finance:manage stay independent in the
   database, and the Finance tab (and its RPCs, under RLS) disappear the
   moment the permission is removed.
   Magic-link sign-in (Supabase Auth) with shouldCreateUser:false — an email
   that was not provisioned by the owner cannot even create an auth user.
   What a signed-in person can see and do is decided entirely by the
   database (RLS + app_permissions); this file only chooses which tabs to
   draw and never writes permissions.
   Column lists are explicit on purpose: the database grants columns, not
   tables, so `select *` would be refused.
   ============================================================= */
import { CONFIG } from '/config.js';

const sb = window.supabase.createClient(CONFIG.SUPABASE_URL, CONFIG.SUPABASE_PUBLISHABLE_KEY, { auth: { flowType: 'pkce', persistSession: true } });

const $ = (s, r = document) => r.querySelector(s);
const view = $('#view');
const esc = (s) => String(s ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
const money = (n, cur = 'USD') => n == null ? '—' : (n / 100).toLocaleString('en-US', { style: 'currency', currency: cur });
const st = (s) => `<span class="st st-${esc(s)}">${esc(String(s ?? '').replace('_', ' '))}</span>`;
const BOOKING_COLS = 'id,reference,service_id,contact_id,customer_name,customer_contact,start_at,end_at,session_timezone,tour_stop_id,delivery_mode,participant_count,status,hold_expires_at,price_amount,currency,notes,cancel_reason,cancelled_at,cancelled_by,created_at,service_title,service_duration_minutes,services(title,slug),tour_stops(city,country)';
const SERVICE_COLS = 'id,slug,title,category,tagline,description,long_description,duration_minutes,price_amount,currency,price_unit,delivery_mode,default_capacity,booking_mode,features,featured,cta_label,active,listed,sort_order,updated_at,updated_by';
const CONTACT_COLS = 'id,crm_contact_id,name,contact,country,city,location_raw,interest,message,utm_source,utm_medium,utm_campaign,utm_content,utm_term,referrer,landing_page,first_visit_at,page,source,status,submission_id,created_at';
const TZS = ['Asia/Dubai', 'Africa/Harare', 'Africa/Johannesburg', 'Africa/Gaborone', 'Africa/Nairobi', 'Europe/London', 'Europe/Paris', 'UTC'];
const WEEKDAYS = ['', 'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'];

let me = null;            // {email, party, permissions:[]}
let services = [];        // catalogue (read-only here)

/* ---------- time helpers (UTC in the database, wall-clock in a zone on screen) ---------- */
function tzParts(date, tz) {
  const p = new Intl.DateTimeFormat('en-US', { timeZone: tz, hourCycle: 'h23', year: 'numeric', month: '2-digit', day: '2-digit', hour: '2-digit', minute: '2-digit', second: '2-digit' }).formatToParts(date);
  const o = {}; for (const x of p) o[x.type] = x.value; return o;
}
function tzOffsetMs(date, tz) { const o = tzParts(date, tz); return Date.UTC(+o.year, o.month - 1, +o.day, +o.hour, +o.minute, +o.second) - date.getTime(); }
function zonedToUtc(local, tz) {                    // 'YYYY-MM-DDTHH:mm' in tz → ISO UTC
  const guess = new Date(local.length === 16 ? local + ':00Z' : local + 'Z');
  let d = new Date(guess.getTime() - tzOffsetMs(guess, tz));
  d = new Date(guess.getTime() - tzOffsetMs(d, tz));
  return d.toISOString();
}
function utcToLocalInput(iso, tz) { if (!iso) return ''; const o = tzParts(new Date(iso), tz); return `${o.year}-${o.month}-${o.day}T${o.hour}:${o.minute}`; }
function fmt(iso, tz, opts = { dateStyle: 'medium', timeStyle: 'short' }) { if (!iso) return '—'; try { return new Intl.DateTimeFormat('en-GB', { timeZone: tz || 'UTC', ...opts }).format(new Date(iso)); } catch { return iso; } }
const dayKey = (iso, tz) => { const o = tzParts(new Date(iso), tz); return `${o.year}-${o.month}-${o.day}`; };
const isoDate = (d) => d.toISOString().slice(0, 10);

/* ---------- ui helpers ---------- */
function toast(msg, err = false) { const t = $('#toast'); t.textContent = msg; t.className = 'ad-toast' + (err ? ' err' : ''); t.hidden = false; clearTimeout(toast.t); toast.t = setTimeout(() => (t.hidden = true), err ? 6000 : 3000); }
function fail(e) { console.error(e); toast(e?.message || e?.error_description || 'Something went wrong', true); }
const has = (p) => me?.permissions?.includes(p);
function table(head, rows, empty = 'Nothing here yet.') {
  if (!rows.length) return `<p class="ad-empty">${esc(empty)}</p>`;
  return `<div class="ad-table-wrap"><table class="ad-table"><thead><tr>${head.map((h) => `<th>${h}</th>`).join('')}</tr></thead><tbody>${rows.join('')}</tbody></table></div>`;
}
function tzSelect(name, value) { const list = TZS.includes(value) || !value ? TZS : [value, ...TZS]; return `<select name="${name}">${list.map((z) => `<option ${z === (value || 'Asia/Dubai') ? 'selected' : ''}>${z}</option>`).join('')}</select>`; }
function serviceChecks(name, selected = []) { return services.map((s) => `<label style="display:flex;gap:8px;align-items:center;font-weight:500"><input type="checkbox" name="${name}" value="${s.id}" ${selected.includes(s.id) ? 'checked' : ''}> ${esc(s.title)}${s.active ? '' : ' (inactive)'}</label>`).join(''); }
const svcTitle = (id) => services.find((s) => s.id === id)?.title || '—';
async function confirmAct(msg) { return window.confirm(msg); }

/* ---------- auth ---------- */
async function boot() {
  $('#login-form').addEventListener('submit', async (e) => {
    e.preventDefault();
    const email = new FormData(e.target).get('email').trim().toLowerCase();
    const m = $('#login-msg'); m.hidden = false; m.className = 'ad-msg';
    m.textContent = 'Sending…';
    const { error } = await sb.auth.signInWithOtp({ email, options: { emailRedirectTo: `${location.origin}/admin/`, shouldCreateUser: false } });
    if (error) { m.className = 'ad-msg err'; m.textContent = /signup|not allowed|not found/i.test(error.message) ? 'This email is not provisioned for the back-office. Ask the owner.' : error.message; return; }
    m.className = 'ad-msg ok'; m.textContent = 'Check your inbox and open the link on this device.';
  });
  document.addEventListener('click', (e) => { if (e.target.closest('[data-signout]')) sb.auth.signOut().then(() => location.reload()); });
  sb.auth.onAuthStateChange((_ev, session) => { render(session); });
  const { data } = await sb.auth.getSession();
  render(data.session);
}

/* ---------- navigation model: sections, permission-gated, some with sub-tabs ---------- */
// A section renders either a single view (run) or a strip of sub-tabs.
// Finance stays one destination (CG-008); Schedule merges the four
// time-management domains (CG-009); CRM merges Leads + Contacts.
function navModel() {
  return [
    { key: 'overview', label: 'Overview', icon: '▦', show: () => true, run: overview },
    { key: 'crm', label: 'CRM', icon: '☺', show: () => has('coach:operations') || has('client_profile:view'),
      subs: [ { key: 'leads', label: 'Leads', show: () => has('coach:operations'), run: leads },
              { key: 'contacts', label: 'Contacts', show: () => has('client_profile:view'), run: crmContacts } ] },
    { key: 'schedule', label: 'Schedule', icon: '◷', show: () => has('coach:operations'),
      subs: [ { key: 'calendar', label: 'Calendar', show: () => true, run: calendar },
              { key: 'sessions', label: 'Sessions', show: () => true, run: sessionsList },
              { key: 'availability', label: 'Availability', show: () => true, run: availability },
              { key: 'exceptions', label: 'Exceptions', show: () => true, run: exceptions },
              { key: 'tours', label: 'Tour stops', show: () => true, run: tours } ] },
    { key: 'bookings', label: 'Bookings', icon: '▤', show: () => has('coach:operations'), run: bookings },
    { key: 'services', label: 'Services', icon: '❖', show: () => has('catalog:view'), run: catalogue },
    { key: 'finance', label: 'Finance', icon: '$', show: () => has('finance:view'), run: finance },
    { key: 'analytics', label: 'Analytics', icon: '◔', show: () => has('analytics:view'), run: analytics },
    { key: 'access', label: 'Access', icon: '⚿', show: () => has('platform:admin'), run: access },
  ];
}
let NAV = [];
let cur = { section: null, sub: null };

async function render(session) {
  if (session && me && me.email === session.user.email && cur.section) { renderAccount(session); return; }
  $('#login').hidden = !!session; $('#app').hidden = true; $('#noaccess').hidden = true;
  $('#sidebar').hidden = true; $('#topbar').hidden = true; $('#subnav').hidden = true;
  if (!session) { me = null; cur = { section: null, sub: null }; return; }
  try {
    const { data, error } = await sb.rpc('my_permissions'); if (error) throw error;
    me = data;
    const model = navModel();
    const others = model.filter((s) => s.key !== 'overview' && s.show());
    NAV = model.filter((s) => s.key === 'overview' ? others.length > 0 : s.show())
               .map((s) => ({ ...s, subs: s.subs ? s.subs.filter((x) => x.show()) : null }))
               .filter((s) => !s.subs || s.subs.length);
    if (!NAV.length) { renderAccount(session); $('#noaccess').hidden = false; return; }
    const { data: svc, error: e2 } = await sb.from('services').select(SERVICE_COLS).order('sort_order'); if (e2) throw e2;
    services = svc || [];
    // sidebar
    $('#nav').innerHTML = NAV.map((s) => `<a data-section="${s.key}"><span class="ico">${s.icon}</span>${esc(s.label)}</a>`).join('');
    $('#nav').onclick = (e) => { const a = e.target.closest('[data-section]'); if (a) { go(a.dataset.section); closeDrawer(); } };
    $('#side-foot').textContent = session.user.email;
    $('#sidebar').hidden = false; $('#topbar').hidden = false; $('#app').hidden = false;
    renderAccount(session);
    $('#burger').onclick = () => { $('#sidebar').classList.add('open'); $('#scrim').hidden = false; };
    $('#scrim').onclick = closeDrawer;
    // initial route from the hash
    const [hSec, hSub] = location.hash.slice(1).split('/');
    go(NAV.some((s) => s.key === hSec) ? hSec : NAV[0].key, hSub);
  } catch (e) { fail(e); }
}
function closeDrawer() { $('#sidebar').classList.remove('open'); $('#scrim').hidden = true; }

function renderAccount(session) {
  const email = session.user.email;
  const ini = (email || '?').slice(0, 2).toUpperCase();
  $('#account').innerHTML = `<button class="acct" id="acct-btn" aria-haspopup="true"><span class="who">${esc(email)}</span><span class="ini">${esc(ini)}</span></button>`;
  const btn = $('#acct-btn');
  btn.onclick = (e) => {
    e.stopPropagation();
    if ($('.ad-acct-menu')) { $('.ad-acct-menu').remove(); return; }
    const m = document.createElement('div'); m.className = 'ad-acct-menu';
    m.innerHTML = `<div class="em">Signed in as<br><b>${esc(email)}</b></div><button data-signout>Sign out</button>`;
    $('#account').appendChild(m);
    setTimeout(() => document.addEventListener('click', function close() { m.remove(); document.removeEventListener('click', close); }), 0);
  };
}

// route to a section (and optional sub-tab); keeps the hash in sync
function go(sectionKey, subKey) {
  const section = NAV.find((s) => s.key === sectionKey) || NAV[0];
  cur.section = section.key;
  for (const a of $('#nav').querySelectorAll('[data-section]')) a.classList.toggle('on', a.dataset.section === section.key);
  $('#topbar-title').textContent = section.label;
  $('#topbar-sub').textContent = '';
  if (section.subs && section.subs.length) {
    const sub = section.subs.find((x) => x.key === subKey) || section.subs[0];
    cur.sub = sub.key;
    location.hash = `${section.key}/${sub.key}`;
    $('#subnav').hidden = false;
    $('#subnav').innerHTML = section.subs.map((x) => `<a data-sub="${x.key}" class="${x.key === sub.key ? 'on' : ''}">${esc(x.label)}</a>`).join('');
    $('#subnav').onclick = (e) => { const a = e.target.closest('[data-sub]'); if (a) go(section.key, a.dataset.sub); };
    view.innerHTML = '<p class="ad-empty">Loading…</p>';
    sub.run().catch(fail);
  } else {
    cur.sub = null;
    location.hash = section.key;
    $('#subnav').hidden = true;
    view.innerHTML = '<p class="ad-empty">Loading…</p>';
    section.run().catch(fail);
  }
}

/* =============================== CRM · LEADS =============================== */
// Leads are enquiry submissions. Each row is clickable and opens the client
// profile popup, focused on that enquiry. Coach:operations only.
async function leads() {
  const status = view.dataset.leadStatus || '';
  const search = (view.dataset.leadSearch || '').trim();
  let q = sb.from('contacts').select(CONTACT_COLS).order('created_at', { ascending: false }).limit(300);
  if (status) q = q.eq('status', status);
  if (search) q = q.or(`name.ilike.%${search}%,contact.ilike.%${search}%,interest.ilike.%${search}%,city.ilike.%${search}%,country.ilike.%${search}%,message.ilike.%${search}%`);
  const { data, error } = await q; if (error) throw error;
  const ids = data.map((c) => c.id);
  const { data: mediaRows } = ids.length ? await sb.from('contact_media').select('contact_id').in('contact_id', ids).eq('status', 'uploaded') : { data: [] };
  const mediaCount = {}; for (const m of mediaRows || []) mediaCount[m.contact_id] = (mediaCount[m.contact_id] || 0) + 1;
  const opts = ['new', 'contacted', 'qualified', 'closed', 'spam'];
  view.innerHTML = `
    <div class="ad-head"><div><h1>Leads</h1><p class="ad-muted">Website enquiries, newest first. Click a lead to open the client.</p></div>
      <div class="ad-filters">
        <input id="lead-search" placeholder="Search name, contact, city…" value="${esc(search)}">
        <select id="lead-status"><option value="">All statuses</option>${opts.map((o) => `<option ${o === status ? 'selected' : ''}>${o}</option>`).join('')}</select>
      </div></div>
    <div class="ad-panel">${table(['When', 'Who', 'Where', 'Interest', 'Message', 'Status', ''], data.map((c) => `<tr class="clik" data-crm="${esc(c.crm_contact_id || '')}" data-enquiry="${c.id}">
      <td>${fmt(c.created_at, 'Asia/Dubai')}</td>
      <td><b>${esc(c.name)}</b><br><span class="ad-muted" style="font-size:12px">${esc(c.contact)}</span></td>
      <td>${esc(c.location_raw || [c.city, c.country].filter(Boolean).join(', ') || '—')}</td>
      <td>${esc(c.interest || '—')}</td>
      <td class="msg">${esc((c.message || '').slice(0, 140))}${(c.message || '').length > 140 ? '…' : ''}</td>
      <td>${st(c.status)}</td>
      <td class="ad-muted">${mediaCount[c.id] ? ('📎 ' + mediaCount[c.id]) : ''}</td>
    </tr>`), 'No leads match.')}</div>`;
  $('#lead-status').onchange = (e) => { view.dataset.leadStatus = e.target.value; leads().catch(fail); };
  $('#lead-search').onchange = (e) => { view.dataset.leadSearch = e.target.value.trim(); leads().catch(fail); };
  view.querySelectorAll('tr.clik').forEach((tr) => tr.onclick = () => openProfile(tr.dataset.crm || null, tr.dataset.enquiry, 'enquiries'));
}

/* =============================== CRM · CONTACTS =============================== */
// Canonical people (crm_contacts) with enquiry/booking counts. client_profile:view.
async function crmContacts() {
  const search = (view.dataset.cSearch || '').trim();
  const status = view.dataset.cStatus || '';
  const reviewOnly = view.dataset.cReview === '1';
  const { data, error } = await sb.rpc('crm_list_contacts', { p_search: search || null, p_review_only: reviewOnly }); if (error) throw error;
  const rows = (data || []).filter((c) => !status || c.status === status);
  const reviewCount = (data || []).filter((c) => c.needs_review).length;
  const opts = ['lead', 'active', 'past', 'archived'];
  view.innerHTML = `
    <div class="ad-head"><div><h1>Contacts</h1><p class="ad-muted">Every person who has enquired or booked. Click to open the profile.</p></div>
      <div class="ad-filters">
        <input id="c-search" placeholder="Search name, email, phone, city…" value="${esc(search)}">
        <select id="c-status"><option value="">All statuses</option>${opts.map((o) => `<option ${o === status ? 'selected' : ''}>${o}</option>`).join('')}</select>
        <button class="btn btn-sm ${reviewOnly ? 'btn-accent' : 'btn-line'}" id="c-review">${reviewOnly ? 'Showing needs-review' : 'Needs review'}${!reviewOnly && reviewCount ? ` (${reviewCount})` : ''}</button>
        ${has('client_profile:manage') ? '<button class="btn btn-accent btn-sm" id="c-new">New contact</button>' : ''}
      </div></div>
    ${reviewOnly ? '<p class="ad-note">These people were auto-created from an ambiguous match (a shared email or phone) and were never merged automatically. Open a profile to review, correct, or merge it into the right person.</p>' : ''}
    <div class="ad-panel">${table(['Name', 'Where', 'Contact', 'Interest', 'Enquiries', 'Bookings', 'Last activity', 'Status'], rows.map((c) => `<tr class="clik" data-crm="${c.id}">
      <td><b>${esc(c.display_name || '—')}</b>${c.needs_review ? ' <span class="ad-badge-rev">review</span>' : ''}</td>
      <td>${esc([c.city, c.country].filter(Boolean).join(', ') || '—')}</td>
      <td class="ad-muted" style="font-size:12px">${esc(c.email || c.phone || '—')}</td>
      <td>${esc(c.main_interest || '—')}</td>
      <td class="num">${c.enquiry_count}</td>
      <td class="num">${c.booking_count}</td>
      <td>${fmt(c.last_activity_at, 'Asia/Dubai', { dateStyle: 'medium' })}</td>
      <td>${st(c.status)}</td>
    </tr>`), reviewOnly ? 'Nothing needs review.' : 'No contacts match.')}</div>`;
  $('#c-status').onchange = (e) => { view.dataset.cStatus = e.target.value; crmContacts().catch(fail); };
  $('#c-search').onchange = (e) => { view.dataset.cSearch = e.target.value.trim(); crmContacts().catch(fail); };
  $('#c-review').onclick = () => { view.dataset.cReview = reviewOnly ? '' : '1'; crmContacts().catch(fail); };
  const nb = $('#c-new'); if (nb) nb.onclick = () => openContactEditor(null);
  view.querySelectorAll('tr.clik').forEach((tr) => tr.onclick = () => openProfile(tr.dataset.crm, null, 'overview'));
}

/* =============================== OVERVIEW =============================== */
async function overview() {
  const { data, error } = await sb.rpc('admin_overview'); if (error) throw error;
  const o = data.operations, f = data.finance, c = data.crm;
  const cards = [];
  if (o) cards.push(['New leads · 7 days', o.new_leads_7d], ["Today's sessions", o.today_sessions], ['Upcoming bookings', o.upcoming_bookings]);
  if (f) cards.push(['Orders awaiting payment', f.pending_payment_orders], ['Unsettled Gari payable', money(f.unsettled_payable)]);
  if (c) cards.push(['CRM contacts', c.total_contacts], ['Flagged for review', c.needs_review]);
  // next session (coach operations) — the most useful thing on a phone
  let upcoming = [];
  if (has('coach:operations')) { const { data: u } = await sb.rpc('sessions_upcoming', { p_limit: 6 }); upcoming = u || []; }
  const nextCard = (s) => {
    const t = lp(s.start_at); const ml = mapLinks(s); const online = s.delivery_mode === 'online';
    const pack = s.pack ? `<span class="ov-pack">${s.pack.used}/${s.pack.total_sessions}</span>` : '';
    return `<div class="ov-next" data-sess="${s.id}">
      <div class="ov-next-top"><div class="ov-time">${String(t.h).padStart(2,'0')}:${String(t.m).padStart(2,'0')}</div>
        <div class="ov-when">${prettyDay(t.date)}</div>${pack}</div>
      <div class="ov-name">${esc(s.client_name || 'Client')}</div>
      <div class="ov-type">${esc(s.title || 'Session')} · ${online ? 'Online' : (s.location_name ? esc(s.location_name) : 'In person')}</div>
      <div class="cg-actions"><button class="btn btn-accent btn-sm" data-open>Open</button>
        ${online && s.meeting_url ? `<a class="btn btn-line btn-sm" href="${esc(s.meeting_url)}" target="_blank" rel="noopener">Join</a>` : (!online && (s.location_name || s.location_address) ? `<a class="btn btn-line btn-sm" href="${ml.gmaps}" target="_blank" rel="noopener">Directions</a>` : '')}</div></div>`;
  };
  view.innerHTML = `
    <div class="ad-head"><div><h1>Overview</h1><p class="ad-muted">A quick read on what needs attention. Only what you're allowed to see.</p></div></div>
    ${upcoming.length ? `<div class="ov-nextwrap"><div class="ov-lbl">Next session${upcoming.length > 1 ? 's' : ''}</div>
      <div class="ov-nextrow">${upcoming.map(nextCard).join('')}</div></div>` : ''}
    <div class="ad-kpis">${cards.map(([l, v]) => `<div class="ad-kpi"><b>${v}</b><span>${esc(l)}</span></div>`).join('') || '<p class="ad-empty">Nothing to show yet.</p>'}</div>`;
  // clicking a next-session card opens it (seed calData so the popup summary resolves)
  calData = { sessions: upcoming, blocks: [] };
  view.querySelectorAll('.ov-next').forEach((el) => { const openBtn = el.querySelector('[data-open]'); const go2 = () => openSession(el.dataset.sess); el.onclick = go2; if (openBtn) openBtn.onclick = (e) => { e.stopPropagation(); go2(); }; el.querySelectorAll('a').forEach((a) => a.onclick = (e) => e.stopPropagation()); });
}

/* =============================== BOOKINGS / CALENDAR =============================== */
function bookingRow(b, tz, withActions = true) {
  const acts = [];
  if (withActions && has('coach:operations')) {
    if (['hold', 'pending_payment', 'confirmed'].includes(b.status)) acts.push(`<button class="btn btn-line btn-xs" data-act="cancelled" data-ref="${b.reference}">Cancel</button>`);
    if (b.status === 'confirmed' && new Date(b.start_at) <= new Date()) acts.push(`<button class="btn btn-dark btn-xs" data-act="completed" data-ref="${b.reference}">Completed</button>`, `<button class="btn btn-line btn-xs" data-act="no_show" data-ref="${b.reference}">No-show</button>`);
    if (b.status === 'hold' && b.price_amount == null) acts.push(`<button class="btn btn-accent btn-xs" data-act="confirmed" data-ref="${b.reference}">Confirm</button>`);
  }
  const where = b.tour_stops ? `${b.tour_stops.city}, ${b.tour_stops.country}` : b.delivery_mode;
  return `<tr>
    <td><b>${fmt(b.start_at, tz, { timeStyle: 'short' })}</b>–${fmt(b.end_at, tz, { timeStyle: 'short' })}<br><span class="ad-muted" style="font-size:12px">${fmt(b.start_at, tz, { dateStyle: 'medium' })} · ${esc(tz)}</span></td>
    <td>${esc(b.service_title || b.services?.title || svcTitle(b.service_id))}<br><span class="ad-muted" style="font-size:12px">${esc(where)}${b.participant_count > 1 ? ' · ' + b.participant_count + ' people' : ''}</span></td>
    <td><b>${esc(b.customer_name)}</b><br><a href="${b.customer_contact.includes('@') ? 'mailto:' + esc(b.customer_contact) : 'https://wa.me/' + esc(b.customer_contact.replace(/\D/g, ''))}">${esc(b.customer_contact)}</a>${b.notes ? `<div class="msg">${esc(b.notes)}</div>` : ''}</td>
    <td>${esc(b.reference)}<br>${st(b.status)}${b.cancel_reason ? `<div class="msg">${esc(b.cancel_reason)}</div>` : ''}</td>
    <td class="num">${b.price_amount == null ? 'on request' : money(b.price_amount, b.currency)}</td>
    <td class="acts">${acts.join('')}</td></tr>`;
}
function bindBookingActions() {
  view.querySelectorAll('[data-act]').forEach((btn) => btn.onclick = async () => {
    const act = btn.dataset.act, ref = btn.dataset.ref;
    let reason = null;
    if (act === 'cancelled') { reason = window.prompt(`Cancel ${ref}? Optional reason for your records:`); if (reason === null) return; }
    else if (!(await confirmAct(`Mark ${ref} as ${act.replace('_', ' ')}?`))) return;
    const { error } = await sb.rpc('ops_set_booking_status', { p_reference: ref, p_status: act, p_reason: reason || null });
    if (error) return fail(error);
    toast(`${ref} → ${act.replace('_', ' ')}${act === 'cancelled' && reason !== null ? '. Refunds, if any, are handled by Oolala.' : ''}`);
    go(tab);
  });
}
/* ============================ CALENDAR ============================ */
/* Gari's operating calendar: Day (default) / Week / Month, reading the
   authoritative calendar_range RPC (sessions + blocks). Times are shown in
   the coach's zone. Tapping a session opens a popup; tapping an empty slot
   offers Add session / Block time, prefilled. iPhone-first. */
const CAL_TZ = 'Asia/Dubai';
const CAL_H0 = 7, CAL_H1 = 22;                 // visible hours 07:00–22:00
function todayISO() { const o = tzParts(new Date(), CAL_TZ); return `${o.year}-${o.month}-${o.day}`; }  // today in the coach's zone
const cal = { view: (() => { try { return localStorage.getItem('cg_cal_view') || 'day'; } catch { return 'day'; } })(), anchor: todayISO(), selDay: null };
function anchorISO() { return cal.anchor; }  // 'YYYY-MM-DD' in CAL_TZ
// local wall-clock parts of an ISO instant, in the calendar zone
function lp(iso) { const o = tzParts(new Date(iso), CAL_TZ); return { date: `${o.year}-${o.month}-${o.day}`, h: +o.hour, m: +o.minute, mins: +o.hour * 60 + +o.minute }; }
// zone-local 'YYYY-MM-DD' + hour → ISO UTC
function localToISO(dateStr, h, m = 0) { return zonedToUtc(`${dateStr}T${String(h).padStart(2, '0')}:${String(m).padStart(2, '0')}`, CAL_TZ); }
function addDaysISO(dateStr, n) { const d = new Date(dateStr + 'T12:00:00'); d.setDate(d.getDate() + n); return d.toISOString().slice(0, 10); }
function weekStartISO(dateStr) { const d = new Date(dateStr + 'T12:00:00'); const dow = (d.getDay() + 6) % 7; d.setDate(d.getDate() - dow); return d.toISOString().slice(0, 10); }  // Monday
const DOW_SHORT = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
const MONTHS = ['January', 'February', 'March', 'April', 'May', 'June', 'July', 'August', 'September', 'October', 'November', 'December'];
function prettyDay(dateStr) { const d = new Date(dateStr + 'T12:00:00'); return `${DOW_SHORT[(d.getDay() + 6) % 7]} ${d.getDate()} ${MONTHS[d.getMonth()]}`; }

let calData = { sessions: [], blocks: [] };

async function calendar() {
  view.innerHTML = `
    <div class="cal-head">
      <div class="cal-head-l"><h1>Schedule</h1>
        <div class="cal-nav"><button class="btn btn-line btn-sm" id="cal-today">Today</button>
          <button class="cal-arrow" id="cal-prev" aria-label="Previous">‹</button>
          <span class="cal-title" id="cal-title"></span>
          <button class="cal-arrow" id="cal-next" aria-label="Next">›</button></div>
      </div>
      <div class="cal-head-r">
        <div class="cal-views" role="tablist">
          ${['day', 'week', 'month'].map((v) => `<button data-cv="${v}" class="${v === cal.view ? 'on' : ''}">${v[0].toUpperCase() + v.slice(1)}</button>`).join('')}
        </div>
        <button class="btn btn-accent btn-sm" id="cal-add">+ Session</button>
        <button class="btn btn-line btn-sm" id="cal-block">Block time</button>
      </div>
    </div>
    <div id="cal-body" class="cal-body"><p class="ad-empty">Loading…</p></div>`;
  $('#cal-today').onclick = () => { cal.anchor = todayISO(); calRender().catch(fail); };
  $('#cal-prev').onclick = () => { calShift(-1); };
  $('#cal-next').onclick = () => { calShift(1); };
  $('#cal-add').onclick = () => sessionForm(null);
  $('#cal-block').onclick = () => blockForm(null);
  view.querySelector('.cal-views').onclick = (e) => { const b = e.target.closest('[data-cv]'); if (!b) return; cal.view = b.dataset.cv; try { localStorage.setItem('cg_cal_view', cal.view); } catch {} view.querySelectorAll('[data-cv]').forEach((x) => x.classList.toggle('on', x === b)); calRender().catch(fail); };
  await calRender();
}
function calShift(dir) {
  const a = anchorISO();
  cal.anchor = cal.view === 'day' ? addDaysISO(a, dir) : cal.view === 'week' ? addDaysISO(a, 7 * dir) : (() => { const d = new Date(a + 'T12:00:00'); d.setMonth(d.getMonth() + dir); return d.toISOString().slice(0, 10); })();
  calRender().catch(fail);
}
async function calRender() {
  const a = anchorISO();
  let fromISO, toISO, title;
  if (cal.view === 'day') { fromISO = localToISO(a, 0); toISO = localToISO(addDaysISO(a, 1), 0); title = prettyDay(a); }
  else if (cal.view === 'week') { const ws = weekStartISO(a); fromISO = localToISO(ws, 0); toISO = localToISO(addDaysISO(ws, 7), 0); const we = addDaysISO(ws, 6); title = `${prettyDay(ws)} – ${prettyDay(we)}`; }
  else { const d = new Date(a + 'T12:00:00'); const ms = `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-01`; const me = (() => { const x = new Date(ms + 'T12:00:00'); x.setMonth(x.getMonth() + 1); return x.toISOString().slice(0, 10); })(); fromISO = localToISO(ms, 0); toISO = localToISO(me, 0); title = `${MONTHS[d.getMonth()]} ${d.getFullYear()}`; }
  $('#cal-title').textContent = title;
  const { data, error } = await sb.rpc('calendar_range', { p_from: fromISO, p_to: toISO });
  if (error) { fail(error); return; }
  calData = { sessions: data.sessions || [], blocks: data.blocks || [] };
  const body = $('#cal-body');
  if (cal.view === 'day') body.innerHTML = renderTimeline(a);
  else if (cal.view === 'week') body.innerHTML = (window.matchMedia('(max-width:760px)').matches ? renderWeekMobile(a) : renderWeekDesktop(a));
  else body.innerHTML = renderMonth(a);
  bindCalBody();
}
function eventsFor(dateStr) {
  const s = calData.sessions.filter((x) => lp(x.start_at).date === dateStr);
  const b = calData.blocks.filter((x) => lp(x.start_at).date === dateStr);
  return { s, b };
}
function posStyle(iso, endIso) {
  const a = lp(iso), b = lp(endIso);
  const top = Math.max(0, (a.mins - CAL_H0 * 60)) / 60;
  const dur = Math.max(0.5, (b.mins - a.mins) / 60);
  return `top:${top * 3}rem;height:${dur * 3}rem`;
}
function sessionChip(x) {
  const t = lp(x.start_at), e = lp(x.end_at);
  const time = `${String(t.h).padStart(2, '0')}:${String(t.m).padStart(2, '0')}–${String(e.h).padStart(2, '0')}:${String(e.m).padStart(2, '0')}`;
  const pack = x.pack ? `<span class="cal-pack">${x.pack.used}/${x.pack.total_sessions}</span>` : '';
  const pay = x.pack && x.pack.payment_status ? `<span class="cal-pay ${x.pack.payment_status === 'paid' ? 'ok' : 'due'}">${x.pack.payment_status === 'paid' ? 'Paid' : 'Due'}</span>` : '';
  const mode = x.delivery_mode === 'online' ? '🖥' : '📍';
  return `<div class="cal-ev st-${esc(x.status)}" data-sess="${x.id}" style="${posStyle(x.start_at, x.end_at)}">
    <div class="cal-ev-t">${time} ${mode}</div>
    <div class="cal-ev-c">${esc(x.client_name || 'Client')}</div>
    <div class="cal-ev-s">${esc(x.title || 'Session')}</div>
    <div class="cal-ev-m">${pack}${pay}</div></div>`;
}
function blockChip(x) {
  return `<div class="cal-block" data-block="${x.id}" style="${posStyle(x.start_at, x.end_at)}">
    <div class="cal-ev-t">Blocked</div><div class="cal-ev-s">${esc(x.label || '')}</div></div>`;
}
function hourRows(dateStr) {
  let h = '';
  for (let i = CAL_H0; i < CAL_H1; i++) h += `<div class="cal-hr" data-date="${dateStr}" data-hour="${i}"><span class="cal-hrl">${String(i).padStart(2, '0')}:00</span></div>`;
  return h;
}
function renderTimeline(dateStr) {
  const { s, b } = eventsFor(dateStr);
  return `<div class="cal-day"><div class="cal-grid">
    ${hourRows(dateStr)}
    <div class="cal-layer">${b.map(blockChip).join('')}${s.map(sessionChip).join('')}</div>
  </div></div>`;
}
function renderWeekDesktop(dateStr) {
  const ws = weekStartISO(dateStr); const today = anchorISO(); const realToday = tzParts(new Date(), CAL_TZ);
  const todayStr = `${realToday.year}-${realToday.month}-${realToday.day}`;
  let cols = '';
  for (let i = 0; i < 7; i++) {
    const ds = addDaysISO(ws, i); const { s, b } = eventsFor(ds); const d = new Date(ds + 'T12:00:00');
    cols += `<div class="cal-wcol ${ds === todayStr ? 'is-today' : ''}">
      <div class="cal-wch" data-goday="${ds}">${DOW_SHORT[i]} <b>${d.getDate()}</b></div>
      <div class="cal-grid cal-grid-w">${hourRows(ds)}<div class="cal-layer">${b.map(blockChip).join('')}${s.map(sessionChip).join('')}</div></div></div>`;
  }
  return `<div class="cal-week"><div class="cal-wgutter"><div class="cal-wch">&nbsp;</div>${Array.from({ length: CAL_H1 - CAL_H0 }, (_, i) => `<div class="cal-gh">${String(CAL_H0 + i).padStart(2, '0')}:00</div>`).join('')}</div>${cols}</div>`;
}
function renderWeekMobile(dateStr) {
  const ws = weekStartISO(dateStr); const we = addDaysISO(ws, 6);
  const active = (cal.selDay && cal.selDay >= ws && cal.selDay <= we) ? cal.selDay : dateStr;
  let chips = '';
  for (let i = 0; i < 7; i++) { const ds = addDaysISO(ws, i); const d = new Date(ds + 'T12:00:00'); const n = eventsFor(ds).s.length;
    chips += `<button class="cal-mchip ${ds === active ? 'on' : ''}" data-selday="${ds}"><span>${DOW_SHORT[i][0]}</span><b>${d.getDate()}</b>${n ? `<i class="cal-dot"></i>` : ''}</button>`; }
  return `<div class="cal-mweek"><div class="cal-mchips">${chips}</div>${renderTimeline(active)}</div>`;
}
function renderMonth(dateStr) {
  const d = new Date(dateStr + 'T12:00:00'); const y = d.getFullYear(), m = d.getMonth();
  const first = new Date(y, m, 1); const startDow = (first.getDay() + 6) % 7;
  const realToday = tzParts(new Date(), CAL_TZ); const todayStr = `${realToday.year}-${realToday.month}-${realToday.day}`;
  const counts = {}; for (const s of calData.sessions) { const k = lp(s.start_at).date; counts[k] = (counts[k] || 0) + 1; }
  const blockDays = {}; for (const b of calData.blocks) { const k = lp(b.start_at).date; blockDays[k] = true; }
  let cells = '';
  for (let i = 0; i < startDow; i++) cells += `<div class="cal-mc empty"></div>`;
  const dim = new Date(y, m + 1, 0).getDate();
  for (let day = 1; day <= dim; day++) {
    const ds = `${y}-${String(m + 1).padStart(2, '0')}-${String(day).padStart(2, '0')}`; const n = counts[ds] || 0;
    cells += `<div class="cal-mc ${ds === todayStr ? 'is-today' : ''}" data-goday="${ds}">
      <span class="cal-mcn">${day}</span>${n ? `<span class="cal-mcount">${n}</span>` : ''}${blockDays[ds] ? '<i class="cal-mblock"></i>' : ''}
      ${n ? `<div class="cal-mdots">${Array.from({ length: Math.min(n, 4) }, () => '<i></i>').join('')}</div>` : ''}</div>`;
  }
  return `<div class="cal-month"><div class="cal-mhead">${DOW_SHORT.map((x) => `<span>${x}</span>`).join('')}</div><div class="cal-mgrid">${cells}</div></div>`;
}
function bindCalBody() {
  const body = $('#cal-body');
  body.querySelectorAll('[data-sess]').forEach((el) => el.onclick = (e) => { e.stopPropagation(); openSession(el.dataset.sess); });
  body.querySelectorAll('[data-block]').forEach((el) => el.onclick = (e) => { e.stopPropagation(); openBlock(el.dataset.block); });
  body.querySelectorAll('.cal-hr').forEach((el) => el.onclick = () => slotSheet(el.dataset.date, +el.dataset.hour));
  body.querySelectorAll('[data-goday]').forEach((el) => el.onclick = () => { cal.anchor = el.dataset.goday; cal.view = 'day'; try { localStorage.setItem('cg_cal_view', 'day'); } catch {} calendar().catch(fail); });
  body.querySelectorAll('[data-selday]').forEach((el) => el.onclick = () => { cal.selDay = el.dataset.selday; $('#cal-body').innerHTML = renderWeekMobile(anchorISO()); bindCalBody(); });
}
// tapping an empty slot: choose Add session or Block time, prefilled
function slotSheet(dateStr, hour) {
  const host = ensureSheet();
  host.querySelector('.cg-sheet').innerHTML = `<div class="cg-sheet-h"><b>${prettyDay(dateStr)} · ${String(hour).padStart(2, '0')}:00</b><button class="pf-close" data-x>×</button></div>
    <div class="cg-sheet-b"><div class="cg-actions">
      <button class="btn btn-accent" data-a="sess">Add session</button>
      <button class="btn btn-line" data-a="block">Block time</button></div></div>`;
  host.querySelector('[data-x]').onclick = closeSheet;
  host.querySelector('[data-a="sess"]').onclick = () => { closeSheet(); sessionForm({ date: dateStr, hour }); };
  host.querySelector('[data-a="block"]').onclick = () => { closeSheet(); blockForm({ date: dateStr, hour }); };
}

/* ---- bottom-sheet host (session popup, block popup, forms) ---- */
function ensureSheet() {
  let host = $('#cg-sheet-host');
  if (!host) { host = document.createElement('div'); host.id = 'cg-sheet-host'; host.className = 'cg-sheet-host'; host.innerHTML = '<div class="cg-scrim"></div><div class="cg-sheet" role="dialog" aria-modal="true"></div>'; document.body.appendChild(host); host.querySelector('.cg-scrim').onclick = closeSheet; }
  host.hidden = false; document.body.style.overflow = 'hidden'; return host;
}
function closeSheet() { const h = $('#cg-sheet-host'); if (h) { h.hidden = true; h.querySelector('.cg-sheet').innerHTML = ''; } if ($('#profile').hidden) document.body.style.overflow = ''; }
document.addEventListener('keydown', (e) => { if (e.key === 'Escape') { const h = $('#cg-sheet-host'); if (h && !h.hidden) closeSheet(); } });

function mapLinks(loc) {
  const q = (loc.location_lat != null && loc.location_lng != null) ? `${loc.location_lat},${loc.location_lng}` : null;
  const addr = loc.location_address || loc.location_name || '';
  const gmaps = q ? `https://www.google.com/maps/search/?api=1&query=${q}` : `https://www.google.com/maps/search/?api=1&query=${encodeURIComponent(addr)}`;
  const waze = q ? `https://waze.com/ul?ll=${q}&navigate=yes` : `https://waze.com/ul?q=${encodeURIComponent(addr)}`;
  return { gmaps, waze, addr };
}

async function openSession(id) {
  const host = ensureSheet(); const sheet = host.querySelector('.cg-sheet');
  sheet.innerHTML = '<div class="cg-sheet-b"><p class="ad-empty">Loading…</p></div>';
  const { data: s, error } = await sb.from('coaching_sessions').select('*').eq('id', id).maybeSingle();
  if (error || !s) { fail(error || { message: 'Not found' }); return; }
  const summary = calData.sessions.find((x) => x.id === id) || {};
  let contact = null;
  if (has('client_profile:view')) { const { data } = await sb.from('crm_contacts').select('display_name,phone,email').eq('id', s.crm_contact_id).maybeSingle(); contact = data; }
  let pack = summary.pack || null;
  if (!pack && s.session_pack_id) { const { data } = await sb.rpc('packs_for_contact', { p_contact_id: s.crm_contact_id }); pack = (data || []).find((p) => p.id === s.session_pack_id) || null; }
  const t = lp(s.start_at), e = lp(s.end_at); const dur = Math.round((new Date(s.end_at) - new Date(s.start_at)) / 60000);
  const name = contact?.display_name || summary.client_name || 'Client';
  const ph = contact?.phone;
  const online = s.delivery_mode === 'online';
  const ml = mapLinks(s);
  const pay = pack && pack.payment_status ? `<span class="cal-pay ${pack.payment_status === 'paid' ? 'ok' : 'due'}">${esc(pack.payment_status)}</span>` : '';
  sheet.innerHTML = `
    <div class="cg-sheet-h"><b>${esc(name)}</b>${st(s.status)}<button class="pf-close" data-x>×</button></div>
    <div class="cg-sheet-b">
      <div class="cg-sec"><div class="cg-sec-t">Session</div>
        <dl class="cg-kv"><dt>Date</dt><dd>${prettyDay(t.date)}</dd>
          <dt>Time</dt><dd>${String(t.h).padStart(2,'0')}:${String(t.m).padStart(2,'0')} – ${String(e.h).padStart(2,'0')}:${String(e.m).padStart(2,'0')} (${dur} min)</dd>
          <dt>Type</dt><dd>${esc(s.title || summary.title || 'Session')} · ${online ? 'Online' : 'In person'}</dd></dl></div>
      ${pack ? `<div class="cg-sec"><div class="cg-sec-t">Package</div>
        <div class="cg-pack"><div class="cg-pack-x">${pack.used} / ${pack.total_sessions}</div><div class="cg-pack-r">${pack.remaining} remaining</div></div>
        <dl class="cg-kv">${'price_amount' in pack ? `<dt>Price</dt><dd>${money(pack.price_amount, pack.currency)} ${pay}</dd><dt>Paid</dt><dd>${pack.paid_at ? fmt(pack.paid_at, CAL_TZ, { dateStyle: 'medium' }) : '—'}</dd>` : ''}<dt>Pack</dt><dd>${esc(pack.title || '')}</dd></dl></div>` : ''}
      ${(!online && (s.location_name || s.location_address)) ? `<div class="cg-sec"><div class="cg-sec-t">Location</div>
        <div class="cg-loc"><b>${esc(s.location_name || '')}</b>${s.location_address ? `<div class="ad-muted">${esc(s.location_address)}</div>` : ''}</div>
        <div class="cg-actions"><button class="btn btn-line btn-sm" data-copyaddr>Copy address</button>
          <a class="btn btn-line btn-sm" href="${ml.gmaps}" target="_blank" rel="noopener">Google Maps</a>
          <a class="btn btn-line btn-sm" href="${ml.waze}" target="_blank" rel="noopener">Waze</a></div></div>` : ''}
      ${(online && s.meeting_url) ? `<div class="cg-sec"><div class="cg-sec-t">Online</div>
        <div class="cg-actions"><button class="btn btn-line btn-sm" data-copylink>Copy link</button>
          <a class="btn btn-line btn-sm" href="${esc(s.meeting_url)}" target="_blank" rel="noopener">Open meeting</a></div></div>` : ''}
      ${s.note ? `<div class="cg-sec"><div class="cg-sec-t">Note</div><p style="margin:0;white-space:pre-wrap">${esc(s.note)}</p></div>` : ''}
      <div class="cg-actions cg-actions-grid">
        ${has('client_profile:view') ? '<button class="btn btn-line" data-open>Open client</button>' : ''}
        ${ph ? `<a class="btn btn-line" href="${waHref(ph)}" target="_blank" rel="noopener">WhatsApp</a>` : ''}
        ${s.status !== 'completed' ? '<button class="btn btn-accent" data-complete>Mark completed</button>' : ''}
        ${s.status === 'scheduled' ? '<button class="btn btn-line" data-noshow>No-show</button>' : ''}
        <button class="btn btn-line" data-pack>Link / change package</button>
        <button class="btn btn-line" data-edit>Edit / reschedule</button>
        ${s.status !== 'cancelled' ? '<button class="btn btn-line" data-cancel>Cancel</button>' : ''}
        ${(!s.booking_id && s.status !== 'completed') ? '<button class="btn btn-line" data-del style="color:var(--danger,#a12a2a)">Delete</button>' : ''}
      </div>
      ${s.booking_id ? '<p class="ad-muted" style="font-size:12px;margin-top:10px">This session came from a website booking.</p>' : ''}
    </div>`;
  sheet.querySelector('[data-x]').onclick = closeSheet;
  const on = (sel, fn) => { const el = sheet.querySelector(sel); if (el) el.onclick = fn; };
  on('[data-copyaddr]', async () => { try { await navigator.clipboard.writeText(ml.addr); toast('Address copied'); } catch {} });
  on('[data-copylink]', async () => { try { await navigator.clipboard.writeText(s.meeting_url); toast('Link copied'); } catch {} });
  on('[data-open]', () => { closeSheet(); openProfile(s.crm_contact_id, null, 'overview'); });
  on('[data-complete]', () => sessStatus(id, 'completed'));
  on('[data-noshow]', () => noShowSheet(id));
  on('[data-cancel]', async () => { if (await confirmAct('Cancel this session?')) sessStatus(id, 'cancelled'); });
  on('[data-edit]', () => { closeSheet(); sessionForm(s); });
  on('[data-pack]', () => packPicker(s));
  on('[data-del]', async () => { if (await confirmAct('Delete this session? This cannot be undone.')) { const { error } = await sb.rpc('session_delete', { p_id: id }); if (error) return fail(error); toast('Session deleted'); closeSheet(); calRender().catch(fail); } });
}
async function sessStatus(id, status) {
  const { error } = await sb.rpc('session_set_status', { p_id: id, p_status: status });
  if (error) return fail(error); toast('Session ' + status); closeSheet(); calRender().catch(fail);
}
function noShowSheet(id) {
  const host = ensureSheet(); host.querySelector('.cg-sheet').innerHTML = `<div class="cg-sheet-h"><b>Mark no-show</b><button class="pf-close" data-x>×</button></div>
    <div class="cg-sheet-b"><p>Did this no-show still consume a session from the package?</p>
    <div class="cg-actions"><button class="btn btn-line" data-free>No — don't consume</button><button class="btn btn-accent" data-charge>Yes — consume a session</button></div></div>`;
  const sheet = host.querySelector('.cg-sheet');
  sheet.querySelector('[data-x]').onclick = closeSheet;
  sheet.querySelector('[data-free]').onclick = async () => { const { error } = await sb.rpc('session_set_status', { p_id: id, p_status: 'no_show', p_chargeable: false }); if (error) return fail(error); toast('Marked no-show'); closeSheet(); calRender().catch(fail); };
  sheet.querySelector('[data-charge]').onclick = async () => { const { error } = await sb.rpc('session_set_status', { p_id: id, p_status: 'no_show', p_chargeable: true }); if (error) return fail(error); toast('Marked no-show (charged)'); closeSheet(); calRender().catch(fail); };
}
async function packPicker(s) {
  const host = ensureSheet(); const sheet = host.querySelector('.cg-sheet');
  sheet.innerHTML = '<div class="cg-sheet-b"><p class="ad-empty">Loading…</p></div>';
  const { data: packs, error } = await sb.rpc('packs_for_contact', { p_contact_id: s.crm_contact_id }); if (error) { fail(error); return; }
  sheet.innerHTML = `<div class="cg-sheet-h"><b>Link to package</b><button class="pf-close" data-x>×</button></div>
    <div class="cg-sheet-b"><div class="cg-actions" style="flex-direction:column;align-items:stretch">
      ${(packs || []).map((p) => `<button class="btn ${p.id === s.session_pack_id ? 'btn-accent' : 'btn-line'}" data-pack="${p.id}" style="text-align:left">${esc(p.title)} · ${p.used}/${p.total_sessions}${p.status !== 'active' ? ' · ' + p.status : ''}</button>`).join('') || '<p class="ad-muted">No packages for this client yet.</p>'}
      <button class="btn btn-line" data-pack="">Unlink (no package)</button>
      <button class="btn btn-line" data-newpack>+ New package…</button>
    </div></div>`;
  sheet.querySelector('[data-x]').onclick = closeSheet;
  sheet.querySelectorAll('[data-pack]').forEach((b) => b.onclick = async () => {
    const { error } = await sb.rpc('session_write', { p: { id: s.id, session_pack_id: b.dataset.pack || null } });
    if (error) return fail(error); toast('Package updated'); closeSheet(); calRender().catch(fail);
  });
  sheet.querySelector('[data-newpack]').onclick = () => packForm(s.crm_contact_id, (newId) => { sb.rpc('session_write', { p: { id: s.id, session_pack_id: newId } }).then(() => { toast('Linked to new package'); calRender().catch(fail); }); });
}

async function openBlock(id) {
  const b = calData.blocks.find((x) => x.id === id); if (!b) return;
  const host = ensureSheet(); const sheet = host.querySelector('.cg-sheet');
  const t = lp(b.start_at), e = lp(b.end_at);
  sheet.innerHTML = `<div class="cg-sheet-h"><b>Blocked time</b><button class="pf-close" data-x>×</button></div>
    <div class="cg-sheet-b"><dl class="cg-kv"><dt>When</dt><dd>${prettyDay(t.date)} · ${String(t.h).padStart(2,'0')}:${String(t.m).padStart(2,'0')} – ${String(e.h).padStart(2,'0')}:${String(e.m).padStart(2,'0')}</dd>
      <dt>Label</dt><dd>${esc(b.label || '—')}</dd>${b.private_note ? `<dt>Private note</dt><dd>${esc(b.private_note)}</dd>` : ''}</dl>
      <p class="ad-muted" style="font-size:12px">Blocked periods are removed from public booking availability.</p>
      <div class="cg-actions">${b.source === 'calendar_block' ? '<button class="btn btn-line" data-edit>Edit</button><button class="btn btn-line" data-unblock style="color:var(--danger,#a12a2a)">Unblock</button>' : '<span class="ad-muted" style="font-size:12px">Managed under Exceptions.</span>'}</div></div>`;
  sheet.querySelector('[data-x]').onclick = closeSheet;
  const eb = sheet.querySelector('[data-edit]'); if (eb) eb.onclick = () => { closeSheet(); blockForm(b); };
  const ub = sheet.querySelector('[data-unblock]'); if (ub) ub.onclick = async () => { if (!await confirmAct('Remove this block? The time becomes bookable again.')) return; const { error } = await sb.rpc('block_remove', { p_id: id }); if (error) return fail(error); toast('Unblocked'); closeSheet(); calRender().catch(fail); };
}

/* ---- session create / edit ---- */
async function sessionForm(prefill) {
  const host = ensureSheet(); const sheet = host.querySelector('.cg-sheet');
  const editing = prefill && prefill.id;
  const st0 = editing ? lp(prefill.start_at) : null;
  const dateVal = editing ? st0.date : (prefill?.date || anchorISO());
  const timeVal = editing ? `${String(st0.h).padStart(2,'0')}:${String(st0.m).padStart(2,'0')}` : (prefill?.hour != null ? `${String(prefill.hour).padStart(2,'0')}:00` : '10:00');
  const dur = editing ? Math.round((new Date(prefill.end_at) - new Date(prefill.start_at)) / 60000) : 60;
  let cid = editing ? prefill.crm_contact_id : (prefill?.crm_contact_id || null);
  let cname = prefill?.crm_name || '';
  const lockClient = editing || !!(prefill && prefill.crm_contact_id);
  if (cid && !cname && has('client_profile:view')) { const { data } = await sb.from('crm_contacts').select('display_name').eq('id', cid).maybeSingle(); cname = data?.display_name || ''; }
  const svcOpts = services.map((s) => `<option value="${s.id}" data-dur="${s.duration_minutes}" data-mode="${s.delivery_mode}" ${editing && prefill.service_id === s.id ? 'selected' : ''}>${esc(s.title)}</option>`).join('');
  sheet.innerHTML = `<div class="cg-sheet-h"><b>${editing ? 'Edit session' : 'New session'}</b><button class="pf-close" data-x>×</button></div>
    <div class="cg-sheet-b"><form id="sess-form" class="cg-form">
      <label>Client ${lockClient ? `<input value="${esc(cname)}" disabled>` : `<input id="cl-search" placeholder="Search client…" autocomplete="off" required><div id="cl-res" class="cg-cl-res"></div><input type="hidden" name="crm_contact_id">`}</label>
      <div class="cg-row"><label>Date <input type="date" name="date" value="${dateVal}" required></label>
        <label>Start <input type="time" name="time" value="${timeVal}" required></label>
        <label>Duration (min) <input type="number" name="dur" min="15" max="480" step="5" value="${dur}" required></label></div>
      <div class="cg-row"><label>Type <select name="service_id"><option value="">—</option>${svcOpts}</select></label>
        <label>Mode <select name="delivery_mode"><option value="in_person" ${editing && prefill.delivery_mode==='in_person'?'selected':''}>In person</option><option value="online" ${editing && prefill.delivery_mode==='online'?'selected':''}>Online</option></select></label></div>
      <label>Title / label <input name="title" value="${editing ? esc(prefill.title || '') : ''}" placeholder="e.g. Private coaching"></label>
      <div id="loc-fields" ${editing && prefill.delivery_mode==='online' ? 'hidden' : ''}>
        <label>Location name <input name="location_name" value="${editing ? esc(prefill.location_name || '') : ''}" placeholder="e.g. Dubai Padel Academy"></label>
        <label>Address <input name="location_address" value="${editing ? esc(prefill.location_address || '') : ''}"></label>
        <div class="cg-row"><label>Latitude <input name="location_lat" value="${editing ? (prefill.location_lat ?? '') : ''}" placeholder="optional"></label>
          <label>Longitude <input name="location_lng" value="${editing ? (prefill.location_lng ?? '') : ''}" placeholder="optional"></label></div></div>
      <div id="url-field" ${!(editing && prefill.delivery_mode==='online') ? 'hidden' : ''}><label>Meeting link <input name="meeting_url" value="${editing ? esc(prefill.meeting_url || '') : ''}" placeholder="https://…"></label></div>
      <label>Note <input name="note" value="${editing ? esc(prefill.note || '') : ''}" placeholder="Optional"></label>
      <div class="cg-actions"><button class="btn btn-accent" type="submit">${editing ? 'Save' : 'Create session'}</button><button class="btn btn-line" type="button" data-x2>Cancel</button></div>
    </form></div>`;
  const form = sheet.querySelector('#sess-form');
  sheet.querySelector('[data-x]').onclick = closeSheet; sheet.querySelector('[data-x2]').onclick = closeSheet;
  const modeSel = form.delivery_mode; const toggleLoc = () => { form.querySelector('#loc-fields').hidden = modeSel.value === 'online'; form.querySelector('#url-field').hidden = modeSel.value !== 'online'; };
  modeSel.onchange = toggleLoc;
  form.service_id.onchange = (e) => { const o = e.target.selectedOptions[0]; if (o?.dataset.dur) form.dur.value = o.dataset.dur; if (o?.dataset.mode) { modeSel.value = o.dataset.mode === 'online' ? 'online' : 'in_person'; toggleLoc(); } if (o && !form.title.value) form.title.value = o.textContent; };
  if (!lockClient) {
    const box = form.querySelector('#cl-search'), res = form.querySelector('#cl-res');
    box.oninput = async () => { const q = box.value.trim(); if (q.length < 2) { res.innerHTML = ''; return; } const { data } = await sb.rpc('crm_list_contacts', { p_search: q, p_review_only: false }); res.innerHTML = (data || []).slice(0, 6).map((c) => `<button type="button" data-cid="${c.id}" data-name="${esc(c.display_name || '')}">${esc(c.display_name || '—')} · ${esc(c.email || c.phone || '')}</button>`).join(''); res.querySelectorAll('[data-cid]').forEach((b) => b.onclick = () => { cid = b.dataset.cid; form.crm_contact_id.value = cid; box.value = b.dataset.name; res.innerHTML = ''; }); };
  }
  form.onsubmit = async (e) => {
    e.preventDefault(); const f = new FormData(form);
    const contactId = lockClient ? cid : f.get('crm_contact_id');
    if (!contactId) return toast('Pick a client', true);
    const startISO = zonedToUtc(`${f.get('date')}T${f.get('time')}`, CAL_TZ);
    const endISO = new Date(new Date(startISO).getTime() + Number(f.get('dur')) * 60000).toISOString();
    const p = { start_at: startISO, end_at: endISO, session_timezone: CAL_TZ, delivery_mode: f.get('delivery_mode'),
      service_id: f.get('service_id') || null, title: f.get('title') || null, note: f.get('note') || null,
      location_name: f.get('location_name') || null, location_address: f.get('location_address') || null,
      location_lat: f.get('location_lat') || null, location_lng: f.get('location_lng') || null, meeting_url: f.get('meeting_url') || null };
    if (editing) p.id = prefill.id; else p.crm_contact_id = contactId;
    const { error } = await sb.rpc('session_write', { p }); if (error) return fail(error);
    toast(editing ? 'Session saved' : 'Session created'); closeSheet(); calRender().catch(fail);
  };
}

/* ---- block create / edit ---- */
function blockForm(prefill) {
  const host = ensureSheet(); const sheet = host.querySelector('.cg-sheet');
  const editing = prefill && prefill.id;
  const st0 = editing ? lp(prefill.start_at) : null, en0 = editing ? lp(prefill.end_at) : null;
  const dateVal = editing ? st0.date : (prefill?.date || anchorISO());
  const startVal = editing ? `${String(st0.h).padStart(2,'0')}:${String(st0.m).padStart(2,'0')}` : (prefill?.hour != null ? `${String(prefill.hour).padStart(2,'0')}:00` : '09:00');
  const endVal = editing ? `${String(en0.h).padStart(2,'0')}:${String(en0.m).padStart(2,'0')}` : (prefill?.hour != null ? `${String(prefill.hour + 1).padStart(2,'0')}:00` : '10:00');
  sheet.innerHTML = `<div class="cg-sheet-h"><b>${editing ? 'Edit block' : 'Block time'}</b><button class="pf-close" data-x>×</button></div>
    <div class="cg-sheet-b"><form id="blk-form" class="cg-form">
      <label>Date <input type="date" name="date" value="${dateVal}" required></label>
      <div class="cg-row"><label>From <input type="time" name="start" value="${startVal}" required></label>
        <label>To <input type="time" name="end" value="${endVal}" required></label></div>
      <label>Label <input name="label" value="${editing ? esc(prefill.label || '') : ''}" placeholder="e.g. Personal, Travel, Lunch"></label>
      <label>Private note <input name="private_note" value="${editing ? esc(prefill.private_note || '') : ''}" placeholder="Only you see this"></label>
      <p class="ad-muted" style="font-size:12px">This makes the time unavailable for public booking.</p>
      <div class="cg-actions"><button class="btn btn-accent" type="submit">${editing ? 'Save' : 'Block'}</button><button class="btn btn-line" type="button" data-x2>Cancel</button></div>
    </form></div>`;
  sheet.querySelector('[data-x]').onclick = closeSheet; sheet.querySelector('[data-x2]').onclick = closeSheet;
  sheet.querySelector('#blk-form').onsubmit = async (e) => {
    e.preventDefault(); const f = new FormData(e.target);
    const startISO = zonedToUtc(`${f.get('date')}T${f.get('start')}`, CAL_TZ);
    const endISO = zonedToUtc(`${f.get('date')}T${f.get('end')}`, CAL_TZ);
    if (new Date(endISO) <= new Date(startISO)) return toast('End must be after start', true);
    const body = { start_at: startISO, end_at: endISO, timezone: CAL_TZ, label: f.get('label') || null, private_note: f.get('private_note') || null };
    const { error } = editing ? await sb.rpc('block_update', { p_id: prefill.id, p: body }) : await sb.rpc('block_create', { p: body });
    if (error) return fail(error); toast(editing ? 'Block updated' : 'Time blocked'); closeSheet(); calRender().catch(fail);
  };
}

/* ---- pack create (standalone or from a picker) ---- */
async function packForm(contactId, onCreated) {
  const host = ensureSheet(); const sheet = host.querySelector('.cg-sheet');
  const canFin = has('finance:manage');
  sheet.innerHTML = `<div class="cg-sheet-h"><b>New package</b><button class="pf-close" data-x>×</button></div>
    <div class="cg-sheet-b"><form id="pack-form" class="cg-form">
      <label>Title <input name="title" value="10-session coaching pack" required></label>
      <div class="cg-row"><label>Total sessions <input type="number" name="total_sessions" min="1" max="100" value="10" required></label>
        <label>Agreement date <input type="date" name="agreement_date" value="${anchorISO()}"></label></div>
      ${canFin ? `<div class="cg-sec"><div class="cg-sec-t">Payment (finance)</div>
        <div class="cg-row"><label>Price <input type="number" name="price_major" min="0" step="0.01" placeholder="e.g. 850"></label>
          <label>Currency <input name="currency" value="USD" maxlength="3"></label></div>
        <div class="cg-row"><label>Status <select name="payment_status"><option value="unpaid">unpaid</option><option value="partial">partial</option><option value="paid">paid</option></select></label>
          <label>Method <select name="payment_source"><option value="">—</option><option value="stripe">stripe</option><option value="bank_transfer">bank transfer</option><option value="cash">cash</option><option value="manual">manual</option><option value="external">external</option></select></label></div>
        <label>Paid on <input type="date" name="paid_date"></label></div>` : '<p class="ad-muted" style="font-size:12px">Payment details need a finance permission and can be added later.</p>'}
      <div class="cg-actions"><button class="btn btn-accent" type="submit">Create package</button><button class="btn btn-line" type="button" data-x2>Cancel</button></div>
    </form></div>`;
  sheet.querySelector('[data-x]').onclick = closeSheet; sheet.querySelector('[data-x2]').onclick = closeSheet;
  sheet.querySelector('#pack-form').onsubmit = async (e) => {
    e.preventDefault(); const f = new FormData(e.target);
    const p = { crm_contact_id: contactId, title: f.get('title'), total_sessions: Number(f.get('total_sessions')), agreement_date: f.get('agreement_date') || null };
    if (canFin) { if (f.get('price_major')) { p.price_amount = Math.round(Number(f.get('price_major')) * 100); p.currency = (f.get('currency') || 'USD').toUpperCase(); }
      if (f.get('payment_status')) p.payment_status = f.get('payment_status');
      if (f.get('payment_source')) p.payment_source = f.get('payment_source');
      if (f.get('paid_date')) p.paid_at = zonedToUtc(`${f.get('paid_date')}T12:00`, CAL_TZ); }
    const { data, error } = await sb.rpc('pack_create', { p }); if (error) return fail(error);
    toast('Package created'); closeSheet(); if (onCreated) onCreated(data.id);
  };
}

/* ---- Sessions list sub-tab ---- */
async function sessionsList() {
  const q = view.dataset.slQ || ''; const status = view.dataset.slStatus || ''; const mode = view.dataset.slMode || '';
  const { data, error } = await sb.rpc('sessions_list', { p: { q: q || null, status: status || null, delivery_mode: mode || null } }); if (error) throw error;
  const rows = data || [];
  const opts = ['scheduled', 'completed', 'cancelled', 'no_show'];
  view.innerHTML = `
    <div class="ad-head"><div><h1>Sessions</h1><p class="ad-muted">Search and history across all coaching sessions.</p></div>
      <div class="ad-filters"><input id="sl-q" placeholder="Client or title…" value="${esc(q)}">
        <select id="sl-status"><option value="">All statuses</option>${opts.map((o) => `<option value="${o}" ${o === status ? 'selected' : ''}>${o.replace('_',' ')}</option>`).join('')}</select>
        <select id="sl-mode"><option value="">All modes</option><option value="in_person" ${mode==='in_person'?'selected':''}>In person</option><option value="online" ${mode==='online'?'selected':''}>Online</option></select></div></div>
    <div class="ad-panel">${table(['Date', 'Time', 'Client', 'Type', 'Package', 'Status'], rows.map((s) => {
      const t = lp(s.start_at), e = lp(s.end_at);
      return `<tr class="clik" data-sess="${s.id}"><td>${prettyDay(t.date)}</td><td>${String(t.h).padStart(2,'0')}:${String(t.m).padStart(2,'0')}–${String(e.h).padStart(2,'0')}:${String(e.m).padStart(2,'0')}</td>
        <td><b>${esc(s.client_name || '—')}</b></td><td>${esc(s.title || '—')} · ${s.delivery_mode === 'online' ? 'online' : 'in person'}</td>
        <td>${s.pack ? `${s.pack.used}/${s.pack.total_sessions}` : '—'}</td><td>${st(s.status)}</td></tr>`;
    }), 'No sessions match.')}</div>`;
  $('#sl-q').onchange = (e) => { view.dataset.slQ = e.target.value.trim(); sessionsList().catch(fail); };
  $('#sl-status').onchange = (e) => { view.dataset.slStatus = e.target.value; sessionsList().catch(fail); };
  $('#sl-mode').onchange = (e) => { view.dataset.slMode = e.target.value; sessionsList().catch(fail); };
  view.querySelectorAll('tr.clik').forEach((tr) => tr.onclick = async () => { await calPreloadFor(tr.dataset.sess); openSession(tr.dataset.sess); });
}
// the Sessions list isn't a calendar range, so seed calData so openSession's summary lookups work
async function calPreloadFor(id) { if (!calData.sessions.find((x) => x.id === id)) calData.sessions = []; }

async function bookings() {
  const tz = view.dataset.tz || 'Asia/Dubai'; const status = view.dataset.bkStatus || ''; const search = view.dataset.bkSearch || '';
  let q = sb.from('bookings').select(BOOKING_COLS).order('start_at', { ascending: false }).limit(200);
  if (status) q = q.eq('status', status);
  if (search) q = q.or(`reference.ilike.%${search}%,customer_name.ilike.%${search}%,customer_contact.ilike.%${search}%`);
  const { data, error } = await q; if (error) throw error;
  const opts = ['hold', 'pending_payment', 'confirmed', 'completed', 'no_show', 'cancelled', 'expired'];
  view.innerHTML = `
    <div class="ad-head"><div><h1>Bookings</h1><p class="ad-muted">Every booking, newest session first.</p></div>
      <div class="ad-filters"><input id="bk-search" placeholder="Reference, name or contact" value="${esc(search)}"><select id="bk-status"><option value="">All statuses</option>${opts.map((o) => `<option value="${o}" ${o === status ? 'selected' : ''}>${o.replace('_', ' ')}</option>`).join('')}</select>${tzSelect('tz', tz)}</div></div>
    <div class="ad-panel">${table(['Time', 'Session', 'Client', 'Ref · status', 'Price', ''], data.map((b) => bookingRow(b, tz)), 'No bookings match.')}</div>`;
  $('#bk-status').onchange = (e) => { view.dataset.bkStatus = e.target.value; bookings().catch(fail); };
  $('#bk-search').onchange = (e) => { view.dataset.bkSearch = e.target.value.trim(); bookings().catch(fail); };
  $('select[name=tz]', view).onchange = (e) => { view.dataset.tz = e.target.value; bookings().catch(fail); };
  bindBookingActions();
}

/* =============================== AVAILABILITY RULES =============================== */
async function availability() {
  const { data, error } = await sb.from('availability_rules').select('id,weekday,start_time,end_time,timezone,service_ids,valid_from,valid_to,active,notes,created_at').order('weekday').order('start_time'); if (error) throw error;
  const editing = view.dataset.editRule ? data.find((r) => r.id === view.dataset.editRule) : null;
  view.innerHTML = `
    <div class="ad-head"><div><h1>Availability</h1><p class="ad-muted">Weekly hours the booking engine offers. Slots follow each service's duration. Closed exceptions punch holes in these.</p></div></div>
    <div class="ad-grid2">
      <div class="ad-panel">${table(['Day', 'Hours', 'Zone', 'Services', 'Valid', 'Active', ''], data.map((r) => `<tr>
        <td><b>${WEEKDAYS[r.weekday]}</b></td><td>${esc(r.start_time.slice(0, 5))}–${esc(r.end_time.slice(0, 5))}</td><td>${esc(r.timezone)}</td>
        <td>${r.service_ids?.length ? r.service_ids.map(svcTitle).map(esc).join('<br>') : 'all'}</td>
        <td>${r.valid_from || r.valid_to ? `${r.valid_from || '…'} → ${r.valid_to || '…'}` : 'always'}</td>
        <td>${r.active ? st('open') : st('closed')}</td>
        <td class="acts"><button class="btn btn-line btn-xs" data-edit="${r.id}">Edit</button><button class="btn btn-line btn-xs" data-toggle="${r.id}" data-to="${!r.active}">${r.active ? 'Disable' : 'Enable'}</button><button class="btn btn-line btn-xs" data-del="${r.id}">Delete</button></td></tr>`), 'No weekly hours yet — add your first rule.')}
        ${data.some((r) => (r.notes || '').toLowerCase().includes('placeholder')) ? '<p class="ad-note">Rows marked "placeholder" were seeded by the developers. Replace them with your real hours.</p>' : ''}</div>
      <div class="ad-panel"><h2>${editing ? 'Edit rule' : 'Add weekly hours'}</h2>
        <form id="rule-form" class="ad-form">
          <div class="row"><label>Day <select name="weekday">${WEEKDAYS.slice(1).map((d, i) => `<option value="${i + 1}" ${editing?.weekday === i + 1 ? 'selected' : ''}>${d}</option>`).join('')}</select></label>
            <label>From <input type="time" name="start_time" required value="${editing?.start_time?.slice(0, 5) || '09:00'}"></label>
            <label>To <input type="time" name="end_time" required value="${editing?.end_time?.slice(0, 5) || '17:00'}"></label></div>
          <label>Timezone ${tzSelect('timezone', editing?.timezone)}</label>
          <div class="row"><label>Valid from <input type="date" name="valid_from" value="${editing?.valid_from || ''}"></label><label>Valid to <input type="date" name="valid_to" value="${editing?.valid_to || ''}"></label></div>
          <label>Services (none = all)<div style="display:grid;gap:6px">${serviceChecks('service_ids', editing?.service_ids || [])}</div></label>
          <label>Notes <input name="notes" value="${esc(editing?.notes || '')}"></label>
          <div class="actions"><button class="btn btn-accent btn-sm" type="submit">${editing ? 'Save' : 'Add'}</button>${editing ? '<button class="btn btn-line btn-sm" type="button" data-cancel-edit>Cancel</button>' : ''}</div>
        </form></div></div>`;
  view.querySelectorAll('[data-edit]').forEach((b) => b.onclick = () => { view.dataset.editRule = b.dataset.edit; availability().catch(fail); });
  view.querySelector('[data-cancel-edit]')?.addEventListener('click', () => { delete view.dataset.editRule; availability().catch(fail); });
  view.querySelectorAll('[data-toggle]').forEach((b) => b.onclick = async () => { const { error } = await sb.from('availability_rules').update({ active: b.dataset.to === 'true' }).eq('id', b.dataset.toggle); if (error) return fail(error); toast('Saved'); availability().catch(fail); });
  view.querySelectorAll('[data-del]').forEach((b) => b.onclick = async () => { if (!(await confirmAct('Delete this rule? Existing bookings are not affected.'))) return; const { error } = await sb.from('availability_rules').delete().eq('id', b.dataset.del); if (error) return fail(error); toast('Deleted'); availability().catch(fail); });
  $('#rule-form').onsubmit = async (e) => {
    e.preventDefault(); const f = new FormData(e.target);
    const ids = f.getAll('service_ids');
    const row = { weekday: +f.get('weekday'), start_time: f.get('start_time'), end_time: f.get('end_time'), timezone: f.get('timezone'), valid_from: f.get('valid_from') || null, valid_to: f.get('valid_to') || null, service_ids: ids.length ? ids : null, notes: f.get('notes') || null };
    if (row.end_time <= row.start_time) return toast('End must be after start', true);
    const { error } = editing ? await sb.from('availability_rules').update(row).eq('id', editing.id) : await sb.from('availability_rules').insert(row);
    if (error) return fail(error); toast('Saved'); delete view.dataset.editRule; availability().catch(fail);
  };
}

/* =============================== EXCEPTIONS =============================== */
async function exceptions() {
  const [{ data, error }, { data: stops }] = await Promise.all([
    sb.from('availability_exceptions').select('id,kind,start_at,end_at,timezone,reason,service_ids,tour_stop_id,active,tour_stops(city,slug)').gte('end_at', new Date(Date.now() - 7 * 864e5).toISOString()).order('start_at'),
    sb.from('tour_stops').select('id,slug,city,status').order('start_at'),
  ]); if (error) throw error;
  const editing = view.dataset.editExc ? data.find((r) => r.id === view.dataset.editExc) : null;
  const tz = editing?.timezone || 'Asia/Dubai';
  view.innerHTML = `
    <div class="ad-head"><div><h1>Exceptions</h1><p class="ad-muted"><b>Closed</b> blocks time (holiday, travel, a day off). <b>Open</b> adds bookable time outside your weekly hours — link it to a tour stop to make it a tour window.</p></div></div>
    <div class="ad-grid2">
      <div class="ad-panel">${table(['Kind', 'From', 'To', 'Zone', 'Reason', 'Tour stop', ''], data.map((r) => `<tr>
        <td>${st(r.kind)}${r.active ? '' : ' ' + st('cancelled')}</td><td>${fmt(r.start_at, r.timezone)}</td><td>${fmt(r.end_at, r.timezone)}</td><td>${esc(r.timezone)}</td>
        <td>${esc(r.reason || '')}${r.service_ids?.length ? `<div class="msg">${r.service_ids.map(svcTitle).map(esc).join(', ')}</div>` : ''}</td>
        <td>${r.tour_stops ? esc(r.tour_stops.city) : '—'}</td>
        <td class="acts"><button class="btn btn-line btn-xs" data-edit="${r.id}">Edit</button><button class="btn btn-line btn-xs" data-del="${r.id}">Delete</button></td></tr>`), 'No upcoming exceptions.')}</div>
      <div class="ad-panel"><h2>${editing ? 'Edit exception' : 'Add exception'}</h2>
        <form id="exc-form" class="ad-form">
          <div class="row"><label>Kind <select name="kind"><option value="closed" ${editing?.kind === 'closed' ? 'selected' : ''}>Closed (block time)</option><option value="open" ${editing?.kind === 'open' ? 'selected' : ''}>Open (extra hours)</option></select></label>
            <label>Timezone ${tzSelect('timezone', tz)}</label></div>
          <div class="row"><label>From <input type="datetime-local" name="start" required value="${utcToLocalInput(editing?.start_at, tz)}"></label><label>To <input type="datetime-local" name="end" required value="${utcToLocalInput(editing?.end_at, tz)}"></label></div>
          <label>Reason <input name="reason" value="${esc(editing?.reason || '')}" placeholder="Holiday, travel, padel clinic…"></label>
          <label>Tour stop (open windows only) <select name="tour_stop_id"><option value="">— none —</option>${(stops || []).map((s) => `<option value="${s.id}" ${editing?.tour_stop_id === s.id ? 'selected' : ''}>${esc(s.city)} (${s.status})</option>`).join('')}</select></label>
          <label>Services (none = all)<div style="display:grid;gap:6px">${serviceChecks('service_ids', editing?.service_ids || [])}</div></label>
          <div class="actions"><button class="btn btn-accent btn-sm" type="submit">${editing ? 'Save' : 'Add'}</button>${editing ? '<button class="btn btn-line btn-sm" type="button" data-cancel-edit>Cancel</button>' : ''}</div>
        </form><p class="ad-note">Times are entered in the chosen timezone and stored in UTC.</p></div></div>`;
  view.querySelectorAll('[data-edit]').forEach((b) => b.onclick = () => { view.dataset.editExc = b.dataset.edit; exceptions().catch(fail); });
  view.querySelector('[data-cancel-edit]')?.addEventListener('click', () => { delete view.dataset.editExc; exceptions().catch(fail); });
  view.querySelectorAll('[data-del]').forEach((b) => b.onclick = async () => { if (!(await confirmAct('Delete this exception?'))) return; const { error } = await sb.from('availability_exceptions').delete().eq('id', b.dataset.del); if (error) return fail(error); toast('Deleted'); exceptions().catch(fail); });
  $('#exc-form').onsubmit = async (e) => {
    e.preventDefault(); const f = new FormData(e.target); const z = f.get('timezone'); const ids = f.getAll('service_ids');
    const row = { kind: f.get('kind'), timezone: z, start_at: zonedToUtc(f.get('start'), z), end_at: zonedToUtc(f.get('end'), z), reason: f.get('reason') || null, tour_stop_id: f.get('kind') === 'open' ? (f.get('tour_stop_id') || null) : null, service_ids: ids.length ? ids : null, active: true };
    if (row.end_at <= row.start_at) return toast('End must be after start', true);
    const { error } = editing ? await sb.from('availability_exceptions').update(row).eq('id', editing.id) : await sb.from('availability_exceptions').insert(row);
    if (error) return fail(error); toast('Saved'); delete view.dataset.editExc; exceptions().catch(fail);
  };
}

/* =============================== TOUR STOPS =============================== */
async function tours() {
  const { data, error } = await sb.from('tour_stops').select('id,slug,city,country,timezone,start_at,end_at,booking_opens_at,booking_closes_at,venue,address,location_notes,status,tour_stop_services(service_id)').order('start_at', { ascending: false }); if (error) throw error;
  const editing = view.dataset.editTour ? data.find((r) => r.id === view.dataset.editTour) : null;
  const tz = editing?.timezone || 'Africa/Harare';
  const statuses = ['draft', 'open', 'closed', 'completed', 'cancelled'];
  view.innerHTML = `
    <div class="ad-head"><div><h1>Tour stops</h1><p class="ad-muted">Where you'll coach in person. A stop produces bookable slots only while it is <b>open</b>, through its open exceptions, for its eligible services.</p></div></div>
    <div class="ad-grid2">
      <div class="ad-panel">${table(['Stop', 'Dates', 'Booking window', 'Services', 'Status', ''], data.map((r) => `<tr>
        <td><b>${esc(r.city)}</b>, ${esc(r.country)}<br><span class="ad-muted" style="font-size:12px">${esc(r.venue || '')}${r.venue && r.address ? ' · ' : ''}${esc(r.address || '')}</span></td>
        <td>${fmt(r.start_at, r.timezone, { dateStyle: 'medium' })} → ${fmt(r.end_at, r.timezone, { dateStyle: 'medium' })}<br><span class="ad-muted" style="font-size:12px">${esc(r.timezone)}</span></td>
        <td>${r.booking_opens_at || r.booking_closes_at ? `${fmt(r.booking_opens_at, r.timezone)} → ${fmt(r.booking_closes_at, r.timezone)}` : 'while open'}</td>
        <td>${r.tour_stop_services?.length ? r.tour_stop_services.map((x) => esc(svcTitle(x.service_id))).join('<br>') : '<span class="ad-muted">none yet</span>'}</td>
        <td>${st(r.status)}</td>
        <td class="acts"><button class="btn btn-line btn-xs" data-edit="${r.id}">Edit</button>${r.status === 'draft' ? `<button class="btn btn-accent btn-xs" data-status="open" data-id="${r.id}">Open</button>` : ''}${r.status === 'open' ? `<button class="btn btn-line btn-xs" data-status="closed" data-id="${r.id}">Close</button>` : ''}</td></tr>`), 'No tour stops yet.')}
        <p class="ad-note">After opening a stop, add its bookable windows under Exceptions (kind Open, linked to the stop).</p></div>
      <div class="ad-panel"><h2>${editing ? 'Edit stop' : 'Add stop'}</h2>
        <form id="tour-form" class="ad-form">
          <div class="row"><label>City <input name="city" required value="${esc(editing?.city || '')}"></label><label>Country <input name="country" required value="${esc(editing?.country || '')}"></label></div>
          <div class="row"><label>Slug <input name="slug" required pattern="[a-z0-9-]{2,80}" value="${esc(editing?.slug || '')}" placeholder="harare-2026-11"></label><label>Timezone ${tzSelect('timezone', tz)}</label></div>
          <div class="row"><label>Arrive <input type="datetime-local" name="start" required value="${utcToLocalInput(editing?.start_at, tz)}"></label><label>Leave <input type="datetime-local" name="end" required value="${utcToLocalInput(editing?.end_at, tz)}"></label></div>
          <div class="row"><label>Booking opens <input type="datetime-local" name="opens" value="${utcToLocalInput(editing?.booking_opens_at, tz)}"></label><label>Booking closes <input type="datetime-local" name="closes" value="${utcToLocalInput(editing?.booking_closes_at, tz)}"></label></div>
          <div class="row"><label>Venue <input name="venue" value="${esc(editing?.venue || '')}"></label><label>Address <input name="address" value="${esc(editing?.address || '')}"></label></div>
          <label>Location notes <textarea name="location_notes">${esc(editing?.location_notes || '')}</textarea></label>
          <label>Status <select name="status">${statuses.map((s) => `<option ${(editing?.status || 'draft') === s ? 'selected' : ''}>${s}</option>`).join('')}</select></label>
          <label>Eligible services<div style="display:grid;gap:6px">${serviceChecks('service_ids', (editing?.tour_stop_services || []).map((x) => x.service_id))}</div></label>
          <div class="actions"><button class="btn btn-accent btn-sm" type="submit">${editing ? 'Save' : 'Add'}</button>${editing ? '<button class="btn btn-line btn-sm" type="button" data-cancel-edit>Cancel</button>' : ''}</div>
        </form></div></div>`;
  view.querySelectorAll('[data-edit]').forEach((b) => b.onclick = () => { view.dataset.editTour = b.dataset.edit; tours().catch(fail); });
  view.querySelector('[data-cancel-edit]')?.addEventListener('click', () => { delete view.dataset.editTour; tours().catch(fail); });
  view.querySelectorAll('[data-status]').forEach((b) => b.onclick = async () => { const { error } = await sb.from('tour_stops').update({ status: b.dataset.status }).eq('id', b.dataset.id); if (error) return fail(error); toast('Saved'); tours().catch(fail); });
  $('#tour-form').onsubmit = async (e) => {
    e.preventDefault(); const f = new FormData(e.target); const z = f.get('timezone');
    const row = { city: f.get('city'), country: f.get('country'), slug: f.get('slug'), timezone: z, start_at: zonedToUtc(f.get('start'), z), end_at: zonedToUtc(f.get('end'), z),
      booking_opens_at: f.get('opens') ? zonedToUtc(f.get('opens'), z) : null, booking_closes_at: f.get('closes') ? zonedToUtc(f.get('closes'), z) : null,
      venue: f.get('venue') || null, address: f.get('address') || null, location_notes: f.get('location_notes') || null, status: f.get('status') };
    if (row.end_at <= row.start_at) return toast('Leave must be after arrive', true);
    let id = editing?.id;
    if (editing) { const { error } = await sb.from('tour_stops').update(row).eq('id', id); if (error) return fail(error); }
    else { const { data: ins, error } = await sb.from('tour_stops').insert(row).select('id').single(); if (error) return fail(error); id = ins.id; }
    const ids = f.getAll('service_ids');
    const { error: e1 } = await sb.from('tour_stop_services').delete().eq('tour_stop_id', id); if (e1) return fail(e1);
    if (ids.length) { const { error: e2 } = await sb.from('tour_stop_services').insert(ids.map((service_id) => ({ tour_stop_id: id, service_id }))); if (e2) return fail(e2); }
    toast('Saved'); delete view.dataset.editTour; tours().catch(fail);
  };
}

/* =============================== SERVICES (catalogue, CG-007) =============================== */
/* The commercial catalogue is the only admin-editable content. Writes go
   through catalog_save_service (catalog:manage) which audits every change.
   Changing a price / title / duration affects future bookings only:
   holds, bookings and orders keep the snapshot taken when they were made. */
async function catalogue() {
  const manage = has('catalog:manage');
  const [{ data: rows, error }, { data: audit }] = await Promise.all([
    sb.from('services').select(SERVICE_COLS).order('sort_order').order('title'),
    sb.from('catalog_audit').select('slug,action,changed_by,changed_at,changed_fields').order('changed_at', { ascending: false }).limit(40),
  ]); if (error) throw error;
  services = rows || [];
  const editing = view.dataset.editSvc === 'new' ? {} : (view.dataset.editSvc ? services.find((s) => s.slug === view.dataset.editSvc) : null);
  const opt = (list, v) => list.map((x) => `<option value="${x}" ${x === v ? 'selected' : ''}>${x}</option>`).join('');
  view.innerHTML = `
    <div class="ad-head"><div><h1>Services</h1><p class="ad-muted">The commercial catalogue: what the website shows and what can be booked. Bookable = offered in the picker at the listed price; enquiry = a card whose button opens the form. Existing bookings and orders keep the price, title and duration they were sold with.</p></div>
      ${manage ? '<div class="ad-filters"><button class="btn btn-accent btn-sm" data-new-svc>Add a service</button></div>' : ''}</div>
    <div class="ad-panel">${table(['Order', 'Service', 'Mode', 'Price', 'Duration', 'Delivery', 'Capacity', 'Public', ''], services.map((s) => `<tr>
      <td class="num">${s.sort_order}</td>
      <td><b>${esc(s.title)}</b>${s.featured ? ' ' + st('featured') : ''}<br><span class="ad-muted" style="font-size:12px">${esc(s.slug)} · ${esc(s.category)}${s.tagline ? ' · ' + esc(s.tagline) : ''}</span></td>
      <td>${st(s.booking_mode === 'slot' ? 'bookable' : 'enquiry')}</td>
      <td class="num">${s.price_amount == null ? 'on request' : money(s.price_amount, s.currency)}<br><span class="ad-muted" style="font-size:12px">${esc(s.price_unit)}</span></td>
      <td class="num">${s.duration_minutes} min</td><td>${esc(s.delivery_mode)}</td><td class="num">${s.default_capacity}</td>
      <td>${s.active ? st('open') : st('closed')} ${s.listed ? st('ready') : st('hold')}<br><span class="ad-muted" style="font-size:12px">${s.active ? 'active' : 'inactive'} · ${s.listed ? 'listed' : 'hidden'}</span></td>
      <td class="acts">${manage ? `<button class="btn btn-line btn-xs" data-edit-svc="${esc(s.slug)}">Edit</button>` : ''}</td></tr>`), 'No service yet.')}
      <p class="ad-note">"Active" means the service can be booked or enquired about; "listed" means it appears on the website. Services are never deleted — deactivate and hide them instead, so history stays intact.</p></div>
    ${editing ? `<div class="ad-panel"><h2>${editing.id ? 'Edit ' + esc(editing.title) : 'New service'}</h2>
      <form id="svc-form" class="ad-form">
        <div class="row">
          <label>Slug (identity, cannot change later) <input name="slug" required pattern="[a-z0-9-]{2,60}" value="${esc(editing.slug || '')}" ${editing.id ? 'readonly' : ''}></label>
          <label>Title <input name="title" required maxlength="120" value="${esc(editing.title || '')}"></label>
          <label>Tagline (small label above the title) <input name="tagline" maxlength="40" value="${esc(editing.tagline || '')}"></label></div>
        <label>Short description (the card) <textarea name="description" maxlength="300">${esc(editing.description || '')}</textarea></label>
        <label>Long description (internal / future detail page) <textarea name="long_description" maxlength="2000">${esc(editing.long_description || '')}</textarea></label>
        <label>Features, one per line (max 8) <textarea name="features">${esc((editing.features || []).join('\n'))}</textarea></label>
        <div class="row">
          <label>Price (major units, empty = on request) <input name="price" type="number" min="0" step="0.01" value="${editing.price_amount == null ? '' : (editing.price_amount / 100)}"></label>
          <label>Currency <input name="currency" pattern="[A-Z]{3}" value="${esc(editing.currency || 'USD')}"></label>
          <label>Price unit <select name="price_unit">${opt(['per session', 'per month', 'one-off', 'per person'], editing.price_unit || 'per session')}</select></label>
          <label>Duration (minutes) <input name="duration_minutes" type="number" min="15" max="480" required value="${editing.duration_minutes || 60}"></label></div>
        <div class="row">
          <label>Booking mode <select name="booking_mode">${opt(['slot', 'enquiry'], editing.booking_mode || 'enquiry')}</select></label>
          <label>Delivery <select name="delivery_mode">${opt(['online', 'onsite'], editing.delivery_mode || 'online')}</select></label>
          <label>Category <select name="category">${opt(['coaching', 'mentoring', 'onsite', 'programme', 'group'], editing.category || 'coaching')}</select></label>
          <label>Default capacity <input name="default_capacity" type="number" min="1" max="100" value="${editing.default_capacity || 1}"></label></div>
        <div class="row">
          <label>Button label (optional) <input name="cta_label" maxlength="40" value="${esc(editing.cta_label || '')}" placeholder="Book a session → / Enquire →"></label>
          <label>Display order <input name="sort_order" type="number" value="${editing.sort_order ?? 100}"></label></div>
        <div class="row">
          <label style="display:flex;gap:8px;align-items:center"><input type="checkbox" name="active" ${editing.active ? 'checked' : ''}> Active</label>
          <label style="display:flex;gap:8px;align-items:center"><input type="checkbox" name="listed" ${editing.listed ? 'checked' : ''}> Listed on the website</label>
          <label style="display:flex;gap:8px;align-items:center"><input type="checkbox" name="featured" ${editing.featured ? 'checked' : ''}> Highlighted card</label></div>
        <div class="actions"><button class="btn btn-accent btn-sm" type="submit">Save</button><button class="btn btn-line btn-sm" type="button" data-cancel-edit>Cancel</button></div>
      </form>
      <p class="ad-note">A bookable service with a price is charged exactly this amount at Checkout. Prices of enquiry-only products are shown on the website only when commerce is switched on in config.js.</p></div>` : ''}
    <div class="ad-panel"><h2>Change log</h2>${table(['When', 'Who', 'Service', 'Action', 'Fields'], (audit || []).map((a) => `<tr><td>${fmt(a.changed_at, 'Asia/Dubai', { dateStyle: 'medium', timeStyle: 'short' })}</td><td>${esc(a.changed_by)}</td><td>${esc(a.slug)}</td><td>${st(a.action === 'create' ? 'new' : 'contacted')}</td><td class="msg">${esc((a.changed_fields || []).join(', '))}</td></tr>`), 'No change recorded yet.')}</div>`;
  view.querySelector('[data-new-svc]')?.addEventListener('click', () => { view.dataset.editSvc = 'new'; catalogue().catch(fail); });
  view.querySelectorAll('[data-edit-svc]').forEach((b) => b.onclick = () => { view.dataset.editSvc = b.dataset.editSvc; catalogue().catch(fail); });
  view.querySelector('[data-cancel-edit]')?.addEventListener('click', () => { delete view.dataset.editSvc; catalogue().catch(fail); });
  $('#svc-form')?.addEventListener('submit', async (e) => {
    e.preventDefault(); const f = new FormData(e.target);
    const priceRaw = String(f.get('price') || '').trim();
    const p = {
      slug: f.get('slug'), title: f.get('title'), tagline: f.get('tagline'), description: f.get('description'), long_description: f.get('long_description'),
      features: String(f.get('features') || '').split('\n').map((x) => x.trim()).filter(Boolean),
      price_amount: priceRaw === '' ? null : Math.round(Number(priceRaw) * 100), currency: String(f.get('currency') || 'USD').toUpperCase(), price_unit: f.get('price_unit'),
      duration_minutes: Number(f.get('duration_minutes')), booking_mode: f.get('booking_mode'), delivery_mode: f.get('delivery_mode'), category: f.get('category'),
      default_capacity: Number(f.get('default_capacity')), cta_label: f.get('cta_label'), sort_order: Number(f.get('sort_order')),
      active: f.get('active') === 'on', listed: f.get('listed') === 'on', featured: f.get('featured') === 'on',
    };
    if (p.price_amount !== null && (!Number.isFinite(p.price_amount) || p.price_amount < 0)) return toast('Price must be a positive amount', true);
    const { data, error } = await sb.rpc('catalog_save_service', { p });
    if (error) return fail(error);
    const changed = data?.changed || [];
    toast(changed.length ? `Saved — changed: ${changed.join(', ')}` : 'No change');
    delete view.dataset.editSvc; catalogue().catch(fail);
  });
}

/* =============================== FINANCE =============================== */
async function finance() {
  const manage = has('finance:manage');
  const [{ data: orders, error }, { data: settlements }, { data: events }] = await Promise.all([
    sb.rpc('finance_orders').limit(300),
    sb.from('partner_settlements').select('*').order('created_at', { ascending: false }),
    sb.rpc('finance_webhook_log').limit(30),
  ]); if (error) throw error;
  const open = orders.filter((o) => o.earning_status === 'open');
  const sum = (arr, k) => arr.reduce((a, o) => a + (o[k] || 0), 0);
  const today = new Date(); const monthStart = new Date(Date.UTC(today.getUTCFullYear(), today.getUTCMonth(), 1));
  view.innerHTML = `
    <div class="ad-head"><div><h1>Finance</h1><p class="ad-muted">Stripe <b>test mode</b>. Orders, payments and the partner ledger. No names, no contacts, no enquiries — only a masked hint to match a Stripe receipt. Refunds are issued in the Stripe dashboard and land here through the webhook.</p></div></div>
    <div class="ad-kpis">
      <div class="ad-kpi"><b>${money(sum(orders.filter((o) => o.paid_at), 'gross_amount'))}</b><span>Gross collected</span></div>
      <div class="ad-kpi"><b>${money(sum(orders, 'net_collected'))}</b><span>Net after fees, refunds, chargebacks</span></div>
      <div class="ad-kpi"><b>${money(sum(orders, 'oolala_commission'))}</b><span>Oolala commission (${CONFIG.COMMISSION_RATE})</span></div>
      <div class="ad-kpi"><b>${money(sum(open, 'gari_payable'))}</b><span>Payable to Gari — not yet settled</span></div>
    </div>
    <div class="ad-panel"><h2>Settlements</h2>
      ${table(['Ref', 'Period', 'Items', 'Gross', 'Fees', 'Refunds/CB', 'Net', 'Commission', 'Payable', 'Status', ''], settlements.map((s) => `<tr>
        <td>${esc(s.reference)}</td><td>${s.period_start} → ${s.period_end}</td><td class="num">${(orders.filter((o) => o.settlement_id === s.id)).length}</td>
        <td class="num">${money(s.gross_amount, s.currency)}</td><td class="num">${money(s.fee_amount, s.currency)}</td><td class="num">${money(s.refund_amount + s.chargeback_amount, s.currency)}</td>
        <td class="num">${money(s.net_collected, s.currency)}</td><td class="num">${money(s.oolala_commission, s.currency)}</td><td class="num"><b>${money(s.amount_payable, s.currency)}</b></td>
        <td>${st(s.status)}${s.bank_transfer_reference ? `<div class="msg">${esc(s.bank_transfer_reference)}</div>` : ''}</td>
        <td class="acts">${manage && s.status === 'ready' ? `<button class="btn btn-accent btn-xs" data-paid="${s.reference}">Mark paid</button>` : ''}${manage && s.status === 'paid' ? `<button class="btn btn-dark btn-xs" data-recon="${s.reference}">Reconciled</button>` : ''}</td></tr>`), 'No settlement yet.')}
      ${manage ? `<form id="settle-form" class="ad-form" style="margin-top:16px"><div class="row"><label>Period from <input type="date" name="from" required value="${isoDate(monthStart)}"></label><label>to <input type="date" name="to" required value="${isoDate(today)}"></label><label>Currency <input name="currency" value="USD" pattern="[A-Z]{3}"></label></div>
        <div class="actions"><button class="btn btn-accent btn-sm" type="submit">Create settlement for open earnings</button></div></form><p class="ad-note">Creates a settlement from every open earning whose payment date falls in the period, then freezes those earnings. Pay Gari by bank transfer and record the reference with "Mark paid".</p>` : '<p class="ad-note">View only. Settlement actions need the finance:manage permission.</p>'}</div>
    <div class="ad-panel"><h2>Orders</h2>
      ${table(['Created', 'Order', 'Booking', 'Session', 'Customer hint', 'Gross', 'Fee', 'Refunds', 'CB', 'Net', 'Commission', 'Payable', 'Status'], orders.map((o) => `<tr>
        <td>${fmt(o.created_at, 'Asia/Dubai')}</td><td>${esc(o.reference)}<br>${st(o.status)}</td><td>${esc(o.booking_reference)}<br>${st(o.booking_status)}</td>
        <td>${esc(o.service_title)}<br><span class="ad-muted" style="font-size:12px">${fmt(o.session_start_at, o.session_timezone)} · ${esc(o.delivery_mode)}</span></td>
        <td class="ad-muted" style="font-size:12px">${esc(o.customer_hint || '—')}</td>
        <td class="num">${money(o.gross_amount, o.currency)}</td><td class="num">${money(o.stripe_fee, o.currency)}</td><td class="num">${money(o.refund_amount, o.currency)}</td><td class="num">${money(o.chargeback_amount, o.currency)}</td>
        <td class="num">${money(o.net_collected, o.currency)}</td><td class="num">${money(o.oolala_commission, o.currency)}</td><td class="num"><b>${money(o.gari_payable, o.currency)}</b></td>
        <td>${o.earning_status ? st(o.earning_status) : '—'}${o.adjusted_at ? '<div class="msg">adjusted after settlement</div>' : ''}</td></tr>`), 'No orders yet.')}</div>
    <div class="ad-panel"><h2>Webhook log</h2>${table(['Received', 'Event', 'Type', 'Status', 'Note'], events.map((e) => `<tr><td>${fmt(e.received_at, 'Asia/Dubai', { dateStyle: 'medium', timeStyle: 'medium' })}</td><td class="ad-muted" style="font-size:12px">${esc(e.event_id)}</td><td>${esc(e.event_type)}</td><td>${st(e.status)}</td><td class="msg">${esc(e.note || '')}</td></tr>`), 'No Stripe events received yet.')}</div>`;
  view.querySelectorAll('[data-paid]').forEach((b) => b.onclick = async () => {
    const ref = window.prompt(`Bank transfer reference for ${b.dataset.paid}:`); if (!ref) return;
    const { error } = await sb.rpc('finance_mark_settlement_paid', { p_reference: b.dataset.paid, p_bank_transfer_reference: ref }); if (error) return fail(error); toast('Marked paid'); finance().catch(fail);
  });
  view.querySelectorAll('[data-recon]').forEach((b) => b.onclick = async () => {
    if (!(await confirmAct(`Mark ${b.dataset.recon} as reconciled with the bank statement?`))) return;
    const { error } = await sb.rpc('finance_mark_settlement_reconciled', { p_reference: b.dataset.recon }); if (error) return fail(error); toast('Reconciled'); finance().catch(fail);
  });
  $('#settle-form')?.addEventListener('submit', async (e) => {
    e.preventDefault(); const f = new FormData(e.target);
    const { data, error } = await sb.rpc('finance_create_settlement', { p_period_start: f.get('from'), p_period_end: f.get('to'), p_currency: f.get('currency') || 'USD' }); if (error) return fail(error);
    toast(`${data.reference}: ${data.items} item(s), payable ${money(data.amount_payable, data.currency)}`); finance().catch(fail);
  });
}

/* =============================== ANALYTICS =============================== */
async function analytics() {
  const { data: a, error } = await sb.rpc('analytics_summary'); if (error) throw error;
  const kv = (obj) => Object.entries(obj || {}).sort((x, y) => y[1] - x[1]).map(([k, v]) => `<tr><td>${esc(k)}</td><td class="num">${v}</td></tr>`);
  view.innerHTML = `
    <div class="ad-head"><div><h1>Analytics</h1><p class="ad-muted">Aggregates only — no names, no messages. Generated ${fmt(a.generated_at, 'Asia/Dubai')}.</p></div></div>
    <div class="ad-kpis">
      <div class="ad-kpi"><b>${a.leads.total}</b><span>Leads, all time</span></div>
      <div class="ad-kpi"><b>${a.leads.last_30d}</b><span>Leads, last 30 days</span></div>
      <div class="ad-kpi"><b>${a.bookings.confirmed_last_30d}</b><span>Confirmed bookings, last 30 days</span></div>
      <div class="ad-kpi"><b>${money(a.revenue.totals.gross)}</b><span>Gross collected (test mode)</span></div>
      <div class="ad-kpi"><b>${money(a.revenue.totals.payable)}</b><span>Payable to Gari, all time</span></div>
    </div>
    <div class="ad-grid2">
      <div class="ad-panel"><h2>Leads per week (12 weeks)</h2>${table(['Week of', 'Leads'], a.leads.by_week.map((w) => `<tr><td>${w.week}</td><td class="num">${w.count}</td></tr>`), 'No leads in the last 12 weeks.')}</div>
      <div class="ad-panel"><h2>Leads by interest</h2>${table(['Interest', 'Leads'], kv(a.leads.by_interest))}</div>
      <div class="ad-panel"><h2>Leads by country</h2>${table(['Country', 'Leads'], a.leads.by_country.map((c) => `<tr><td>${esc(c.country)}</td><td class="num">${c.count}</td></tr>`))}</div>
      <div class="ad-panel"><h2>Leads by source</h2>${table(['Source', 'Leads'], kv(a.leads.by_source))}</div>
      <div class="ad-panel"><h2>Bookings by status</h2>${table(['Status', 'Bookings'], kv(a.bookings.by_status))}</div>
      <div class="ad-panel"><h2>Sessions by service</h2>${table(['Service', 'Sessions'], a.bookings.by_service.map((s) => `<tr><td>${esc(s.service)}</td><td class="num">${s.count}</td></tr>`))}</div>
      <div class="ad-panel"><h2>Revenue by month</h2>${table(['Month', 'Orders', 'Gross', 'Net', 'Commission', 'Payable'], a.revenue.by_month.map((m) => `<tr><td>${m.month}</td><td class="num">${m.orders}</td><td class="num">${money(m.gross)}</td><td class="num">${money(m.net)}</td><td class="num">${money(m.commission)}</td><td class="num">${money(m.payable)}</td></tr>`), 'No paid orders yet.')}</div>
    </div>`;
}

/* =============================== ACCESS (platform:admin) =============================== */
/* Access administration only. Granting a permission here never bypasses RLS:
   business data still requires the explicit business permissions. */
const PERMS = ['coach:operations', 'client_profile:view', 'client_profile:manage', 'health_metrics:view', 'health_metrics:manage', 'coaching_sensitive:view', 'coaching_sensitive:manage', 'finance:view', 'finance:manage', 'analytics:view', 'catalog:view', 'catalog:manage', 'platform:admin'];
async function access() {
  const { data: users, error } = await sb.rpc('admin_list_access'); if (error) throw error;
  view.innerHTML = `
    <div class="ad-head"><div><h1>Access</h1><p class="ad-muted">Who can sign in and what each person may do. Invitations are created in Supabase Auth; this screen attaches application access to an invited email. Nothing here bypasses the row-level rules.</p></div></div>
    <div class="ad-panel">${table(['Email', 'Name', 'Party', 'Auth', 'Active', ...PERMS.map((p) => p.replace(':', ':<wbr>'))], users.map((u) => `<tr>
      <td>${esc(u.email)}</td><td>${esc(u.display_name || '')}</td><td>${esc(u.party)}</td>
      <td>${u.auth_exists ? st('confirmed') : st('pending')}</td>
      <td><input type="checkbox" data-active="${esc(u.email)}" ${u.active ? 'checked' : ''} ${u.email === me.email ? 'disabled' : ''}></td>
      ${PERMS.map((p) => `<td><input type="checkbox" data-perm="${p}" data-email="${esc(u.email)}" ${u.permissions.includes(p) ? 'checked' : ''} ${u.email === me.email && p === 'platform:admin' ? 'disabled' : ''}></td>`).join('')}
    </tr>`), 'No application users yet.')}
      <p class="ad-note">"Auth pending" means the email has no Supabase Auth identity yet — invite it under Authentication → Users, then it can sign in.</p>
      <p class="ad-note"><b>Sensitive coaching data.</b> <code>health_metrics:*</code> (progress measurements) and <code>coaching_sensitive:*</code> (private coaching notes and consent management) are granted independently — no other permission, <b>platform:admin included</b>, implies them. Tick or untick them per person to give or remove that access on its own.</p></div>
    <div class="ad-panel"><h2>Add a person</h2>
      <form id="access-form" class="ad-form"><div class="row">
        <label>Email <input type="email" name="email" required></label>
        <label>Name <input name="display_name" required></label>
        <label>Party <select name="party"><option value="gari">gari</option><option value="oolala">oolala</option><option value="studio">studio</option></select></label></div>
        <label>Permissions<div style="display:grid;gap:6px">${PERMS.map((p) => `<label style="display:flex;gap:8px;align-items:center;font-weight:500"><input type="checkbox" name="perm" value="${p}"> ${p}</label>`).join('')}</div></label>
        <div class="actions"><button class="btn btn-accent btn-sm" type="submit">Add</button></div></form>
      <p class="ad-note">The person must already have been invited in Supabase Auth, otherwise this is refused.</p></div>`;
  view.querySelectorAll('[data-perm]').forEach((cb) => cb.onchange = async () => {
    const { error } = await sb.rpc(cb.checked ? 'admin_grant' : 'admin_revoke', { p_email: cb.dataset.email, p_permission: cb.dataset.perm });
    if (error) { cb.checked = !cb.checked; return fail(error); } toast((cb.checked ? 'Granted ' : 'Revoked ') + cb.dataset.perm);
  });
  view.querySelectorAll('[data-active]').forEach((cb) => cb.onchange = async () => {
    const u = users.find((x) => x.email === cb.dataset.active);
    const { error } = await sb.rpc('admin_set_user', { p_email: u.email, p_display_name: u.display_name, p_party: u.party, p_active: cb.checked });
    if (error) { cb.checked = !cb.checked; return fail(error); } toast(cb.checked ? 'Activated' : 'Deactivated');
  });
  $('#access-form').onsubmit = async (e) => {
    e.preventDefault(); const f = new FormData(e.target);
    const { error } = await sb.rpc('admin_set_user', { p_email: f.get('email'), p_display_name: f.get('display_name'), p_party: f.get('party'), p_active: true });
    if (error) return fail(error);
    for (const p of f.getAll('perm')) { const { error: e2 } = await sb.rpc('admin_grant', { p_email: f.get('email'), p_permission: p }); if (e2) return fail(e2); }
    toast('Access saved'); access().catch(fail);
  };
}

/* =============================== CLIENT PROFILE POPUP =============================== */
/* A large responsive dialog opened from Leads or Contacts. It overlays the
   list (never navigates away), so closing it returns to the same tab,
   filters, search and scroll position. Each section is permission-gated:
   the canonical profile/notes need client_profile:*, progress needs
   health_metrics:*, enquiries/bookings/media need coach:operations, payments
   needs finance:view. Media reuses the private enquiry bucket via short-lived
   signed URLs — no second copy. */
let pf = null;   // { crmId, enquiryId, contact, enquiry, section }

const pfName = () => pf.contact?.display_name || pf.enquiry?.name || 'Client';
function pfPrimary() {
  const em = pf.contact?.email || (pf.enquiry && pf.enquiry.contact?.includes('@') ? pf.enquiry.contact : null);
  const ph = pf.contact?.phone || (pf.enquiry && !pf.enquiry.contact?.includes('@') ? pf.enquiry.contact : null);
  return { em, ph };
}
const waHref = (p) => 'https://wa.me/' + String(p || '').replace(/\D/g, '');
const initials = (n) => (n || '?').trim().split(/\s+/).slice(0, 2).map((x) => x[0]?.toUpperCase() || '').join('') || '?';

async function openProfile(crmId, enquiryId, section = 'overview') {
  const host = $('#profile'); host.hidden = false; document.body.style.overflow = 'hidden';
  host.innerHTML = '<div class="sheet"><div class="pf-body"><p class="ad-empty">Loading…</p></div></div>';
  let enquiry = null, contact = null;
  if (enquiryId) { const { data } = await sb.from('contacts').select(CONTACT_COLS).eq('id', enquiryId).maybeSingle(); enquiry = data; if (!crmId) crmId = data?.crm_contact_id; }
  if (crmId && has('client_profile:view')) { const { data } = await sb.from('crm_contacts').select('*').eq('id', crmId).maybeSingle(); contact = data; }
  pf = { crmId, enquiryId, contact, enquiry, section };
  renderProfile(section);
}
function pfClose() { const host = $('#profile'); host.hidden = true; host.innerHTML = ''; document.body.style.overflow = ''; pf = null; }
document.addEventListener('keydown', (e) => { if (e.key === 'Escape' && !$('#profile').hidden) pfClose(); });

function pfSections() {
  const s = [];
  if (has('client_profile:view') && pf.contact) s.push(['overview', 'Overview', pfOverview], ['notes', 'Notes', pfNotes]);
  if (has('health_metrics:view') && pf.contact) s.push(['progress', 'Progress', pfProgress]);
  if (has('coach:operations') && pf.crmId) s.push(['sessions', 'Sessions', pfSessions]);
  if (has('coach:operations')) s.push(['enquiries', 'Enquiries', pfEnquiries], ['bookings', 'Bookings', pfBookings]);
  if (has('finance:view') && has('coach:operations')) s.push(['payments', 'Payments', pfPayments]);
  if (has('coach:operations')) s.push(['media', 'Media', pfMedia], ['attribution', 'Attribution', pfAttribution]);
  return s;
}

// Client profile → Sessions & packages (operational; the shareable recap/report is CG-012)
async function pfSessions() {
  const [{ data: packs, error: pe }, { data: sess, error: se }] = await Promise.all([
    sb.rpc('packs_for_contact', { p_contact_id: pf.crmId }),
    sb.rpc('sessions_list', { p: { crm_contact_id: pf.crmId } }),
  ]);
  if (pe) throw pe; if (se) throw se;
  const pk = packs || [], ss = sess || [];
  const cname = pf.contact?.display_name || 'this client';
  const packCard = (p) => `<div class="cg-packcard"><div class="cg-packcard-h"><b>${esc(p.title)}</b>${p.status !== 'active' ? st(p.status) : ''}</div>
    <div class="cg-pack"><div class="cg-pack-x">${p.used} / ${p.total_sessions}</div><div class="cg-pack-r">${p.remaining} remaining</div></div>
    ${'price_amount' in p ? `<div class="ad-muted" style="font-size:12.5px">${money(p.price_amount, p.currency)} · ${esc(p.payment_status)}${p.paid_at ? ' · paid ' + fmt(p.paid_at, CAL_TZ, { dateStyle: 'medium' }) : ''}</div>` : ''}</div>`;
  $('#pf-body').innerHTML = `
    <div class="ad-actions" style="display:flex;gap:8px;flex-wrap:wrap;margin-bottom:14px">
      <button class="btn btn-accent btn-sm" id="pf-new-sess">+ Session</button>
      <button class="btn btn-line btn-sm" id="pf-new-pack">+ Package</button></div>
    ${pk.length ? `<div class="cg-packgrid">${pk.map(packCard).join('')}</div>` : '<p class="pf-sec-empty">No packages yet.</p>'}
    <h2 style="font-size:14px;text-transform:uppercase;letter-spacing:.06em;color:var(--grey-text);margin:18px 0 8px">Sessions</h2>
    ${ss.length ? `<div class="ad-panel" style="padding:0"><div class="ad-table-wrap"><table class="ad-table"><thead><tr><th>Date</th><th>Time</th><th>Type</th><th>Package</th><th>Status</th></tr></thead><tbody>
      ${ss.map((s) => { const t = lp(s.start_at), e = lp(s.end_at); return `<tr class="clik" data-sess="${s.id}"><td>${prettyDay(t.date)}</td><td>${String(t.h).padStart(2,'0')}:${String(t.m).padStart(2,'0')}–${String(e.h).padStart(2,'0')}:${String(e.m).padStart(2,'0')}</td><td>${esc(s.title || '—')}</td><td>${s.pack ? `${s.pack.used}/${s.pack.total_sessions}` : '—'}</td><td>${st(s.status)}</td></tr>`; }).join('')}
      </tbody></table></div></div>` : '<p class="pf-sec-empty">No sessions yet.</p>'}`;
  $('#pf-new-sess').onclick = () => sessionForm({ crm_contact_id: pf.crmId, crm_name: cname });
  $('#pf-new-pack').onclick = () => packForm(pf.crmId, () => pfSessions().catch(fail));
  $('#pf-body').querySelectorAll('tr.clik').forEach((tr) => tr.onclick = () => { calData = { sessions: ss, blocks: [] }; openSession(tr.dataset.sess); });
}

function renderProfile(section) {
  const secs = pfSections();
  const active = secs.find(([k]) => k === section) || secs[0];
  pf.section = active ? active[0] : null;
  const { em, ph } = pfPrimary();
  const c = pf.contact;
  const meta = [c ? st(c.status) : null,
    [c?.city || pf.enquiry?.city, c?.country || pf.enquiry?.country].filter(Boolean).join(', ') || null,
    em, ph].filter(Boolean);
  const host = $('#profile');
  host.innerHTML = `<div class="sheet">
    <div class="pf-head">
      <div class="pf-avatar">${esc(initials(pfName()))}</div>
      <div class="pf-id"><h2>${esc(pfName())}</h2><div class="pf-meta">${meta.map((m) => `<span>${typeof m === 'string' && m.startsWith('<span') ? m : esc(m)}</span>`).join('')}</div></div>
      <div class="pf-actions">
        ${ph ? `<a class="btn btn-line btn-xs" href="${waHref(ph)}" target="_blank" rel="noopener">WhatsApp</a>` : ''}
        ${em ? `<a class="btn btn-line btn-xs" href="mailto:${esc(em)}">Email</a>` : ''}
        ${(c && has('client_profile:manage')) ? '<button class="btn btn-line btn-xs" id="pf-edit">Edit</button>' : ''}
        <button class="pf-close" id="pf-x" aria-label="Close">×</button>
      </div>
    </div>
    ${secs.length ? `<div class="pf-tabs">${secs.map(([k, l]) => `<a data-pf="${k}" class="${k === pf.section ? 'on' : ''}">${l}</a>`).join('')}</div>` : ''}
    <div class="pf-body" id="pf-body"><p class="ad-empty">Loading…</p></div>
  </div>`;
  $('#pf-x').onclick = pfClose;
  const eb = $('#pf-edit'); if (eb) eb.onclick = () => openContactEditor(pf.contact);
  const tabs = host.querySelector('.pf-tabs');
  if (tabs) tabs.onclick = (e) => { const a = e.target.closest('[data-pf]'); if (a) { for (const x of tabs.querySelectorAll('a')) x.classList.toggle('on', x === a); renderProfileBody(a.dataset.pf); } };
  if (active) renderProfileBody(active[0]); else $('#pf-body').innerHTML = '<p class="pf-sec-empty">No sections you can view.</p>';
}
function renderProfileBody(key) {
  pf.section = key;
  const run = pfSections().find(([k]) => k === key)?.[2];
  $('#pf-body').innerHTML = '<p class="ad-empty">Loading…</p>';
  if (run) run().catch(fail);
}

/* ---- profile sections ---- */
async function pfOverview() {
  const c = pf.contact;
  const kv = [
    ['Status', c.status], ['City', c.city], ['Country', c.country],
    ['Email', c.email], ['Phone / WhatsApp', c.phone],
    ['Preferred timezone', c.preferred_timezone], ['Preferred language', c.preferred_language],
    ['Height', c.height_cm != null ? c.height_cm + ' cm' : null],
    ['Goals', c.goals],
    ['First seen', fmt(c.first_seen_at, 'Asia/Dubai', { dateStyle: 'medium' })],
    ['Last activity', fmt(c.last_activity_at, 'Asia/Dubai', { dateStyle: 'medium' })],
  ];
  const canMerge = c.needs_review && has('client_profile:manage');
  $('#pf-body').innerHTML = `
    ${c.needs_review ? `<div class="ad-note"><p style="margin:0 0 8px">This person was auto-created from an ambiguous match (a shared email or phone) and is <b>flagged for review</b>. If it is the same person as an existing contact, you can merge this record into that one.</p>
      ${canMerge ? `<div id="pf-merge"><button class="btn btn-line btn-xs" id="pf-merge-open">Merge into another contact…</button></div>` : ''}</div>` : ''}
    <dl class="pf-kv">${kv.map(([k, v]) => `<dt>${esc(k)}</dt><dd>${v ? esc(v) : '—'}</dd>`).join('')}</dl>
    <details class="pf-tech"><summary>Technical</summary><dl class="pf-kv" style="margin-top:10px"><dt>CRM id</dt><dd>${esc(c.id)}</dd><dt>Created by</dt><dd>${esc(c.created_by || '—')}</dd><dt>Updated by</dt><dd>${esc(c.updated_by || '—')}</dd></dl></details>`;
  if (canMerge) $('#pf-merge-open').onclick = () => pfMergePicker(c);
}

// Manual merge of a needs-review record INTO an existing contact. The DB does
// the move transactionally and audits it (crm_merge_contacts); this only picks
// a safe, explicit target and confirms. Enquiry history is never rewritten.
async function pfMergePicker(source) {
  const host = $('#pf-merge');
  host.innerHTML = `<div style="margin-top:8px">
    <input id="pf-merge-search" placeholder="Search the contact to merge into…" style="width:100%;padding:8px;border:1px solid var(--line);border-radius:8px;font:inherit">
    <div id="pf-merge-results" style="margin-top:8px"></div></div>`;
  const box = $('#pf-merge-search'); box.focus();
  const run = async () => {
    const q = box.value.trim();
    if (q.length < 2) { $('#pf-merge-results').innerHTML = '<p class="ad-muted" style="font-size:12px">Type at least 2 characters.</p>'; return; }
    const { data, error } = await sb.rpc('crm_list_contacts', { p_search: q, p_review_only: false });
    if (error) return fail(error);
    const cands = (data || []).filter((x) => x.id !== source.id).slice(0, 8);
    $('#pf-merge-results').innerHTML = cands.length ? cands.map((x) => `<button class="btn btn-line btn-xs" data-target="${x.id}" style="display:block;width:100%;text-align:left;margin-bottom:6px">
      <b>${esc(x.display_name || '—')}</b> · ${esc(x.email || x.phone || 'no contact')} · ${x.enquiry_count} enq / ${x.booking_count} bk${x.needs_review ? ' · <span class="ad-badge-rev">review</span>' : ''}</button>`).join('')
      : '<p class="ad-muted" style="font-size:12px">No matches.</p>';
    $('#pf-merge-results').querySelectorAll('[data-target]').forEach((b) => b.onclick = async () => {
      const target = cands.find((x) => x.id === b.dataset.target);
      if (!await confirmAct(`Merge "${source.display_name || 'this record'}" INTO "${target.display_name || 'the selected contact'}"?\n\nAll enquiries, bookings, notes, measurements and consent history move to the kept contact, and this duplicate record is deleted. This cannot be undone.`)) return;
      const { error } = await sb.rpc('crm_merge_contacts', { p_source: source.id, p_target: target.id });
      if (error) return fail(error);
      toast('Contacts merged'); pfClose(); crmContacts().catch(fail);
    });
  };
  box.oninput = run; run();
}

async function pfNotes() {
  const { data, error } = await sb.from('crm_notes').select('*').eq('crm_contact_id', pf.crmId).order('pinned', { ascending: false }).order('created_at', { ascending: false });
  if (error) throw error;
  const canManage = has('client_profile:manage');
  const canPrivate = has('coaching_sensitive:manage');
  const seesPrivate = has('coaching_sensitive:view');
  const cats = ['general', 'session', 'goal', 'admin'];
  $('#pf-body').innerHTML = `
    ${canManage ? `<form id="pf-note-form" class="ad-form" style="margin:0 0 16px">
      <textarea name="body" required placeholder="Add a note — visible only to the back-office."></textarea>
      <div class="actions"><select name="category"><option value="">No category</option>${cats.map((c) => `<option>${c}</option>`).join('')}</select>
      ${canPrivate ? `<label style="flex-direction:row;align-items:center;gap:6px;font-weight:600" title="Private coaching notes are only visible to people with coaching_sensitive access."><input type="checkbox" name="private"> Private coaching note</label>` : ''}
      <label style="flex-direction:row;align-items:center;gap:6px;font-weight:600"><input type="checkbox" name="pinned"> Pin</label>
      <button class="btn btn-accent btn-sm" type="submit">Add note</button></div></form>` : ''}
    ${seesPrivate ? '' : '<p class="ad-muted" style="font-size:12px;margin:0 0 10px">Operational notes only. Private coaching notes need <code>coaching_sensitive:view</code>.</p>'}
    <div id="pf-note-list">${(data || []).map(noteHtml).join('') || '<p class="pf-sec-empty">No notes yet.</p>'}</div>`;
  const form = $('#pf-note-form');
  if (form) form.onsubmit = async (e) => {
    e.preventDefault(); const f = new FormData(form);
    const { error } = await sb.rpc('crm_add_note', { p_contact_id: pf.crmId, p_body: f.get('body'), p_category: f.get('category') || null, p_pinned: !!f.get('pinned'), p_scope: f.get('private') ? 'coach_private' : 'operational' });
    if (error) return fail(error); toast('Note added'); pfNotes().catch(fail);
  };
  bindNoteActions();
}
function noteHtml(n) {
  const priv = n.scope === 'coach_private';
  return `<div class="pf-note ${n.pinned ? 'pinned' : ''}" data-note="${n.id}">
    <div class="body">${esc(n.body)}</div>
    <div class="meta">${n.pinned ? '📌 ' : ''}${priv ? '<span class="ad-badge-priv">private</span> ' : ''}${n.category ? esc(n.category) + ' · ' : ''}${esc(n.author)} · ${fmt(n.created_at, 'Asia/Dubai')}${n.updated_at && n.updated_at !== n.created_at ? ' · edited' : ''}
      ${has('client_profile:manage') ? `<button class="btn btn-line btn-xs" data-note-edit="${n.id}">Edit</button><button class="btn btn-line btn-xs" data-note-pin="${n.id}" data-to="${!n.pinned}">${n.pinned ? 'Unpin' : 'Pin'}</button>` : ''}</div></div>`;
}
function bindNoteActions() {
  $('#pf-body').querySelectorAll('[data-note-pin]').forEach((b) => b.onclick = async () => {
    const note = $('#pf-body').querySelector(`[data-note="${b.dataset.notePin}"] .body`).textContent;
    const { error } = await sb.rpc('crm_edit_note', { p_note_id: b.dataset.notePin, p_body: note, p_pinned: b.dataset.to === 'true' });
    if (error) return fail(error); pfNotes().catch(fail);
  });
  $('#pf-body').querySelectorAll('[data-note-edit]').forEach((b) => b.onclick = () => {
    const card = $('#pf-body').querySelector(`[data-note="${b.dataset.noteEdit}"]`);
    const body = card.querySelector('.body').textContent;
    card.innerHTML = `<textarea class="ad-edit" style="width:100%;min-height:70px;font:inherit;padding:8px;border:1px solid var(--line);border-radius:8px">${esc(body)}</textarea>
      <div class="actions" style="display:flex;gap:8px;margin-top:8px"><button class="btn btn-accent btn-xs" data-save>Save</button><button class="btn btn-line btn-xs" data-cancel>Cancel</button></div>`;
    card.querySelector('[data-cancel]').onclick = () => pfNotes().catch(fail);
    card.querySelector('[data-save]').onclick = async () => {
      const { error } = await sb.rpc('crm_edit_note', { p_note_id: b.dataset.noteEdit, p_body: card.querySelector('textarea').value });
      if (error) return fail(error); toast('Note updated'); pfNotes().catch(fail);
    };
  });
}

async function pfProgress() {
  const [{ data, error }, { data: cs, error: ce }] = await Promise.all([
    sb.from('body_measurements').select('*').eq('crm_contact_id', pf.crmId).order('measured_at', { ascending: false }).order('created_at', { ascending: false }),
    sb.rpc('consent_status', { p_contact_id: pf.crmId }),
  ]);
  if (error) throw error; if (ce) throw ce;
  const rows = data || [];
  const latest = rows[0], prev = rows[1];
  const consent = cs || { active: false, is_minor: false, notice_version: null, history: [] };
  const canManage = has('health_metrics:manage');
  const canView = has('health_metrics:view');
  const isMinor = !!consent.is_minor;
  const active = !!consent.active;
  const canRecord = canManage && active && !isMinor;      // measurement form only when consent is active
  const delta = (a, b, unit, goodDown) => {
    if (a == null || b == null) return '';
    const d = +(a - b).toFixed(1); if (d === 0) return `<div class="delta flat">no change</div>`;
    const down = d < 0; const good = goodDown ? down : !down;
    return `<div class="delta ${good ? 'up' : 'down'}">${down ? '↓' : '↑'} ${Math.abs(d)}${unit}</div>`;
  };
  const metric = (lbl, val, unit, d) => val == null ? '' : `<div class="pf-metric"><div class="lbl">${lbl}</div><div class="val">${val}${unit}</div>${d}</div>`;
  const chron = rows.slice().reverse().filter((r) => r.weight_kg != null);

  // ---- consent panel ----
  const statusBadge = isMinor ? '<span class="ad-badge-rev">minor — not available</span>'
    : active ? '<span class="ad-badge-ok">consent active</span>'
    : '<span class="ad-badge-warn">no active consent</span>';
  const hist = (consent.history || []).slice(0, 6).map((h) => `<tr><td>${esc(h.status)}</td><td>${esc(h.source || '—')}</td><td>${esc(h.notice_version || '—')}</td><td>${h.consented_at ? fmt(h.consented_at, 'Asia/Dubai', { dateStyle: 'medium', timeStyle: 'short' }) : '—'}</td><td>${h.withdrawn_at ? fmt(h.withdrawn_at, 'Asia/Dubai', { dateStyle: 'medium', timeStyle: 'short' }) : '—'}</td></tr>`).join('');
  const consentPanel = `
    <div class="pf-consent">
      <div class="pf-consent-head"><b>Progress tracking consent</b> ${statusBadge}${consent.notice_version ? ` <span class="ad-muted" style="font-size:12px">notice ${esc(consent.notice_version)}</span>` : ''}</div>
      ${isMinor ? '<p class="ad-note">This contact is marked as a minor. Progress tracking is not available for minors in this version — there is no measurement recording here.</p>'
        : active ? '<p class="ad-muted" style="font-size:13px;margin:6px 0 0">The client has given consent. You can record and manage their progress below. Withdrawal stops future recording without deleting past records.</p>'
        : '<p class="ad-note">No active consent. Measurements are blocked until the client consents. Send them the consent link, or record their consent as a documented fallback.</p>'}
      ${canManage && !isMinor ? `<div class="actions" style="display:flex;gap:8px;flex-wrap:wrap;margin-top:10px">
        ${!active ? '<button class="btn btn-accent btn-xs" id="pf-consent-link">Send consent link</button>' : ''}
        ${!active ? '<button class="btn btn-line btn-xs" id="pf-consent-record">Record consent (fallback)…</button>' : ''}
        ${active ? '<button class="btn btn-line btn-xs" id="pf-consent-withdraw">Withdraw consent</button>' : ''}
      </div><div id="pf-consent-out" style="margin-top:8px"></div>` : ''}
      ${hist ? `<details class="pf-tech" style="margin-top:10px"><summary>Consent history</summary><div class="ad-table-wrap" style="margin-top:8px"><table class="ad-table"><thead><tr><th>Status</th><th>Source</th><th>Notice</th><th>Consented</th><th>Withdrawn</th></tr></thead><tbody>${hist}</tbody></table></div></details>` : ''}
    </div>`;

  $('#pf-body').innerHTML = `
    ${consentPanel}
    ${latest ? `<div class="pf-metrics">
      ${metric('Weight', latest.weight_kg, ' kg', delta(latest.weight_kg, prev?.weight_kg, ' kg', true))}
      ${metric('BMI', latest.bmi, '', delta(latest.bmi, prev?.bmi, '', true))}
      ${metric('Body fat', latest.body_fat_pct, '%', delta(latest.body_fat_pct, prev?.body_fat_pct, ' pts', true))}
      ${metric('Muscle', latest.muscle_pct, '%', delta(latest.muscle_pct, prev?.muscle_pct, ' pts', false))}
      <div class="pf-metric"><div class="lbl">Measured</div><div class="val" style="font-size:16px">${fmt(latest.measured_at, 'UTC', { dateStyle: 'medium' })}</div></div>
    </div>${sparkline(chron)}` : '<p class="pf-sec-empty">No measurements yet.</p>'}
    ${canRecord ? `<form id="pf-mform" class="ad-form" style="margin-top:16px">
      <div class="row"><label>Date <input type="date" name="measured_at" value="${new Date().toISOString().slice(0, 10)}"></label>
      <label>Weight (kg) <input type="number" step="0.1" min="20" max="500" name="weight"></label>
      <label>Body fat (%) <input type="number" step="0.1" min="1" max="75" name="body_fat"></label>
      <label>Muscle (%) <input type="number" step="0.1" min="1" max="80" name="muscle"></label>
      <label>Height (cm) <input type="number" step="0.1" min="50" max="260" name="height" placeholder="${pf.contact?.height_cm ?? ''}"></label></div>
      <label>Note <input name="note" placeholder="Optional"></label>
      <div class="actions"><button class="btn btn-accent btn-sm" type="submit">Add measurement</button><span class="ad-muted" style="font-size:12px">BMI is computed from weight and the height on record.</span></div></form>` : ''}
    ${rows.length ? `<div class="ad-panel" style="margin-top:16px;padding:0"><div class="ad-table-wrap"><table class="ad-table"><thead><tr><th>Date</th><th class="num">Weight</th><th class="num">BMI</th><th class="num">Body fat</th><th class="num">Muscle</th><th>Note</th></tr></thead><tbody>
      ${rows.map((r) => `<tr><td>${fmt(r.measured_at, 'UTC', { dateStyle: 'medium' })}</td><td class="num">${r.weight_kg ?? '—'}</td><td class="num">${r.bmi ?? '—'}</td><td class="num">${r.body_fat_pct ?? '—'}</td><td class="num">${r.muscle_pct ?? '—'}</td><td class="msg">${esc(r.note || '')}</td></tr>`).join('')}
      </tbody></table></div></div>` : ''}
    ${(canView && (rows.length || active)) ? `<div class="actions" style="display:flex;gap:8px;flex-wrap:wrap;margin-top:14px">
      <button class="btn btn-line btn-xs" id="pf-export">Export progress data</button>
      ${canManage && rows.length ? '<button class="btn btn-line btn-xs" id="pf-delete-history" style="color:var(--danger,#a12a2a)">Delete progress history…</button>' : ''}
    </div>` : ''}
    <p class="ad-muted" style="font-size:12px;margin-top:14px;line-height:1.5">Progress tracking is for fitness coaching only. It is not medical advice, diagnosis or treatment, and no health judgement is made or shown — BMI is only the arithmetic of weight and recorded height. For medical concerns the client should see a qualified healthcare professional.</p>`;

  const form = $('#pf-mform');
  if (form) form.onsubmit = async (e) => {
    e.preventDefault(); const f = new FormData(form);
    const num = (k) => f.get(k) === '' ? null : Number(f.get(k));
    if (num('weight') == null && num('body_fat') == null && num('muscle') == null) return toast('Enter at least a weight, body fat or muscle value', true);
    const { error } = await sb.rpc('metrics_add', { p_contact_id: pf.crmId, p_measured_at: f.get('measured_at') || null, p_weight: num('weight'), p_body_fat: num('body_fat'), p_muscle: num('muscle'), p_height: num('height'), p_note: f.get('note') || null });
    if (error) return fail(error); toast('Measurement recorded'); pfProgress().catch(fail);
  };

  const linkBtn = $('#pf-consent-link');
  if (linkBtn) linkBtn.onclick = async () => {
    const { data: r, error } = await sb.rpc('consent_issue_link', { p_contact_id: pf.crmId });
    if (error) return fail(error);
    const url = `${location.origin}/consent?t=${r.token}`;
    $('#pf-consent-out').innerHTML = `<label style="font-size:12px;font-weight:600;display:block;margin-bottom:4px">Consent link (valid ${r.expires_in_days} days, one use) — send it to the client:</label>
      <div style="display:flex;gap:8px"><input id="pf-consent-url" readonly value="${esc(url)}" style="flex:1;padding:8px;border:1px solid var(--line);border-radius:8px;font:inherit;font-size:12px"><button class="btn btn-line btn-xs" id="pf-consent-copy">Copy</button></div>
      <p class="ad-muted" style="font-size:12px;margin-top:6px">The link opens the consent notice; the client's own accept/decline is what records consent. It gives no access to any account or CRM data.</p>`;
    $('#pf-consent-url').onclick = (e) => e.target.select();
    $('#pf-consent-copy').onclick = async () => { try { await navigator.clipboard.writeText(url); toast('Link copied'); } catch { $('#pf-consent-url').select(); } };
  };
  const recBtn = $('#pf-consent-record');
  if (recBtn) recBtn.onclick = async () => {
    if (!await confirmAct('Exceptional fallback: record that the client has given consent, on their behalf.\n\nUse this ONLY when the client has consented in person or in writing and cannot use the link. It is logged as an admin-recorded consent. Proceed?')) return;
    const { error } = await sb.rpc('consent_record_admin', { p_contact_id: pf.crmId });
    if (error) return fail(error); toast('Consent recorded (fallback)'); pfProgress().catch(fail);
  };
  const wdBtn = $('#pf-consent-withdraw');
  if (wdBtn) wdBtn.onclick = async () => {
    if (!await confirmAct('Withdraw consent? This stops any future recording. Past records are kept as evidence and are not deleted.')) return;
    const { error } = await sb.rpc('consent_withdraw', { p_contact_id: pf.crmId });
    if (error) return fail(error); toast('Consent withdrawn'); pfProgress().catch(fail);
  };
  const exBtn = $('#pf-export');
  if (exBtn) exBtn.onclick = async () => {
    const { data: rows2, error } = await sb.rpc('metrics_export', { p_contact_id: pf.crmId });
    if (error) return fail(error);
    const blob = new Blob([JSON.stringify(rows2, null, 2)], { type: 'application/json' });
    const url = URL.createObjectURL(blob); const a = document.createElement('a');
    a.href = url; a.download = `progress-${pf.crmId}.json`; document.body.appendChild(a); a.click(); a.remove();
    setTimeout(() => URL.revokeObjectURL(url), 1000); toast('Progress data exported');
  };
  const delBtn = $('#pf-delete-history');
  if (delBtn) delBtn.onclick = async () => {
    if (!await confirmAct('Delete ALL progress measurements for this contact? This permanently removes the measurement history. Consent records are separate and are kept. This cannot be undone.')) return;
    const { error } = await sb.rpc('metrics_delete_history', { p_contact_id: pf.crmId });
    if (error) return fail(error); toast('Progress history deleted'); pfProgress().catch(fail);
  };
}
function sparkline(rows) {
  if (rows.length < 2) return '';
  const ws = rows.map((r) => Number(r.weight_kg));
  const min = Math.min(...ws), max = Math.max(...ws), span = max - min || 1;
  const W = 260, H = 44, n = ws.length;
  const pts = ws.map((w, i) => `${(i / (n - 1) * W).toFixed(1)},${(H - 4 - (w - min) / span * (H - 8)).toFixed(1)}`).join(' ');
  return `<svg class="pf-spark" width="${W}" height="${H}" viewBox="0 0 ${W} ${H}" aria-label="Weight trend"><polyline fill="none" stroke="var(--accent)" stroke-width="2" points="${pts}"/></svg>`;
}

async function pfEnquiries() {
  let list = [];
  if (pf.crmId) { const { data } = await sb.from('contacts').select(CONTACT_COLS).eq('crm_contact_id', pf.crmId).order('created_at', { ascending: false }); list = data || []; }
  else if (pf.enquiry) list = [pf.enquiry];
  if (!list.length) { $('#pf-body').innerHTML = '<p class="pf-sec-empty">No enquiries.</p>'; return; }
  const opts = ['new', 'contacted', 'qualified', 'closed', 'spam'];
  $('#pf-body').innerHTML = list.map((c) => {
    const open = c.id === pf.enquiryId || list.length === 1;
    const where = [c.city, c.country].filter(Boolean).join(', ') || c.location_raw || '—';
    return `<details class="pf-tech" ${open ? 'open' : ''} style="border:1px solid var(--line);border-radius:12px;padding:12px 14px;margin-bottom:10px">
      <summary style="color:var(--black)"><b>${esc(c.interest || 'Enquiry')}</b> · ${fmt(c.created_at, 'Asia/Dubai')} · ${st(c.status)}</summary>
      <dl class="pf-kv" style="margin-top:10px">
        <dt>Name</dt><dd>${esc(c.name || '—')}</dd>
        <dt>Contact</dt><dd>${esc(c.contact || '—')}</dd>
        <dt>Where</dt><dd>${esc(where)}</dd>
        <dt>Interest</dt><dd>${esc(c.interest || '—')}</dd>
        <dt>Message</dt><dd style="white-space:pre-wrap">${esc(c.message || '—')}</dd>
        <dt>Submitted</dt><dd>${fmt(c.created_at, 'Asia/Dubai')}</dd>
      </dl>
      <div class="actions" style="display:flex;gap:8px;flex-wrap:wrap;margin-top:10px;align-items:center">
        ${has('coach:operations') ? `<select data-estatus="${c.id}">${opts.map((o) => `<option ${o === c.status ? 'selected' : ''}>${o}</option>`).join('')}</select>` : ''}
        ${c.contact?.includes('@') ? `<a class="btn btn-line btn-xs" href="mailto:${esc(c.contact)}">Email</a>` : (c.contact ? `<a class="btn btn-line btn-xs" href="${waHref(c.contact)}" target="_blank" rel="noopener">WhatsApp</a>` : '')}
      </div>
      <details class="pf-tech"><summary>Technical</summary><dl class="pf-kv" style="margin-top:8px"><dt>Enquiry id</dt><dd>${esc(c.id)}</dd><dt>Submission id</dt><dd>${esc(c.submission_id || '—')}</dd><dt>Source</dt><dd>${esc(c.source || '—')}</dd></dl></details>
    </details>`;
  }).join('');
  $('#pf-body').querySelectorAll('[data-estatus]').forEach((s) => s.onchange = async () => {
    const { error } = await sb.from('contacts').update({ status: s.value }).eq('id', s.dataset.estatus);
    if (error) return fail(error); toast('Lead status updated');
  });
}

async function pfBookings() {
  if (!pf.crmId) { $('#pf-body').innerHTML = '<p class="pf-sec-empty">No bookings.</p>'; return; }
  const { data, error } = await sb.from('bookings').select(BOOKING_COLS).eq('crm_contact_id', pf.crmId).order('start_at', { ascending: false });
  if (error) throw error;
  const rows = data || [];
  pf._bookingRefs = rows.map((b) => b.reference);
  $('#pf-body').innerHTML = rows.length ? `<div class="ad-table-wrap"><table class="ad-table"><thead><tr><th>When</th><th>Session</th><th>Ref · status</th><th class="num">Price</th></tr></thead><tbody>
    ${rows.map((b) => `<tr><td>${fmt(b.start_at, b.session_timezone, { dateStyle: 'medium', timeStyle: 'short' })}<br><span class="ad-muted" style="font-size:12px">${esc(b.session_timezone)}</span></td>
      <td>${esc(b.service_title || b.services?.title || '—')}<br><span class="ad-muted" style="font-size:12px">${esc(b.delivery_mode)}</span></td>
      <td>${esc(b.reference)}<br>${st(b.status)}</td><td class="num">${b.price_amount == null ? 'on request' : money(b.price_amount, b.currency)}</td></tr>`).join('')}
    </tbody></table></div>` : '<p class="pf-sec-empty">No bookings yet.</p>';
}

async function pfPayments() {
  if (!has('coach:operations')) { $('#pf-body').innerHTML = '<p class="pf-sec-empty">Open this client from Finance to see payment detail.</p>'; return; }
  if (!pf._bookingRefs) { const { data } = await sb.from('bookings').select('reference').eq('crm_contact_id', pf.crmId); pf._bookingRefs = (data || []).map((b) => b.reference); }
  const refs = new Set(pf._bookingRefs);
  const { data, error } = await sb.rpc('finance_orders'); if (error) throw error;
  const rows = (data || []).filter((o) => refs.has(o.booking_reference));
  $('#pf-body').innerHTML = rows.length ? `<div class="ad-table-wrap"><table class="ad-table"><thead><tr><th>Order</th><th>Session</th><th class="num">Gross</th><th class="num">Net</th><th class="num">Commission</th><th class="num">Payable</th><th>Status</th></tr></thead><tbody>
    ${rows.map((o) => `<tr><td>${esc(o.reference)}<br>${st(o.status)}</td><td>${esc(o.service_title)}</td><td class="num">${money(o.gross_amount, o.currency)}</td><td class="num">${money(o.net_collected, o.currency)}</td><td class="num">${money(o.oolala_commission, o.currency)}</td><td class="num"><b>${money(o.gari_payable, o.currency)}</b></td><td>${o.earning_status ? st(o.earning_status) : '—'}</td></tr>`).join('')}
    </tbody></table></div>` : '<p class="pf-sec-empty">No payments for this client.</p>';
}

async function pfMedia() {
  let cids = [];
  if (pf.crmId) { const { data } = await sb.from('contacts').select('id').eq('crm_contact_id', pf.crmId); cids = (data || []).map((c) => c.id); }
  else if (pf.enquiryId) cids = [pf.enquiryId];
  if (!cids.length) { $('#pf-body').innerHTML = '<p class="pf-sec-empty">No attachments.</p>'; return; }
  const { data, error } = await sb.from('contact_media').select('id,contact_id,original_name,content_type,size_bytes,storage_path,status').in('contact_id', cids).eq('status', 'uploaded');
  if (error) throw error;
  const rows = data || [];
  const mb = (n) => n >= 1048576 ? (n / 1048576).toFixed(1) + ' MB' : Math.max(1, Math.round(n / 1024)) + ' KB';
  $('#pf-body').innerHTML = rows.length ? `<p class="ad-note">Attachments from this client's enquiries. Files stay in the private bucket; links open for 10 minutes.</p>
    <div class="ad-table-wrap"><table class="ad-table"><tbody>${rows.map((m) => `<tr><td>${m.content_type.startsWith('video/') ? '🎬' : '🖼'} <a href="#" data-media="${esc(m.storage_path)}">${esc(m.original_name)}</a></td><td class="ad-muted num">${mb(m.size_bytes)}</td></tr>`).join('')}</tbody></table></div>`
    : '<p class="pf-sec-empty">No attachments.</p>';
  $('#pf-body').querySelectorAll('[data-media]').forEach((a) => a.onclick = async (e) => {
    e.preventDefault();
    const { data, error } = await sb.storage.from('enquiry-media').createSignedUrl(a.dataset.media, 600);
    if (error || !data?.signedUrl) return fail(error || new Error('Could not open the file'));
    window.open(data.signedUrl, '_blank', 'noopener');
  });
}

async function pfAttribution() {
  let c = pf.enquiry;
  if (!c && pf.crmId) { const { data } = await sb.from('contacts').select(CONTACT_COLS).eq('crm_contact_id', pf.crmId).order('created_at', { ascending: false }).limit(1); c = (data || [])[0]; }
  if (!c) { $('#pf-body').innerHTML = '<p class="pf-sec-empty">No attribution captured.</p>'; return; }
  const entry = (c.page || '').includes('entry_point=') ? decodeURIComponent(c.page.split('entry_point=')[1]) : null;
  const kv = [['Source', c.utm_source], ['Medium', c.utm_medium], ['Campaign', c.utm_campaign], ['Content', c.utm_content], ['Term', c.utm_term],
    ['CTA / entry point', entry], ['Referrer', c.referrer], ['Landing page', c.landing_page], ['First visit', c.first_visit_at ? fmt(c.first_visit_at, 'Asia/Dubai') : null], ['Submitted from', c.page]];
  $('#pf-body').innerHTML = `<dl class="pf-kv">${kv.map(([k, v]) => `<dt>${esc(k)}</dt><dd>${v ? esc(v) : '—'}</dd>`).join('')}</dl>`;
}

/* ---- create / edit canonical contact ---- */
function openContactEditor(c) {
  const host = $('#profile'); host.hidden = false; document.body.style.overflow = 'hidden';
  const v = (x) => x == null ? '' : x;
  const stOpts = ['lead', 'active', 'past', 'archived'];
  host.innerHTML = `<div class="sheet"><div class="pf-head"><div class="pf-id"><h2>${c ? 'Edit ' + esc(c.display_name || 'contact') : 'New contact'}</h2></div><div class="pf-actions"><button class="pf-close" id="ce-x">×</button></div></div>
    <div class="pf-body"><form id="ce-form" class="ad-form">
      <div class="row"><label>Display name <input name="display_name" required value="${esc(v(c?.display_name))}"></label>
      <label>Status <select name="status">${stOpts.map((s) => `<option ${c && c.status === s ? 'selected' : ''}>${s}</option>`).join('')}</select></label></div>
      <div class="row"><label>Email <input name="email" type="email" value="${esc(v(c?.email))}"></label>
      <label>Phone / WhatsApp <input name="phone" value="${esc(v(c?.phone))}"></label></div>
      <div class="row"><label>City <input name="city" value="${esc(v(c?.city))}"></label>
      <label>Country <input name="country" value="${esc(v(c?.country))}"></label></div>
      <div class="row"><label>Preferred timezone <input name="preferred_timezone" value="${esc(v(c?.preferred_timezone))}" placeholder="Asia/Dubai"></label>
      <label>Preferred language <input name="preferred_language" value="${esc(v(c?.preferred_language))}" placeholder="en"></label>
      <label>Height (cm) <input name="height_cm" type="number" step="0.1" min="50" max="260" value="${esc(v(c?.height_cm))}"></label></div>
      <label>Coaching goals <textarea name="goals">${esc(v(c?.goals))}</textarea></label>
      <div class="actions"><button class="btn btn-accent btn-sm" type="submit">${c ? 'Save' : 'Create'}</button>
      <button class="btn btn-line btn-sm" type="button" id="ce-cancel">Cancel</button></div>
    </form></div></div>`;
  $('#ce-x').onclick = () => c ? renderProfile('overview') : pfClose();
  $('#ce-cancel').onclick = () => c ? renderProfile('overview') : pfClose();
  $('#ce-form').onsubmit = async (e) => {
    e.preventDefault(); const f = new FormData(e.target);
    const p = { display_name: f.get('display_name'), status: f.get('status'), email: f.get('email'), phone: f.get('phone'),
      city: f.get('city'), country: f.get('country'), preferred_timezone: f.get('preferred_timezone'),
      preferred_language: f.get('preferred_language'), height_cm: f.get('height_cm') || null, goals: f.get('goals') };
    if (c) p.id = c.id;
    const { data, error } = await sb.rpc('crm_save_contact', { p }); if (error) return fail(error);
    toast(c ? 'Profile saved' : 'Contact created');
    pf = { crmId: data.id, enquiryId: null, contact: data, enquiry: null, section: 'overview' };
    renderProfile('overview');
    if (cur.section === 'crm' && cur.sub === 'contacts') { /* refresh list underneath */ crmContacts().catch(() => {}); }
  };
}

boot().catch(fail);

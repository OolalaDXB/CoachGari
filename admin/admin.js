/* =============================================================
   Coach Gari — back-office (CG-002.5)
   One script, two areas:
     /admin   (data-area="ops")     coach:operations
     /finance (data-area="finance") finance:view / finance:manage
     analytics:view adds an Analytics tab; platform:admin adds Access;
     catalog:view / catalog:manage add Services (the commercial catalogue).
     A person holding both sets sees an understated link to the other area.
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
const CONTACT_COLS = 'id,name,contact,country,city,location_raw,interest,message,utm_source,utm_medium,utm_campaign,referrer,landing_page,page,status,created_at';
const TZS = ['Asia/Dubai', 'Africa/Harare', 'Africa/Johannesburg', 'Africa/Gaborone', 'Africa/Nairobi', 'Europe/London', 'Europe/Paris', 'UTC'];
const WEEKDAYS = ['', 'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'];

let me = null;            // {email, party, permissions:[]}
let services = [];        // catalogue (read-only here)
let tab = null;
const AREA = document.body.dataset.area || 'ops';   // 'ops' (/admin) or 'finance' (/finance)

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
    const { error } = await sb.auth.signInWithOtp({ email, options: { emailRedirectTo: `${location.origin}/${AREA === 'finance' ? 'finance' : 'admin'}/`, shouldCreateUser: false } });
    if (error) { m.className = 'ad-msg err'; m.textContent = /signup|not allowed|not found/i.test(error.message) ? 'This email is not provisioned for the back-office. Ask the owner.' : error.message; return; }
    m.className = 'ad-msg ok'; m.textContent = 'Check your inbox and open the link on this device.';
  });
  document.addEventListener('click', (e) => { if (e.target.closest('[data-signout]')) sb.auth.signOut().then(() => location.reload()); });
  sb.auth.onAuthStateChange((_ev, session) => { render(session); });
  const { data } = await sb.auth.getSession();
  render(data.session);
}

async function render(session) {
  $('#who').innerHTML = session ? `<span class="ad-muted" style="font-size:13px;margin-right:10px">${esc(session.user.email)}</span><button class="btn btn-line btn-sm" data-signout>Sign out</button>` : '';
  if (session && me && me.email === session.user.email && tab) return;   // already rendered for this user (token refresh)
  $('#login').hidden = !!session; $('#app').hidden = true; $('#noaccess').hidden = true; $('#tabs').hidden = true;
  if (!session) { me = null; tab = null; return; }
  try {
    const { data, error } = await sb.rpc('my_permissions'); if (error) throw error;
    me = data;
    const opsOK = has('coach:operations'), finOK = has('finance:view'), catOK = has('catalog:view');
    const areaOK = AREA === 'finance' ? finOK : (opsOK || catOK);
    if (!areaOK) {
      $('#noaccess').hidden = false;
      const other = $('#other-area');
      if (other && (AREA === 'finance' ? opsOK : finOK)) { other.hidden = false; other.innerHTML = AREA === 'finance' ? 'Your operations area is at <a href="/admin/">/admin</a>.' : 'Your finance area is at <a href="/finance/">/finance</a>.'; }
      return;
    }
    const { data: svc, error: e2 } = await sb.from('services').select(SERVICE_COLS).order('sort_order'); if (e2) throw e2;
    services = svc || [];
    const tabs = [];
    if (AREA === 'ops' && opsOK) tabs.push(['leads', 'Leads'], ['calendar', 'Calendar'], ['bookings', 'Bookings'], ['availability', 'Availability'], ['exceptions', 'Exceptions'], ['tours', 'Tour stops']);
    if (AREA === 'ops' && catOK) tabs.push(['services', 'Services']);
    if (AREA === 'finance') tabs.push(['finance', 'Finance']);
    if (has('analytics:view')) tabs.push(['analytics', 'Analytics']);
    if (has('platform:admin')) tabs.push(['access', 'Access']);
    // cross-area link, only when the person actually holds the other permission
    const other = AREA === 'finance' ? (opsOK ? '<a class="ad-area" href="/admin/">Operations ↗</a>' : '') : (finOK ? '<a class="ad-area" href="/finance/">Finance ↗</a>' : '');
    $('#tabs').innerHTML = tabs.map(([k, l]) => `<a data-tab="${k}">${l}</a>`).join('') + other;
    $('#tabs').hidden = false; $('#app').hidden = false;
    $('#tabs').onclick = (e) => { const a = e.target.closest('[data-tab]'); if (a) go(a.dataset.tab); };
    go(location.hash.slice(1) && tabs.some(([k]) => k === location.hash.slice(1)) ? location.hash.slice(1) : tabs[0][0]);
  } catch (e) { fail(e); }
}

function go(name) {
  tab = name; location.hash = name;
  for (const a of $('#tabs').querySelectorAll('a')) a.classList.toggle('on', a.dataset.tab === name);
  view.innerHTML = '<p class="ad-empty">Loading…</p>';
  ({ leads, calendar, bookings, availability, exceptions, tours, services: catalogue, finance, analytics, access })[name]().catch(fail);
}

/* =============================== LEADS =============================== */
async function leads() {
  const status = view.dataset.leadStatus || '';
  let q = sb.from('contacts').select(CONTACT_COLS).order('created_at', { ascending: false }).limit(200);
  if (status) q = q.eq('status', status);
  const { data, error } = await q; if (error) throw error;
  const ids = data.map((c) => c.id);
  const { data: mediaRows } = ids.length ? await sb.from('contact_media').select('id,contact_id,original_name,content_type,size_bytes,status,storage_path').in('contact_id', ids).eq('status', 'uploaded') : { data: [] };
  const mediaBy = {}; for (const m of mediaRows || []) (mediaBy[m.contact_id] ||= []).push(m);
  const mb = (n) => n >= 1048576 ? (n / 1048576).toFixed(1) + ' MB' : Math.max(1, Math.round(n / 1024)) + ' KB';
  const opts = ['new', 'contacted', 'qualified', 'closed', 'spam'];
  view.innerHTML = `
    <div class="ad-head"><div><h1>Leads</h1><p class="ad-muted">Enquiries from the website form. Only you see these.</p></div>
      <div class="ad-filters"><select id="lead-status"><option value="">All statuses</option>${opts.map((o) => `<option ${o === status ? 'selected' : ''}>${o}</option>`).join('')}</select></div></div>
    <div class="ad-panel">${table(['When', 'Who', 'Where', 'Interest', 'Message', 'Source', 'Status'], data.map((c) => `<tr>
      <td>${fmt(c.created_at, 'Asia/Dubai')}</td>
      <td><b>${esc(c.name)}</b><br><a href="${c.contact.includes('@') ? 'mailto:' + esc(c.contact) : 'https://wa.me/' + esc(c.contact.replace(/\D/g, ''))}">${esc(c.contact)}</a></td>
      <td>${esc(c.location_raw || [c.city, c.country].filter(Boolean).join(', ') || '—')}</td>
      <td>${esc(c.interest || '—')}</td>
      <td class="msg">${esc(c.message || '')}${(mediaBy[c.id] || []).map((m) => `<div><a href="#" data-media-path="${esc(m.storage_path)}">${m.content_type.startsWith('video/') ? '🎬' : '🖼'} ${esc(m.original_name)}</a> <span class="ad-muted">${mb(m.size_bytes)}</span></div>`).join('')}</td>
      <td class="ad-muted" style="font-size:12px">${esc([c.utm_source, c.utm_medium, c.utm_campaign].filter(Boolean).join(' / ') || (c.referrer ? new URL(c.referrer).hostname : 'direct'))}<br>${esc(c.page || '')}</td>
      <td><select data-lead="${c.id}">${opts.map((o) => `<option ${o === c.status ? 'selected' : ''}>${o}</option>`).join('')}</select></td>
    </tr>`), 'No leads yet.')}</div>`;
  $('#lead-status').onchange = (e) => { view.dataset.leadStatus = e.target.value; leads().catch(fail); };
  view.querySelectorAll('[data-media-path]').forEach((a) => a.onclick = async (e) => {
    e.preventDefault();
    const { data, error } = await sb.storage.from('enquiry-media').createSignedUrl(a.dataset.mediaPath, 600);
    if (error || !data?.signedUrl) return fail(error || new Error('Could not open the file'));
    window.open(data.signedUrl, '_blank', 'noopener');
  });
  view.querySelectorAll('[data-lead]').forEach((s) => s.onchange = async () => {
    const { error } = await sb.from('contacts').update({ status: s.value }).eq('id', s.dataset.lead);
    if (error) return fail(error); toast('Lead updated');
  });
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
async function calendar() {
  const tz = view.dataset.tz || 'Asia/Dubai';
  const from = new Date(); from.setUTCHours(0, 0, 0, 0); from.setUTCDate(from.getUTCDate() - 1);
  const to = new Date(from); to.setUTCDate(to.getUTCDate() + 45);
  const { data, error } = await sb.from('bookings').select(BOOKING_COLS).gte('start_at', from.toISOString()).lt('start_at', to.toISOString())
    .in('status', ['hold', 'pending_payment', 'confirmed', 'completed', 'no_show']).order('start_at'); if (error) throw error;
  const groups = {}; for (const b of data) (groups[dayKey(b.start_at, tz)] ||= []).push(b);
  view.innerHTML = `
    <div class="ad-head"><div><h1>Calendar</h1><p class="ad-muted">Next 45 days. Holds expire on their own; paid bookings confirm through payment.</p></div>
      <div class="ad-filters"><label class="ad-muted" style="font-size:13px">Show times in</label>${tzSelect('tz', tz)}</div></div>
    ${Object.keys(groups).length ? Object.entries(groups).map(([d, list]) => `<p class="ad-day">${fmt(list[0].start_at, tz, { weekday: 'long', day: 'numeric', month: 'long' })}</p>
      <div class="ad-panel">${table(['Time', 'Session', 'Client', 'Ref · status', 'Price', ''], list.map((b) => bookingRow(b, tz)))}</div>`).join('') : '<div class="ad-panel"><p class="ad-empty">No sessions in the next 45 days.</p></div>'}`;
  $('select[name=tz]', view).onchange = (e) => { view.dataset.tz = e.target.value; calendar().catch(fail); };
  bindBookingActions();
}
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
const PERMS = ['coach:operations', 'finance:view', 'finance:manage', 'analytics:view', 'catalog:view', 'catalog:manage', 'platform:admin'];
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
      <p class="ad-note">"Auth pending" means the email has no Supabase Auth identity yet — invite it under Authentication → Users, then it can sign in.</p></div>
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

boot().catch(fail);

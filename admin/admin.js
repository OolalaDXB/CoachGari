/* =============================================================
   Coach Gari — back-office (CG-002.5 → CG-009)
   One cockpit at /admin: a sidebar of destinations (mobile drawer), a
   minimal top header with page context + an account menu (Sign Out lives
   inside it), and — for people — a large client-profile popup. Every
   destination is shown only when the signed-in person holds the matching
   permission:
     coach:operations → Leads, Calendar, Bookings, Availability, Exceptions, Tour stops
     catalog:view     → Services (the commercial catalogue)
     finance:view     → Finance (Transactions, Payment methods) and the
                        embedded BEAU PH workspace (Rails, FX) — both users
                        of the launch pair; never gated on platform:admin
     analytics:view   → Analytics
     platform:admin   → Access
   Finance is a tab here, not a separate app — /finance is kept only as a
   deep link that redirects to #finance. Merging the UI does NOT merge the
   permissions: finance:view / finance:manage stay independent in the
   database, and the Finance tab (and its RPCs, under RLS) disappear the
   moment the permission is removed. The Finance / BEAU PH screens live in
   /admin/finance.js and load lazily: Transactions only on open, method
   summaries on the Payment methods tab, one method's configuration on Edit.
   Magic-link sign-in (Supabase Auth) with shouldCreateUser:false — an email
   that was not provisioned by the owner cannot even create an auth user.
   What a signed-in person can see and do is decided entirely by the
   database (RLS + app_permissions); this file only chooses which tabs to
   draw and never writes permissions.
   Column lists are explicit on purpose: the database grants columns, not
   tables, so `select *` would be refused.
   ============================================================= */
import { CONFIG } from '/config.js';
import { initFinance, financeTransactions, financeSubscriptions, financeCommissions, financePaymentMethods, phRails, phFx } from '/admin/finance.js';
import { initCollab, collabList } from '/admin/collab.js';
import { csvToSnapshots } from '/admin/csv.js';

/* flowType 'implicit', deliberately, and this is the line that decides whether anyone
   can sign in from a phone or an iPad.

   Under PKCE, requesting a link makes GoTrue store the one-time token prefixed `pkce_`
   and keep a verifier in THIS browser's storage. The token is then worthless anywhere
   else — including the browser a mail app opens links in, which on iOS is a private
   Safari tab with its own empty storage. That is not a misconfiguration to work around:
   binding the link to one browser is what PKCE is for. It is simply the wrong property
   for a link delivered by email and opened wherever the reader happens to read.

   What we give up: someone who obtains the email can use the link from any browser, and
   the session tokens appear for an instant in the URL fragment — never sent to a server,
   and stripped from the address bar as soon as they are read. What we get back: the
   owner can actually get in, from the device he has.

   The passkey is the real door and is unaffected by any of this. Once one is enrolled on
   each device, the email link is a fallback that is rarely used, and this can go back to
   PKCE — a one-line change, and the reason that reasoning is written down here.

   experimental.passkey is the library's own opt-in: without it every passkey call throws. */
const sb = window.supabase.createClient(CONFIG.SUPABASE_URL, CONFIG.SUPABASE_PUBLISHABLE_KEY, { auth: { flowType: 'implicit', persistSession: true, experimental: { passkey: true } } });

const $ = (s, r = document) => r.querySelector(s);
const view = $('#view');
const esc = (s) => String(s ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
/* One press, one write.

   The audit ledger showed two `create` calls 0.23 ms apart for the same session — one
   gesture, two requests. The database now answers the second with the first, which is the
   fix that holds whatever the cause; this is the other half: while a write is in flight
   its button cannot be pressed again, so the second request is never sent. Cheap, and it
   also tells the operator that something IS happening, which is why the note button was
   pressed three times. */
async function once(btn, fn) {
  if (!btn || btn.disabled) return;
  const label = btn.textContent;
  btn.disabled = true; btn.textContent = 'Saving…';
  try { return await fn(); } finally { btn.disabled = false; btn.textContent = label; }
}

/* A KPI tile shows a number or says it has none. It must never print "NaN" or
   "undefined": both are the screen admitting it does not know, in a way that looks like
   data. A missing part of a sum dashes the whole tile rather than showing a partial
   figure — a wrong number is worse than an absent one, because it gets believed. */
const kpiVal = (v) => (typeof v === 'number' ? (Number.isFinite(v) ? v : '—') : (v == null || v === '' ? '—' : v));

const CG_CCY = 'AED';   // Coach Gari bills in dirhams; the pack editor already defaults to it
const money = (n, cur = 'USD') => n == null ? '—' : (n / 100).toLocaleString('en-US', { style: 'currency', currency: cur });

/* What a session costs comes from its package, or from the client's rate when it has no
   package — never from the session itself, so that "what do I charge Amanda?" keeps one
   answer. The amount is shown with where it came from: a number whose origin is
   invisible is one nobody thinks to correct. */
const PRICE_FROM = { pack: 'from the package', client: 'client rate' };
const priceLine = (p) => !p || p.amount == null
  ? '<span class="ad-muted">Not priced</span>'
  : `${money(p.amount, p.currency)} <span class="ad-muted">· ${PRICE_FROM[p.source] || p.source}</span>`;

// "3 of 10" inside a package; outside one there is no denominator to invent, only the count
const ORD = (n) => n + (['th','st','nd','rd'][(n % 100 - 20) % 10] || ['th','st','nd','rd'][n % 100] || 'th');
const seqLine = (q) => !q || q.n == null ? ''
  : q.of ? `${q.n} of ${q.of}` : `${ORD(q.n)} session`;
const st = (s) => `<span class="st st-${esc(s)}">${esc(String(s ?? '').replace('_', ' '))}</span>`;
const BOOKING_COLS = 'id,reference,service_id,contact_id,crm_contact_id,customer_name,customer_contact,start_at,end_at,session_timezone,tour_stop_id,delivery_mode,participant_count,status,hold_expires_at,price_amount,currency,notes,cancel_reason,cancelled_at,cancelled_by,created_at,service_title,service_duration_minutes,services(title,slug),tour_stops(city,country)';
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
// installed as an app (home screen / dock): standalone display, the service worker keeps the shell available offline
const standalone = !!(window.matchMedia && window.matchMedia('(display-mode: standalone)').matches) || window.navigator.standalone === true;
if (standalone) document.documentElement.classList.add('standalone');
if ('serviceWorker' in navigator && location.pathname.startsWith('/admin')) {
  // scope '/admin', not '/admin/': production serves the page at /admin (vercel.json,
  // cleanUrls + trailingSlash:false), and a page outside its worker's scope is never
  // controlled — no offline, no push, nothing installable. Widening the scope past the
  // worker's own directory needs Service-Worker-Allowed: /admin on /admin/sw.js.
  window.addEventListener('load', async () => {
    // A scope change leaves the old registration behind for ever, holding a cache nothing
    // will ever read. Drop it on the way past; harmless once no browser has one.
    try {
      for (const r of await navigator.serviceWorker.getRegistrations()) {
        if (new URL(r.scope).pathname === '/admin/') await r.unregister();
      }
    } catch {}
    navigator.serviceWorker.register('/admin/sw.js', { scope: '/admin' }).catch(() => {});
  });
}

/* ---------- install prompt -------------------------------------------------
   Offered only to someone signed in who holds back-office access: the browser's
   event is captured here (it fires once, early, and is lost if not kept) but the
   banner is never unhidden from this file. render() calls offerInstall() after
   my_permissions has returned a usable NAV — so a stranger who loads /admin/,
   and a signed-in person with no permission, are never invited to install it.
   iOS has no such event: Safari installs only from its own Share menu, so there
   it shows the instruction instead of a button. */
let installEvent = null;
window.addEventListener('beforeinstallprompt', (e) => { e.preventDefault(); installEvent = e; });
window.addEventListener('appinstalled', () => { installEvent = null; try { localStorage.setItem('cg-install', 'done'); } catch {} $('#install').hidden = true; });

const isIOS = /iP(hone|ad|od)/.test(navigator.userAgent) && !window.MSStream;

function offerInstall() {
  const box = $('#install'); if (!box) return;
  let dismissed = false;
  try { dismissed = !!localStorage.getItem('cg-install'); } catch {}        // private mode: just offer it
  if (standalone || dismissed) { box.hidden = true; return; }
  if (!installEvent && !isIOS) return;                                       // no way to install from here
  if (isIOS && !installEvent) $('#install-how').textContent = 'In Safari: Share, then "Add to Home Screen".';
  $('#install-go').hidden = !installEvent;
  box.hidden = false;
  $('#install-no').onclick = () => { box.hidden = true; try { localStorage.setItem('cg-install', 'no'); } catch {} };
  $('#install-go').onclick = async () => {
    if (!installEvent) return;
    box.hidden = true;
    installEvent.prompt();
    const { outcome } = await installEvent.userChoice.catch(() => ({ outcome: 'dismissed' }));
    installEvent = null;
    if (outcome !== 'accepted') { try { localStorage.setItem('cg-install', 'no'); } catch {} }
  };
}

/* ---------- push notifications --------------------------------------------
   Gated exactly like the install banner, and for a sharper reason: asking for
   notification permission is a prompt the browser shows once and remembers, so
   it must never be spent on someone who does not work here.

   The subscription is written by push_subscribe, which pins it to the caller's
   own signed-in identity — a device cannot be subscribed on someone else's
   behalf. What arrives is a fixed sentence chosen server-side, never a name. */
function urlB64ToUint8Array(s) {
  const p = (s + '='.repeat((4 - s.length % 4) % 4)).replace(/-/g, '+').replace(/_/g, '/');
  return Uint8Array.from(atob(p), (c) => c.charCodeAt(0));
}

async function offerNotifications() {
  const box = $('#notify'); if (!box) return;
  if (!('serviceWorker' in navigator) || !('PushManager' in window) || !('Notification' in window)) return;
  if (isIOS && !standalone) return;                     // iOS only allows push once installed to the Home Screen
  let dismissed = false;
  try { dismissed = !!localStorage.getItem('cg-notify'); } catch {}
  if (Notification.permission === 'denied' || dismissed) { box.hidden = true; return; }

  const reg = await navigator.serviceWorker.ready.catch(() => null);
  if (!reg) return;
  const existing = await reg.pushManager.getSubscription().catch(() => null);
  if (existing) { box.hidden = true; return; }           // already on, on this device

  box.hidden = false;
  $('#notify-no').onclick = () => { box.hidden = true; try { localStorage.setItem('cg-notify', 'no'); } catch {} };
  $('#notify-go').onclick = async () => {
    try {
      const permission = await Notification.requestPermission();
      if (permission !== 'granted') { box.hidden = true; return; }
      const { data: vapid, error: e1 } = await sb.rpc('push_vapid_public');
      if (e1 || !vapid) throw e1 || new Error('notifications are not configured yet');
      const sub = await reg.pushManager.subscribe({ userVisibleOnly: true, applicationServerKey: urlB64ToUint8Array(vapid) });
      const j = sub.toJSON();
      const { error: e2 } = await sb.rpc('push_subscribe', {
        p_endpoint: j.endpoint, p_p256dh: j.keys.p256dh, p_auth: j.keys.auth, p_user_agent: navigator.userAgent,
      });
      if (e2) { await sub.unsubscribe().catch(() => {}); throw e2; }
      box.hidden = true;
      toast('Notifications are on for this device');
    } catch (e) { toast(e.message || 'Could not turn notifications on', true); }
  };
}
/* ---------- passkeys ---------------------------------------------------------
   A passkey is a key pair held by the device (Face ID / Touch ID / a security key)
   and bound to this origin. Signing in with one asks for nothing but the gesture:
   the credential is discoverable, so no email is typed and no code travels.

   Two rules this file follows and must keep following:
     · Enrolment needs an existing session. There is no way to create a first
       passkey from the sign-in screen, by design — otherwise anyone could mint a
       credential for an address they do not own. The owner's email code is how a
       new operator gets in the first time; the passkey is added afterwards.
     · The email code stays. Supabase marks this API experimental ("may change
       without notice"), and it is the only door to the back-office: a library
       upgrade must never be able to lock Gari out. Everything below degrades to
       hidden when WebAuthn is missing or the project has passkeys switched off.

   The relying-party id is fixed server-side to coachgari28.com. Changing it
   invalidates every passkey ever enrolled, on every device. Don't. */
const webauthnOk = !!(window.PublicKeyCredential && navigator.credentials
  && typeof navigator.credentials.create === 'function' && typeof navigator.credentials.get === 'function');

// The browser's own words are unhelpful ("The operation either timed out or was not
// allowed"), and GoTrue answers a project with passkeys off with a 404-ish message.
function passkeyMessage(e, ceremony) {
  const msg = String(e?.message || e || '');
  if (/NotAllowed|not allowed|timed out|abort/i.test(msg)) return ceremony === 'register' ? 'Enrolment was cancelled.' : 'No passkey was used. Use the email code below instead.';
  if (/InvalidState|already registered|exists/i.test(msg)) return 'This device already holds a passkey for the back-office.';
  if (/not enabled|disabled|not found|404/i.test(msg)) return 'Passkeys are not switched on for this project yet.';
  return msg || 'Something went wrong';
}

async function passkeySignIn() {
  const btn = $('#passkey-go'); const m = $('#login-msg');
  m.hidden = false; m.className = 'ad-msg'; m.textContent = 'Waiting for your passkey…';
  btn.disabled = true;
  try {
    const { error } = await sb.auth.signInWithPasskey();
    if (error) throw error;
    m.hidden = true;                                   // onAuthStateChange draws the cockpit
  } catch (e) {
    m.className = 'ad-msg err'; m.textContent = passkeyMessage(e, 'sign-in');
  } finally { btn.disabled = false; }
}

const pkList = (data) => Array.isArray(data) ? data : (data?.passkeys || data?.data || []);
const pkId = (p) => p.id || p.passkey_id || p.credential_id;

async function openPasskeys() {
  const host = $('#profile'); host.hidden = false; document.body.style.overflow = 'hidden';
  const draw = (body) => { host.innerHTML = `<div class="sheet"><div class="pf-head"><div class="pf-id"><h2>Passkeys</h2></div><div class="pf-actions"><button class="pf-close" id="pk-x">×</button></div></div><div class="pf-body">${body}</div></div>`; $('#pk-x').onclick = pfClose; };
  draw('<p class="ad-muted">Loading…</p>');
  let rows = [];
  try {
    const { data, error } = await sb.auth.passkey.list();
    if (error) throw error;
    rows = pkList(data);
  } catch (e) {
    draw(`<p class="ad-msg err">${esc(passkeyMessage(e, 'list'))}</p><p class="ad-muted">The 6-digit email code still works; nothing is broken.</p>`);
    return;
  }
  const body = `<p class="ad-muted">Sign in with Face ID, Touch ID or a security key instead of waiting for an email. Each device gets its own passkey — add one on every device you use. The email code keeps working either way.</p>
    ${table(['Name', 'Added', 'Last used', ''], rows.map((p) => `<tr><td><b>${esc(p.friendly_name || 'Passkey')}</b></td><td>${fmt(p.created_at, 'Asia/Dubai', { dateStyle: 'medium' })}</td><td>${p.last_used_at ? fmt(p.last_used_at, 'Asia/Dubai', { dateStyle: 'medium' }) : '—'}</td><td class="num"><button class="btn btn-line btn-sm" data-pk-del="${esc(pkId(p))}">Remove</button></td></tr>`), 'No passkey yet on any device.')}
    <div class="actions"><button class="btn btn-accent btn-sm" id="pk-add">Add a passkey on this device</button></div>
    <p id="pk-msg" class="ad-msg" hidden></p>`;
  draw(body);
  const say = (text, err = false) => { const m = $('#pk-msg'); m.hidden = false; m.className = 'ad-msg' + (err ? ' err' : ' ok'); m.textContent = text; };
  $('#pk-add').onclick = async () => {
    const b = $('#pk-add'); b.disabled = true;
    try {
      const { error } = await sb.auth.registerPasskey();
      if (error) throw error;
      toast('Passkey added on this device');
      openPasskeys();                                  // redraw with the new row
    } catch (e) { say(passkeyMessage(e, 'register'), true); b.disabled = false; }
  };
  host.querySelectorAll('[data-pk-del]').forEach((b) => b.onclick = async () => {
    if (!await confirmAct('Remove this passkey? That device will need the email code again.')) return;
    try {
      const { error } = await sb.auth.passkey.delete({ passkeyId: b.dataset.pkDel });
      if (error) throw error;
      toast('Passkey removed');
      openPasskeys();
    } catch (e) { say(passkeyMessage(e, 'delete'), true); }
  });
}

/* The code form, revealed either after sending a link or after a link failed to open a
   session here. It needs to know which address the code belongs to: normally the one
   just typed, otherwise the one remembered from the last request on this device, and
   failing that it asks. Only an email address is kept, and only locally. */
function showCodeForm(email) {
  const f = $('#code-form'); f.hidden = false;
  const known = (email || '').trim().toLowerCase();
  if (known) f.dataset.email = known; else delete f.dataset.email;
  $('#code-email').hidden = !!known;
  if (known) { try { localStorage.setItem('cg-email', known); } catch {} }
  (known ? f.querySelector('[name=code]') : f.querySelector('[name=email]')).focus();
}
const lastEmail = () => { try { return localStorage.getItem('cg-email') || ''; } catch { return ''; } };

/* ---------- password ---------------------------------------------------------
   Email + password: no inbox, no link, no device that has to remember anything.
   It exists because the link-based routes each depend on something outside this
   codebase behaving — a mail client that does not pre-open URLs, a browser that
   keeps the storage it wrote, an email template carrying the right variable —
   and on an iPad every one of those assumptions failed at once.

   A password is only as good as its rotation, so an account issued a temporary
   one carries `must_set_password` in its metadata and reaches nothing but the
   screen that replaces it. */
const mustSetPassword = (session) => session?.user?.user_metadata?.must_set_password === true;

function passwordMessage(msg) {
  if (/invalid login credentials/i.test(msg)) return 'That email and password do not match. If the owner has not given you a password yet, use a sign-in link.';
  if (/email not confirmed/i.test(msg)) return 'This address has not been confirmed yet. Ask the owner.';
  if (/password/i.test(msg) && /short|least|weak/i.test(msg)) return msg;
  return msg;
}

/* Changing it later, from the account menu. Supabase does not ask for the current
   password here — the session is the proof — so this screen is reachable only from
   inside one, like every other thing in the sheet. */
function openPassword() {
  const host = $('#profile'); host.hidden = false; document.body.style.overflow = 'hidden';
  host.innerHTML = `<div class="sheet"><div class="pf-head"><div class="pf-id"><h2>Change password</h2></div><div class="pf-actions"><button class="pf-close" id="pw-x">×</button></div></div>
    <div class="pf-body"><form id="pw-form" class="ad-form">
      <label>New password <input type="password" name="password" required minlength="12" autocomplete="new-password"></label>
      <label>Repeat it <input type="password" name="confirm" required minlength="12" autocomplete="new-password"></label>
      <p class="ad-muted">At least 12 characters. Signing in elsewhere is unaffected — this does not end your other sessions.</p>
      <div class="actions"><button class="btn btn-accent btn-sm" type="submit">Save</button>
      <button class="btn btn-line btn-sm" type="button" id="pw-cancel">Cancel</button></div>
    </form><p id="pw-msg" class="ad-msg" hidden></p></div></div>`;
  $('#pw-x').onclick = pfClose; $('#pw-cancel').onclick = pfClose;
  $('#pw-form').onsubmit = async (e) => {
    e.preventDefault(); const f = new FormData(e.target);
    const password = String(f.get('password') || ''); const m = $('#pw-msg');
    m.hidden = false; m.className = 'ad-msg';
    if (password !== String(f.get('confirm') || '')) { m.className = 'ad-msg err'; m.textContent = 'The two do not match.'; return; }
    if (password.length < 12) { m.className = 'ad-msg err'; m.textContent = 'Use at least 12 characters.'; return; }
    m.textContent = 'Saving…';
    const { error } = await sb.auth.updateUser({ password, data: { must_set_password: false } });
    if (error) { m.className = 'ad-msg err'; m.textContent = passwordMessage(error.message); return; }
    pfClose(); toast('Password changed');
  };
}

async function boot() {
  if (webauthnOk) { $('#passkey-box').hidden = false; $('#passkey-go').onclick = passkeySignIn; }

  $('#password-form').addEventListener('submit', async (e) => {
    e.preventDefault();
    const f = new FormData(e.target);
    const email = String(f.get('email') || '').trim().toLowerCase();
    const password = String(f.get('password') || '');
    const m = $('#login-msg'); m.hidden = false; m.className = 'ad-msg'; m.textContent = 'Signing in…';
    const { error } = await sb.auth.signInWithPassword({ email, password });
    if (error) { m.className = 'ad-msg err'; m.textContent = passwordMessage(error.message); return; }
    try { localStorage.setItem('cg-email', email); } catch {}
    m.hidden = true;                                   // onAuthStateChange draws the rest
  });

  // the link and the code are still here, one click away, for whoever has no password yet
  $('#link-toggle').onclick = () => {
    const f = $('#login-form'); f.hidden = !f.hidden;
    if (!f.hidden) { f.querySelector('[name=email]').value = lastEmail(); f.querySelector('[name=email]').focus(); }
  };

  $('#newpass-form').addEventListener('submit', async (e) => {
    e.preventDefault();
    const f = new FormData(e.target);
    const password = String(f.get('password') || ''); const confirm = String(f.get('confirm') || '');
    const m = $('#newpass-msg'); m.hidden = false; m.className = 'ad-msg';
    if (password !== confirm) { m.className = 'ad-msg err'; m.textContent = 'The two do not match.'; return; }
    if (password.length < 12) { m.className = 'ad-msg err'; m.textContent = 'Use at least 12 characters.'; return; }
    m.textContent = 'Saving…';
    // one call: the new password and the flag that lets the cockpit open, so a failure
    // cannot leave an account with a chosen password still marked as temporary
    const { error } = await sb.auth.updateUser({ password, data: { must_set_password: false } });
    if (error) { m.className = 'ad-msg err'; m.textContent = passwordMessage(error.message); return; }
    m.hidden = true; e.target.reset();
    toast('Password saved');
    const { data } = await sb.auth.getSession();
    render(data.session);
  });

  $('#login-form').addEventListener('submit', async (e) => {
    e.preventDefault();
    const email = new FormData(e.target).get('email').trim().toLowerCase();
    const m = $('#login-msg'); m.hidden = false; m.className = 'ad-msg';
    m.textContent = 'Sending…';
    const { error } = await sb.auth.signInWithOtp({ email, options: { emailRedirectTo: `${location.origin}/admin/`, shouldCreateUser: false } });
    if (error) { m.className = 'ad-msg err'; m.textContent = /signup|not allowed|not found/i.test(error.message) ? 'This email is not provisioned for the back-office. Ask the owner.' : error.message; return; }
    m.className = 'ad-msg ok'; m.textContent = 'Check your inbox. Enter the 6-digit code below — that always works. The link only works in this exact browser, so opening it from your mail app will not sign you in.';
    showCodeForm(email);
  });
  // the same one-time email carries a 6-digit code: the way in for the installed app, where the link cannot land
  $('#code-form').addEventListener('submit', async (e) => {
    e.preventDefault();
    const f = new FormData(e.target);
    const email = (e.target.dataset.email || String(f.get('email') || '')).trim().toLowerCase();
    const token = String(f.get('code') || '').replace(/\D/g, '');
    const m = $('#login-msg'); m.hidden = false; m.className = 'ad-msg'; m.textContent = 'Checking…';
    if (!email) { m.className = 'ad-msg err'; m.textContent = 'Enter the email you asked the link for.'; return; }
    if (token.length !== 6) { m.className = 'ad-msg err'; m.textContent = 'Enter the 6 digits from the email.'; return; }
    const { error } = await sb.auth.verifyOtp({ email, token, type: 'email' });
    if (error) { m.className = 'ad-msg err'; m.textContent = /expired|invalid/i.test(error.message) ? 'That code is not valid any more. Send a new link and use the fresh code.' : error.message; return; }
    m.hidden = true;
  });
  document.addEventListener('click', (e) => { if (e.target.closest('[data-signout]')) sb.auth.signOut().then(() => location.reload()); });
  document.addEventListener('click', (e) => { if (e.target.closest('[data-passkeys]')) openPasskeys(); });
  document.addEventListener('click', (e) => { if (e.target.closest('[data-password]')) openPassword(); });
  sb.auth.onAuthStateChange((_ev, session) => { render(session); });

  /* ---- coming back from a sign-in email -------------------------------------
     Two shapes arrive here, and only one of them is portable.

     ?token_hash=…&type=magiclink — built from {{ .TokenHash }} in the email
       template. It is verified below, by this page, against GoTrue's /verify
       endpoint with no PKCE exchange. Nothing about it is tied to a browser, so
       it works from the mail app's own browser, a private window, another
       device. This is the shape the template should use.

     #access_token=… — GoTrue's own {{ .ConfirmationURL }} under the implicit
       flow. supabase-js reads the fragment and stores the session. Portable, and
       the shape the default email template produces today.

     ?code=… — the same link under PKCE, which this client no longer requests.
       Kept handled because a link sent before that change still arrives this way:
       supabase-js needs a verifier stored when the link was REQUESTED, so it only
       ever works in that one browser and opens nothing anywhere else.

     Either way, a failure used to be silent: getSession() returned null, the
     sign-in card was redrawn, and nothing said whether the click had even
     registered. Now it says which of the two happened. */
  const q = new URL(location.href);
  const hash = new URLSearchParams(location.hash.replace(/^#/, ''));
  const tokenHash = q.searchParams.get('token_hash');
  const OTP_TYPES = ['magiclink', 'email', 'signup', 'invite', 'recovery', 'email_change'];
  let linkError = q.searchParams.get('error_description') || hash.get('error_description') || '';
  let expired = false;

  if (tokenHash && !linkError) {
    const asked = String(q.searchParams.get('type') || 'magiclink');
    const type = OTP_TYPES.includes(asked) ? asked : 'magiclink';      // never pass the URL through blind
    const { error } = await sb.auth.verifyOtp({ token_hash: tokenHash, type });
    if (error) { linkError = error.message; expired = /expired|invalid|not found/i.test(error.message); }
  }

  const cameFromLink = !!tokenHash || q.searchParams.has('code') || q.searchParams.has('error') || hash.has('error') || hash.has('access_token');
  const { data } = await sb.auth.getSession();
  if (!data.session && cameFromLink) {
    const m = $('#login-msg'); m.hidden = false; m.className = 'ad-msg err';
    m.textContent = expired
      ? 'That link has expired or was already used. Send a new one — and note that some mail apps open links once on their own, which spends them.'
      : linkError ? `That link did not work: ${linkError}`
      : 'That link did not open a session in this browser. A sign-in link only works in the browser that asked for it — if you opened it from your mail app, come back here and use the 6-digit code from that same email.';
    showCodeForm(lastEmail());
  }
  if (cameFromLink) history.replaceState(null, '', location.pathname);   // don't replay it on refresh
  render(data.session);
}

/* ---------- navigation model: sections, permission-gated, some with sub-tabs ---------- */
// A section renders either a single view (run) or a strip of sub-tabs.
// Finance stays one destination (CG-008); Schedule merges the four
// time-management domains (CG-009); CRM merges Leads + Contacts.
function navModel() {
  return [
    { key: 'overview', label: 'Overview', icon: '▦', show: () => true, run: overview },
    { key: 'crm', label: 'Clients', icon: '<svg viewBox="0 0 24 24" width="17" height="17" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><circle cx="9" cy="7.5" r="3"/><path d="M3.8 19c0-2.9 2.3-5 5.2-5s5.2 2.1 5.2 5"/><path d="M16.2 5.2a3 3 0 0 1 0 5.6"/><path d="M17 14.3c2.3.4 3.9 2.2 3.9 4.7"/></svg>', show: () => has('coach:operations') || has('client_profile:view'),
      subs: [ { key: 'dashboard', label: 'Dashboard', show: () => true, run: crmDashboard },
              { key: 'leads', label: 'Leads', show: () => has('coach:operations'), run: leads },
              { key: 'contacts', label: 'Contacts', show: () => has('client_profile:view'), run: crmContacts } ] },
    { key: 'schedule', label: 'Schedule', icon: '◷', show: () => has('coach:operations'),
      subs: [ { key: 'calendar', label: 'Calendar', show: () => true, run: calendar },
              { key: 'sessions', label: 'Sessions', show: () => true, run: sessionsList },
              { key: 'hours', label: 'Hours', show: () => true, run: hours },
              { key: 'tours', label: 'Tour stops', show: () => true, run: tours } ] },
    { key: 'collab', label: 'Collaborations', icon: '⇄', show: () => has('collab:view'), run: collabList },
    // Finance = the daily business surface (Transactions first, never the infrastructure).
    { key: 'finance', label: 'Finance', icon: '$', show: () => has('finance:view'),
      subs: [ { key: 'transactions', label: 'Transactions', show: () => true, run: financeTransactions },
              { key: 'subscriptions', label: 'Subscriptions', show: () => true, run: financeSubscriptions },
              { key: 'commissions', label: 'Commissions', show: () => true, run: financeCommissions },
              { key: 'methods', label: 'Payment methods', show: () => true, run: financePaymentMethods } ] },
    { key: 'analytics', label: 'Audience', icon: '◔', show: () => has('analytics:view'), run: analytics },
    // Settings = what is configured once and rarely touched: the catalogue, who has access, and the
    // BEAU PH payment infrastructure (Rails, FX) — each tab keeps its own permission.
    { key: 'settings', label: 'Settings', icon: '⚙', show: () => has('catalog:view') || has('platform:admin') || has('finance:view'),
      subs: [ { key: 'services', label: 'Services', show: () => has('catalog:view'), run: catalogue },
              { key: 'business', label: 'Business', show: () => has('platform:admin'), run: orgProfile },
              { key: 'access', label: 'Access', show: () => has('platform:admin'), run: access },
              { key: 'rails', label: 'Payment rails', show: () => has('finance:view'), run: phRails },
              { key: 'fx', label: 'FX', show: () => has('finance:view'), run: phFx } ] },
  ];
}
let NAV = [];
let cur = { section: null, sub: null };

async function render(session) {
  if (session && me && me.email === session.user.email && cur.section) { renderAccount(session); return; }
  $('#login').hidden = !!session; $('#app').hidden = true; $('#noaccess').hidden = true; $('#newpass').hidden = true;
  $('#sidebar').hidden = true; $('#topbar').hidden = true; $('#subnav').hidden = true;
  if (!session) { me = null; cur = { section: null, sub: null }; return; }
  // a temporary password reaches this screen and nothing else — not even my_permissions
  if (mustSetPassword(session)) { $('#newpass').hidden = false; $('#newpass-form [name=password]').focus(); return; }
  try {
    const { data, error } = await sb.rpc('my_permissions'); if (error) throw error;
    me = data;
    initFinance({ sb, $, esc, money, st, fmt, table, toast, fail, has, view, config: CONFIG, openProfile });
    initCollab({ sb, $, esc, money, st, fmt, table, toast, fail, has, view, config: CONFIG });
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
    offerInstall(); offerNotifications();              // signed in, and NAV is not empty: this person works here
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
    m.innerHTML = `<div class="em">Signed in as<br><b>${esc(email)}</b></div>${webauthnOk ? '<button data-passkeys>Passkeys</button>' : ''}<button data-password>Change password</button><button data-signout>Sign out</button>`;
    $('#account').appendChild(m);
    setTimeout(() => document.addEventListener('click', function close() { m.remove(); document.removeEventListener('click', close); }), 0);
  };
}

// route to a section (and optional sub-tab); keeps the hash in sync
function go(sectionKey, subKey) {
  // sections that moved keep their old hashes landing: #bookings → Schedule, #services / #access / #beauph → Settings
  if (sectionKey === 'bookings') { sectionKey = 'schedule'; subKey = 'sessions'; }
  if (sectionKey === 'schedule' && subKey === 'bookings') subKey = 'sessions';                       // Bookings folded into Sessions
  if (sectionKey === 'schedule' && (subKey === 'availability' || subKey === 'exceptions')) subKey = 'hours';   // both folded into Hours
  if (sectionKey === 'services') { sectionKey = 'settings'; subKey = 'services'; }
  if (sectionKey === 'access') { sectionKey = 'settings'; subKey = 'access'; }
  if (sectionKey === 'beauph') { sectionKey = 'settings'; subKey = subKey === 'fx' ? 'fx' : 'rails'; }
  if (sectionKey === 'collaborations') sectionKey = 'collab';   // the push deep link spells it out
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

/* ---- CRM quick actions (non-destructive: status-only, review-flag only) ---- */
async function crmSetStatus(id, status, msg, after) {
  const { error } = await sb.rpc('crm_set_status', { p_id: id, p_status: status });
  if (error) return fail(error);
  toast(msg || `Moved to ${status}`); if (after) after();
}
async function crmClearReview(id, after) {
  const { error } = await sb.rpc('crm_clear_review', { p_id: id });
  if (error) return fail(error);
  toast('Marked as not a duplicate'); if (after) after();
}
async function leadSetStatus(id, status, msg, after) {
  const { error } = await sb.from('contacts').update({ status }).eq('id', id);
  if (error) return fail(error);
  toast(msg || `Lead ${status}`); if (after) after();
}
// Delete an enquiry for good (row + attachments, audited). The CRM person, if any, stays — that
// record is governed by CG-010, never by a lead. One confirmation, no undo.
async function leadDelete(id, name, after) {
  if (!confirm(`Delete the enquiry from ${name || 'this lead'} for good?\n\nThe message and any attachments are removed. The CRM contact (if one exists) is kept.`)) return;
  const { data, error } = await sb.rpc('lead_delete', { p_id: id });
  if (error) return fail(error);
  // the rows are gone; the files follow through the Storage API (SQL cannot delete storage objects)
  const paths = (data && data.paths) || [];
  if (paths.length) { try { await sb.storage.from('enquiry-media').remove(paths); } catch { /* orphaned file: unreachable once its row is gone */ } }
  toast('Enquiry deleted'); if (after) after();
}
// The lead action buttons, shared by the Leads list and the CRM dashboard.
function leadActs(c) {
  if (!has('coach:operations')) return '';
  const a = [];
  if (c.status !== 'qualified') a.push(`<button class="btn btn-accent btn-xs" data-lead-convert="${c.id}" data-lead-crm="${esc(c.crm_contact_id || '')}">Make client</button>`);
  if (['closed', 'spam'].includes(c.status)) a.push(`<button class="btn btn-line btn-xs" data-lead-restore="${c.id}">Restore</button>`);
  else a.push(`<button class="btn btn-line btn-xs" data-lead-archive="${c.id}">Archive</button>`);
  a.push(`<button class="btn btn-line btn-xs" data-lead-delete="${c.id}" data-lead-name="${esc(c.name || '')}">Delete</button>`);
  return a.join('');
}
function wireLeadActs(root, reload) {
  root.querySelectorAll('[data-lead-convert]').forEach((b) => b.onclick = (e) => { e.stopPropagation(); convertLead(b.dataset.leadConvert, b.dataset.leadCrm || null, reload); });
  root.querySelectorAll('[data-lead-archive]').forEach((b) => b.onclick = (e) => { e.stopPropagation(); leadSetStatus(b.dataset.leadArchive, 'closed', 'Lead archived', reload); });
  root.querySelectorAll('[data-lead-restore]').forEach((b) => b.onclick = (e) => { e.stopPropagation(); leadSetStatus(b.dataset.leadRestore, 'new', 'Lead restored', reload); });
  root.querySelectorAll('[data-lead-delete]').forEach((b) => b.onclick = (e) => { e.stopPropagation(); leadDelete(b.dataset.leadDelete, b.dataset.leadName, reload); });
}
// Convert an enquiry to a client: the linked CRM person becomes active, the enquiry is qualified.
async function convertLead(enquiryId, crmId, after) {
  if (crmId) { const { error } = await sb.rpc('crm_set_status', { p_id: crmId, p_status: 'active' }); if (error) return fail(error); }
  const { error: e2 } = await sb.from('contacts').update({ status: 'qualified' }).eq('id', enquiryId);
  if (e2) return fail(e2);
  toast('Converted to client'); if (after) after();
}

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
      <td class="acts">${mediaCount[c.id] ? `<span class="ad-muted" style="font-size:12px">📎 ${mediaCount[c.id]}</span> ` : ''}${leadActs(c)}</td>
    </tr>`), 'No leads match.')}</div>`;
  $('#lead-status').onchange = (e) => { view.dataset.leadStatus = e.target.value; leads().catch(fail); };
  $('#lead-search').onchange = (e) => { view.dataset.leadSearch = e.target.value.trim(); leads().catch(fail); };
  view.querySelectorAll('tr.clik').forEach((tr) => tr.onclick = () => openProfile(tr.dataset.crm || null, tr.dataset.enquiry, 'enquiries'));
  wireLeadActs(view, () => leads().catch(fail));
}

/* =============================== CRM · DASHBOARD =============================== */
// The CRM's own front page: the funnel in numbers, then the two things to act on —
// new leads (convert / archive / delete) and possible duplicates. Lead handling lives
// HERE, not in the Overview, so the cockpit stays a cockpit.
async function crmDashboard() {
  const { data: d, error } = await sb.rpc('crm_dashboard'); if (error) throw error;
  const L = d.leads, K = d.contacts;
  let newLeads = [], review = [];
  if (L) { const { data: r } = await sb.from('contacts').select(CONTACT_COLS).eq('status', 'new').order('created_at', { ascending: false }).limit(12); newLeads = r || []; }
  if (K) { const { data: r } = await sb.rpc('crm_list_contacts', { p_search: null, p_review_only: true }); review = (r || []).slice(0, 8); }
  const canManage = has('client_profile:manage');

  const kpis = [];
  if (L) kpis.push(
    ['New leads to handle', L.new, () => { view.dataset.leadStatus = 'new'; go('crm', 'leads'); }],
    ['Leads · 7 days', L.last_7d, () => { view.dataset.leadStatus = ''; go('crm', 'leads'); }],
    ['Leads · 30 days', L.last_30d, () => { view.dataset.leadStatus = ''; go('crm', 'leads'); }],
    ['Converted to clients', L.qualified, () => { view.dataset.leadStatus = 'qualified'; go('crm', 'leads'); }],
    ['Archived / spam', L.closed + L.spam, () => { view.dataset.leadStatus = 'closed'; go('crm', 'leads'); }]);
  if (K) kpis.push(
    ['Active clients', K.active, () => { view.dataset.cStatus = 'active'; view.dataset.cReview = ''; go('crm', 'contacts'); }],
    ['Contacts', K.total, () => { view.dataset.cStatus = ''; view.dataset.cReview = ''; go('crm', 'contacts'); }],
    ['Flagged for review', K.needs_review, () => { view.dataset.cReview = '1'; go('crm', 'contacts'); }]);

  const leadItem = (c) => `<div class="ov-item" data-enq="${c.id}" data-crm="${esc(c.crm_contact_id || '')}">
    <div class="ov-item-main"><b>${esc(c.name)}</b> <span class="ad-muted" style="font-size:12px">${esc(c.interest || 'enquiry')} · ${fmt(c.created_at, 'Asia/Dubai', { dateStyle: 'medium' })}</span>
      <div class="ad-muted" style="font-size:12px">${esc(c.contact)}</div>${c.message ? `<div class="msg">${esc(c.message.slice(0, 110))}${c.message.length > 110 ? '…' : ''}</div>` : ''}</div>
    <div class="ov-item-acts">${leadActs(c)}<button class="btn btn-line btn-xs" data-ov-open>Open</button></div></div>`;
  const reviewItem = (c) => `<div class="ov-item" data-crmrev="${c.id}">
    <div class="ov-item-main"><b>${esc(c.display_name || '—')}</b> <span class="ad-badge-rev">review</span>
      <div class="ad-muted" style="font-size:12px">${esc(c.email || c.phone || '—')} · ${c.enquiry_count} enq / ${c.booking_count} bk</div></div>
    <div class="ov-item-acts">${canManage ? '<button class="btn btn-line btn-xs" data-ov-keep>Not a duplicate</button>' : ''}<button class="btn btn-accent btn-xs" data-ov-open2>Open &amp; merge</button></div></div>`;
  const panel = (title, items, render, empty) => `<div class="ad-panel ov-panel"><div class="ov-lbl">${esc(title)}${items.length ? ` (${items.length})` : ''}</div>${items.length ? items.map(render).join('') : `<p class="ad-empty">${esc(empty)}</p>`}</div>`;
  const stale = L && L.oldest_new_days >= 3 ? `<p class="ad-note" style="margin:0 0 14px">The oldest unanswered lead is ${L.oldest_new_days} days old.</p>` : '';

  view.innerHTML = `
    <div class="ad-head"><div><h1>Clients</h1><p class="ad-muted">The funnel in numbers, then what to act on: new leads to convert, archive or delete, and possible duplicates to resolve.</p></div></div>
    <div class="ad-kpis">${kpis.map(([l, v], i) => `<button class="ad-kpi ov-kpi-click" data-kpi="${i}"><b>${kpiVal(v)}</b><span>${esc(l)}</span></button>`).join('')}</div>
    ${stale}
    <div class="ov-cols">${L ? panel('New leads', newLeads, leadItem, 'No new leads. Inbox zero.') : ''}${K ? panel('To review — possible duplicates', review, reviewItem, 'Nothing flagged.') : ''}</div>`;

  view.querySelectorAll('[data-kpi]').forEach((b) => { b.onclick = kpis[+b.dataset.kpi][2]; });
  const reload = () => crmDashboard().catch(fail);
  wireLeadActs(view, reload);
  view.querySelectorAll('.ov-item[data-enq]').forEach((el) => { const op = el.querySelector('[data-ov-open]'); if (op) op.onclick = () => openProfile(el.dataset.crm || null, el.dataset.enq, 'enquiries'); });
  view.querySelectorAll('.ov-item[data-crmrev]').forEach((el) => {
    const crm = el.dataset.crmrev;
    const kp = el.querySelector('[data-ov-keep]'); if (kp) kp.onclick = () => crmClearReview(crm, reload);
    const op = el.querySelector('[data-ov-open2]'); if (op) op.onclick = () => openProfile(crm, null, 'overview');
  });
}

/* =============================== CRM · CONTACTS =============================== */
// Canonical people (crm_contacts) with enquiry/booking counts. client_profile:view.
/* The search box types, it does not submit.

   It was bound to `onchange`, which only fires on blur or Enter, so typing a name and
   watching the list sit there unfiltered was the box working exactly as written — and
   looking broken. It searches as you type now, a short pause after the last keystroke so
   one query goes out per word rather than per letter.

   Two things have to be held together for that to feel like a search field. crmContacts()
   rebuilds the whole view, which throws the caret away, so it is put back where it was
   or the next letter lands nowhere. And each run carries a number: a slow query for "Am"
   must not arrive after, and overwrite, the answer for "Amanda". */
let crmRun = 0;
let crmTypeTimer = null;

async function crmContacts(focus) {
  const mine = ++crmRun;
  const raw = view.dataset.cSearch || '';           // untrimmed: a trailing space is a word boundary being typed
  const search = raw.trim();
  const status = view.dataset.cStatus || '';
  const reviewOnly = view.dataset.cReview === '1';
  const { data, error } = await sb.rpc('crm_list_contacts', { p_search: search || null, p_review_only: reviewOnly }); if (error) throw error;
  if (mine !== crmRun) return;                      // a later keystroke already asked a better question
  const rows = (data || []).filter((c) => !status || c.status === status);
  const reviewCount = (data || []).filter((c) => c.needs_review).length;
  const opts = ['lead', 'active', 'past', 'archived'];
  view.innerHTML = `
    <div class="ad-head"><div><h1>Contacts</h1><p class="ad-muted">Every person who has enquired or booked. Click to open the profile.</p></div>
      <div class="ad-filters">
        <input id="c-search" type="search" autocomplete="off" autocapitalize="off" spellcheck="false" placeholder="Search name, email, phone, city…" value="${esc(raw)}">
        <select id="c-status"><option value="">All statuses</option>${opts.map((o) => `<option ${o === status ? 'selected' : ''}>${o}</option>`).join('')}</select>
        <button class="btn btn-sm ${reviewOnly ? 'btn-accent' : 'btn-line'}" id="c-review">${reviewOnly ? 'Showing needs-review' : 'Needs review'}${!reviewOnly && reviewCount ? ` (${reviewCount})` : ''}</button>
        ${has('client_profile:manage') ? '<button class="btn btn-accent btn-sm" id="c-new">New contact</button>' : ''}
      </div></div>
    ${reviewOnly ? '<p class="ad-note">These people share an email or a phone with someone else, so the match was ambiguous. Nothing was merged automatically. Open a profile to review it, or merge it into the record you are keeping — merging moves the sessions, packs and subscriptions across.</p>' : ''}
    <div class="ad-panel">${table(['Name', '<span class="col-wide">Where</span>', 'Contact', '<span class="col-wide">Interest</span>', '<span class="col-wide">Enquiries</span>', '<span class="col-wide">Bookings</span>', '<span class="col-wide">Last activity</span>', 'Status', ''], rows.map((c) => `<tr class="clik" data-crm="${c.id}">
      <td><b>${esc(c.display_name || '—')}</b>${c.needs_review ? ' <span class="ad-badge-rev">review</span>' : ''}</td>
      <td class="col-wide">${esc([c.city, c.country].filter(Boolean).join(', ') || '—')}</td>
      <td class="ad-muted" style="font-size:12px">${esc(c.email || c.phone || '—')}</td>
      <td class="col-wide">${esc(c.main_interest || '—')}</td>
      <td class="num col-wide">${c.enquiry_count}</td>
      <td class="num col-wide">${c.booking_count}</td>
      <td class="col-wide">${fmt(c.last_activity_at, 'Asia/Dubai', { dateStyle: 'medium' })}</td>
      <td>${st(c.status)}</td>
      <td class="acts">${has('client_profile:manage') ? `${c.needs_review ? `<button class="btn btn-accent btn-xs" data-c-merge="${c.id}">Merge…</button><button class="btn btn-line btn-xs" data-c-del="${c.id}" data-c-name="${esc(c.display_name || '')}">Delete this one</button><button class="btn btn-line btn-xs" data-c-keep="${c.id}">Not a duplicate</button>` : ''}${c.status === 'lead' ? `<button class="btn btn-accent btn-xs" data-c-status="${c.id}" data-to="active">Make client</button>` : ''}${c.status === 'archived' ? `<button class="btn btn-line btn-xs" data-c-status="${c.id}" data-to="active">Restore</button>` : `<button class="btn btn-line btn-xs" data-c-status="${c.id}" data-to="archived">Archive</button>`}${c.needs_review ? '' : `<button class="btn btn-line btn-xs" data-c-del="${c.id}" data-c-name="${esc(c.display_name || '')}">Delete</button>`}` : ''}</td>
    </tr>`), reviewOnly ? 'Nothing needs review.' : 'No contacts match.')}</div>`;
  $('#c-status').onchange = (e) => { view.dataset.cStatus = e.target.value; crmContacts().catch(fail); };
  const si = $('#c-search');
  const searchNow = () => { clearTimeout(crmTypeTimer); crmContacts({ caret: si.selectionStart }).catch(fail); };
  si.oninput = (e) => {
    view.dataset.cSearch = e.target.value;
    clearTimeout(crmTypeTimer);
    crmTypeTimer = setTimeout(searchNow, 220);
  };
  // Enter and the clear cross are answers, not typing: they do not wait out the pause
  si.onkeydown = (e) => { if (e.key === 'Enter') { e.preventDefault(); searchNow(); } };
  si.onsearch = searchNow;
  if (focus && focus.caret != null) { si.focus(); try { si.setSelectionRange(focus.caret, focus.caret); } catch {} }
  $('#c-review').onclick = () => { view.dataset.cReview = reviewOnly ? '' : '1'; crmContacts().catch(fail); };
  const nb = $('#c-new'); if (nb) nb.onclick = () => openContactEditor(null);
  view.querySelectorAll('tr.clik').forEach((tr) => tr.onclick = () => openProfile(tr.dataset.crm, null, 'overview'));
  const reload = () => crmContacts().catch(fail);
  view.querySelectorAll('[data-c-status]').forEach((b) => b.onclick = (e) => { e.stopPropagation(); const to = b.dataset.to; crmSetStatus(b.dataset.cStatus, to, to === 'active' ? 'Now a client' : to === 'archived' ? 'Archived' : 'Updated', reload); });
  view.querySelectorAll('[data-c-keep]').forEach((b) => b.onclick = (e) => { e.stopPropagation(); crmClearReview(b.dataset.cKeep, reload); });
  view.querySelectorAll('[data-c-merge]').forEach((b) => b.onclick = (e) => { e.stopPropagation(); openProfile(b.dataset.cMerge, null, 'overview'); });
  view.querySelectorAll('[data-c-del]').forEach((b) => b.onclick = (e) => { e.stopPropagation(); crmDelete(b.dataset.cDel, b.dataset.cName, reload); });
}

/* Delete a person for good.

   Two steps, because the first question is always "what am I about to destroy?".
   crm_delete_preview answers it in numbers, the confirmation repeats them, and only
   then does the delete run with p_cascade.

   Money is the one thing that refuses outright, cascade or not: an order and its
   payment have to go on agreeing with Stripe. That refusal arrives as a foreign-key
   error carrying a sentence written for a human, so show the sentence. */
const countLine = (c) => [
  [c.sessions, 'coaching session'], [c.packs, 'session pack'], [c.bookings, 'booking'],
  [c.subscriptions, 'subscription'], [c.collaborations, 'collaboration'],
  [c.measurements, 'health measurement'], [c.notes, 'note'],
].filter(([n]) => n > 0).map(([n, w]) => `${n} ${w}${n > 1 ? 's' : ''}`).join(', ');

async function crmDelete(id, name, after) {
  const { data: c, error: e0 } = await sb.rpc('crm_delete_preview', { p_id: id });
  if (e0) return fail(e0);
  const who = name || 'this contact';
  if (c.orders > 0 || c.payments > 0) {
    return toast(`${who} has ${c.orders} order(s) and ${c.payments} payment(s) on file. Those records stay — archive instead.`, true);
  }
  const history = countLine(c);
  const enq = c.enquiries > 0 ? `\n\n${c.enquiries} enquiry(ies) are kept and simply unlinked.` : '';
  const msg = history
    ? `Delete ${who} and ${history}?${enq}\n\nThis cannot be undone. Archiving is reversible and keeps everything.`
    : `Delete ${who}?${enq}\n\nThis cannot be undone — archiving is reversible.`;
  if (!await confirmAct(msg)) return;
  const { error } = await sb.rpc('crm_delete_contact', { p_id: id, p_cascade: true });
  if (error) return toast(error.message || 'Could not delete this contact', true);
  toast('Contact deleted');
  if (after) after();
}

/* =============================== OVERVIEW =============================== */
// The Overview is the cockpit, not an inbox: the sessions ahead, the bookings ahead, one
// line on what waits in CRM, two charts over 12 months (revenue → Finance, pipeline → CRM),
// then the headline numbers. Lead handling lives in CRM › Dashboard.

// A column chart in plain SVG (no library: the admin CSP allows self-hosted script only).
// series: [{ name, color, values[] }] on shared labels[]; grouped when > 1 series. Columns
// ≤ 24px, 4px rounded cap, square at the baseline; hairline grid; a legend for ≥ 2 series;
// a hover tooltip per column. Value text wears text tokens, never the series colour.
function columnChart({ labels, series, fmtValue = (v) => String(v), id }) {
  const W = 560, H = 220, padL = 44, padR = 10, padT = 12, padB = 26;
  const iw = W - padL - padR, ih = H - padT - padB;
  const max = Math.max(1, ...series.flatMap((s) => s.values));
  // clean ticks: 4 steps on a 1-2-5 grid
  const raw = max / 4, mag = 10 ** Math.floor(Math.log10(raw)), step = [1, 2, 5, 10].map((k) => k * mag).find((k) => k >= raw);
  const top = Math.ceil(max / step) * step; const ticks = []; for (let t = 0; t <= top; t += step) ticks.push(t);
  const y = (v) => padT + ih - (v / top) * ih;
  const band = iw / labels.length, gap = 2, n = series.length;
  const colW = Math.min(24, (band * 0.7 - gap * (n - 1)) / n);
  const groupW = colW * n + gap * (n - 1);
  const col = (x, v, color, i, k) => {
    const h = padT + ih - y(v), r = Math.min(4, h), yy = y(v), x2 = x + colW;
    const d = h <= 0 ? '' : `M${x},${padT + ih} V${yy + r} Q${x},${yy} ${x + r},${yy} H${x2 - r} Q${x2},${yy} ${x2},${yy + r} V${padT + ih} Z`;
    return `<path d="${d}" fill="${color}" data-i="${i}" data-k="${k}"></path><rect x="${x - 2}" y="${padT}" width="${colW + 4}" height="${ih}" fill="transparent" data-i="${i}" data-k="${k}"></rect>`;
  };
  const cols = labels.map((_, i) => series.map((s, k) => col(padL + band * i + (band - groupW) / 2 + k * (colW + gap), s.values[i] || 0, s.color, i, k)).join('')).join('');
  const grid = ticks.map((t) => `<line x1="${padL}" x2="${W - padR}" y1="${y(t)}" y2="${y(t)}" stroke="var(--line)" stroke-width="1"></line><text x="${padL - 6}" y="${y(t) + 4}" text-anchor="end" class="ov-ax">${esc(fmtValue(t, true))}</text>`).join('');
  const xl = labels.map((l, i) => `<text x="${padL + band * i + band / 2}" y="${H - 8}" text-anchor="middle" class="ov-ax">${esc(l)}</text>`).join('');
  const legend = series.length > 1 ? `<div class="ov-legend">${series.map((s) => `<span><i style="background:${s.color}"></i>${esc(s.name)}</span>`).join('')}</div>` : '';
  return `${legend}<div class="ov-chart" id="${id}"><svg viewBox="0 0 ${W} ${H}" role="img">${grid}${cols}${xl}</svg><div class="ov-tip" hidden></div></div>`;
}
function wireChart(id, labels, series, fmtValue) {
  const root = $('#' + id); if (!root) return; const tip = root.querySelector('.ov-tip');
  root.querySelectorAll('[data-i]').forEach((el) => {
    el.onmouseenter = (e) => { const i = +el.dataset.i, k = +el.dataset.k; tip.innerHTML = `<b>${esc(labels[i])}</b>${series.map((s) => `<div><i style="background:${s.color}"></i>${esc(s.name)} · ${esc(fmtValue(s.values[i] || 0, false, s.name))}</div>`).join('')}`; tip.hidden = false; void k; };
    el.onmousemove = (e) => { const r = root.getBoundingClientRect(); tip.style.left = Math.min(e.clientX - r.left + 12, r.width - tip.offsetWidth - 4) + 'px'; tip.style.top = (e.clientY - r.top - 10) + 'px'; };
    el.onmouseleave = () => { tip.hidden = true; };
  });
}
// A line chart for a daily series (30–60 points: a column per day would be a fence).
// 2px line, the hue at 10% as an area wash, an end dot with a 2px surface ring, hairline
// grid, one crosshair tooltip. Same plain SVG, same tokens, no library.
function lineChart({ labels, series, fmtValue = (v) => String(v), id }) {
  const W = 560, H = 200, padL = 46, padR = 12, padT = 12, padB = 24;
  const iw = W - padL - padR, ih = H - padT - padB;
  const max = Math.max(1, ...series.flatMap((s) => s.values));
  const raw = max / 4, mag = 10 ** Math.floor(Math.log10(raw || 1));
  const step = [1, 2, 5, 10].map((k) => k * mag).find((k) => k >= raw) || 1;
  const top = Math.ceil(max / step) * step; const ticks = []; for (let t = 0; t <= top; t += step) ticks.push(t);
  const n = Math.max(1, labels.length - 1);
  const x = (i) => padL + (n === 0 ? iw / 2 : (i / n) * iw);
  const y = (v) => padT + ih - (v / top) * ih;
  const grid = ticks.map((t) => `<line x1="${padL}" x2="${W - padR}" y1="${y(t)}" y2="${y(t)}" stroke="var(--line)" stroke-width="1"></line><text x="${padL - 6}" y="${y(t) + 4}" text-anchor="end" class="ov-ax">${esc(fmtValue(t, true))}</text>`).join('');
  const paths = series.map((s) => {
    const pts = s.values.map((v, i) => `${x(i)},${y(v || 0)}`).join(' ');
    const area = `M${padL},${padT + ih} L${s.values.map((v, i) => `${x(i)},${y(v || 0)}`).join(' L')} L${x(s.values.length - 1)},${padT + ih} Z`;
    const last = s.values.length - 1;
    return `<path d="${area}" fill="${s.color}" fill-opacity=".10"></path>
      <polyline points="${pts}" fill="none" stroke="${s.color}" stroke-width="2" stroke-linejoin="round" stroke-linecap="round"></polyline>
      <circle cx="${x(last)}" cy="${y(s.values[last] || 0)}" r="4.5" fill="${s.color}" stroke="#fff" stroke-width="2"></circle>`;
  }).join('');
  // one invisible column per point carries the hover
  const hit = labels.map((_, i) => `<rect x="${x(i) - iw / (n * 2 || 2)}" y="${padT}" width="${iw / (n || 1)}" height="${ih}" fill="transparent" data-i="${i}"></rect>`).join('');
  const every = Math.max(1, Math.ceil(labels.length / 7));
  const xl = labels.map((l, i) => (i % every === 0 || i === labels.length - 1) ? `<text x="${x(i)}" y="${H - 6}" text-anchor="middle" class="ov-ax">${esc(l)}</text>` : '').join('');
  const legend = series.length > 1 ? `<div class="ov-legend">${series.map((s) => `<span><i style="background:${s.color}"></i>${esc(s.name)}</span>`).join('')}</div>` : '';
  return `${legend}<div class="ov-chart" id="${id}"><svg viewBox="0 0 ${W} ${H}" role="img">${grid}${paths}${hit}${xl}</svg><div class="ov-tip" hidden></div></div>`;
}
const CHART_COLORS = ['#1540E8', '#eb6834', '#1baf7a'];   // validated pair/triple (dataviz six checks, light surface)

async function overview() {
  const { data, error } = await sb.rpc('admin_overview'); if (error) throw error;
  const o = data.operations, f = data.finance, c = data.crm;
  const tz = view.dataset.tz || 'Asia/Dubai';

  // next sessions, next bookings, what waits in CRM (counts only), the two charts
  let upcoming = [], nextBookings = [], newLeads = 0, review = 0, charts = {};
  const jobs = [sb.rpc('admin_overview_charts', { p_months: 12 })];
  if (has('coach:operations')) jobs.push(
    sb.rpc('sessions_upcoming', { p_limit: 6 }),
    sb.from('contacts').select('id', { count: 'exact', head: true }).eq('status', 'new'),
    sb.from('bookings').select(BOOKING_COLS).in('status', ['confirmed', 'pending_payment', 'hold']).gte('start_at', new Date().toISOString()).order('start_at', { ascending: true }).limit(5));
  const [chR, uR, lR, bR] = await Promise.all(jobs);
  charts = chR.data || {};
  if (uR) { upcoming = uR.data || []; newLeads = lR.count || 0; nextBookings = bR.data || []; }
  // what already happened and nobody closed: the daily gesture, not a list to browse
  let toClose = [];
  if (has('coach:operations')) {
    const { data: tc } = await sb.rpc('sessions_to_close', { p_hours: 72, p_limit: 6 });
    toClose = tc || [];
  }
  if (c) review = c.needs_review || 0;

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
  /* A session that has happened and is still 'scheduled'. Two buttons and one
     line — done, no-show, and what we worked on — without opening anything.
     The note input is always there: the line is worth writing whether or not
     the status changes, and asking for a second click to reveal it is how a
     daily gesture stops being daily. */
  const canNote = has('client_profile:manage');
  const closeCard = (s) => {
    const t = lp(s.start_at);
    return `<div class="ov-close" data-close="${s.id}">
      <div class="ov-close-top"><div class="ov-when">${prettyDay(t.date)} · ${String(t.h).padStart(2,'0')}:${String(t.m).padStart(2,'0')}</div>
        <button class="btn btn-line btn-xs" data-open>Open</button></div>
      <div class="ov-name">${esc(s.client_name || 'Client')}</div>
      <div class="ov-type">${esc(s.title || 'Session')}</div>
      <div class="cg-actions ov-close-acts">
        <button class="btn btn-accent btn-sm" data-done>Done</button>
        <button class="btn btn-line btn-sm" data-noshow>No-show</button>
      </div>
      ${canNote ? `<div class="ov-noteline">
        <input class="ad-input" data-note maxlength="500" placeholder="What did you work on?" value="${esc(s.note || '')}" aria-label="Session note">
        <button class="btn btn-line btn-sm" data-savenote>Save</button></div>` : ''}
    </div>`;
  };

  const kpis = [];
  if (o) kpis.push(['New leads · 7 days', o.new_leads_7d, () => go('crm', 'dashboard')], ["Today's sessions", o.today_sessions, () => go('schedule')], ['Upcoming bookings', o.upcoming_bookings, () => go('schedule', 'sessions')]);
  if (f) kpis.push(['Orders awaiting payment', f.pending_payment_orders, () => go('finance', 'transactions')], ['Unsettled Gari payable', money(f.unsettled_payable), () => go('finance', 'commissions')]);
  if (c) kpis.push(['Contacts', c.total_contacts, () => { view.dataset.cReview = ''; go('crm', 'contacts'); }], ['Flagged for review', c.needs_review, () => { view.dataset.cReview = '1'; go('crm', 'contacts'); }]);

  // one line, one button: the inbox itself is CRM › Dashboard
  const waiting = [];
  if (newLeads) waiting.push(`<b>${newLeads}</b> new lead${newLeads > 1 ? 's' : ''} to handle`);
  if (review) waiting.push(`<b>${review}</b> possible duplicate${review > 1 ? 's' : ''} to review`);
  const crmLine = (has('coach:operations') || has('client_profile:view'))
    ? `<div class="ad-panel ov-crm"><div>${waiting.length ? waiting.join(' · ') : 'Nothing waiting — no new leads, nothing to review.'}</div><button class="btn ${waiting.length ? 'btn-accent' : 'btn-line'} btn-sm" id="ov-crm">Open Clients</button></div>` : '';

  // charts: revenue by month (per currency, the biggest first, at most three) and the pipeline
  const monthLabel = (ym) => new Date(ym + '-01T00:00:00Z').toLocaleDateString('en-GB', { month: 'short', timeZone: 'UTC' });
  let revenueHtml = '', pipelineHtml = '', revSeries = [], pipeSeries = [], revLabels = [], pipeLabels = [];
  if (charts.revenue) {
    revLabels = charts.revenue.map((m) => monthLabel(m.month));
    const totals = {}; charts.revenue.forEach((m) => Object.entries(m.by_currency || {}).forEach(([cur, v]) => { totals[cur] = (totals[cur] || 0) + Number(v); }));
    const curs = Object.keys(totals).sort((a, b) => totals[b] - totals[a]).slice(0, 3);
    revSeries = curs.map((cur, k) => ({ name: cur, color: CHART_COLORS[k], values: charts.revenue.map((m) => Number((m.by_currency || {})[cur] || 0) / 100) }));
    const main = curs[0];
    const revFmt = (v, axis, cur) => main ? (axis ? (v >= 1000 ? (v / 1000).toFixed(v % 1000 ? 1 : 0) + 'k' : String(v)) : money(Math.round(v * 100), cur || main)) : String(v);
    revenueHtml = `<div class="ad-panel ov-chartpanel"><div class="ov-chart-head"><div><div class="ov-lbl">Revenue · 12 months</div><div class="ov-hero">${main ? money(Math.round(totals[main]), main) : '—'}</div></div><button class="btn btn-line btn-xs" id="ov-fin">Finance</button></div>
      ${main ? columnChart({ labels: revLabels, series: revSeries, fmtValue: revFmt, id: 'ov-rev' }) : '<p class="ad-empty">No paid order yet.</p>'}
      ${curs.length > 1 ? `<p class="ad-note">Each currency as collected; the headline is ${esc(main)} only.</p>` : ''}</div>`;
    revSeries._fmt = revFmt;
  }
  if (charts.pipeline) {
    pipeLabels = charts.pipeline.map((m) => monthLabel(m.month));
    pipeSeries = [['enquiries', 'Enquiries'], ['clients', 'New clients'], ['sessions', 'Sessions']].map(([k, name], i) => ({ name, color: CHART_COLORS[i], values: charts.pipeline.map((m) => Number(m[k] || 0)) }));
    const any = pipeSeries.some((s) => s.values.some((v) => v > 0));
    const won = pipeSeries[1].values.reduce((a, b) => a + b, 0);
    pipelineHtml = `<div class="ad-panel ov-chartpanel"><div class="ov-chart-head"><div><div class="ov-lbl">Pipeline · 12 months</div><div class="ov-hero">${won} new client${won === 1 ? '' : 's'}</div></div><button class="btn btn-line btn-xs" id="ov-crm2">Clients</button></div>
      ${any ? columnChart({ labels: pipeLabels, series: pipeSeries, id: 'ov-pipe' }) : '<p class="ad-empty">Nothing yet — the first enquiry starts the curve.</p>'}</div>`;
  }

  const hour = Number(new Intl.DateTimeFormat('en-GB', { hour: 'numeric', hour12: false, timeZone: tz }).format(new Date()));
  const first = ((me && me.display_name) || '').split(' ')[0];
  const hello = `${hour < 12 ? 'Good morning' : hour < 18 ? 'Good afternoon' : 'Good evening'}${first ? ', ' + esc(first) : ''}.`;
  const today = new Intl.DateTimeFormat('en-GB', { weekday: 'long', day: 'numeric', month: 'long', timeZone: tz }).format(new Date());

  view.innerHTML = `
    <div class="ad-head"><div><h1>${hello}</h1><p class="ad-muted">${esc(today)} · ${esc(tz)}</p></div></div>
    ${toClose.length ? `<div class="ov-nextwrap ov-closewrap"><div class="ov-lbl">To close${toClose.length > 1 ? ` · ${toClose.length}` : ''}</div>
      <div class="ov-nextrow">${toClose.map(closeCard).join('')}</div></div>` : ''}
    ${upcoming.length ? `<div class="ov-nextwrap"><div class="ov-lbl">Next session${upcoming.length > 1 ? 's' : ''}</div>
      <div class="ov-nextrow">${upcoming.map(nextCard).join('')}</div></div>` : ''}
    ${has('coach:operations') ? `<div class="ad-panel"><div class="ov-chart-head"><div class="ov-lbl">Upcoming bookings${nextBookings.length ? ` (${nextBookings.length})` : ''}</div><div class="cg-actions"><button class="btn btn-line btn-xs" id="ov-bk">All sessions</button><button class="btn btn-line btn-xs" id="ov-cal">Calendar</button></div></div>
      ${nextBookings.length ? table(['Time', 'Session', 'Client', 'Ref · status', 'Price'], nextBookings.map((b) => bookingRow(b, tz, false)), '') : '<p class="ad-empty">No booking ahead.</p>'}</div>` : ''}
    ${crmLine}
    ${revenueHtml || pipelineHtml ? `<div class="ad-grid2 ov-charts">${revenueHtml}${pipelineHtml}</div>` : ''}
    <div class="ad-kpis">${kpis.map(([l, v], i) => `<button class="ad-kpi${kpis[i][2] ? ' ov-kpi-click' : ''}" data-kpi="${i}"><b>${kpiVal(v)}</b><span>${esc(l)}</span></button>`).join('') || '<p class="ad-empty">Nothing to show yet.</p>'}</div>`;

  // next-session cards
  calData = { sessions: upcoming, blocks: [] };
  view.querySelectorAll('.ov-next').forEach((el) => { const openBtn = el.querySelector('[data-open]'); const go2 = () => openSession(el.dataset.sess); el.onclick = go2; if (openBtn) openBtn.onclick = (e) => { e.stopPropagation(); go2(); }; el.querySelectorAll('a').forEach((a) => a.onclick = (e) => e.stopPropagation()); });
  // to-close cards: done · no-show · one line, each one call, no popup
  view.querySelectorAll('.ov-close').forEach((el) => {
    const id = el.dataset.close;
    const noteEl = el.querySelector('[data-note]');
    const drop = () => {
      const wrap = el.closest('.ov-closewrap'); el.remove();
      if (wrap && !wrap.querySelector('.ov-close')) wrap.remove();
    };
    // the line is worth keeping even when the status changes in the same breath
    const saveNote = async () => {
      const txt = (noteEl && noteEl.value || '').trim();
      if (!txt) return true;
      const { error } = await sb.rpc('session_note_quick', { p_id: id, p_text: txt });
      if (error) { fail(error); return false; }
      return true;
    };
    const mark = async (status, label) => {
      if (!await saveNote()) return;
      const { error } = await sb.rpc('session_set_status', { p_id: id, p_status: status, p_chargeable: false });
      if (error) return fail(error);
      toast(label); drop();
    };
    const openBtn = el.querySelector('[data-open]');
    if (openBtn) openBtn.onclick = () => openSession(id);
    el.querySelector('[data-done]').onclick = () => mark('completed', 'Marked done');
    el.querySelector('[data-noshow]').onclick = () => mark('no_show', 'Marked no-show — open it to charge the session');
    const saveBtn = el.querySelector('[data-savenote]');
    if (saveBtn) saveBtn.onclick = async () => {
      if (!(noteEl.value || '').trim()) return toast('Nothing to save yet');
      if (await saveNote()) toast('Noted');
    };
    if (noteEl) noteEl.onkeydown = (e) => { if (e.key === 'Enter') { e.preventDefault(); if (saveBtn) saveBtn.click(); } };
  });

  const on = (id, fn) => { const el = $('#' + id); if (el) el.onclick = fn; };
  on('ov-crm', () => go('crm', 'dashboard')); on('ov-crm2', () => go('crm', 'dashboard'));
  on('ov-bk', () => go('schedule', 'sessions')); on('ov-cal', () => go('schedule', 'calendar'));
  on('ov-fin', () => go('finance', 'transactions'));
  if (revSeries.length) wireChart('ov-rev', revLabels, revSeries, revSeries._fmt);
  if (pipeSeries.length) wireChart('ov-pipe', pipeLabels, pipeSeries, (v) => String(v));
  // headline numbers jump to their list
  view.querySelectorAll('[data-kpi]').forEach((b) => { const fn = kpis[+b.dataset.kpi][2]; if (fn) b.onclick = fn; });
}

/* =============================== BOOKINGS / CALENDAR =============================== */
function bookingRow(b, tz, withActions = true) {
  const acts = [];
  if (withActions && has('coach:operations')) {
    if (['hold', 'pending_payment', 'confirmed'].includes(b.status)) acts.push(`<button class="btn btn-line btn-xs" data-act="cancelled" data-ref="${b.reference}">Cancel</button>`);
    if (b.status === 'confirmed' && new Date(b.start_at) <= new Date()) acts.push(`<button class="btn btn-dark btn-xs" data-act="completed" data-ref="${b.reference}">Completed</button>`, `<button class="btn btn-line btn-xs" data-act="no_show" data-ref="${b.reference}">No-show</button>`);
    if (b.status === 'hold' && b.price_amount == null) acts.push(`<button class="btn btn-accent btn-xs" data-act="confirmed" data-ref="${b.reference}">Confirm</button>`);
    // Open booking with a known client: jump to that client's Sessions tab to build a priced hours package
    // and issue a pay link. Only where pricing a fresh commercial offer still makes sense — an open hold or a
    // confirmed session. Never for a booking already in payment (pending_payment) or a final one
    // (completed, no_show, cancelled, expired).
    if (b.crm_contact_id && has('client_profile:view') && ['hold', 'confirmed'].includes(b.status))
      acts.push(`<button class="btn btn-line btn-xs" data-pack-crm="${b.crm_contact_id}">Price &amp; package</button>`);
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
    sessionsList().catch(fail);
  });
  // "Price & package": jump to the client's Sessions tab to build a priced hours package and issue a pay link
  view.querySelectorAll('[data-pack-crm]').forEach((btn) => btn.onclick = () => openProfile(btn.dataset.packCrm, null, 'sessions'));
}
/* ============================ CALENDAR ============================ */
/* Gari's operating calendar: Day (default) / Week / Month, reading the
   authoritative calendar_range RPC (sessions + blocks). Times are shown in
   the coach's zone. Tapping a session opens a popup; tapping an empty slot
   offers Add session / Block time, prefilled. iPhone-first. */
const CAL_TZ = 'Asia/Dubai';
const calH0 = 0, calH1 = 24;                   // full day; the timeline scrolls and auto-lands near 07:00 / the first session
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
  if (cal.view !== 'month') requestAnimationFrame(calScrollDefault);
}
function eventsFor(dateStr) {
  const s = calData.sessions.filter((x) => lp(x.start_at).date === dateStr);
  const b = calData.blocks.filter((x) => lp(x.start_at).date === dateStr);
  return { s, b };
}
function posStyle(iso, endIso) {
  const a = lp(iso), b = lp(endIso);
  const top = Math.max(0, (a.mins - calH0 * 60)) / 60;
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
  for (let i = calH0; i < calH1; i++) h += `<div class="cal-hr" data-date="${dateStr}" data-hour="${i}"><span class="cal-hrl">${String(i).padStart(2, '0')}:00</span></div>`;
  return h;
}
function renderTimeline(dateStr) {
  const { s, b } = eventsFor(dateStr);
  return `<div class="cal-day cal-scroll"><div class="cal-grid">
    ${hourRows(dateStr)}
    <div class="cal-layer">${b.map(blockChip).join('')}${s.map(sessionChip).join('')}</div>
  </div></div>`;
}
// scroll the timeline so ~07:00 (or the first session, if earlier) is at the top
function calScrollDefault() {
  const sc = $('#cal-body .cal-scroll') || $('#cal-body .cal-week'); if (!sc) return;
  let h = 7;
  const mins = [...calData.sessions, ...calData.blocks].map((x) => lp(x.start_at).mins).filter((m) => Number.isFinite(m) && m >= 0);
  if (mins.length) h = Math.max(0, Math.min(7, Math.floor(Math.min(...mins) / 60)));
  const row = sc.querySelector(`.cal-hr[data-hour="${h}"]`);
  if (row) { const off = row.getBoundingClientRect().top - sc.getBoundingClientRect().top; sc.scrollTop += off - (sc.classList.contains('cal-week') ? 42 : 8); }
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
  return `<div class="cal-week"><div class="cal-wgutter"><div class="cal-wch">&nbsp;</div>${Array.from({ length: calH1 - calH0 }, (_, i) => `<div class="cal-gh">${String(calH0 + i).padStart(2, '0')}:00</div>`).join('')}</div>${cols}</div>`;
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
    <div class="cg-sheet-b"><div class="cg-acts">
      <button class="cg-act cg-act-go" data-a="sess">${ICO.plus}<span>Add session</span></button>
      <button class="cg-act" data-a="block">${ICO.clock}<span>Block time</span></button></div></div>`;
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
  /* Both are derived — which session this is depends on its neighbours, and what it
     costs depends on the package and the client's rate — so the server answers rather
     than the card computing it from a row that cannot see either. */
  const [pr, sq] = await Promise.all([
    has('finance:view') ? sb.rpc('session_price_json', { p_id: id }) : Promise.resolve({ data: null }),
    sb.rpc('session_seq_json', { p_id: id }),
  ]);
  const price = pr.data, seq = sq.data;
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
          <dt>Type</dt><dd>${esc(s.title || summary.title || 'Session')} · ${online ? 'Online' : 'In person'}</dd>
          ${seqLine(seq) ? `<dt>Session</dt><dd>${seqLine(seq)}</dd>` : ''}
          ${has('finance:view') ? `<dt>Price</dt><dd>${priceLine(price)}</dd>` : ''}</dl></div>
      ${pack ? `<div class="cg-sec"><div class="cg-sec-t">Package</div>
        <div class="cg-pack"><div class="cg-pack-x">${pack.used} / ${pack.total_sessions}</div><div class="cg-pack-r">${pack.remaining} remaining</div></div>
        <dl class="cg-kv">${'price_amount' in pack ? `<dt>Price</dt><dd>${money(pack.price_amount, pack.currency)} ${pay}</dd><dt>Paid</dt><dd>${pack.paid_at ? fmt(pack.paid_at, CAL_TZ, { dateStyle: 'medium' }) : '—'}</dd>` : ''}<dt>Pack</dt><dd>${esc(pack.title || '')}</dd></dl></div>` : ''}
      ${(!online && (s.location_name || s.location_address)) ? `<div class="cg-sec"><div class="cg-sec-t">Location</div>
        <div class="cg-loc"><b>${esc(s.location_name || '')}</b>${s.location_address ? `<div class="ad-muted">${esc(s.location_address)}</div>` : ''}</div>
        <div class="cg-acts cg-acts-thin"><button class="cg-act" data-copyaddr>${ICO.copy}<span>Copy address</span></button>
          <a class="cg-act" href="${ml.gmaps}" target="_blank" rel="noopener">${ICO.map}<span>Google Maps</span></a>
          <a class="cg-act" href="${ml.waze}" target="_blank" rel="noopener">${ICO.nav}<span>Waze</span></a></div></div>` : ''}
      ${(online && s.meeting_url) ? `<div class="cg-sec"><div class="cg-sec-t">Online</div>
        <div class="cg-acts cg-acts-thin"><button class="cg-act" data-copylink>${ICO.copy}<span>Copy link</span></button>
          <a class="cg-act" href="${esc(s.meeting_url)}" target="_blank" rel="noopener">${ICO.link}<span>Open meeting</span></a></div></div>` : ''}
      ${has('client_profile:manage')
        ? `<div class="cg-sec"><div class="cg-sec-t">What we worked on</div>
             <div class="ov-noteline"><input class="ad-input" data-note maxlength="500" placeholder="One line — it goes to the client's history" value="${esc(s.note || '')}" aria-label="Session note">
               <button class="btn btn-line btn-sm" data-savenote>Save</button></div></div>`
        : (s.note ? `<div class="cg-sec"><div class="cg-sec-t">Note</div><p style="margin:0;white-space:pre-wrap">${esc(s.note)}</p></div>` : '')}
      <div class="cg-acts">
        ${s.status !== 'completed' ? `<button class="cg-act cg-act-go" data-complete>${ICO.check}<span>Mark completed</span></button>` : ''}
        ${has('client_profile:view') ? `<button class="cg-act" data-open>${ICO.person}<span>Open client</span></button>` : ''}
        ${ph ? `<a class="cg-act" href="${waHref(ph)}" target="_blank" rel="noopener">${ICO.wa}<span>WhatsApp</span></a>` : ''}
        ${(pack && pack.payment_status && pack.payment_status !== 'paid' && has('finance:manage')) ? `<button class="cg-act" data-collect>${ICO.money}<span>Collect payment</span></button>` : ''}
        ${s.status === 'scheduled' ? `<button class="cg-act" data-noshow>${ICO.noshow}<span>No-show</span></button>` : ''}
        <button class="cg-act" data-pack>${ICO.pack}<span>Package</span></button>
        <button class="cg-act" data-edit>${ICO.edit}<span>Reschedule</span></button>
        ${s.status !== 'cancelled' ? `<button class="cg-act" data-cancel>${ICO.cancel}<span>Cancel</span></button>` : ''}
        ${(!s.booking_id && s.status !== 'completed') ? `<button class="cg-act cg-act-danger" data-del>${ICO.trash}<span>Delete</span></button>` : ''}
      </div>
      ${s.booking_id ? '<p class="ad-muted" style="font-size:12px;margin-top:10px">This session came from a website booking.</p>' : ''}
    </div>`;
  sheet.querySelector('[data-x]').onclick = closeSheet;
  const on = (sel, fn) => { const el = sheet.querySelector(sel); if (el) el.onclick = fn; };
  on('[data-copyaddr]', async () => { try { await navigator.clipboard.writeText(ml.addr); toast('Address copied'); } catch {} });
  on('[data-copylink]', async () => { try { await navigator.clipboard.writeText(s.meeting_url); toast('Link copied'); } catch {} });
  on('[data-open]', () => { closeSheet(); openProfile(s.crm_contact_id, null, 'overview'); });
  // one line, written here, landing in the client's history against this session
  const noteEl = sheet.querySelector('[data-note]');
  on('[data-savenote]', (e) => once(e.currentTarget, async () => {
    const txt = (noteEl.value || '').trim();
    if (!txt) return toast('Nothing to save yet');
    const { error } = await sb.rpc('session_note_quick', { p_id: id, p_text: txt });
    if (error) return fail(error);
    toast('Noted');                     // one session, one note: saving again corrects it
  }));
  if (noteEl) noteEl.onkeydown = (e) => { if (e.key === 'Enter') { e.preventDefault(); const b = sheet.querySelector('[data-savenote]'); if (b) b.click(); } };
  on('[data-complete]', () => sessStatus(id, 'completed'));
  // Session → Collect payment → (Tap to Pay in the PSP app) → paid → pack/ledger updated. Same BEAU PH capability as from the client profile.
  on('[data-collect]', () => { pfPackActions(pack, () => calRender().catch(fail)); pfCollectInPerson(pack, () => calRender().catch(fail)); });
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
      <div class="cg-acts">${b.source === 'calendar_block' ? `<button class="cg-act" data-edit>${ICO.edit}<span>Edit</span></button><button class="cg-act cg-act-danger" data-unblock>${ICO.trash}<span>Unblock</span></button>` : '<span class="ad-muted" style="font-size:12px">Managed under Exceptions.</span>'}</div></div>`;
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
  // when the client is known, offer their packages so a session links in one step
  let packs = [];
  if (cid) { const { data } = await sb.rpc('packs_for_contact', { p_contact_id: cid }); packs = data || []; }
  const packOpts = `<option value="">— No package</option>${packs.map((p) => `<option value="${p.id}" ${editing && prefill.session_pack_id === p.id ? 'selected' : ''}>${esc(p.title)} · ${p.used}/${p.total_sessions}</option>`).join('')}`;
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
      ${cid ? `<label>Package <select name="session_pack_id">${packOpts}</select></label>` : ''}
      ${has('finance:view') ? `<p class="ad-muted" style="font-size:12px;margin:2px 0 0">Priced by the package above, or by the client's rate when there is no package. A session has no price of its own.</p>` : ''}
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
  form.onsubmit = (e) => { e.preventDefault(); return once(form.querySelector('[type=submit]'), async () => {
    const f = new FormData(form);
    const contactId = lockClient ? cid : f.get('crm_contact_id');
    if (!contactId) return toast('Pick a client', true);
    const startISO = zonedToUtc(`${f.get('date')}T${f.get('time')}`, CAL_TZ);
    const endISO = new Date(new Date(startISO).getTime() + Number(f.get('dur')) * 60000).toISOString();
    const p = { start_at: startISO, end_at: endISO, session_timezone: CAL_TZ, delivery_mode: f.get('delivery_mode'),
      service_id: f.get('service_id') || null, title: f.get('title') || null, note: f.get('note') || null,
      location_name: f.get('location_name') || null, location_address: f.get('location_address') || null,
      location_lat: f.get('location_lat') || null, location_lng: f.get('location_lng') || null, meeting_url: f.get('meeting_url') || null };
    if (form.querySelector('[name=session_pack_id]')) p.session_pack_id = f.get('session_pack_id') || null;
    if (editing) p.id = prefill.id; else p.crm_contact_id = contactId;
    const { data, error } = await sb.rpc('session_write', { p }); if (error) return fail(error);
    // the server answers a repeated create with the session that already exists
    toast(data && data.existing ? 'That session was already there' : (editing ? 'Session saved' : 'Session created'));
    closeSheet(); calRender().catch(fail);
  }); };
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
      <!-- The default title no longer names a count. "10-session coaching pack" sat next to a
           Total sessions field that could say anything, so a pack of six was routinely created
           carrying the word ten in its title — and that title is the snapshot the client sees
           on the receipt and the report. A neutral default cannot contradict the field below. -->
      <label>Title <input name="title" value="Training Session package" required></label>
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
  const q = view.dataset.slQ || ''; const status = view.dataset.slStatus || ''; const mode = view.dataset.slMode || ''; const origin = view.dataset.slOrigin || '';
  const tz = view.dataset.tz || 'Asia/Dubai';
  // one list of the time: coaching sessions (a confirmed website booking IS a session), plus the
  // website bookings that have not become one yet — a hold or an unpaid booking — shown on top with their actions
  const [{ data, error }, pR] = await Promise.all([
    sb.rpc('sessions_list', { p: { q: q || null, status: status || null, delivery_mode: mode || null, origin: origin || null } }),
    sb.from('bookings').select(BOOKING_COLS).in('status', ['hold', 'pending_payment']).order('start_at', { ascending: true }).limit(50),
  ]); if (error) throw error;
  const rows = data || [], pending = pR.data || [];
  const opts = ['scheduled', 'completed', 'cancelled', 'no_show'];
  const payChip = (b) => !b ? '—' : `${b.price_amount == null ? 'on request' : esc(money(b.price_amount, b.currency))}<br>${st(b.status)}`;
  view.innerHTML = `
    <div class="ad-head"><div><h1>Sessions</h1><p class="ad-muted">Every session — booked on the site or entered here — with its payment. Click a row to open it.</p></div>
      <div class="ad-filters"><input id="sl-q" placeholder="Client, title or reference…" value="${esc(q)}">
        <select id="sl-origin"><option value="">All origins</option><option value="site" ${origin==='site'?'selected':''}>Booked on the site</option><option value="manual" ${origin==='manual'?'selected':''}>Entered by the coach</option></select>
        <select id="sl-status"><option value="">All statuses</option>${opts.map((o) => `<option value="${o}" ${o === status ? 'selected' : ''}>${o.replace('_',' ')}</option>`).join('')}</select>
        <select id="sl-mode"><option value="">All modes</option><option value="in_person" ${mode==='in_person'?'selected':''}>In person</option><option value="online" ${mode==='online'?'selected':''}>Online</option></select></div></div>
    ${pending.length ? `<div class="ad-panel"><div class="ov-lbl">Site bookings not confirmed yet (${pending.length})</div><p class="ad-muted" style="font-size:13px;margin:0 0 8px">A hold or an unpaid booking. It becomes a session once confirmed.</p>
      ${table(['Time', 'Session', 'Client', 'Ref · status', 'Price', ''], pending.map((b) => bookingRow(b, tz)), '')}</div>` : ''}
    <div class="ad-panel">${table(['Date', 'Time', '#', 'Client', '<span class="col-wide">Type</span>', '<span class="col-wide">Origin</span>', '<span class="col-wide">Package</span>', ...(has('finance:view') ? ['Price'] : []), '<span class="col-wide">Payment</span>', 'Status'], rows.map((s) => {
      const t = lp(s.start_at), e = lp(s.end_at); const b = s.booking;
      return `<tr class="clik" data-sess="${s.id}"><td>${prettyDay(t.date)}</td><td>${String(t.h).padStart(2,'0')}:${String(t.m).padStart(2,'0')}–${String(e.h).padStart(2,'0')}:${String(e.m).padStart(2,'0')}</td>
        <td class="ad-muted" style="font-size:12.5px">${seqLine(s.seq) || '—'}</td>
        <td><b>${esc(s.client_name || '—')}</b></td><td class="col-wide">${esc(s.title || '—')} · ${s.delivery_mode === 'online' ? 'online' : 'in person'}</td>
        <td class="col-wide">${b ? `Site<br><span class="ad-muted" style="font-size:12px">${esc(b.reference)}</span>` : '<span class="ad-muted">Coach</span>'}</td>
        <td class="col-wide">${s.pack ? `${s.pack.used}/${s.pack.total_sessions}` : '—'}</td>
        ${has('finance:view') ? `<td style="font-size:12.5px">${priceLine(s.price)}</td>` : ''}
        <td class="col-wide">${payChip(b)}</td><td>${st(s.status)}</td></tr>`;
    }), 'No sessions match.')}</div>`;
  $('#sl-q').onchange = (e) => { view.dataset.slQ = e.target.value.trim(); sessionsList().catch(fail); };
  $('#sl-origin').onchange = (e) => { view.dataset.slOrigin = e.target.value; sessionsList().catch(fail); };
  $('#sl-status').onchange = (e) => { view.dataset.slStatus = e.target.value; sessionsList().catch(fail); };
  $('#sl-mode').onchange = (e) => { view.dataset.slMode = e.target.value; sessionsList().catch(fail); };
  view.querySelectorAll('tr.clik').forEach((tr) => tr.onclick = async () => { await calPreloadFor(tr.dataset.sess); openSession(tr.dataset.sess); });
  bindBookingActions();
}
// the Sessions list isn't a calendar range, so seed calData so openSession's summary lookups work
async function calPreloadFor(id) { if (!calData.sessions.find((x) => x.id === id)) calData.sessions = []; }

/* =============================== AVAILABILITY RULES =============================== */
// Days off, Outlook-style: a grid of the next weeks; one click blocks a whole day (a closed
// exception 00:00–24:00 in Asia/Dubai), one click on a blocked day frees it again. Only the
// days this grid created ("Day off") are toggled back; a hand-written exception stays.
const DAYOFF_TZ = 'Asia/Dubai', DAYOFF_WEEKS = 8, DAYOFF_REASON = 'Day off';
function dayOffGrid(exceptions) {
  const today = tzParts(new Date(), DAYOFF_TZ); const t0 = new Date(`${today.year}-${today.month}-${today.day}T12:00:00Z`);
  const monday = new Date(t0.getTime() - ((t0.getUTCDay() + 6) % 7) * 864e5);
  const dayKey = (d) => d.toISOString().slice(0, 10);
  const nextKey = (key) => dayKey(new Date(Date.parse(key + 'T12:00:00Z') + 864e5));
  const coversDay = (e, key) => e.kind === 'closed' && e.active && e.start_at <= zonedToUtc(key + 'T00:00', DAYOFF_TZ) && e.end_at >= zonedToUtc(nextKey(key) + 'T00:00', DAYOFF_TZ);
  const cells = [];
  for (let i = 0; i < DAYOFF_WEEKS * 7; i++) {
    const d = new Date(monday.getTime() + i * 864e5); const key = dayKey(d);
    const ex = exceptions.find((e) => coversDay(e, key));
    const past = key < `${today.year}-${today.month}-${today.day}`;
    const mine = ex && (ex.reason || '').startsWith(DAYOFF_REASON);
    cells.push(`<button type="button" class="doff${ex ? ' off' : ''}${past ? ' past' : ''}${key === `${today.year}-${today.month}-${today.day}` ? ' today' : ''}" data-day="${key}" ${ex ? `data-ex="${ex.id}" data-mine="${mine ? 1 : 0}"` : ''} ${past ? 'disabled' : ''} title="${ex ? esc(ex.reason || 'blocked') : 'Block this day'}">
      ${d.getUTCDate() === 1 || i === 0 ? `<i>${MONTHS[d.getUTCMonth()].slice(0, 3)}</i>` : ''}<b>${d.getUTCDate()}</b></button>`);
  }
  return `<div class="doff-head">${DOW_SHORT.map((x) => `<span>${x}</span>`).join('')}</div><div class="doff-grid">${cells.join('')}</div>`;
}
async function availability(root = view) {
  const from = new Date(Date.now() - 8 * 864e5).toISOString();
  const [{ data, error }, exR] = await Promise.all([
    sb.from('availability_rules').select('id,weekday,start_time,end_time,timezone,service_ids,valid_from,valid_to,active,notes,created_at').order('weekday').order('start_time'),
    sb.from('availability_exceptions').select('id,kind,start_at,end_at,timezone,reason,active').eq('kind', 'closed').gte('end_at', from).order('start_at'),
  ]); if (error) throw error;
  const editing = view.dataset.editRule ? data.find((r) => r.id === view.dataset.editRule) : null;
  root.innerHTML = `
    <div class="ad-panel"><div class="ov-chart-head"><div><h2 style="margin:0">Days off</h2><p class="ad-muted" style="font-size:13px;margin:2px 0 0">Click a day to block it entirely (${DAYOFF_TZ}); click again to free it. Part of a day, or extra hours → an exception, further down.</p></div></div>
      ${dayOffGrid(exR.data || [])}</div>
    <div class="ad-grid2">
      <div class="ad-panel"><h2>Weekly hours</h2><p class="ad-muted" style="font-size:13px;margin:-6px 0 10px">What the booking engine offers; slots follow each service's duration.</p>${table(['Day', 'Hours', 'Zone', 'Services', 'Valid', 'Active', ''], data.map((r) => `<tr>
        <td><b>${WEEKDAYS[r.weekday]}</b></td><td>${esc(r.start_time.slice(0, 5))}–${esc(r.end_time.slice(0, 5))}</td><td>${esc(r.timezone)}</td>
        <td>${r.service_ids?.length ? r.service_ids.map(svcTitle).map(esc).join('<br>') : 'all'}</td>
        <td>${r.valid_from || r.valid_to ? `${r.valid_from || '…'} → ${r.valid_to || '…'}` : 'always'}</td>
        <td>${r.active ? st('open') : st('closed')}</td>
        <td class="acts"><button class="btn btn-line btn-xs" data-edit="${r.id}">Edit</button><button class="btn btn-line btn-xs" data-toggle="${r.id}" data-to="${!r.active}">${r.active ? 'Disable' : 'Enable'}</button><button class="btn btn-line btn-xs" data-del="${r.id}">Delete</button></td></tr>`), 'No weekly hours yet — add your first rule.')}
        ${data.some((r) => (r.notes || '').toLowerCase().includes('placeholder')) ? '<p class="ad-note">Rows marked "placeholder" were seeded by the developers. Replace them with your real hours.</p>' : ''}</div>
      <div class="ad-panel"><h2>${editing ? 'Edit rule' : 'Add weekly hours'}</h2>
        ${!editing ? '<p class="ad-note" style="margin:0 0 12px">Gari works around the clock: <button class="btn btn-line btn-xs" type="button" id="rule-247">Set 24/7</button> replaces every rule with 00:00–24:00, seven days, Asia/Dubai. Block time off with an exception.</p>' : ''}
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
  root.querySelectorAll('[data-edit]').forEach((b) => b.onclick = () => { view.dataset.editRule = b.dataset.edit; availability(root).catch(fail); });
  root.querySelectorAll('.doff:not([disabled])').forEach((b) => b.onclick = async () => {
    const day = b.dataset.day;
    if (b.dataset.ex) {
      if (b.dataset.mine !== '1') return toast('This day is blocked by a hand-written exception — edit it in the exceptions below', true);
      const { error: e1 } = await sb.from('availability_exceptions').delete().eq('id', b.dataset.ex); if (e1) return fail(e1);
      toast(`${prettyDay(day)} is open again`);
    } else {
      const { error: e1 } = await sb.from('availability_exceptions').insert({ kind: 'closed', timezone: DAYOFF_TZ, start_at: zonedToUtc(day + 'T00:00', DAYOFF_TZ), end_at: zonedToUtc(new Date(Date.parse(day + 'T12:00:00Z') + 864e5).toISOString().slice(0, 10) + 'T00:00', DAYOFF_TZ), reason: DAYOFF_REASON, service_ids: null, active: true }); if (e1) return fail(e1);
      toast(`${prettyDay(day)} blocked`);
    }
    availability(root).catch(fail);
  });
  const b247 = root.querySelector('#rule-247'); if (b247) b247.onclick = async () => {
    if (!(await confirmAct('Replace every weekly rule with 00:00–24:00, seven days (Asia/Dubai)? Exceptions and bookings are untouched.'))) return;
    const { error: e1 } = await sb.from('availability_rules').delete().not('id', 'is', null); if (e1) return fail(e1);
    const rows = [1, 2, 3, 4, 5, 6, 7].map((w) => ({ weekday: w, start_time: '00:00', end_time: '24:00', timezone: 'Asia/Dubai', service_ids: null, notes: 'Around the clock — set from the back-office' }));
    const { error: e2 } = await sb.from('availability_rules').insert(rows); if (e2) return fail(e2);
    toast('Available 24/7'); availability(root).catch(fail);
  };
  root.querySelector('[data-cancel-edit]')?.addEventListener('click', () => { delete view.dataset.editRule; availability(root).catch(fail); });
  root.querySelectorAll('[data-toggle]').forEach((b) => b.onclick = async () => { const { error } = await sb.from('availability_rules').update({ active: b.dataset.to === 'true' }).eq('id', b.dataset.toggle); if (error) return fail(error); toast('Saved'); availability(root).catch(fail); });
  root.querySelectorAll('[data-del]').forEach((b) => b.onclick = async () => { if (!(await confirmAct('Delete this rule? Existing bookings are not affected.'))) return; const { error } = await sb.from('availability_rules').delete().eq('id', b.dataset.del); if (error) return fail(error); toast('Deleted'); availability(root).catch(fail); });
  root.querySelector('#rule-form').onsubmit = async (e) => {
    e.preventDefault(); const f = new FormData(e.target);
    const ids = f.getAll('service_ids');
    const row = { weekday: +f.get('weekday'), start_time: f.get('start_time'), end_time: f.get('end_time'), timezone: f.get('timezone'), valid_from: f.get('valid_from') || null, valid_to: f.get('valid_to') || null, service_ids: ids.length ? ids : null, notes: f.get('notes') || null };
    if (row.end_time <= row.start_time) return toast('End must be after start', true);
    const { error } = editing ? await sb.from('availability_rules').update(row).eq('id', editing.id) : await sb.from('availability_rules').insert(row);
    if (error) return fail(error); toast('Saved'); delete view.dataset.editRule; availability(root).catch(fail);
  };
}

/* =============================== EXCEPTIONS =============================== */
async function exceptions(root = view) {
  const [{ data, error }, { data: stops }] = await Promise.all([
    sb.from('availability_exceptions').select('id,kind,start_at,end_at,timezone,reason,service_ids,tour_stop_id,active,tour_stops(city,slug)').gte('end_at', new Date(Date.now() - 7 * 864e5).toISOString()).order('start_at'),
    sb.from('tour_stops').select('id,slug,city,status').order('start_at'),
  ]); if (error) throw error;
  const editing = view.dataset.editExc ? data.find((r) => r.id === view.dataset.editExc) : null;
  const tz = editing?.timezone || 'Asia/Dubai';
  root.innerHTML = `
    <div class="ad-grid2">
      <div class="ad-panel"><h2>Exceptions</h2><p class="ad-muted" style="font-size:13px;margin:-6px 0 10px"><b>Closed</b> blocks time (part of a day, travel). <b>Open</b> adds bookable time outside the weekly hours — link it to a tour stop to make it a tour window.</p>${table(['Kind', 'From', 'To', 'Zone', 'Reason', 'Tour stop', ''], data.map((r) => `<tr>
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
  root.querySelectorAll('[data-edit]').forEach((b) => b.onclick = () => { view.dataset.editExc = b.dataset.edit; exceptions(root).catch(fail); });
  root.querySelector('[data-cancel-edit]')?.addEventListener('click', () => { delete view.dataset.editExc; exceptions(root).catch(fail); });
  root.querySelectorAll('[data-del]').forEach((b) => b.onclick = async () => { if (!(await confirmAct('Delete this exception?'))) return; const { error } = await sb.from('availability_exceptions').delete().eq('id', b.dataset.del); if (error) return fail(error); toast('Deleted'); exceptions(root).catch(fail); });
  root.querySelector('#exc-form').onsubmit = async (e) => {
    e.preventDefault(); const f = new FormData(e.target); const z = f.get('timezone'); const ids = f.getAll('service_ids');
    const row = { kind: f.get('kind'), timezone: z, start_at: zonedToUtc(f.get('start'), z), end_at: zonedToUtc(f.get('end'), z), reason: f.get('reason') || null, tour_stop_id: f.get('kind') === 'open' ? (f.get('tour_stop_id') || null) : null, service_ids: ids.length ? ids : null, active: true };
    if (row.end_at <= row.start_at) return toast('End must be after start', true);
    const { error } = editing ? await sb.from('availability_exceptions').update(row).eq('id', editing.id) : await sb.from('availability_exceptions').insert(row);
    if (error) return fail(error); toast('Saved'); delete view.dataset.editExc; exceptions(root).catch(fail);
  };
}

/* =============================== HOURS (days off · weekly hours · exceptions) =============================== */
async function hours() {
  view.innerHTML = `
    <div class="ad-head"><div><h1>Hours</h1><p class="ad-muted">When Gari can be booked: block whole days in one click, set the weekly hours, add exceptions for the rest.</p></div></div>
    <div id="hours-av"></div><div id="hours-ex"></div>`;
  await Promise.all([availability($('#hours-av')), exceptions($('#hours-ex'))]);
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
      <p class="ad-note">A bookable service with a price is charged exactly this amount at Checkout. Prices of enquiry-only products are shown on the website only when SHOW_PUBLIC_ENQUIRY_PRICES is true in config.js.</p></div>` : ''}
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

/* Finance and the BEAU PH workspace live in /admin/finance.js (Transactions, Payment methods, Rails, FX). */

/* =============================== ANALYTICS =============================== */
/* =============================== ANALYTICS — audience =============================== */
// One screen for the audience: the website (Plausible, synced daily) and the social
// platforms (YouTube synced; Instagram / TikTok by CSV export or by hand), then the
// funnel from a visit to a client. Numbers only — no name, no message, ever.
const PLATFORMS = { instagram: 'Instagram', tiktok: 'TikTok', youtube: 'YouTube', facebook: 'Facebook', linkedin: 'LinkedIn', x: 'X', other: 'Other' };
const compact = (n) => { const v = Number(n || 0); return v >= 1e6 ? (v / 1e6).toFixed(v % 1e6 ? 1 : 0) + 'M' : v >= 1e3 ? (v / 1e3).toFixed(v % 1e3 ? 1 : 0) + 'k' : String(v); };
const delta = (now, before) => {
  if (before == null || !before) return '';
  const d = Number(now || 0) - Number(before); if (!d) return '<span class="an-d">=</span>';
  const pct = Math.round((d / before) * 100);
  return `<span class="an-d ${d > 0 ? 'up' : 'down'}">${d > 0 ? '▲' : '▼'} ${compact(Math.abs(d))}${Number.isFinite(pct) ? ` · ${Math.abs(pct)}%` : ''}</span>`;
};

/* Seconds as m:ss. The site is one page, so how long a visit lasts is the
   engagement number — bounce rate cannot be one here: Plausible counts a bounce
   as a session with a single pageview, and a single pageview is all this site
   can produce however well it works. */
const mmss = (sec) => {
  const n = Number(sec);
  if (!Number.isFinite(n) || n <= 0) return '—';
  return n < 60 ? `${Math.round(n)}s` : `${Math.floor(n / 60)}m ${String(Math.round(n % 60)).padStart(2, '0')}s`;
};

async function analytics() {
  const days = +(view.dataset.anDays || 30);
  const { data: a, error } = await sb.rpc('audience_overview', { p_days: days }); if (error) throw error;
  const web = a.web || {}, social = a.social || {}, f = a.funnel || {}, cfg = a.config || {};
  const canManage = !!a.can_manage;
  const series = web.series || [];
  /* A daily line is unreadable over a year and a monthly one is useless over a
     week, so the grouping is the reader's choice, not ours. Grouping happens
     here, on rows we already have — no second request, and the totals stay the
     same whichever grain is picked. */
  const grain = view.dataset.anGrain || 'day';
  const startOf = (iso) => {
    const d = new Date(iso + 'T12:00:00Z');
    if (grain === 'week') { const wd = (d.getUTCDay() + 6) % 7; d.setUTCDate(d.getUTCDate() - wd); }        // ISO weeks start on Monday
    else if (grain === 'month') d.setUTCDate(1);
    return d.toISOString().slice(0, 10);
  };
  const buckets = new Map();
  for (const d of series) {
    const k = startOf(d.day);
    const b = buckets.get(k) || { day: k, visitors: 0, pageviews: 0, visits: 0 };
    b.visitors += Number(d.visitors || 0); b.pageviews += Number(d.pageviews || 0); b.visits += Number(d.visits || 0);
    buckets.set(k, b);
  }
  const grouped = [...buckets.values()].sort((x, y) => x.day.localeCompare(y.day));
  const bucketLabel = (iso) => {
    const x = new Date(iso + 'T12:00:00Z');
    if (grain === 'month') return `${MONTHS[x.getUTCMonth()].slice(0, 3)} ${String(x.getUTCFullYear()).slice(2)}`;
    return `${grain === 'week' ? 'w/c ' : ''}${x.getUTCDate()} ${MONTHS[x.getUTCMonth()].slice(0, 3)}`;
  };
  const labels = grouped.map((d) => bucketLabel(d.day));
  const visitors = { name: 'Visitors', color: CHART_COLORS[0], values: grouped.map((d) => d.visitors) };
  const views = { name: 'Pageviews', color: CHART_COLORS[1], values: grouped.map((d) => d.pageviews) };
  const asTable = view.dataset.anView === 'table';
  const igDays = cfg.instagram_expires_at ? Math.max(0, Math.ceil((new Date(cfg.instagram_expires_at) - new Date()) / 86400000)) : null;

  // followers across platforms, most recent snapshot first
  const cards = Object.entries(social).map(([k, v]) => {
    const l = v.latest || {};
    return `<div class="an-card">
      <div class="an-plat">${esc(PLATFORMS[k] || k)}${l.source ? `<span class="an-src">${esc(l.source)}</span>` : ''}</div>
      <b>${l.followers != null ? compact(l.followers) : '—'}</b><span>followers ${delta(l.followers, v.followers_before)}</span>
      <div class="an-sub">${l.views != null ? compact(l.views) + ' views' : ''}${l.posts != null ? ` · ${compact(l.posts)} posts` : ''}</div>
      <div class="an-sub">${l.date ? 'as of ' + prettyDay(l.date) : 'no snapshot yet'}</div>
    </div>`;
  }).join('');

  const followerSeries = Object.entries(social).filter(([, v]) => (v.series || []).some((p) => p.followers != null))
    .slice(0, 3).map(([k, v], i) => ({ name: PLATFORMS[k] || k, color: CHART_COLORS[i], key: k, points: v.series.filter((p) => p.followers != null) }));
  const fLabels = [...new Set(followerSeries.flatMap((s) => s.points.map((p) => p.date)))].sort();
  const fSeries = followerSeries.map((s) => ({ name: s.name, color: s.color, values: fLabels.map((d) => { const p = s.points.filter((q) => q.date <= d).pop(); return p ? p.followers : 0; }) }));

  const funnelRows = [['Website visitors', f.visitors, () => {}], ['Enquiries', f.enquiries, () => go('crm', 'leads')],
    ['Collaboration requests', f.collab_requests, () => go('collab')], ['Bookings', f.bookings, () => go('schedule', 'sessions')],
    ['New clients', f.clients, () => { view.dataset.cStatus = 'active'; go('crm', 'contacts'); }]];
  const fMax = Math.max(1, ...funnelRows.map(([, v]) => Number(v || 0)));

  const srcRows = (web.sources || []).map((r) => `<tr><td>${esc(r.source || 'Direct')}</td><td class="num">${compact(r.visitors)}</td></tr>`);
  const goalRows = (web.goals || []).map((r) => `<tr><td>${esc(r.goal)}</td><td class="num">${compact(r.visitors)}</td><td class="num">${compact(r.events)}</td></tr>`);
  /* Where people are is the commercial question — what to price in what
     currency, which rails to open. Country only: the city would narrow a
     visitor further without changing a single decision. */
  const ctryList = (web.countries || []).filter((r) => r && r.visitors);
  const ctryTotal = ctryList.reduce((t, r) => t + Number(r.visitors || 0), 0) || 1;
  const ctryRows = ctryList.slice(0, 12).map((r) => `<tr><td>${esc(regionName(r.country))}</td><td class="num">${compact(r.visitors)}</td><td class="num">${Math.round((Number(r.visitors) / ctryTotal) * 100)}%</td></tr>`);

  view.innerHTML = `
    <div class="ad-head"><div><h1>Audience</h1><p class="ad-muted">The website and the social platforms, side by side. Aggregates only — no names, no messages.</p></div>
      <div class="ad-filters">
        <select id="an-days">${[7, 30, 90, 365].map((d) => `<option value="${d}" ${d === days ? 'selected' : ''}>Last ${d} days</option>`).join('')}</select>
        ${canManage ? '<button class="btn btn-line btn-sm" id="an-sync">Sync now</button><button class="btn btn-accent btn-sm" id="an-add">Add numbers</button>' : ''}
      </div></div>

    ${cfg.last_sync_error ? `<p class="ad-note" style="color:#b3261e;margin:0 0 12px">Last sync: ${esc(cfg.last_sync_error)}</p>` : ''}

    <div class="ad-kpis">
      <div class="ad-kpi"><b>${compact(web.visitors)}</b><span>Website visitors</span><span class="an-sub">${web.has_previous ? (delta(web.visitors, web.visitors_prev) || `vs ${compact(web.visitors_prev)} before`) : 'no period to compare yet'}</span></div>
      <div class="ad-kpi"><b>${compact(web.pageviews)}</b><span>Pageviews</span></div>
      <div class="ad-kpi" title="How long a visit lasts on average. On a one-page site this is the engagement figure: someone who reads the offers and the prices stays; someone who bounces off the header does not."><b>${mmss(web.visit_duration)}</b><span>Time on page</span><span class="an-sub">average visit</span></div>
      <div class="ad-kpi"><b>${compact(Object.values(social).reduce((t, v) => t + Number(v.latest?.followers || 0), 0))}</b><span>Followers, all platforms</span></div>
      <div class="ad-kpi"><b>${f.enquiries ?? 0}</b><span>Enquiries in the period</span></div>
    </div>

    ${cards ? `<div class="an-cards">${cards}</div>` : ''}

    <div class="ad-grid2 ov-charts">
      <div class="ad-panel ov-chartpanel"><div class="ov-chart-head"><div><div class="ov-lbl">Website · ${days} days</div>
        <div class="ov-hero">${compact(web.visitors)} visitors</div></div>
        <div class="ad-filters" style="margin:0;gap:6px">
          <select id="an-days2">${[7, 30, 90, 365].map((d) => `<option value="${d}" ${d === days ? 'selected' : ''}>Last ${d} days</option>`).join('')}</select>
          <select id="an-grain">${[['day', 'By day'], ['week', 'By week'], ['month', 'By month']].map(([k, l]) => `<option value="${k}" ${grain === k ? 'selected' : ''}>${l}</option>`).join('')}</select>
          <button class="btn btn-line btn-xs" id="an-view">${asTable ? 'Chart' : 'Table'}</button>
        </div></div>
        ${!grouped.length ? `<p class="ad-empty">${cfg.web_start_date && cfg.web_start_date > new Date().toISOString().slice(0, 10)
            ? 'Counting starts on ' + prettyDay(cfg.web_start_date) + '. Nothing is counted before then.'
            : 'No website numbers yet — use Sync now.'}</p>`
          : asTable ? table([grain === 'month' ? 'Month' : grain === 'week' ? 'Week of' : 'Day', 'Visitors', 'Pageviews', 'Visits'],
              grouped.slice().reverse().map((d) => `<tr><td>${esc(bucketLabel(d.day))}</td><td class="num">${compact(d.visitors)}</td><td class="num">${compact(d.pageviews)}</td><td class="num">${compact(d.visits)}</td></tr>`))
          : lineChart({ labels, series: [visitors, views], id: 'an-web' })}
        <p class="ad-note" style="margin-top:8px">${cfg.web_synced_at ? 'Synced ' + fmt(cfg.web_synced_at, 'Asia/Dubai', { dateStyle: 'medium', timeStyle: 'short' }) : 'Not synced yet'}${(cfg.web_exclude_paths || []).length ? ` · ${(cfg.web_exclude_paths || []).join(', ')} not counted` : ''}</p></div>

      <div class="ad-panel"><h2 style="margin-top:0">Which countries</h2>
        ${ctryRows.length ? table(['Country', 'Visitors', 'Share'], ctryRows)
          : '<p class="ad-empty">Synced with the website numbers.</p>'}
        <p class="ad-note">Country only — never a city, never an address. This is the list to read before deciding what to price in which currency and which payment rails are worth opening.</p></div>
    </div>

    <div class="ad-panel ov-chartpanel"><div class="ov-chart-head"><div><div class="ov-lbl">Followers · ${days} days</div>
      <div class="ov-hero">${fSeries.length ? compact(fSeries.reduce((t, s) => t + (s.values[s.values.length - 1] || 0), 0)) : '—'}</div></div></div>
      ${fSeries.length ? lineChart({ labels: fLabels.map((d) => { const x = new Date(d + 'T12:00:00Z'); return `${x.getUTCDate()} ${MONTHS[x.getUTCMonth()].slice(0, 3)}`; }), series: fSeries, id: 'an-fol' })
        : '<p class="ad-empty">Two snapshots of a platform draw the curve. Add numbers, or import an export.</p>'}</div>

    <div class="ad-grid2">
      <div class="ad-panel"><h2>From a visit to a client · ${days} days</h2>
        ${funnelRows.map(([label, v, fn], i) => {
          const prev = i ? Number(funnelRows[i - 1][1] || 0) : 0;
          const rate = i && prev ? `${((Number(v || 0) / prev) * 100).toFixed(Number(v) / prev < 0.1 ? 1 : 0)}%` : '';
          return `<div class="an-fun${fn ? ' clik' : ''}" data-fun="${i}">
          <div class="an-fun-bar" style="width:${Math.max(3, Math.round((Number(v || 0) / fMax) * 100))}%"></div>
          <span>${esc(label)}</span>${rate ? `<i class="an-rate">${rate} of the step above</i>` : ''}<b>${compact(v)}</b></div>`;
        }).join('')}
        <p class="ad-note">Bars are to scale, so the drop from a visit to an enquiry is the one you see. Each step is counted in the period, never followed person by person — a visitor and an enquiry are never linked.</p></div>

      <div class="ad-panel"><h2>Where the visits come from</h2>
        ${srcRows.length ? table(['Source', 'Visitors'], srcRows) : '<p class="ad-empty">Synced with the website numbers.</p>'}
        ${goalRows.length ? `<h2 style="margin-top:18px">Goals</h2>${table(['Goal', 'Visitors', 'Events'], goalRows)}` : ''}</div>
    </div>


    <div class="ad-panel"><div class="ov-chart-head"><h2 style="margin:0">Snapshots</h2>
      ${canManage ? '<button class="btn btn-line btn-xs" id="an-import">Import a CSV export</button>' : ''}</div>
      ${table(['Date', 'Platform', 'Followers', 'Views', 'Likes', 'Source', ''], (a.recent || []).map((r) => `<tr>
        <td>${prettyDay(r.date)}</td><td><b>${esc(PLATFORMS[r.platform] || r.platform)}</b></td>
        <td class="num">${r.followers != null ? compact(r.followers) : '—'}</td><td class="num">${r.views != null ? compact(r.views) : '—'}</td>
        <td class="num">${r.likes != null ? compact(r.likes) : '—'}</td><td>${st(r.source)}</td>
        <td class="acts">${canManage ? `<button class="btn btn-line btn-xs" data-an-del="${r.id}">Delete</button>` : ''}</td></tr>`),
        'No snapshot yet — add the numbers of a platform, or import an export.')}</div>

    ${canManage ? `<div class="ad-panel"><h2>Handles and channel</h2>
      <form id="an-cfg" class="ad-form">
        <div class="row"><label>Plausible site <input name="plausible_site_id" value="${esc(cfg.plausible_site_id || '')}"></label>
          <label>YouTube channel (ID or @handle) <input name="youtube_channel_id" value="${esc(cfg.youtube_channel_id || '')}" placeholder="@coachgari28"></label></div>
        <div class="row"><label>Instagram handle <input name="instagram_handle" value="${esc(cfg.instagram_handle || '')}" placeholder="@coachgari28"></label>
          <label>TikTok handle <input name="tiktok_handle" value="${esc(cfg.tiktok_handle || '')}" placeholder="@coachgari28"></label></div>
        <div class="actions"><button class="btn btn-accent btn-sm" type="submit">Save</button></div>
      </form>

      <p class="ad-note">YouTube syncs on its own once a day from the public counters — an identifier or a @handle is all it needs. Above a thousand, Google rounds the subscriber count to three significant figures; the exact number exists only in YouTube Studio. TikTok stays manual: its API requires an app published in both stores, which this project does not have and should not build for a follower count — export the numbers from the app and import the file. ${cfg.youtube_synced_at ? 'YouTube synced ' + fmt(cfg.youtube_synced_at, 'Asia/Dubai', { dateStyle: 'medium' }) + '.' : ''}</p>

      <h2 style="margin-top:20px">Instagram</h2>
      ${cfg.instagram_user_id ? `<p class="ad-note" style="margin-bottom:10px">Connected${cfg.instagram_username ? ' as <b>' + esc(cfg.instagram_username) + '</b>' : ''}${igDays != null ? ` · the connection renews itself, ${igDays} day${igDays === 1 ? '' : 's'} of margin left` : ''}${cfg.instagram_synced_at ? ' · synced ' + fmt(cfg.instagram_synced_at, 'Asia/Dubai', { dateStyle: 'medium' }) : ''}.
          ${igDays != null && igDays < 14 ? '<b style="color:#b3261e">Renew it by hand soon: past the expiry date Meta cannot revive it and the account must be connected again.</b>' : ''}</p>
        ${cfg.instagram_error ? `<p class="ad-note" style="color:#b3261e">Last Instagram sync: ${esc(cfg.instagram_error)}</p>` : ''}
        <button class="btn btn-line btn-sm" id="ig-off">Disconnect Instagram</button>`
      : `<form id="ig-on" class="ad-form">
          <div class="row"><label>Instagram user id <input name="user_id" inputmode="numeric" placeholder="17841400000000000" required></label>
            <label>Username <input name="username" placeholder="@coach_gari28"></label></div>
          <label>Long-lived access token <input name="token" type="password" autocomplete="off" required placeholder="IGQ…"></label>
          <div class="actions"><button class="btn btn-accent btn-sm" type="submit">Connect</button></div>
        </form>
        <p class="ad-note">Instagram only reads a <b>professional</b> account (Business or Creator), and only with a token its owner issued — there is no key-only path as there is for YouTube. A Facebook Page is no longer needed. The token is stored encrypted, never shown again, and renews itself every month; only followers and post count are read, never a follower list or a message.</p>`}</div>` : ''}`;

  const setDays = (e) => { view.dataset.anDays = e.target.value; analytics().catch(fail); };
  $('#an-days').onchange = setDays;
  const d2 = $('#an-days2'); if (d2) d2.onchange = setDays;
  const gr = $('#an-grain'); if (gr) gr.onchange = (e) => { view.dataset.anGrain = e.target.value; analytics().catch(fail); };
  const vw = $('#an-view'); if (vw) vw.onclick = () => { view.dataset.anView = asTable ? 'chart' : 'table'; analytics().catch(fail); };
  if (grouped.length && !asTable) wireChart('an-web', labels, [visitors, views], (v) => compact(v));
  if (fSeries.length) wireChart('an-fol', fLabels.map((d) => prettyDay(d)), fSeries, (v) => compact(v));
  view.querySelectorAll('[data-fun]').forEach((el) => { const fn = funnelRows[+el.dataset.fun][2]; if (fn) el.onclick = fn; });

  const on = (id, fn) => { const el = $('#' + id); if (el) el.onclick = fn; };
  on('an-sync', async () => {
    const { data: r, error: e1 } = await sb.rpc('analytics_sync_now'); if (e1) return fail(e1);
    toast(r && r.ok ? 'Sync asked — reload in a moment' : 'Sync is not configured yet', !(r && r.ok));
  });
  on('an-add', () => openSnapshotEditor());
  on('an-import', () => openSnapshotImport());
  view.querySelectorAll('[data-an-del]').forEach((b) => b.onclick = async () => {
    if (!(await confirmAct('Delete this snapshot?'))) return;
    const { error: e1 } = await sb.rpc('audience_snapshot_delete', { p_id: b.dataset.anDel }); if (e1) return fail(e1);
    toast('Deleted'); analytics().catch(fail);
  });
  const igOn = $('#ig-on'); if (igOn) igOn.onsubmit = async (e) => {
    e.preventDefault(); const d = new FormData(igOn);
    const { error: e1 } = await sb.rpc('instagram_connect', {
      p_token: String(d.get('token') || '').trim(), p_user_id: String(d.get('user_id') || '').trim(),
      p_username: String(d.get('username') || '').trim() || null });
    /* The field is cleared whatever happened. A long-lived token sitting in a
       form on a shared screen is the one thing this page must not leave behind. */
    igOn.reset();
    if (e1) return fail(e1);
    toast('Instagram connected — sync to pull the numbers'); analytics().catch(fail);
  };
  const igOff = $('#ig-off'); if (igOff) igOff.onclick = async () => {
    if (!confirm('Disconnect Instagram?\n\nThe stored token is deleted. Reconnecting means issuing a new one from Meta.')) return;
    const { error: e1 } = await sb.rpc('instagram_disconnect'); if (e1) return fail(e1);
    toast('Disconnected'); analytics().catch(fail);
  };

  const cf = $('#an-cfg'); if (cf) cf.onsubmit = async (e) => {
    e.preventDefault(); const d = new FormData(cf);
    const { error: e1 } = await sb.rpc('analytics_config_set', { p: Object.fromEntries(d.entries()) }); if (e1) return fail(e1);
    toast('Saved'); analytics().catch(fail);
  };
  /* The counting window — when the history starts, which pages are work rather
     than audience — is a setup decision taken once, not a dial the coach turns
     from week to week; moving it silently rewrites every figure on the screen.
     It stays configuration in the database (analytics_web_config_set, audited)
     and is set by whoever runs the project, through scripts, not from here.
     What the screen does owe the reader is the rule it is showing under, and
     the note under the chart says it. */
}

// The audience forms ride the existing bottom sheet (session / block popups), not a second modal.
function openSnapSheet(title, body) {
  const host = ensureSheet(); const sheet = host.querySelector('.cg-sheet');
  sheet.innerHTML = `<div class="cg-sheet-h"><b>${esc(title)}</b><button class="btn btn-line btn-xs" data-x>Close</button></div><div class="cg-sheet-b">${body}</div>`;
  sheet.querySelector('[data-x]').onclick = closeSheet;
  sheet.querySelectorAll('[data-x2]').forEach((b) => b.onclick = closeSheet);
}

// Type one platform's numbers for one day. Blank fields are left alone on an existing row.
function openSnapshotEditor() {
  const today = new Intl.DateTimeFormat('en-CA', { timeZone: 'Asia/Dubai' }).format(new Date());
  openSnapSheet('Add numbers', `<form id="an-snap" class="ad-form">
      <div class="row"><label>Platform <select name="platform">${Object.entries(PLATFORMS).map(([k, v]) => `<option value="${k}">${v}</option>`).join('')}</select></label>
        <label>Date <input type="date" name="date" value="${today}" max="${today}" required></label></div>
      <div class="row"><label>Followers <input type="number" name="followers" min="0" inputmode="numeric"></label>
        <label>Views <input type="number" name="views" min="0" inputmode="numeric"></label></div>
      <div class="row"><label>Likes <input type="number" name="likes" min="0"></label>
        <label>Comments <input type="number" name="comments" min="0"></label>
        <label>Posts <input type="number" name="posts" min="0"></label></div>
      <label>Note <input name="note" placeholder="Optional"></label>
      <div class="actions"><button class="btn btn-accent btn-sm" type="submit">Save</button><button class="btn btn-line btn-sm" type="button" data-x2>Cancel</button></div>
    </form>
    <p class="ad-note">A blank field leaves the stored value alone. Saving the same platform and date twice updates the row.</p>`);
  $('#an-snap').onsubmit = async (e) => {
    e.preventDefault(); const f = new FormData(e.target);
    const p = {}; for (const [k, v] of f.entries()) if (String(v).trim() !== '') p[k] = v;
    const { error } = await sb.rpc('audience_snapshot_upsert', { p }); if (error) return fail(error);
    closeSheet(); toast('Saved'); analytics().catch(fail);
  };
}

/* A platform export, parsed in the browser by admin/csv.js: nothing leaves the page
   but the numbers, and the header row is mapped by name so an Instagram, TikTok or
   YouTube Studio export imports without the coach renaming a column. */
function openSnapshotImport() {
  openSnapSheet('Import a CSV export', `
    <p class="ad-muted" style="font-size:14px;margin:0 0 12px">Export from Instagram, TikTok or YouTube Studio and drop the file here. Columns are recognised by their name (date, followers, views, likes, comments, shares, posts); anything else is ignored. Nothing but the numbers leaves this page.</p>
    <form id="an-imp" class="ad-form">
      <label>Platform <select name="platform">${Object.entries(PLATFORMS).map(([k, v]) => `<option value="${k}">${v}</option>`).join('')}</select></label>
      <label>File <input type="file" name="file" accept=".csv,.tsv,text/csv,text/plain" required></label>
      <div id="an-imp-prev" class="ad-note"></div>
      <div class="actions"><button class="btn btn-accent btn-sm" type="submit" disabled id="an-imp-go">Import</button><button class="btn btn-line btn-sm" type="button" data-x2>Cancel</button></div>
    </form>`);
  let parsed = [];
  const form = $('#an-imp'), prev = $('#an-imp-prev'), go = $('#an-imp-go');
  form.file.onchange = async () => {
    const file = form.file.files[0]; if (!file) return;
    if (file.size > 2 * 1024 * 1024) { prev.textContent = 'That file is larger than 2 MB — export a shorter period.'; go.disabled = true; return; }
    const res = csvToSnapshots(await file.text());
    parsed = res.rows.slice(0, 400);
    prev.innerHTML = res.error ? esc(res.error)
      : `${parsed.length} row${parsed.length === 1 ? '' : 's'} ready${res.skipped ? `, ${res.skipped} ignored` : ''}${parsed.length ? ` · ${esc(parsed[0].date)} → ${esc(parsed[parsed.length - 1].date)}` : ''}.`;
    go.disabled = !parsed.length;
  };
  form.onsubmit = async (e) => {
    e.preventDefault();
    const { data, error } = await sb.rpc('audience_snapshots_import', { p_platform: new FormData(form).get('platform'), p_rows: parsed });
    if (error) return fail(error);
    closeSheet(); toast(`${data.imported} row${data.imported === 1 ? '' : 's'} imported`); analytics().catch(fail);
  };
}

/* =============================== ACCESS (platform:admin) =============================== */
/* Access administration only. Granting a permission here never bypasses RLS:
   business data still requires the explicit business permissions. */
const PERMS = ['coach:operations', 'client_profile:view', 'client_profile:manage', 'health_metrics:view', 'health_metrics:manage', 'coaching_sensitive:view', 'coaching_sensitive:manage', 'finance:view', 'finance:manage', 'analytics:view', 'analytics:manage', 'catalog:view', 'catalog:manage', 'platform:admin'];
/* ---------- Settings › Business: who the coach is on a contract ----------
   A collaboration agreement names a party, and a party needs a legal name, a
   licence and an address. None of it can be guessed, so it is typed once here
   and printed on every agreement issued afterwards. The document keeps the
   version it was signed with, so correcting a typo today never rewrites a
   contract signed last month. */
async function orgProfile() {
  const { data: o, error } = await sb.from('org_profile').select('*').eq('id', 1).maybeSingle();
  if (error) return fail(error);
  const v = o || {};
  const f = (k, label, ph = '') => `<label>${esc(label)} <input name="${k}" value="${esc(v[k] || '')}" placeholder="${esc(ph)}"></label>`;
  view.innerHTML = `
    <div class="ad-head"><div><h1>Business</h1><p class="ad-muted">What appears on a collaboration agreement. Leave a field empty and it is left off the document rather than filled with a guess.</p></div></div>
    <div class="ad-panel"><form id="org-form" class="ad-form">
      <div class="row">${f('legal_name', 'Legal name', 'The entity that signs')}${f('trading_name', 'Trading name', 'Coach Gari')}</div>
      <div class="row">${f('licence_no', 'Licence number', 'e.g. the free-zone licence')}${f('jurisdiction', 'Jurisdiction', 'e.g. RAK Economic Zone, United Arab Emirates')}</div>
      <label>Registered address <input name="address" value="${esc(v.address || '')}"></label>
      <div class="row">${f('email', 'Contract email', 'collab@…')}${f('website', 'Website', 'coachgari28.com')}</div>
      <div class="cg-actions"><button class="btn btn-accent" type="submit">Save</button></div>
    </form>
    <p class="ad-muted" style="font-size:12px;margin-top:10px">Agreements are signed electronically under UAE Federal Decree-Law No. 46 of 2021. The jurisdiction above is the one named in the governing-law clause.${v.updated_at ? ` Last changed ${esc(fmt(v.updated_at, 'Asia/Dubai', { dateStyle: 'medium' }))}${v.updated_by ? ' by ' + esc(v.updated_by) : ''}.` : ''}</p></div>`;
  $('#org-form').onsubmit = async (e) => {
    e.preventDefault();
    const d = Object.fromEntries(new FormData(e.target).entries());
    const { error: e2 } = await sb.rpc('org_profile_set', { p: d });
    if (e2) return fail(e2);
    toast('Saved');
    orgProfile().catch(fail);
  };
}

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
/* wa.me wants E.164 with no punctuation, and it does not complain about a number that
   cannot exist — it just opens on nobody. CRM numbers arrive international now, but a
   raw enquiry still carries whatever the person typed into the contact form, so the same
   rule the database uses is applied here: 0 + one of the six UAE mobile prefixes + seven
   digits is a Dubai mobile; 00 in front is the international prefix written out. Anything
   else is passed through as digits, exactly as before. */
const e164 = (p) => {
  const d = String(p || '').replace(/\D/g, '');
  if (/^00[0-9]{8,}$/.test(d)) return d.slice(2);
  if (/^0(50|52|54|55|56|58)[0-9]{7}$/.test(d)) return '971' + d.slice(1);
  return d;
};
const waHref = (p) => 'https://wa.me/' + e164(p);
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
  const [{ data: packs, error: pe }, { data: sess, error: se }, { data: rate }] = await Promise.all([
    sb.rpc('packs_for_contact', { p_contact_id: pf.crmId }),
    sb.rpc('sessions_list', { p: { crm_contact_id: pf.crmId } }),
    has('finance:view') ? sb.rpc('client_rate_get', { p_contact_id: pf.crmId }) : Promise.resolve({ data: null }),
  ]);
  if (pe) throw pe; if (se) throw se;
  const pk = packs || [], ss = sess || [];
  const cname = pf.contact?.display_name || 'this client';
  const packCard = (p) => `<div class="cg-packcard"><div class="cg-packcard-h"><b>${esc(p.title)}</b>${p.status !== 'active' ? st(p.status) : ''}${'payment_status' in p ? `<span class="cal-pay ${p.payment_status === 'paid' ? 'ok' : 'due'}" style="margin-left:auto">${esc(p.payment_status)}</span>` : ''}</div>
    <div class="cg-pack"><div class="cg-pack-x">${p.used} / ${p.total_sessions}</div><div class="cg-pack-r">${p.remaining} remaining</div></div>
    ${'price_amount' in p ? `<div class="ad-muted" style="font-size:12.5px">${money(p.price_amount, p.currency)}${p.paid_at ? ' · paid ' + fmt(p.paid_at, CAL_TZ, { dateStyle: 'medium' }) : ''}</div>` : ''}
    <div class="cg-actions" style="margin-top:10px"><button class="btn btn-line btn-xs" data-packact="${p.id}">Recap &amp; payment…</button></div></div>`;
  /* What Gari charges THIS client. It sits above the packages because it is the thing
     everything else falls back to: a session with no price of its own and no package
     takes this one. Empty means no special rate, which is not the same as free. */
  const rateRow = !has('finance:view') ? '' : `
    <div class="cg-raterow">
      <div><span class="cg-rate-k">Rate for ${esc(cname)}</span>
        <b class="cg-rate-v">${rate ? money(rate.amount, rate.currency) : '<span class="ad-muted">No special rate</span>'}</b>
        <span class="ad-muted" style="font-size:12px">per session, unless a package or the session itself says otherwise</span></div>
      ${has('finance:manage') ? `<button class="btn btn-line btn-xs" id="pf-rate">${rate ? 'Change' : 'Set rate'}</button>` : ''}
    </div>`;
  $('#pf-body').innerHTML = `
    ${rateRow}
    <div class="ad-actions" style="display:flex;gap:8px;flex-wrap:wrap;margin-bottom:14px">
      <button class="btn btn-accent btn-sm" id="pf-new-sess">+ Session</button>
      <button class="btn btn-line btn-sm" id="pf-new-pack">+ Package</button></div>
    ${pk.length ? `<div class="cg-packgrid">${pk.map(packCard).join('')}</div>` : '<p class="pf-sec-empty">No packages yet.</p>'}
    <h2 style="font-size:14px;text-transform:uppercase;letter-spacing:.06em;color:var(--grey-text);margin:18px 0 8px">Sessions</h2>
    ${ss.length ? `<div class="ad-panel" style="padding:0"><div class="ad-table-wrap"><table class="ad-table"><thead><tr><th>Date</th><th>Time</th><th>#</th><th>Type</th><th>Package</th>${has('finance:view') ? '<th>Price</th>' : ''}<th>Status</th></tr></thead><tbody>
      ${ss.map((s) => { const t = lp(s.start_at), e = lp(s.end_at); return `<tr class="clik" data-sess="${s.id}"><td>${prettyDay(t.date)}</td><td>${String(t.h).padStart(2,'0')}:${String(t.m).padStart(2,'0')}–${String(e.h).padStart(2,'0')}:${String(e.m).padStart(2,'0')}</td><td class="ad-muted">${seqLine(s.seq) || '—'}</td><td>${esc(s.title || '—')}</td><td>${s.pack ? `${s.pack.used}/${s.pack.total_sessions}` : '—'}</td>${has('finance:view') ? `<td style="font-size:12.5px">${priceLine(s.price)}</td>` : ''}<td>${st(s.status)}</td></tr>`; }).join('')}
      </tbody></table></div></div>` : '<p class="pf-sec-empty">No sessions yet.</p>'}`;
  $('#pf-new-sess').onclick = () => sessionForm({ crm_contact_id: pf.crmId, crm_name: cname });
  $('#pf-new-pack').onclick = () => packForm(pf.crmId, () => pfSessions().catch(fail));
  const rb = $('#pf-rate'); if (rb) rb.onclick = () => clientRateForm(pf.crmId, cname, rate, () => pfSessions().catch(fail));
  $('#pf-body').querySelectorAll('tr.clik').forEach((tr) => tr.onclick = () => { calData = { sessions: ss, blocks: [] }; openSession(tr.dataset.sess); });
  $('#pf-body').querySelectorAll('[data-packact]').forEach((b) => b.onclick = () => pfPackActions(pk.find((x) => x.id === b.dataset.packact)));
}

/* Set or clear what Gari charges one client.

   An empty field clears the rate rather than storing zero, and the form says so out
   loud: "no special rate" and "free" are different answers, and a back-office that
   quietly turns one into the other bills the wrong amount for years. */
function clientRateForm(contactId, cname, rate, after) {
  const host = ensureSheet(); const sheet = host.querySelector('.cg-sheet');
  sheet.innerHTML = `<div class="cg-sheet-h"><b>Rate for ${esc(cname)}</b><button class="pf-close" data-x>×</button></div>
    <div class="cg-sheet-b"><form id="rate-form" class="cg-form">
      <label>Price per session <input name="amount" type="number" min="0" step="1" value="${rate ? rate.amount / 100 : ''}" placeholder="e.g. 350" autofocus>
        <span class="ad-muted" style="font-size:12px">In ${esc(CG_CCY)}. Leave empty for no special rate — this client is then priced only by their packages.</span></label>
      <label>Why this rate <input name="note" value="${rate ? esc(rate.note || '') : ''}" placeholder="Optional — e.g. long-standing client, group of two"></label>
      <p class="ad-muted" style="font-size:12px">Sessions inside a package keep the package's price. This applies to everything else.</p>
      <div class="cg-actions"><button class="btn btn-accent" type="submit">Save</button>
        ${rate ? '<button class="btn btn-line" type="button" data-clear>Remove the rate</button>' : ''}
        <button class="btn btn-line" type="button" data-x2>Cancel</button></div>
    </form></div>`;
  const close = () => closeSheet();
  sheet.querySelector('[data-x]').onclick = close; sheet.querySelector('[data-x2]').onclick = close;
  const save = async (amount, note) => {
    const { error } = await sb.rpc('client_rate_set', {
      p_contact_id: contactId, p_amount: amount, p_currency: CG_CCY, p_note: note || null });
    if (error) return fail(error);
    toast(amount == null ? 'Rate removed' : 'Rate saved'); close(); after();
  };
  const cb = sheet.querySelector('[data-clear]'); if (cb) cb.onclick = () => save(null, null);
  sheet.querySelector('#rate-form').onsubmit = (e) => {
    e.preventDefault(); const f = new FormData(e.target);
    const v = String(f.get('amount') || '').trim();
    save(v === '' ? null : Math.round(Number(v) * 100), f.get('note'));
  };
}

/* ---- pack: recap, share, payment, renewal, history (CG-012) + collect in person (BEAU PH softpos handoff) ---- */
// Device/platform this cockpit runs on — one of BEAU PH's eligibility inputs (server-side decides; this only reports).
function detectPlatform() {
  const ua = navigator.userAgent || '';
  if (/iPhone|iPad|iPod/i.test(ua) || (navigator.platform === 'MacIntel' && navigator.maxTouchPoints > 1)) return 'ios_pwa';
  if (/Android/i.test(ua)) return 'android_pwa';
  return 'web';
}
function pfPackActions(p, after) {
  const host = ensureSheet(); const sheet = host.querySelector('.cg-sheet');
  const money2 = (mi, cur) => mi == null ? '—' : money(mi, cur);
  const refresh = after || (() => pfSessions().catch(fail));
  sheet.innerHTML = `<div class="cg-sheet-h"><b>${esc(p.title)}</b>${p.public_ref ? `<span class="ad-muted" style="font-size:12px;font-weight:600">${esc(p.public_ref)}</span>` : ''}<button class="pf-close" data-x>×</button></div>
    <div class="cg-sheet-b">
      <div class="cg-pack"><div class="cg-pack-x">${p.used} / ${p.total_sessions}</div><div class="cg-pack-r">${p.remaining} remaining</div></div>
      ${'price_amount' in p ? `<p class="ad-muted" style="font-size:13px;margin:0 0 8px">${money2(p.price_amount, p.currency)} · ${esc(p.payment_status)}</p>` : ''}
      <div class="cg-acts">
        <button class="cg-act cg-act-go" data-a="share">${ICO.share}<span>Recap &amp; share</span></button>
        ${(has('finance:manage') && p.payment_status !== 'paid') ? `<button class="cg-act" data-a="collect">${ICO.tap}<span>Collect in person</span></button>` : ''}
        ${has('finance:manage') ? `<button class="cg-act" data-a="record">${ICO.receipt}<span>Record payment</span></button>` : ''}
        <button class="cg-act" data-a="renew">${ICO.renew}<span>Renew package</span></button>
        <button class="cg-act" data-a="history">${ICO.history}<span>Payment history</span></button>
      </div>
      <div id="pf-pack-out" style="margin-top:12px"></div>
    </div>`;
  sheet.querySelector('[data-x]').onclick = closeSheet;
  const on = (a, fn) => { const el = sheet.querySelector(`[data-a="${a}"]`); if (el) el.onclick = fn; };
  on('share', () => pfShareRecap(p));
  on('collect', () => pfCollectInPerson(p, refresh));
  on('record', () => pfRecordPayment(p, refresh));
  on('renew', async () => { if (!await confirmAct('Renew this package? A NEW package is created (the old one stays exactly as it is).')) return; const { error } = await sb.rpc('pack_renew', { p_pack_id: p.id }); if (error) return fail(error); toast('New package created'); closeSheet(); refresh(); });
  on('history', async () => {
    const { data, error } = await sb.rpc('pack_payment_history', { p_pack_id: p.id }); if (error) return fail(error);
    const rows = data || [];
    $('#pf-pack-out').innerHTML = rows.length ? `<div class="ad-table-wrap"><table class="ad-table"><thead><tr><th>Reference</th><th>Status</th><th>Source</th><th>${has('finance:view') ? 'Amount' : ''}</th><th>Paid</th></tr></thead><tbody>
      ${rows.map((o) => `<tr><td>${esc(o.order_reference)}</td><td>${st(o.status)}</td><td>${esc(o.source || '—')}</td><td>${o.amount != null ? money(o.amount, o.currency) : ''}</td><td>${o.paid_at ? fmt(o.paid_at, CAL_TZ, { dateStyle: 'medium' }) : '—'}</td></tr>`).join('')}
      </tbody></table></div>` : '<p class="ad-muted" style="font-size:13px">No payment requests or payments yet.</p>';
  });
}

async function pfShareRecap(p) {
  const out = $('#pf-pack-out'); out.innerHTML = '<p class="ad-muted" style="font-size:13px">Creating secure link…</p>';
  const { data, error } = await sb.rpc('report_issue_link', { p_pack_id: p.id });
  if (error) { out.innerHTML = ''; return fail(error); }
  const url = `${location.origin}/r/${data.token}`;
  const first = (pf.contact?.display_name || '').split(' ')[0] || '';
  const due = ('price_amount' in p && p.payment_status !== 'paid' && p.price_amount) ? `\nAmount due: ${money(p.price_amount, p.currency)}` : '';
  const refLine = p.public_ref ? `\nPayment reference: ${p.public_ref}` : '';
  const msg = `Hi ${first},\n\nHere is your Coach Gari session recap:\n${url}\n\n${p.title}\n${p.used}/${p.total_sessions} completed${due}${refLine}\n\nYou can pay by card, Aani or bank transfer on the link above.\n\nThanks,\nGari`;
  const ph = pf.contact?.phone; const em = pf.contact?.email;
  out.innerHTML = `
    <label style="font-size:12px;font-weight:700;color:var(--grey-text);display:block;margin-bottom:4px">Message (edit before sending)</label>
    <textarea id="pf-share-msg" style="width:100%;min-height:150px;font:inherit;font-size:13px;padding:10px;border:1px solid var(--line);border-radius:10px">${esc(msg)}</textarea>
    <div class="cg-actions" style="margin-top:10px">
      ${ph ? '<button class="btn btn-accent btn-sm" data-s="wa">WhatsApp</button>' : ''}
      <button class="btn btn-line btn-sm" data-s="email">Email</button>
      <button class="btn btn-line btn-sm" data-s="copymsg">Copy message</button>
      <button class="btn btn-line btn-sm" data-s="copylink">Copy link</button>
      <button class="btn btn-line btn-sm" data-s="revoke" style="color:var(--danger,#a12a2a)">Revoke link</button>
    </div>
    <p class="ad-muted" style="font-size:12px;margin-top:8px">The link opens the client's recap and payment options. It never shows body metrics, health data or private notes. Nothing is auto-sent.</p>`;
  const getMsg = () => $('#pf-share-msg').value;
  const sOn = (s, fn) => { const el = out.querySelector(`[data-s="${s}"]`); if (el) el.onclick = fn; };
  sOn('wa', () => window.open(`${waHref(ph)}?text=${encodeURIComponent(getMsg())}`, '_blank', 'noopener'));
  sOn('email', () => { const subject = 'Your Coach Gari session recap'; window.location.href = `mailto:${em ? encodeURIComponent(em) : ''}?subject=${encodeURIComponent(subject)}&body=${encodeURIComponent(getMsg())}`; });
  sOn('copymsg', async () => { try { await navigator.clipboard.writeText(getMsg()); toast('Message copied'); } catch {} });
  sOn('copylink', async () => { try { await navigator.clipboard.writeText(url); toast('Link copied'); } catch {} });
  sOn('revoke', async () => { if (!await confirmAct('Revoke this recap link? Anyone holding it will no longer be able to open it.')) return; const { error: e2 } = await sb.rpc('report_revoke', { p_pack_id: p.id }); if (e2) return fail(e2); toast('Link revoked'); out.innerHTML = '<p class="ad-muted" style="font-size:13px">Link revoked. Use “Recap &amp; share” again to issue a new one.</p>'; });
}

/* Collect in person — BEAU PH `softpos` capability, V0 = handoff to the PSP's certified Tap to Pay app.
   The server decides what can be offered (merchant config × country × currency × device × readiness);
   this page shows the amount + reference, sends the operator to the PSP app, and records the app's
   receipt reference. No card data, no NFC, nothing charged from here. */
async function pfCollectInPerson(p, after) {
  const out = $('#pf-pack-out'); out.innerHTML = '<p class="ad-muted" style="font-size:13px">Checking in-person options…</p>';
  const { data: o, error } = await sb.rpc('cg_ph_collect_options', { p_pack_id: p.id, p_platform: detectPlatform() });
  if (error) { out.innerHTML = ''; return fail(error); }
  if (o.paid) { out.innerHTML = '<p class="ad-muted" style="font-size:13px">This package is already paid.</p>'; return; }
  const opts = o.options || [];
  if (!opts.length) {
    out.innerHTML = '<p class="ad-muted" style="font-size:13px">No in-person acceptance is set up yet. In <b>Finance → Payment methods</b>, enable <b>Cash</b> or the Tap to Pay app you use (Network International <i>N-Genius One</i> or Magnati <i>SwipeX</i>). Card data never touches this app.</p>';
    return;
  }
  const cur = o.currency || 'AED';
  out.innerHTML = `<form id="pf-collect" class="cg-form" style="margin-top:4px">
    <div class="cg-row"><label>Amount <input type="number" name="amount_major" min="0" step="0.01" required value="${o.amount != null ? (o.amount / 100).toFixed(2) : ''}"></label>
      <label>Currency <input name="currency" value="${esc(cur)}" maxlength="3" readonly></label></div>
    <label>Reference <span style="display:flex;gap:8px;align-items:center"><input name="reference_show" value="${esc(o.reference || '')}" readonly style="flex:1"><button type="button" class="btn btn-line btn-xs" data-copyref>Copy</button></span></label>
    <label>Accept with <select name="opt">${opts.map((x, i) => `<option value="${i}">${esc(x.display_name)}${x.capability === 'cash' ? '' : ' — ' + esc((x.settings && x.settings.handoff_app) || x.capability)}${x.handoff ? ' (PSP app)' : ''}</option>`).join('')}</select></label>
    <ol class="ad-muted" id="pf-collect-steps" style="font-size:12.5px;margin:6px 0 8px 18px;padding:0;line-height:1.5"></ol>
    <div class="cg-actions" id="pf-collect-open"></div>
    <label id="pf-collect-receipt-l">Receipt / transaction reference from the app <input name="receipt" placeholder="e.g. RRN or receipt number" autocomplete="off"></label>
    <div class="cg-actions"><button class="btn btn-accent btn-sm" type="submit" id="pf-collect-submit">Customer tapped — confirm paid</button></div>
    <p class="ad-muted" id="pf-collect-foot" style="font-size:12px;margin:6px 0 0"></p>
  </form>`;
  const form = out.querySelector('#pf-collect');
  const renderOpt = () => {
    const x = opts[Number(form.opt.value)] || opts[0];
    const amt = Math.round(Number(form.amount_major.value) * 100) || o.amount;
    if (x.capability === 'cash') {
      $('#pf-collect-steps').innerHTML = [`Take <b>${money(amt, cur)}</b> in cash from the customer`, 'Count it and confirm below — the receipt is recorded in BEAU PH under your name']
        .map((s) => `<li>${s}</li>`).join('');
      $('#pf-collect-open').innerHTML = '';
      $('#pf-collect-receipt-l').firstChild.textContent = 'Note (optional) ';
      form.receipt.placeholder = 'e.g. paid after the session';
      $('#pf-collect-submit').textContent = 'Cash received — confirm paid';
      $('#pf-collect-foot').textContent = 'Confirming records an operator-confirmed cash receipt in BEAU PH and marks the package paid. Cash goes straight to Coach Gari (no Oolala earning). Nothing is confirmed automatically.';
      return;
    }
    const app = (x.settings && x.settings.handoff_app) || x.display_name; const url = x.settings && x.settings.handoff_url;
    $('#pf-collect-steps').innerHTML = [`Open <b>${esc(app)}</b> on this phone`, `Choose Tap to Pay and enter <b>${money(amt, cur)}</b>`, 'Let the customer tap their card, phone or watch', 'Copy the receipt / transaction reference shown by the app into the field below']
      .map((s) => `<li>${s}</li>`).join('');
    $('#pf-collect-open').innerHTML = url ? `<a class="btn btn-line btn-sm" href="${esc(url)}" rel="noopener">Open ${esc(app)}</a>` : `<span class="ad-muted" style="font-size:12px">Switch to the ${esc(app)} app, then come back here.</span>`;
    $('#pf-collect-receipt-l').firstChild.textContent = 'Receipt / transaction reference from the app ';
    form.receipt.placeholder = 'e.g. RRN or receipt number';
    $('#pf-collect-submit').textContent = 'Customer tapped — confirm paid';
    $('#pf-collect-foot').textContent = 'Confirming records an operator-attested receipt in BEAU PH and marks the package paid. The money settles to your PSP merchant account (no Oolala earning). Nothing is charged from this page.';
  };
  form.opt.onchange = renderOpt; form.amount_major.oninput = renderOpt; renderOpt();
  out.querySelector('[data-copyref]').onclick = async () => { try { await navigator.clipboard.writeText(o.reference || ''); toast('Reference copied'); } catch {} };
  form.onsubmit = async (e) => {
    e.preventDefault(); const x = opts[Number(form.opt.value)] || opts[0];
    const amt = Math.round(Number(form.amount_major.value) * 100); if (!amt || amt <= 0) return toast('Enter an amount', true);
    const receipt = (form.receipt.value || '').trim(); if (!receipt && x.capability !== 'cash') return toast('Enter the receipt reference from the app', true);
    const { error: e2 } = await sb.rpc('payment_record_manual', {
      p_pack_id: p.id, p_amount: amt, p_currency: cur, p_source: x.provider, p_reference: receipt || null, p_paid_at: null,
      p_capability: x.capability, p_platform: detectPlatform() });
    if (e2) return fail(e2); toast('Paid — package and ledger updated'); closeSheet(); if (after) after();
  };
}

function pfRecordPayment(p, after) {
  const out = $('#pf-pack-out');
  const cur = ('currency' in p) ? p.currency : 'AED';
  const refresh = after || (() => pfSessions().catch(fail));
  out.innerHTML = `<form id="pf-pay-form" class="cg-form" style="margin-top:4px">
    <p class="ad-muted" style="font-size:12.5px;margin:0">Record a payment actually received (Aani, bank transfer, cash…). This is manual reconciliation — it never happens automatically, and card payments are handled by Stripe, not here.</p>
    <div class="cg-row"><label>Amount <input type="number" name="amount_major" min="0" step="0.01" required placeholder="e.g. 3120"></label>
      <label>Currency <input name="currency" value="${esc(cur)}" maxlength="3"></label></div>
    <div class="cg-row"><label>Source <select name="source"><option value="aani">Aani</option><option value="bank_transfer">Bank transfer</option><option value="cash">Cash</option><option value="manual">Manual</option><option value="external">External</option></select></label>
      <label>Paid on <input type="date" name="paid_date" value="${new Date().toISOString().slice(0, 10)}"></label></div>
    <label>Reference (from the client) <input name="reference" placeholder="Optional"></label>
    <div class="cg-actions"><button class="btn btn-accent btn-sm" type="submit">Record payment</button></div></form>`;
  out.querySelector('#pf-pay-form').onsubmit = async (e) => {
    e.preventDefault(); const f = new FormData(e.target);
    const amt = Math.round(Number(f.get('amount_major')) * 100);
    if (!amt || amt <= 0) return toast('Enter an amount', true);
    const { error } = await sb.rpc('payment_record_manual', {
      p_pack_id: p.id, p_amount: amt, p_currency: (f.get('currency') || 'AED').toUpperCase(),
      p_source: f.get('source'), p_reference: f.get('reference') || null,
      p_paid_at: f.get('paid_date') ? zonedToUtc(`${f.get('paid_date')}T12:00`, CAL_TZ) : null });
    if (error) return fail(error); toast('Payment recorded'); closeSheet(); refresh();
  };
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
      <button class="pf-close" id="pf-x" aria-label="Close">×</button>
      <div class="pf-avatar">${esc(initials(pfName()))}</div>
      <div class="pf-id"><h2>${esc(pfName())}</h2><div class="pf-meta">${meta.map((m) => `<span>${typeof m === 'string' && m.startsWith('<span') ? m : esc(m)}</span>`).join('')}</div></div>
      <div class="pf-actions">
        ${ph ? `<a class="btn btn-line btn-xs" href="${waHref(ph)}" target="_blank" rel="noopener">WhatsApp</a>` : ''}
        ${em ? `<a class="btn btn-line btn-xs" href="mailto:${esc(em)}">Email</a>` : ''}
        ${(c && has('client_profile:manage')) ? '<button class="btn btn-line btn-xs" id="pf-edit">Edit</button>' : ''}
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
const ICO = {
  share: '<svg viewBox="0 0 24 24" width="17" height="17" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M12 3v12M8 7l4-4 4 4"/><path d="M5 13v6.5h14V13"/></svg>',
  tap: '<svg viewBox="0 0 24 24" width="17" height="17" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M10 10V5.5a1.6 1.6 0 0 1 3.2 0V12"/><path d="M13.2 11.4a1.5 1.5 0 0 1 3 0V13"/><path d="M16.2 12.4a1.5 1.5 0 0 1 3 0v3.2c0 2.8-2.2 5-5 5h-1.4c-1.4 0-2.7-.6-3.6-1.7L6 15.5a1.6 1.6 0 0 1 2.4-2.1l1.6 1.7"/></svg>',
  receipt: '<svg viewBox="0 0 24 24" width="17" height="17" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M6 3h12v18l-3-2-3 2-3-2-3 2V3Z"/><path d="M9 8h6M9 12h6"/></svg>',
  renew: '<svg viewBox="0 0 24 24" width="17" height="17" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M20 12a8 8 0 1 1-2.6-5.9"/><path d="M20 4v4.5h-4.5"/></svg>',
  history: '<svg viewBox="0 0 24 24" width="17" height="17" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><circle cx="12" cy="12" r="9"/><path d="M12 7v5.5l3.5 2"/></svg>',
  clock: '<svg viewBox="0 0 24 24" width="17" height="17" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><rect x="3.5" y="5" width="17" height="16" rx="2.5"/><path d="M8 3v4M16 3v4M3.5 10h17"/></svg>',
  map: '<svg viewBox="0 0 24 24" width="17" height="17" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M12 21s7-6.2 7-11a7 7 0 1 0-14 0c0 4.8 7 11 7 11Z"/><circle cx="12" cy="10" r="2.6"/></svg>',
  nav: '<svg viewBox="0 0 24 24" width="17" height="17" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="m3 11 18-8-8 18-2-8-8-2Z"/></svg>',
  link: '<svg viewBox="0 0 24 24" width="17" height="17" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M10.5 13.5a4 4 0 0 0 5.7 0l2.3-2.3a4 4 0 0 0-5.7-5.7l-1.2 1.2"/><path d="M13.5 10.5a4 4 0 0 0-5.7 0l-2.3 2.3a4 4 0 0 0 5.7 5.7l1.2-1.2"/></svg>',
  plus: '<svg viewBox="0 0 24 24" width="17" height="17" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" aria-hidden="true"><path d="M12 5v14M5 12h14"/></svg>',
  check: '<svg viewBox="0 0 24 24" width="17" height="17" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M20 6 9 17l-5-5"/></svg>',
  noshow: '<svg viewBox="0 0 24 24" width="17" height="17" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><circle cx="9" cy="8" r="3.2"/><path d="M3.5 19c0-2.8 2.4-5 5.5-5 1 0 1.9.2 2.7.6"/><path d="m16 15 5 5M21 15l-5 5"/></svg>',
  person: '<svg viewBox="0 0 24 24" width="17" height="17" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><circle cx="12" cy="8" r="3.4"/><path d="M5 20c0-3.3 3.1-6 7-6s7 2.7 7 6"/></svg>',
  pack: '<svg viewBox="0 0 24 24" width="17" height="17" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="m12 3 8 4.5v9L12 21l-8-4.5v-9L12 3Z"/><path d="m4 7.5 8 4.5 8-4.5M12 12v9"/></svg>',
  edit: '<svg viewBox="0 0 24 24" width="17" height="17" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M4 20h4L19 9a2.1 2.1 0 0 0-3-3L5 17v3Z"/><path d="m14.5 6.5 3 3"/></svg>',
  cancel: '<svg viewBox="0 0 24 24" width="17" height="17" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><circle cx="12" cy="12" r="9"/><path d="m8.5 8.5 7 7"/></svg>',
  trash: '<svg viewBox="0 0 24 24" width="17" height="17" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M4 7h16M10 7V5h4v2M6 7l1 13h10l1-13"/></svg>',
  money: '<svg viewBox="0 0 24 24" width="17" height="17" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><rect x="2.5" y="6" width="19" height="12" rx="2"/><circle cx="12" cy="12" r="2.6"/></svg>',
  call: '<svg viewBox="0 0 24 24" width="14" height="14" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M6.5 3.5 9 4l1 3.5-1.8 1.4a12 12 0 0 0 5.4 5.4L15 12.5 18.5 14l.5 2.5c0 1-.9 1.9-2 1.8A15 15 0 0 1 4.7 5C4.6 3.9 5.5 3 6.5 3.5Z"/></svg>',
  wa: '<svg viewBox="0 0 24 24" width="14" height="14" fill="currentColor"><path d="M12 2a10 10 0 0 0-8.6 15l-1.3 4.7 4.8-1.3A10 10 0 1 0 12 2Zm5.5 14.2c-.2.6-1.2 1.2-1.7 1.2-.5.1-1 .2-3.2-.7-2.7-1.1-4.4-3.9-4.5-4-.1-.2-1.1-1.4-1.1-2.7 0-1.3.7-1.9.9-2.2.2-.2.5-.3.7-.3h.5c.2 0 .4 0 .6.5l.8 2c.1.2.1.4 0 .5l-.4.6c-.2.2-.3.4-.1.7.2.3.9 1.4 1.9 2 .9.6 1.3.7 1.5.6.2-.1.5-.6.7-.9.2-.2.3-.2.6-.1l1.9.9c.2.1.4.2.5.3.1.3.1.7-.1 1.1Z"/></svg>',
  mail: '<svg viewBox="0 0 24 24" width="14" height="14" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><rect x="3" y="5" width="18" height="14" rx="2.5"/><path d="m3.5 7 8.5 6 8.5-6"/></svg>',
  copy: '<svg viewBox="0 0 24 24" width="14" height="14" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><rect x="9" y="9" width="11" height="11" rx="2.5"/><path d="M15 5.5A2.5 2.5 0 0 0 12.5 3h-6A2.5 2.5 0 0 0 4 5.5v8"/></svg>',
};
async function pfOverview() {
  const c = pf.contact;
  const tel = c.phone ? 'tel:' + c.phone.replace(/[^\d+]/g, '') : null;
  const groups = [
    ['Location', [['City', c.city], ['Country', c.country]]],
    ['Preferences', [['Timezone', c.preferred_timezone], ['Language', c.preferred_language]]],
    ['Coaching', [['Height', c.height_cm != null ? c.height_cm + ' cm' : null], ['Goals', c.goals]]],
    ['Activity', [['Status', c.status], ['First seen', fmt(c.first_seen_at, 'Asia/Dubai', { dateStyle: 'medium' })], ['Last activity', fmt(c.last_activity_at, 'Asia/Dubai', { dateStyle: 'medium' })]]],
  ];
  const gitem = (k, v) => `<div class="pf-gitem"><span class="k">${esc(k)}</span><span class="v ${v ? '' : 'muted'}">${v ? esc(v) : '—'}</span></div>`;
  const canMerge = c.needs_review && has('client_profile:manage');
  $('#pf-body').innerHTML = `
    ${c.needs_review ? `<div class="ad-note"><p style="margin:0 0 8px">This person was auto-created from an ambiguous match (a shared email or phone) and is <b>flagged for review</b>. If it is the same person as an existing contact, you can merge this record into that one.</p>
      ${canMerge ? `<div id="pf-merge"><button class="btn btn-line btn-xs" id="pf-merge-open">Merge into another contact…</button></div>` : ''}</div>` : ''}
    <div class="pf-contact">
      ${c.phone ? `<div class="pf-crow"><div class="pf-crow-main"><div class="pf-crow-k">Phone / WhatsApp</div><a class="pf-crow-v" href="${tel}">${esc(c.phone)}</a></div>
        <div class="pf-cacts"><a class="pf-cbtn call" href="${tel}">${ICO.call} Call</a><a class="pf-cbtn wa" href="${waHref(c.phone)}" target="_blank" rel="noopener">${ICO.wa} WhatsApp</a><button class="pf-cbtn" data-copy="${esc(c.phone)}">${ICO.copy} Copy</button></div></div>` : ''}
      ${c.email ? `<div class="pf-crow"><div class="pf-crow-main"><div class="pf-crow-k">Email</div><a class="pf-crow-v" href="mailto:${esc(c.email)}">${esc(c.email)}</a></div>
        <div class="pf-cacts"><a class="pf-cbtn call" href="mailto:${esc(c.email)}">${ICO.mail} Email</a><button class="pf-cbtn" data-copy="${esc(c.email)}">${ICO.copy} Copy</button></div></div>` : ''}
      ${(!c.phone && !c.email) ? '<p class="pf-sec-empty">No phone or email on file.</p>' : ''}
    </div>
    ${has('client_profile:manage') ? `<div class="pf-group pf-msg"><div class="pf-group-t">Reminders</div>
      <label class="pf-check"><input type="checkbox" id="pf-rem" ${c.reminders_opt_out ? '' : 'checked'}> Send a reminder the day before a session</label>
      <label class="pf-check"><input type="checkbox" id="pf-wa" ${c.whatsapp_opt_in ? 'checked' : ''} ${c.phone ? '' : 'disabled'}> Also by WhatsApp${c.phone ? '' : ' — no phone number on file'}</label>
      <p class="ad-muted" style="font-size:12px;margin:6px 0 0">WhatsApp is off until this person says yes. A number on file is not consent.${c.whatsapp_opt_in_at ? ` Recorded ${esc(fmt(c.whatsapp_opt_in_at, 'Asia/Dubai', { dateStyle: 'medium' }))}${c.whatsapp_opt_in_by ? ' by ' + esc(c.whatsapp_opt_in_by) : ''}.` : ''}</p></div>` : ''}
    <div class="pf-groups">
      ${groups.map(([t, items]) => `<div class="pf-group"><div class="pf-group-t">${esc(t)}</div><div class="pf-glist">${items.map(([k, v]) => gitem(k, v)).join('')}</div></div>`).join('')}
    </div>
    <details class="pf-tech"><summary>Technical</summary><dl class="pf-kv" style="margin-top:10px"><dt>CRM id</dt><dd>${esc(c.id)}</dd><dt>Created by</dt><dd>${esc(c.created_by || '—')}</dd><dt>Updated by</dt><dd>${esc(c.updated_by || '—')}</dd></dl></details>`;
  $('#pf-body').querySelectorAll('[data-copy]').forEach((b) => b.onclick = async () => { try { await navigator.clipboard.writeText(b.dataset.copy); toast('Copied'); } catch {} });
  if (canMerge) $('#pf-merge-open').onclick = () => pfMergePicker(c);
  // reminders: one RPC, audited, and the checkbox goes back if the server says no
  const rem = $('#pf-rem'), wa = $('#pf-wa');
  const saveMsg = async (el, args, revert) => {
    const { error } = await sb.rpc('contact_messaging_set', { p_contact_id: c.id, ...args });
    if (error) { el.checked = revert; return fail(error); }
    Object.assign(c, { reminders_opt_out: !rem.checked, whatsapp_opt_in: !!(wa && wa.checked) });
    toast('Saved');
  };
  if (rem) rem.onchange = () => saveMsg(rem, { p_reminders_opt_out: !rem.checked }, !rem.checked);
  if (wa) wa.onchange = () => saveMsg(wa, { p_whatsapp_opt_in: wa.checked }, !wa.checked);
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
  if (form) form.onsubmit = (e) => { e.preventDefault(); return once(form.querySelector('[type=submit]'), async () => {
    const f = new FormData(form);
    const { error } = await sb.rpc('crm_add_note', { p_contact_id: pf.crmId, p_body: f.get('body'), p_category: f.get('category') || null, p_pinned: !!f.get('pinned'), p_scope: f.get('private') ? 'coach_private' : 'operational' });
    if (error) return fail(error);
    form.reset();                       // the field empties, so it is obvious the note landed
    toast('Note added'); pfNotes().catch(fail);
  }); };
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
  // a client's money is their booking orders plus their session-pack orders (no booking reference)
  const rows = (data || []).filter((o) => (o.booking_reference && refs.has(o.booking_reference)) || (pf.crmId && o.crm_contact_id === pf.crmId));
  $('#pf-body').innerHTML = rows.length ? `<div class="ad-table-wrap"><table class="ad-table"><thead><tr><th>Order</th><th>Item</th><th class="num">Gross</th><th class="num">Net</th><th class="num">Commission</th><th class="num">Payable</th><th>Status</th></tr></thead><tbody>
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
/* ---- searchable country picker (same behaviour as the public form): a select-like trigger, a search box, a
   scrollable list; the input keeps carrying the value so the RPC payload is unchanged. Names from
   Intl.DisplayNames in the operator's language, English fallback. ---- */
/* Plausible reports a country as an ISO 3166-1 alpha-2 code. Show it in the
   operator's own language, and fall back to the code itself rather than to
   nothing — an unknown code still says more than a blank cell. */
let REGION_NAMES = null;
function regionName(code) {
  const c = String(code || '').toUpperCase();
  if (!/^[A-Z]{2}$/.test(c)) return code || 'Unknown';
  if (!REGION_NAMES) { try { REGION_NAMES = new Intl.DisplayNames([navigator.language, 'en'], { type: 'region' }); } catch { REGION_NAMES = null; } }
  try { return (REGION_NAMES && REGION_NAMES.of(c)) || c; } catch { return c; }
}
let COUNTRY_NAMES = null;
function countryNames() {
  if (COUNTRY_NAMES) return COUNTRY_NAMES;
  const codes = 'AF AX AL DZ AS AD AO AI AQ AG AR AM AW AU AT AZ BS BH BD BB BY BE BZ BJ BM BT BO BQ BA BW BV BR IO BN BG BF BI KH CM CA CV KY CF TD CL CN CX CC CO KM CG CD CK CR CI HR CU CW CY CZ DK DJ DM DO EC EG SV GQ ER EE SZ ET FK FO FJ FI FR GF PF TF GA GM GE DE GH GI GR GL GD GP GU GT GG GN GW GY HT HM VA HN HK HU IS IN ID IR IQ IE IM IL IT JM JP JE JO KZ KE KI KP KR KW KG LA LV LB LS LR LY LI LT LU MO MG MW MY MV ML MT MH MQ MR MU YT MX FM MD MC MN ME MS MA MZ MM NA NR NP NL NC NZ NI NE NG NU NF MK MP NO OM PK PW PS PA PG PY PE PH PN PL PT PR QA RE RO RU RW BL SH KN LC MF PM VC WS SM ST SA SN RS SC SL SG SX SK SI SB SO ZA GS SS ES LK SD SR SJ SE CH SY TW TJ TZ TH TL TG TK TO TT TN TR TM TC TV UG UA AE GB US UM UY UZ VU VE VN VG VI WF EH YE ZM ZW'.split(' ');
  let names = null;
  for (const loc of [navigator.language, 'en']) { if (names || !loc) continue; try { names = new Intl.DisplayNames([loc], { type: 'region' }); } catch { names = null; } }
  COUNTRY_NAMES = codes.map((c) => { try { return (names && names.of(c)) || c; } catch { return c; } }).sort((a, b) => a.localeCompare(b));
  return COUNTRY_NAMES;
}
function countryPicker(input) {
  if (!input || input.type === 'hidden') return;
  const NAMES = countryNames();
  const wrap = document.createElement('div'); wrap.className = 'cs';
  input.parentNode.insertBefore(wrap, input); wrap.appendChild(input); input.type = 'hidden';
  const trigger = document.createElement('button'); trigger.type = 'button'; trigger.className = 'cs-trigger'; trigger.setAttribute('aria-haspopup', 'listbox'); trigger.setAttribute('aria-expanded', 'false');
  const value = document.createElement('span'); value.className = 'cs-value'; const chev = document.createElement('span'); chev.className = 'cs-chev'; chev.setAttribute('aria-hidden', 'true');
  trigger.append(value, chev);
  const pop = document.createElement('div'); pop.className = 'cs-pop'; pop.hidden = true;
  const search = document.createElement('input'); search.type = 'text'; search.className = 'cs-search'; search.autocomplete = 'off'; search.placeholder = 'Type to search…'; search.setAttribute('aria-label', 'Search countries');
  const list = document.createElement('ul'); list.className = 'cs-list'; list.setAttribute('role', 'listbox');
  pop.append(search, list); wrap.append(trigger, pop);
  let active = -1, rows = [];
  const setValue = (name) => { input.value = name || ''; value.textContent = name || 'Choose a country'; value.classList.toggle('ph', !name); };
  const setActive = (i, center) => {
    if (active >= 0 && rows[active]) rows[active].classList.remove('active');
    active = i; if (active >= 0 && rows[active]) { rows[active].classList.add('active'); rows[active].scrollIntoView({ block: center ? 'center' : 'nearest' }); }
  };
  const render = (q) => {
    q = (q || '').trim().toLowerCase(); list.innerHTML = ''; rows = []; active = -1;
    for (const n of NAMES) {
      if (q && !n.toLowerCase().includes(q)) continue;
      const li = document.createElement('li'); li.setAttribute('role', 'option'); li.textContent = n;
      const on = n === input.value; li.setAttribute('aria-selected', on ? 'true' : 'false'); if (on) li.classList.add('on');
      li.addEventListener('mousedown', (e) => { e.preventDefault(); choose(n); });
      list.appendChild(li); rows.push(li);
    }
    if (!rows.length) { const e = document.createElement('li'); e.className = 'cs-empty'; e.textContent = 'No match'; list.appendChild(e); }
    const sel = rows.findIndex((li) => li.classList.contains('on')); setActive(sel >= 0 ? sel : (q ? 0 : -1), true);
  };
  const open = () => { if (!pop.hidden) return; pop.hidden = false; trigger.setAttribute('aria-expanded', 'true'); search.value = ''; render(''); search.focus(); };
  const close = (refocus) => { if (pop.hidden) return; pop.hidden = true; trigger.setAttribute('aria-expanded', 'false'); if (refocus) trigger.focus(); };
  const choose = (name) => { setValue(name); close(true); };
  trigger.onclick = () => (pop.hidden ? open() : close(true));
  trigger.onkeydown = (e) => { if (e.key === 'ArrowDown' || e.key === 'ArrowUp') { e.preventDefault(); open(); } };
  search.oninput = () => render(search.value);
  search.onkeydown = (e) => {
    if (e.key === 'ArrowDown') { e.preventDefault(); if (rows.length) setActive(Math.min(active + 1, rows.length - 1)); }
    else if (e.key === 'ArrowUp') { e.preventDefault(); if (rows.length) setActive(Math.max(active - 1, 0)); }
    else if (e.key === 'Enter') { e.preventDefault(); if (active >= 0 && rows[active]) choose(rows[active].textContent); }
    else if (e.key === 'Escape') { e.preventDefault(); close(true); }
    else if (e.key === 'Tab') close(false);
  };
  document.addEventListener('mousedown', (e) => { if (!wrap.contains(e.target)) close(false); });
  const exact = NAMES.find((n) => n.toLowerCase() === (input.value || '').trim().toLowerCase());
  setValue(exact || (input.value || '').trim());   // an existing free-text value is kept and shown until the operator picks
}

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
      <button class="btn btn-line btn-sm" type="button" id="ce-cancel">Cancel</button>
      ${c ? '<button class="btn btn-line btn-sm" type="button" id="ce-delete">Delete this contact</button>' : ''}</div>
    </form>
    <div id="ce-dups" class="ad-dups" hidden></div></div></div>`;
  countryPicker($('#ce-form').country);
  const del = $('#ce-delete');
  if (del) del.onclick = () => crmDelete(c.id, c.display_name, () => { pfClose(); if (cur.section === 'crm' && cur.sub === 'contacts') crmContacts().catch(() => {}); });
  $('#ce-x').onclick = () => c ? renderProfile('overview') : pfClose();
  $('#ce-cancel').onclick = () => c ? renderProfile('overview') : pfClose();
  $('#ce-form').onsubmit = async (e) => {
    e.preventDefault(); const f = new FormData(e.target);
    const p = { display_name: f.get('display_name'), status: f.get('status'), email: f.get('email'), phone: f.get('phone'),
      city: f.get('city'), country: f.get('country'), preferred_timezone: f.get('preferred_timezone'),
      preferred_language: f.get('preferred_language'), height_cm: f.get('height_cm') || null, goals: f.get('goals') };
    if (c) p.id = c.id;
    /* The database refuses a duplicate unless the caller says it knows. Ask here rather
       than letting the refusal arrive as an error: the operator usually wants the person
       who already exists, not a second copy of them. */
    const { data: dups } = await sb.rpc('crm_find_duplicates', { p_email: p.email || null, p_phone: p.phone || null, p_exclude: c ? c.id : null });
    if (dups && dups.length) {
      const box = $('#ce-dups');
      box.hidden = false;
      box.innerHTML = `<b>${dups.length === 1 ? 'Someone already has this' : 'These people already have this'} ${esc(dups[0].matched_on)}</b>
        <ul>${dups.map((d) => `<li><button type="button" class="ad-link" data-open-dup="${d.id}">${esc(d.display_name || 'Unnamed')}</button>
          <span class="ad-muted">${esc(d.email || d.phone || '')} · ${esc(d.status)}</span></li>`).join('')}</ul>
        <p class="ad-muted">Open that record instead, or save this one anyway — both will be flagged so you can merge them later.</p>
        <div class="actions"><button type="button" class="btn btn-line btn-sm" id="ce-anyway">Save anyway</button></div>`;
      box.querySelectorAll('[data-open-dup]').forEach((b) => b.onclick = () => openProfile(b.dataset.openDup, null, 'overview'));
      $('#ce-anyway').onclick = async () => { p.allow_duplicate = true; await saveContact(p, c); };
      return;
    }
    await saveContact(p, c);
  };
  async function saveContact(p, c) {
    const { data, error } = await sb.rpc('crm_save_contact', { p }); if (error) return fail(error);
    toast(c ? 'Profile saved' : 'Contact created');
    pf = { crmId: data.id, enquiryId: null, contact: data, enquiry: null, section: 'overview' };
    renderProfile('overview');
    if (cur.section === 'crm' && cur.sub === 'contacts') { /* refresh list underneath */ crmContacts().catch(() => {}); }
  }
}

boot().catch(fail);

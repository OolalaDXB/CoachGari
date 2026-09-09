/* =============================================================
   CG-010 — the client consent page (/consent?t=<token>).
   External, not inline: the Content-Security-Policy allows no
   inline script, so an inline block never runs.
   ============================================================= */
import { CONFIG } from '/config.js';

const $ = (id) => document.getElementById(id);
const show = (id) => { for (const s of ['loading','error','notice','done']) $(s).hidden = (s !== id); };
const token = new URLSearchParams(location.search).get('t') || new URLSearchParams(location.search).get('token') || '';
const endpoint = CONFIG.CONSENT_ENDPOINT;

function fail(title, msg) { $('err-title').textContent = title; $('err-msg').textContent = msg || ''; show('error'); }

async function api(action, extra) {
  const res = await fetch(endpoint, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ action, token, ...extra }),
  });
  let data = {}; try { data = await res.json(); } catch {}
  return { res, data };
}

function renderNotice(first, notice) {
  $('n-title').textContent = notice.title || 'Progress tracking consent';
  $('n-ver').textContent = 'Notice version ' + (notice.notice_version || '');
  $('n-greeting').textContent = first ? ('Hello ' + first + ',') : 'Hello,';
  $('n-purpose').textContent = notice.purpose || '';
  const ul = $('n-data'); ul.textContent = '';
  (notice.data || []).forEach((d) => { const li = document.createElement('li'); li.textContent = d; ul.appendChild(li); });
  $('n-access').textContent = notice.access || '';
  $('n-retention').textContent = notice.retention || '';
  $('n-withdraw').textContent = notice.withdraw || '';
  $('n-rights').textContent = notice.rights || '';
  $('n-disclaimer').textContent = notice.disclaimer || '';
  $('n-contact').textContent = notice.contact ? ('Questions or requests: ' + notice.contact) : '';
  show('notice');
}

let busy = false;
async function submit(decision) {
  if (busy) return; busy = true;
  $('btn-agree').disabled = true; $('btn-decline').disabled = true;
  const { res, data } = await api('submit', { decision });
  busy = false;
  if (!res.ok || !data.ok) {
    if (res.status === 410) return fail('This link has expired', 'This consent link has already been used or has expired. Please ask your coach for a new one.');
    return fail('Something went wrong', 'Please try again, or ask your coach for a new link.');
  }
  if (decision === 'accept') {
    $('done').className = 'card state ok';
    $('done-title').textContent = 'Thank you, your consent is recorded';
    $('done-msg').textContent = 'Your coach can now record your fitness progress. You can withdraw at any time by asking your coach.';
  } else {
    $('done').className = 'card state';
    $('done-title').textContent = 'Noted: no progress tracking';
    $('done-msg').textContent = 'We have recorded that you do not want progress tracking. Your coaching continues as normal.';
  }
  show('done');
}

async function init() {
  if (!endpoint) return fail('Unavailable', 'Consent is not configured.');
  if (!/^[0-9a-f]{64}$/.test(token)) return fail('This link is not valid', 'The link looks incomplete. Please open it exactly as your coach sent it.');
  const { res, data } = await api('view', {});
  if (!res.ok || !data.ok) {
    if (res.status === 410) return fail('This link has expired', 'This consent link has already been used or has expired. Please ask your coach for a new one.');
    if (res.status === 404) return fail('This link is not valid', 'Please ask your coach for a new link.');
    return fail('Something went wrong', 'Please try again shortly.');
  }
  renderNotice(data.first_name, data.notice || {});
  $('agree-box').addEventListener('change', (e) => { $('btn-agree').disabled = !e.target.checked; });
  $('btn-agree').addEventListener('click', () => { if ($('agree-box').checked) submit('accept'); });
  $('btn-decline').addEventListener('click', () => submit('decline'));
}

init().catch(() => fail('Something went wrong', 'Please try again shortly.'));

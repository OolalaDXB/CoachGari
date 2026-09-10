/* Collaborate with Coach Gari — public intake.
   Posts one enquiry to CONFIG.COLLAB_ENDPOINT (action "intake"), then shows the
   private collaboration room link. No prices, no PII in analytics. */
import { CONFIG } from '/config.js';

const form = document.querySelector('[data-collab]');
const statusEl = document.querySelector('.form-status');
const live = document.querySelector('.cl-live');
const done = document.querySelector('.cl-done');
const pageLoadedAt = Date.now();
let inFlight = false;

function say(msg, cls) { statusEl.textContent = msg || ''; statusEl.className = 'form-status ' + (cls || ''); }
const val = (n) => (form.elements[n] ? String(form.elements[n].value || '').trim() : '');

if (window.plausible) try { window.plausible('collaboration_form_opened'); } catch { /* ignore */ }

form.addEventListener('submit', async (e) => {
  e.preventDefault();
  if (inFlight) return;
  if (!CONFIG.COLLAB_ENDPOINT) { say('This form is not available right now. Please email Coach Gari.', 'err'); return; }

  const name = val('name');
  const email = val('email');
  const phone = val('phone');
  if (!name) { say('Please add your name.', 'err'); form.elements.name.focus(); return; }
  if (!email && !phone) { say('Add an email or phone so Coach Gari can reply.', 'err'); form.elements.email.focus(); return; }

  const budgetRaw = val('budget');
  const budget = budgetRaw ? Math.round(Number(budgetRaw) * 100) : null;   // major units → minor
  const payload = {
    action: 'intake', ts: pageLoadedAt, website: val('website'),
    name, company: val('company'), email, phone, url: val('url'),
    type: val('type'), title: val('title'), initial_request: val('initial_request'),
    date_from: val('date_from'), date_to: val('date_to'), location: val('location'),
    budget_amount: Number.isFinite(budget) && budget >= 0 ? budget : null,
    budget_currency: val('budget_currency') || null, offer: val('offer'),
  };

  inFlight = true; say('Sending…');
  try {
    const res = await fetch(CONFIG.COLLAB_ENDPOINT, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(payload) });
    let data = {}; try { data = await res.json(); } catch { /* ignore */ }
    if (res.status === 200 && data.ok && data.token) {
      if (window.plausible) try { window.plausible('collaboration_submitted'); } catch { /* ignore */ }
      const url = `${location.origin}/c/${data.token}`;
      document.querySelector('.cl-ref').textContent = data.public_ref || '';
      const room = document.querySelector('.cl-room'); room.value = url;
      live.style.display = 'none'; done.style.display = 'block';
      window.scrollTo({ top: 0, behavior: 'smooth' });
    } else if (res.status === 400 && data.error === 'validation') {
      say(data.message || 'Please check the highlighted fields.', 'err');
    } else if (res.status === 429) {
      say('Please try again in a little while.', 'err');
    } else {
      say('Something went wrong. Please try again, or email Coach Gari.', 'err');
    }
  } catch {
    say('Network error. Please try again.', 'err');
  } finally {
    inFlight = false;
  }
});

const copyBtn = document.querySelector('[data-copy]');
if (copyBtn) copyBtn.addEventListener('click', async () => {
  const room = document.querySelector('.cl-room');
  try { await navigator.clipboard.writeText(room.value); copyBtn.textContent = 'Copied'; setTimeout(() => (copyBtn.textContent = 'Copy'), 1500); }
  catch { room.select(); }
});

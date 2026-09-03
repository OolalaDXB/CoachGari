/* =============================================================
   Coach Gari — shared behaviour for every page.

   Reads everything it needs from /config.js, the single source
   of truth. Loaded as an ES module:
     <script type="module" src="/assets/site.js"></script>

   Responsibilities:
     1. Reveal-on-scroll (IntersectionObserver)
     2. SHOWCASE <-> SHOP toggle (CONFIG.COMMERCE)
     3. WhatsApp links built from CONFIG.WHATSAPP + button context
     4. First-touch attribution (UTM, referrer, landing page)
     5. Enquiry form -> CONFIG.FORM_ENDPOINT (idempotent, honeypot)
     6. Config-driven text / href injection (commission, links)

   Where a value in CONFIG is still empty, the page keeps its
   existing placeholder markup untouched — nothing breaks, it
   just isn't wired yet.
   ============================================================= */
import { CONFIG } from '/config.js';

/* ---- 1. reveal on scroll ---------------------------------- */
(function reveal(){
  var els = document.querySelectorAll('.reveal');
  if (window.matchMedia('(prefers-reduced-motion: reduce)').matches ||
      !('IntersectionObserver' in window)) {
    els.forEach(function(e){ e.classList.add('in'); });
    return;
  }
  var io = new IntersectionObserver(function(entries){
    entries.forEach(function(e){
      if (e.isIntersecting) { e.target.classList.add('in'); io.unobserve(e.target); }
    });
  }, { threshold: .08 });
  els.forEach(function(e){ io.observe(e); });
})();

/* ---- 2. showcase <-> shop --------------------------------- */
/* false = vitrine: no prices, every CTA goes to the form.
   true  = boutique: prices shown, buy buttons use data-checkout.
   To switch on payments: set COMMERCE:true in config.js and
   paste each product's Payment Link into its data-checkout.     */
(function commerce(){
  var items = document.querySelectorAll('.item');
  if (!items.length) return;

  items.forEach(function(item){
    var priceEl = item.querySelector('.price');
    var buyEl   = item.querySelector('.buy');
    var isFeat  = item.classList.contains('feat');
    if (!priceEl || !buyEl) return;

    if (CONFIG.COMMERCE) {
      priceEl.className = 'price';
      priceEl.innerHTML = item.dataset.price + ' <small>' + item.dataset.unit + '</small>';
      buyEl.innerHTML =
        '<a class="btn btn-full btn-sm ' + (isFeat ? 'btn-accent' : 'btn-soft') + '" href="' +
        (item.dataset.checkout || '#enquiry') + '">' +
        (isFeat ? 'Start coaching →' : 'Buy now') + '</a>';
    } else {
      priceEl.className = 'price enquire';
      priceEl.textContent = 'On request';
      buyEl.innerHTML =
        '<a class="btn btn-full btn-sm ' + (isFeat ? 'btn-accent' : 'btn-soft') +
        '" href="#enquiry">Enquire →</a>';
    }
  });

  if (CONFIG.COMMERCE) {
    document.querySelectorAll('[data-cta-main]').forEach(function(a){
      if (a.getAttribute('href') === '#enquiry') a.setAttribute('href', '#programmes');
    });
  }
})();

/* ---- 3. WhatsApp links ------------------------------------ */
/* Any element carrying data-wa becomes a wa.me link, with the
   attribute's text as the pre-filled message context. When
   CONFIG.WHATSAPP is empty the element keeps its existing href
   (a scroll anchor), so the page still works before the number
   is provided.                                                 */
(function whatsapp(){
  var els = document.querySelectorAll('[data-wa]');
  if (!els.length || !CONFIG.WHATSAPP) return;

  var num = String(CONFIG.WHATSAPP).replace(/[^0-9]/g, '');
  if (!num) return;

  els.forEach(function(el){
    var context = el.getAttribute('data-wa') || '';
    var text = context
      ? 'Hi Coach Gari — ' + context
      : 'Hi Coach Gari, I found you online.';
    el.setAttribute('href', 'https://wa.me/' + num + '?text=' + encodeURIComponent(text));
    el.setAttribute('rel', 'noopener');
    el.setAttribute('target', '_blank');
  });
})();

/* ---- 4. first-touch attribution --------------------------- */
/* Remembers where the visitor came from the first time they
   land, so the enquiry keeps its origin even after browsing.
   Stored in localStorage only; nothing leaves the browser until
   the visitor submits the form. Not an analytics system.        */
var FT_KEY = 'cg_first_touch';
var UTM_KEYS = ['utm_source', 'utm_medium', 'utm_campaign', 'utm_content', 'utm_term'];

function readParams(){
  var out = {};
  try {
    var q = new URLSearchParams(window.location.search);
    UTM_KEYS.forEach(function(k){ var v = q.get(k); if (v) out[k] = v.slice(0, 200); });
  } catch (e) {}
  return out;
}

function firstTouch(){
  var stored = null;
  try { stored = JSON.parse(localStorage.getItem(FT_KEY) || 'null'); } catch (e) {}
  if (stored && stored.first_visit_at) return stored;

  var ft = readParams();
  ft.referrer = (document.referrer || '').slice(0, 1000);
  ft.landing_page = (window.location.pathname + window.location.search).slice(0, 1000);
  ft.first_visit_at = new Date().toISOString();
  try { localStorage.setItem(FT_KEY, JSON.stringify(ft)); } catch (e) {}
  return ft;
}

var FIRST_TOUCH = firstTouch();

function attribution(){
  // First touch wins; UTMs present on the current URL fill any gaps.
  var now = readParams();
  var out = {};
  UTM_KEYS.forEach(function(k){ out[k] = FIRST_TOUCH[k] || now[k] || null; });
  out.referrer = FIRST_TOUCH.referrer || null;
  out.landing_page = FIRST_TOUCH.landing_page || null;
  out.first_visit_at = FIRST_TOUCH.first_visit_at || null;
  return out;
}

/* ---- 5. enquiry form -------------------------------------- */
function newId(){
  if (window.crypto && crypto.randomUUID) return crypto.randomUUID();
  return 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'.replace(/[xy]/g, function(c){
    var r = Math.random() * 16 | 0; return (c === 'x' ? r : (r & 0x3 | 0x8)).toString(16);
  });
}

(function enquiry(){
  var form = document.querySelector('form[data-enquiry]');
  if (!form) return;

  var status = form.querySelector('.form-status');
  var btn = form.querySelector('button[type="submit"]');
  var pageLoadedAt = Date.now();
  var submissionId = newId(); // one id per form fill → double click / retry can't create two rows
  var inFlight = false;

  function say(msg, cls){
    if (!status) return;
    status.textContent = msg;
    status.className = 'form-status ' + (cls || '');
  }

  form.addEventListener('submit', function(e){
    e.preventDefault();
    if (inFlight) return;

    if (!CONFIG.FORM_ENDPOINT) {
      say('The form isn’t connected yet. Reach Coach Gari on WhatsApp in the meantime.', 'err');
      return;
    }

    var fields = Object.fromEntries(new FormData(form).entries());
    var payload = {
      submission_id: submissionId,
      ts: pageLoadedAt,
      name: fields.name || '',
      contact: fields.contact || fields.email || '',
      location: fields.location || '',
      interest: fields.interest || '',
      message: fields.detail || fields.message || '',
      website: fields.website || '',          // honeypot — humans never see it
      page: window.location.pathname,
      attribution: attribution(),
    };

    inFlight = true;
    if (btn) btn.disabled = true;
    say('Sending…');

    fetch(CONFIG.FORM_ENDPOINT, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(payload),
    })
    .then(function(r){ return r.json().then(function(j){ return { status: r.status, body: j }; }); })
    .then(function(res){
      if (res.status === 200 && res.body && res.body.ok) {
        form.reset();
        submissionId = newId(); // next enquiry gets a fresh id
        say('Thanks — that’s with Coach Gari. You’ll hear back soon.', 'ok');
        return;
      }
      if (res.status === 400 && res.body && res.body.error === 'validation') {
        var f = res.body.fields || [];
        say(f.indexOf('contact') !== -1
          ? 'Add an email or WhatsApp number so Coach Gari can reply.'
          : 'Add your name so Coach Gari knows who’s asking.', 'err');
        return;
      }
      if (res.status === 429) {
        say('Too many messages in a row — give it a few minutes, or message on WhatsApp.', 'err');
        return;
      }
      throw new Error('status ' + res.status);
    })
    .catch(function(){
      say('Something went wrong sending that. Try again, or message on WhatsApp.', 'err');
    })
    .finally(function(){ inFlight = false; if (btn) btn.disabled = false; });
  });
})();

/* ---- 6. config-driven text / href ------------------------- */
/* <span data-config="COMMISSION_RATE">__ %</span> -> replaced when set.
   <a data-config-href="STUDIO_URL" href="#">    -> href set when present. */
(function inject(){
  document.querySelectorAll('[data-config]').forEach(function(el){
    var key = el.getAttribute('data-config');
    if (CONFIG[key]) el.textContent = CONFIG[key];
  });
  document.querySelectorAll('[data-config-href]').forEach(function(el){
    var key = el.getAttribute('data-config-href');
    if (CONFIG[key]) el.setAttribute('href', CONFIG[key]);
  });
})();

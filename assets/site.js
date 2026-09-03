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

/* ---- country search ---------------------------------------- */
/* <datalist data-countries> is filled from ISO 3166-1 alpha-2 codes,
   named in the visitor's language by Intl.DisplayNames (no list of
   names to maintain, nothing fetched). The visitor types to search;
   on submit the value must match one of those names. The form still
   sends one "City, Country" string, so the backend is unchanged.  */
var COUNTRY_NAMES = [];
(function countries(){
  var lists = document.querySelectorAll('[data-countries]');
  if (!lists.length) return;
  var codes = ('AF AX AL DZ AS AD AO AI AQ AG AR AM AW AU AT AZ BS BH BD BB BY BE BZ BJ BM BT BO BQ BA BW BV BR IO BN BG BF BI KH CM CA CV KY CF TD CL CN CX CC CO KM CG CD CK CR CI HR CU CW CY CZ DK DJ DM DO EC EG SV GQ ER EE SZ ET FK FO FJ FI FR GF PF TF GA GM GE DE GH GI GR GL GD GP GU GT GG GN GW GY HT HM VA HN HK HU IS IN ID IR IQ IE IM IL IT JM JP JE JO KZ KE KI KP KR KW KG LA LV LB LS LR LY LI LT LU MO MG MW MY MV ML MT MH MQ MR MU YT MX FM MD MC MN ME MS MA MZ MM NA NR NP NL NC NZ NI NE NG NU NF MK MP NO OM PK PW PS PA PG PY PE PH PN PL PT PR QA RE RO RU RW BL SH KN LC MF PM VC WS SM ST SA SN RS SC SL SG SX SK SI SB SO ZA GS SS ES LK SD SR SJ SE CH SY TW TJ TZ TH TL TG TK TO TT TN TR TM TC TV UG UA AE GB US UM UY UZ VU VE VN VG VI WF EH YE ZM ZW').split(' ');
  var names;
  try { names = new Intl.DisplayNames([navigator.language || 'en', 'en'], { type: 'region' }); } catch (e) { names = null; }
  COUNTRY_NAMES = codes.map(function(c){
    var n = c; try { n = (names && names.of(c)) || c; } catch (e) {}
    return n;
  }).sort(function(a, b){ return a.localeCompare(b); });
  lists.forEach(function(list){
    var frag = document.createDocumentFragment();
    COUNTRY_NAMES.forEach(function(n){ var o = document.createElement('option'); o.value = n; frag.appendChild(o); });
    list.appendChild(frag);
  });
})();

function matchCountry(value){
  var v = String(value || '').trim().toLowerCase();
  if (!v) return null;
  for (var i = 0; i < COUNTRY_NAMES.length; i++) if (COUNTRY_NAMES[i].toLowerCase() === v) return COUNTRY_NAMES[i];
  var starts = COUNTRY_NAMES.filter(function(n){ return n.toLowerCase().indexOf(v) === 0; });
  return starts.length === 1 ? starts[0] : null;   // a unique prefix ("zimb") is accepted and normalised
}

/* ---- travel / waitlist CTAs -------------------------------- */
/* "Join the list", "Tell me where" and the footer email box all
   lead to the ONE enquiry form: scroll there, preselect the
   "Live event near me" interest, switch the location prompt to
   "Where should Gari come next?", focus the city field. The
   source is kept in the submission (page ?entry_point=…) without
   touching first-touch UTM attribution. Reached organically, the
   form is untouched.                                            */
(function travel(){
  var form = document.querySelector('form[data-enquiry]');
  if (!form) return;
  var city = form.querySelector('#f-city');
  var country = form.querySelector('#f-country');
  var contact = form.querySelector('[name="contact"]');
  var interest = form.querySelector('select[name="interest"]');
  var cityLabel = form.querySelector('label[for="f-city"]');
  var defaults = {
    label: cityLabel ? cityLabel.textContent : '',
    cityPh: city ? city.placeholder : '',
    countryPh: country ? country.placeholder : '',
    interest: interest ? interest.value : ''
  };

  function enter(source, email){
    form.dataset.entryPoint = source;
    if (interest) {
      for (var i = 0; i < interest.options.length; i++) {
        if (/live event near me/i.test(interest.options[i].text)) { interest.selectedIndex = i; break; }
      }
    }
    if (cityLabel) cityLabel.textContent = 'Where should Gari come next?';
    if (city) city.placeholder = 'City';
    if (country) country.placeholder = 'Country';
    if (email && contact && !contact.value) contact.value = email;
    var target = document.getElementById('enquiry') || form;
    target.scrollIntoView({ behavior: 'smooth', block: 'start' });
    if (city) setTimeout(function(){ city.focus({ preventScroll: true }); }, 450);
  }

  form.resetTravel = function(){
    delete form.dataset.entryPoint;
    if (cityLabel) cityLabel.textContent = defaults.label;
    if (city) city.placeholder = defaults.cityPh;
    if (country) country.placeholder = defaults.countryPh;
  };

  document.querySelectorAll('[data-travel]').forEach(function(a){
    a.addEventListener('click', function(e){ e.preventDefault(); enter(a.getAttribute('data-travel')); });
  });
  document.querySelectorAll('form[data-travel-form]').forEach(function(f){
    f.addEventListener('submit', function(e){
      e.preventDefault();
      var input = f.querySelector('input');
      enter(f.getAttribute('data-travel-form'), input ? input.value.trim() : '');
      f.reset();
    });
  });
})();

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
    var countryEl = form.querySelector('[data-country-input]');
    if (countryEl && COUNTRY_NAMES.length) {
      var matched = matchCountry(countryEl.value);
      if (!matched) {
        say('Pick your country from the list as you type.', 'err');
        countryEl.focus();
        return;
      }
      countryEl.value = matched; fields.country = matched;
    }
    var payload = {
      submission_id: submissionId,
      ts: pageLoadedAt,
      name: fields.name || '',
      contact: fields.contact || fields.email || '',
      location: fields.location || [fields.city, fields.country].filter(Boolean).map(function(v){ return String(v).trim(); }).join(', '),
      interest: fields.interest || '',
      message: fields.detail || fields.message || '',
      website: fields.website || '',          // honeypot — humans never see it
      page: window.location.pathname + (form.dataset.entryPoint ? '?entry_point=' + encodeURIComponent(form.dataset.entryPoint) : ''),
      attribution: attribution(),
    };
    var travelEntry = form.dataset.entryPoint || '';
    if (travelEntry) payload.attribution.entry_point = travelEntry;

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
        say(travelEntry
          ? 'You’re on the list. If enough people ask for your city, Gari may bring a session there.'
          : 'Thanks — that’s with Coach Gari. You’ll hear back soon.', 'ok');
        if (travelEntry && form.resetTravel) form.resetTravel();
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

/* ---- 6b. Plausible — aggregate website analytics ----------- */
/* Loads the official Plausible script only when
   CONFIG.PLAUSIBLE_DOMAIN is set. Cookie-free, no personal data.
   The first-touch attribution above remains the conversion source;
   Plausible is for aggregate traffic only.                       */
(function plausible(){
  if (!CONFIG.PLAUSIBLE_DOMAIN) return;
  var s = document.createElement('script');
  s.defer = true;
  s.setAttribute('data-domain', CONFIG.PLAUSIBLE_DOMAIN);
  s.src = 'https://plausible.io/js/script.js';
  document.head.appendChild(s);
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

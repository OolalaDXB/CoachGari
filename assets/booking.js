/* =============================================================
   Coach Gari — booking flow (CG-002 / CG-003)
   family → (child) → date → slot → details → hold (recap + price) → payment → confirmation

   Talks only to CONFIG.BOOKING_ENDPOINT (public Edge Function) and,
   for paid services, CONFIG.CHECKOUT_ENDPOINT. Nothing here decides
   price, duration or capacity — the server does. Times are shown in
   the visitor's timezone; the session timezone is always displayed.
   ============================================================= */
import { CONFIG } from '/config.js';

var root = document.querySelector('[data-booking]');
if (root && CONFIG.BOOKING_ENDPOINT) init();

function uuid(){
  if (window.crypto && crypto.randomUUID) return crypto.randomUUID();
  return 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'.replace(/[xy]/g, function(c){
    var r = Math.random() * 16 | 0; return (c === 'x' ? r : (r & 0x3 | 0x8)).toString(16);
  });
}
function el(tag, attrs, children){
  var e = document.createElement(tag);
  if (attrs) Object.keys(attrs).forEach(function(k){
    if (k === 'class') e.className = attrs[k];
    else if (k === 'text') e.textContent = attrs[k];
    else if (k === 'html') e.innerHTML = attrs[k];
    else e.setAttribute(k, attrs[k]);
  });
  (children || []).forEach(function(c){ if (c) e.appendChild(typeof c === 'string' ? document.createTextNode(c) : c); });
  return e;
}
function api(path, opts){
  return fetch(CONFIG.BOOKING_ENDPOINT + (path || ''), opts).then(function(r){
    return r.json().then(function(j){ return { status: r.status, body: j }; });
  });
}
function money(amount, currency){
  // Always the server's amount (minor units) — "100 USD", "12.50 USD". Never a frontend constant.
  if (amount === null || amount === undefined) return 'On request';
  var units = amount / 100;
  return (Number.isInteger(units) ? String(units) : units.toFixed(2)) + ' ' + currency;
}
function fmtTime(iso, tz){
  try { return new Intl.DateTimeFormat(undefined, { hour: '2-digit', minute: '2-digit', timeZone: tz }).format(new Date(iso)); }
  catch (e) { return iso.slice(11, 16); }
}
function fmtDateTime(iso, tz){
  try { return new Intl.DateTimeFormat(undefined, { weekday: 'short', day: 'numeric', month: 'short', hour: '2-digit', minute: '2-digit', timeZone: tz, timeZoneName: 'short' }).format(new Date(iso)); }
  catch (e) { return iso; }
}
function fmtDate(iso, tz){
  try { return new Intl.DateTimeFormat(undefined, { weekday: 'long', day: 'numeric', month: 'long', timeZone: tz }).format(new Date(iso)); }
  catch (e) { return iso.slice(0, 10); }
}
function todayPlus(days){
  var d = new Date(); d.setDate(d.getDate() + days);
  return d.toISOString().slice(0, 10);
}

function init(){
  var tz = (Intl.DateTimeFormat().resolvedOptions().timeZone) || 'UTC';
  var state = { services: [], tourStops: [], family: null, choice: null, service: null, date: todayPlus(1), slots: [], slot: null, slotsSeq: 0, key: uuid(), booking: null };
  var reduceMotion = !!(window.matchMedia && window.matchMedia('(prefers-reduced-motion: reduce)').matches);

  /* Public booking hierarchy: what the customer chooses first, then optionally a child choice, then
     availability. A family either IS a bookable service (final) or reveals children that are. This is
     the page's information architecture — it does not mirror catalogue rows one-to-one — and it holds
     nothing commercial: no price, no currency, no duration. A family (or child) whose canonical
     service is not bookable right now is simply not offered. Adding a child under any family later
     does not add a top-level choice. */
  var FAMILIES = [
    { key: 'conversation',      label: 'The Conversation', context: 'Online', service: 'conversation' },
    { key: 'personal-training', label: 'Personal training', children: [
        { key: 'personal-training-in-person', label: 'In person', context: 'Dubai', service: 'personal-training-dubai' },
        { key: 'personal-training-online',    label: 'Online',                     service: 'personal-training-online' } ] },
    { key: 'padel',             label: 'Padel',            context: 'Dubai',  children: [
        { key: 'padel-one-to-one', label: 'One-to-one',   service: 'padel-one-to-one' },
        { key: 'padel-group',      label: 'Group session', service: 'padel-group-session' } ] },
  ];

  var status = el('p', { class: 'bk-status', role: 'status', 'aria-live': 'polite' });
  var stepService = el('div', { class: 'bk-step' });
  var stepDate = el('div', { class: 'bk-step' });
  var stepSlots = el('div', { class: 'bk-step' });
  var stepForm = el('div', { class: 'bk-step' });
  var stepDone = el('div', { class: 'bk-step bk-done' });
  root.appendChild(stepService); root.appendChild(stepDate); root.appendChild(stepSlots);
  root.appendChild(stepForm); root.appendChild(stepDone); root.appendChild(status);

  function say(msg, cls){ status.textContent = msg || ''; status.className = 'bk-status ' + (cls || ''); }
  function after(ms, fn){ if (reduceMotion) fn(); else setTimeout(fn, ms); }
  function nextFrame(fn){ if (reduceMotion) fn(); else requestAnimationFrame(function(){ requestAnimationFrame(fn); }); }

  /* A bearer token must not linger in the address bar, the history entry or the Referer
     header sent to any third party the page loads. Capture it, then rewrite the URL. */
  function scrubUrl(){
    try {
      var u = new URL(window.location.href), hit = false;
      ['t', 'token', 'access_token', 'manage_token', 'session_id', 'session', 'paid'].forEach(function(k){
        if (u.searchParams.has(k)) { u.searchParams.delete(k); hit = true; }
      });
      if (hit && window.history && history.replaceState) {
        var s = u.searchParams.toString();
        history.replaceState(null, '', u.pathname + (s ? '?' + s : '') + u.hash);
      }
    } catch (e) { /* a URL we cannot parse is one we cannot leak from */ }
  }

  // Returning from payment? ?booking=REF&t=TOKEN
  var q = new URLSearchParams(window.location.search);
  if (q.get('booking') && q.get('t')) {
    // Capture the manage token, then strip it from the address bar, history and any
    // outgoing Referer before anything else runs. Polling continues from memory.
    var bkRef = q.get('booking'), bkTok = q.get('t');
    scrubUrl();
    [stepService, stepDate, stepSlots, stepForm].forEach(function(s){ s.hidden = true; });
    pollState(bkRef, bkTok);
    return;
  }

  /* Catalogue load. Three outcomes, never confused:
       - API answered 200 with bookable services → picker
       - API answered 200 with none bookable     → "opens soon"   (a real catalogue state)
       - API error / network error               → "temporarily unavailable", after one retry,
         and always console.error('booking_init_failed: <reason>') so a regression
         is diagnosable from the browser. */
  function loadCatalogue(attempt){
    say('Loading…');
    return Promise.all([api('?action=bookable'), api('?action=tour_stops')]).then(function(res){
      var bad = res.find(function(r){ return r.status !== 200 || !r.body || r.body.ok === false; });
      if (bad) {
        throw new Error('http ' + bad.status + (bad.body && bad.body.error ? ' ' + bad.body.error : '') + (bad.body && bad.body.code ? ' (' + bad.body.code + ')' : ''));
      }
      state.services = res[0].body.services || [];
      state.tourStops = res[1].body.tour_stops || [];
      if (!offered().length) {
        console.warn('booking_init_failed: no_active_services (API reachable, nothing bookable)');
        say('Booking opens soon. Message on WhatsApp in the meantime.', 'err');
        return;
      }
      say('');
      renderServices();
      preselectFamily();
    }).catch(function(e){
      var reason = (e && e.message) || 'network_error';
      if (attempt < 2) { console.warn('booking_init_retry: ' + reason); return new Promise(function(r){ setTimeout(r, 1500); }).then(function(){ return loadCatalogue(attempt + 1); }); }
      console.error('booking_init_failed: ' + reason + ' — endpoint ' + CONFIG.BOOKING_ENDPOINT);
      say('Booking is temporarily unavailable. Message Coach Gari on WhatsApp in the meantime.', 'err');
    });
  }
  loadCatalogue(1);

  function svc(slug){ for (var i = 0; i < state.services.length; i++) if (state.services[i].slug === slug) return state.services[i]; return null; }
  // the families the catalogue can honour right now, in the fixed order
  function offered(){
    return FAMILIES.map(function(f){
      if (f.children) {
        var kids = f.children.filter(function(c){ return !!svc(c.service); });
        return kids.length ? { key: f.key, label: f.label, context: f.context, children: kids } : null;
      }
      return svc(f.service) ? f : null;
    }).filter(Boolean);
  }

  var levelHost = null, tourHost = null, busy = false;
  /* A deep link such as #personal-training (resolved by site.js to #book + data-book-family)
     opens the picker on that family, as if the customer had chosen it. Only from the root state. */
  function preselectFamily(){
    var key = document.documentElement.getAttribute('data-book-family');
    if (!key || !levelHost) return;
    document.documentElement.removeAttribute('data-book-family');
    if (state.family) return;
    var b = levelHost.querySelector('[data-choice="' + key + '"]');
    if (b) b.click();
  }
  window.addEventListener('hashchange', function(){ preselectFamily(); });
  function renderServices(){
    stepService.innerHTML = '';
    stepService.appendChild(el('h4', { text: '1. What do you want to book?' }));
    levelHost = el('div', { class: 'bk-level' });
    stepService.appendChild(levelHost);
    tourHost = el('div');
    stepService.appendChild(tourHost);
    renderFamilies();
  }
  function choiceButton(item, onPick){
    var b = el('button', { type: 'button', class: 'bk-service', 'data-choice': item.key, 'aria-pressed': 'false' }, [
      el('b', { text: item.label }),
      item.context ? el('span', { text: item.context }) : null,
    ]);
    b.addEventListener('click', onPick);
    return b;
  }
  function mark(b, on){ b.classList.toggle('on', on); b.setAttribute('aria-pressed', on ? 'true' : 'false'); }
  function clearBelow(){ stepDate.innerHTML = ''; stepSlots.innerHTML = ''; stepForm.innerHTML = ''; stepDone.innerHTML = ''; tourHost.innerHTML = ''; }

  /* Level 0: exactly the top-level families. One state machine:
       root                → the three choices
       select(family)      → the other choices collapse out of the layout (opacity + width, one easing),
                             the chosen one stays as the current context with a Back control;
                             a final family goes straight to the day / time steps, a family with
                             children slides them in from the right
       back()              → the reverse, without a reload; the day already picked is kept
     The context button itself is a second way back. Nothing here is re-bound: each render creates
     fresh buttons, and `busy` ignores clicks during a transition. */
  function renderFamilies(focusKey){
    levelHost.innerHTML = '';
    var list = el('div', { class: 'bk-services', role: 'group', 'aria-label': 'What do you want to book?' });
    offered().forEach(function(f){
      var b = choiceButton(f, function(){ if (state.family && state.family.key === f.key) back(); else select(f, b, list); });
      if (f.children) b.setAttribute('aria-expanded', 'false');
      list.appendChild(b);
    });
    levelHost.appendChild(list);
    if (focusKey) { var t = list.querySelector('[data-choice="' + focusKey + '"]'); if (t) t.focus(); }
  }

  function select(f, btn, list){
    if (busy || state.family) return;
    busy = true;
    state.family = f; state.choice = null; state.service = null; state.slot = null; state.slotsSeq++;
    clearBelow(); say('');
    btn.classList.add('ctx'); mark(btn, true);
    if (f.children) btn.setAttribute('aria-expanded', 'true');
    var siblings = Array.prototype.filter.call(list.querySelectorAll('.bk-service'), function(c){ return c !== btn; });
    siblings.forEach(function(c){ c.classList.add('bk-out'); c.setAttribute('tabindex', '-1'); c.setAttribute('aria-hidden', 'true'); });
    after(320, function(){
      siblings.forEach(function(c){ c.hidden = true; });
      var view = el('div', { class: 'bk-children' + (reduceMotion ? '' : ' bk-enter') });
      if (f.children) {
        var group = el('div', { class: 'bk-services', role: 'group', 'aria-label': f.label + ' — which session?' });
        f.children.forEach(function(c){
          var b = choiceButton(c, function(){ pickChild(f, c, b, group); });
          group.appendChild(b);
        });
        view.appendChild(group);
      }
      var backBtn = el('button', { type: 'button', class: 'bk-back', text: '← Back', 'aria-label': 'Back to all sessions' });
      backBtn.addEventListener('click', back);
      view.appendChild(backBtn);
      levelHost.appendChild(view);
      nextFrame(function(){ view.classList.remove('bk-enter'); });
      busy = false;
      if (f.children) {
        say(f.label + ': choose ' + f.children.map(function(c){ return c.label.toLowerCase(); }).join(' or ') + '.');
        var first = view.querySelector('.bk-service'); if (first) first.focus();
      } else {
        state.choice = f; state.service = svc(f.service);
        renderTour(); renderDate(); loadSlots();
      }
    });
  }

  // a child choice: the canonical service is known → availability may load now
  function pickChild(f, item, btn, group){
    Array.prototype.forEach.call(group.querySelectorAll('.bk-service'), function(c){ mark(c, c === btn); });
    state.choice = item; state.service = svc(item.service); state.slot = null;
    say('');
    renderTour(); renderDate(); loadSlots();
  }

  // back to the three top-level choices; reverses the transition, keeps the date the customer picked
  function back(){
    if (busy || !state.family) return;
    busy = true;
    var f = state.family;
    var view = levelHost.querySelector('.bk-children');
    var list = levelHost.querySelector('.bk-services');
    state.family = null; state.choice = null; state.service = null; state.slot = null; state.slotsSeq++;
    clearBelow(); say('');
    if (view) view.classList.add('bk-enter');
    after(220, function(){
      if (view) view.remove();
      Array.prototype.forEach.call(list.querySelectorAll('.bk-service'), function(c){
        c.classList.remove('ctx'); mark(c, false); c.removeAttribute('aria-hidden'); c.removeAttribute('tabindex');
        if (c.getAttribute('data-choice') === f.key && f.children) c.setAttribute('aria-expanded', 'false');
        c.hidden = false;
      });
      nextFrame(function(){ Array.prototype.forEach.call(list.querySelectorAll('.bk-service'), function(c){ c.classList.remove('bk-out'); }); });
      var t = list.querySelector('[data-choice="' + f.key + '"]'); if (t) t.focus();
      after(320, function(){ busy = false; });
    });
  }

  // "Gari on tour": context for the chosen service only — never a top-level choice
  function renderTour(){
    tourHost.innerHTML = '';
    if (!state.service) return;
    var stops = state.tourStops.filter(function(t){ return t.services.indexOf(state.service.slug) !== -1; });
    if (!stops.length) return;
    var tour = el('div', { class: 'bk-tour' }, [el('h4', { text: 'Gari on tour' })]);
    stops.forEach(function(t){
      tour.appendChild(el('div', { class: 'bk-tourstop' }, [
        el('b', { text: t.city + ', ' + t.country }),
        el('span', { text: fmtDate(t.start_at, t.timezone) + ' → ' + fmtDate(t.end_at, t.timezone) + ' · ' + t.timezone + (t.venue ? ' · ' + t.venue : '') }),
        t.location_notes ? el('em', { text: t.location_notes }) : null,
      ]));
    });
    tourHost.appendChild(tour);
  }

  function renderDate(){
    stepDate.innerHTML = '';
    if (!state.service) return;
    stepDate.appendChild(el('h4', { text: '2. Pick a day' }));
    var input = el('input', { type: 'date', class: 'bk-date', min: todayPlus(0), max: todayPlus(60), value: state.date });
    input.addEventListener('change', function(){ state.date = input.value; state.slot = null; loadSlots(); });
    stepDate.appendChild(input);
    stepDate.appendChild(el('p', { class: 'bk-note', text: 'Times shown in your timezone (' + tz + ').' }));
  }

  function where(s){ return s.tour_stop_id ? s.city + ', ' + s.country + ' (' + s.session_timezone + ')' : (state.service.delivery_mode === 'online' ? 'Online' : 'In person') + ' · ' + s.session_timezone; }

  /* Availability loads only once a FINAL service is chosen, and exactly one outcome is ever on screen:
     free times, "nothing free", or an error with a retry — never times next to an error, never times
     from an earlier choice (a request superseded by a newer choice is dropped when it answers). */
  function loadSlots(){
    if (!state.service || !state.date) return;
    var seq = ++state.slotsSeq;
    stepSlots.innerHTML = ''; stepForm.innerHTML = ''; stepDone.innerHTML = ''; say('');
    stepSlots.appendChild(el('h4', { text: '3. Pick a time' }));
    var wait = el('p', { class: 'bk-note', text: 'Looking for free times…' });
    stepSlots.appendChild(wait);
    api('?action=slots&service=' + encodeURIComponent(state.service.slug) + '&from=' + state.date + '&to=' + state.date + '&tz=' + encodeURIComponent(tz))
      .then(function(res){
        if (seq !== state.slotsSeq) return;
        if (!(res.status === 200 && res.body && res.body.ok !== false && Array.isArray(res.body.slots))) throw new Error('http ' + res.status + (res.body && res.body.error ? ' ' + res.body.error : ''));
        wait.remove(); say('');
        state.slots = res.body.slots;
        if (!state.slots.length) { stepSlots.appendChild(el('p', { class: 'bk-note', text: 'Nothing free that day. Try another one.' })); return; }
        var grid = el('div', { class: 'bk-slots', role: 'group', 'aria-label': 'Free times' });
        state.slots.forEach(function(s){
          var label = fmtTime(s.start_at, tz) + (s.tour_stop_id ? ' · ' + s.city : '');
          var b = el('button', { type: 'button', class: 'bk-slot' + (s.tour_stop_id ? ' tour' : ''), text: label, title: where(s), 'aria-pressed': 'false' });
          b.addEventListener('click', function(){ state.slot = s; renderForm(); Array.prototype.forEach.call(grid.children, function(c){ c.classList.remove('on'); c.setAttribute('aria-pressed', 'false'); }); b.classList.add('on'); b.setAttribute('aria-pressed', 'true'); });
          grid.appendChild(b);
        });
        stepSlots.appendChild(grid);
      })
      .catch(function(e){
        if (seq !== state.slotsSeq) return;
        console.error('booking_slots_failed: ' + ((e && e.message) || 'network_error'));
        stepSlots.innerHTML = '';
        stepSlots.appendChild(el('h4', { text: '3. Pick a time' }));
        var retry = el('button', { type: 'button', class: 'bk-retry', text: 'Try again' });
        retry.addEventListener('click', function(){ loadSlots(); });
        stepSlots.appendChild(el('div', { class: 'bk-error', role: 'alert' }, [el('p', { text: 'Could not load times. Try again in a moment.' }), retry]));
      });
  }

  function renderForm(){
    stepForm.innerHTML = ''; stepDone.innerHTML = ''; say('');
    var s = state.slot, svc = state.service;
    stepForm.appendChild(el('h4', { text: '4. Your details' }));
    stepForm.appendChild(el('p', { class: 'bk-summary', html:
      '<b>' + svc.title + '</b> · ' + fmtDateTime(s.start_at, tz) +
      (s.tour_stop_id ? '<br>In person: ' + s.city + ', ' + s.country + ' (' + s.session_timezone + ')' + (s.venue ? ' · ' + s.venue : '')
                      : '<br>' + (svc.delivery_mode === 'online' ? 'Online' : 'In person') + ' · session timezone ' + s.session_timezone) }));
    var form = el('form', { class: 'bk-form', novalidate: '' });
    form.appendChild(el('div', { class: 'two' }, [
      el('div', { class: 'field' }, [el('label', { for: 'bk-name', text: 'Your name' }), el('input', { id: 'bk-name', name: 'name', type: 'text', autocomplete: 'name', required: '' })]),
      el('div', { class: 'field' }, [el('label', { for: 'bk-contact', text: 'Email or WhatsApp' }), el('input', { id: 'bk-contact', name: 'contact', type: 'text', required: '' })]),
    ]));
    form.appendChild(el('div', { class: 'field' }, [el('label', { for: 'bk-notes', text: 'Anything useful to know (optional)' }), el('textarea', { id: 'bk-notes', name: 'notes' })]));
    var btn = el('button', { class: 'btn btn-accent btn-full', type: 'submit', text: svc.price_amount === null ? 'Request this time →' : 'Hold this time →' });
    form.appendChild(btn);
    stepForm.appendChild(form);

    var inFlight = false;
    form.addEventListener('submit', function(e){
      e.preventDefault(); if (inFlight) return;
      var fd = new FormData(form);
      var payload = { action: 'hold', service: svc.slug, start_at: s.start_at, participants: 1, idempotency_key: state.key,
                      name: fd.get('name') || '', contact: fd.get('contact') || '', tour_stop: s.tour_stop_slug || null, notes: fd.get('notes') || '' };
      inFlight = true; btn.disabled = true; say('Holding your time…');
      api('', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(payload) })
        .then(function(res){
          if (res.status === 200 && res.body.ok) { state.booking = res.body.booking; onHeld(); return; }
          if (res.status === 409) { say('That time just went. Pick another one.', 'err'); state.key = uuid(); loadSlots(); return; }
          if (res.status === 400) { say('Add your name and an email or WhatsApp number.', 'err'); return; }
          if (res.status === 429) { say('Too many attempts. Give it a few minutes.', 'err'); return; }
          throw new Error('status ' + res.status);
        })
        .catch(function(){ say('Something went wrong. Try again, or message on WhatsApp.', 'err'); })
        .finally(function(){ inFlight = false; btn.disabled = false; });
    });
  }

  function onHeld(){
    var b = state.booking;
    stepForm.hidden = true; say('');
    stepDone.innerHTML = '';
    stepDone.appendChild(el('h4', { text: 'Time held: ' + b.reference }));
    stepDone.appendChild(el('p', { class: 'bk-summary', html: '<b>' + b.service.title + '</b> · ' + fmtDateTime(b.start_at, tz) + '<br>Session timezone: ' + b.session_timezone + (b.tour_stop ? '<br>' + b.tour_stop.city + ', ' + b.tour_stop.country + (b.tour_stop.venue ? ' · ' + b.tour_stop.venue : '') : '') }));
    if (b.price_amount === null || b.price_amount === undefined) {
      stepDone.appendChild(el('p', { class: 'bk-note', text: 'This session is priced on request. Coach Gari will confirm the price and the time with you directly.' }));
      return;
    }
    var mins = Math.max(1, Math.round((new Date(b.hold_expires_at) - Date.now()) / 60000));
    stepDone.appendChild(el('p', { class: 'bk-note', text: 'Held for ' + mins + ' minutes. Pay ' + money(b.price_amount, b.currency) + ' to confirm.' }));
    var pay = el('button', { type: 'button', class: 'btn btn-accent', text: 'Continue to payment →' });
    pay.addEventListener('click', function(){ startCheckout(b, pay); });
    stepDone.appendChild(pay);
    var terms = el('p', { class: 'bk-terms' }); terms.appendChild(document.createTextNode('By paying you agree to the '));
    terms.appendChild(el('a', { href: '/legal#cancellation', target: '_blank', rel: 'noopener', text: 'terms and cancellation policy' })); terms.appendChild(document.createTextNode('.'));
    stepDone.appendChild(terms);
  }

  // Stripe.js is loaded only when someone actually pays (never on page load).
  function loadStripeJs(){
    return new Promise(function(resolve, reject){
      if (window.Stripe) return resolve(window.Stripe);
      var s = document.createElement('script'); s.src = 'https://js.stripe.com/v3/'; s.async = true;
      s.onload = function(){ window.Stripe ? resolve(window.Stripe) : reject(new Error('stripe_js')); };
      s.onerror = function(){ reject(new Error('stripe_js')); };
      document.head.appendChild(s);
    });
  }

  var embedded = null;   // the mounted Stripe Embedded Checkout, if any
  function closeEmbedded(){ if (embedded) { try { embedded.destroy(); } catch (e) {} embedded = null; } var m = stepDone.querySelector('.bk-checkout'); if (m) m.remove(); }

  // Embedded Checkout: the card form is mounted right here, under the held time.
  // Completing it is NOT proof of payment: pollState() reads the server state,
  // which only the verified Stripe webhook can move to "confirmed".
  function startCheckout(b, btn){
    if (!CONFIG.CHECKOUT_ENDPOINT) { say('Payment is not switched on yet. Coach Gari will confirm with you directly.', 'err'); return; }
    btn.disabled = true; say('Preparing secure payment…');
    fetch(CONFIG.CHECKOUT_ENDPOINT, { method: 'POST', headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ ref: b.reference, token: b.manage_token }) })
      .then(function(r){ return r.json().then(function(j){ return { status: r.status, body: j }; }); })
      .then(function(res){
        if (res.status === 409) { say('This hold has expired. Pick a time again.', 'err'); return; }
        if (!(res.status === 200 && res.body.ok && res.body.client_secret && res.body.publishable_key)) throw new Error('status ' + res.status);
        return loadStripeJs().then(function(Stripe){
          var stripe = Stripe(res.body.publishable_key);
          return stripe.initEmbeddedCheckout({ clientSecret: res.body.client_secret, onComplete: function(){ closeEmbedded(); pollState(b.reference, b.manage_token, true); } });
        }).then(function(instance){
          closeEmbedded(); embedded = instance;
          var box = el('div', { class: 'bk-checkout' });
          var mount = el('div', { class: 'bk-checkout-mount' });
          var cancel = el('button', { type: 'button', class: 'bk-checkout-cancel', text: 'Cancel card payment' });
          cancel.addEventListener('click', function(){ closeEmbedded(); btn.hidden = false; btn.disabled = false; say(''); });
          box.appendChild(mount); box.appendChild(cancel); stepDone.appendChild(box);
          instance.mount(mount); btn.hidden = true; say('');
        });
      })
      .catch(function(){ closeEmbedded(); say('Could not start payment. Try again, or message on WhatsApp.', 'err'); btn.disabled = false; btn.hidden = false; });
  }

  // After the card form completes (or Stripe returns from a bank redirect): never proof. Poll the server state.
  function pollState(ref, token, paidHint){
    var paid = paidHint || q.get('paid') === '1';
    var tries = 0;
    stepDone.innerHTML = '';
    stepDone.appendChild(el('h4', { text: 'Confirming your session…' }));
    var line = el('p', { class: 'bk-note', text: 'Payment received. We’re confirming your session now. You’ll receive the details by email shortly.' });
    stepDone.appendChild(line);
    (function tick(){
      api('?action=state&ref=' + encodeURIComponent(ref) + '&token=' + encodeURIComponent(token)).then(function(res){
        var b = res.body && res.body.booking;
        if (!b) { line.textContent = 'We could not find that booking.'; return; }
        if (b.status === 'confirmed') {
          stepDone.innerHTML = '';
          stepDone.appendChild(el('h4', { text: 'Booking confirmed: ' + b.reference }));
          stepDone.appendChild(el('p', { class: 'bk-summary', html: '<b>' + b.service.title + '</b> · ' + fmtDateTime(b.start_at, tz) + '<br>Session timezone: ' + b.session_timezone + (b.tour_stop ? '<br>' + b.tour_stop.city + ', ' + b.tour_stop.country + (b.tour_stop.venue ? ' · ' + b.tour_stop.venue : '') : '') }));
          stepDone.appendChild(el('p', { class: 'bk-note', text: 'The details are on their way by email.' }));
          return;
        }
        if (b.status === 'cancelled' || b.status === 'expired') { line.textContent = 'This booking is ' + b.status + '. Pick a time again if you still want it.'; return; }
        // Came back without paying (cancel_url): the hold is still live — offer payment again.
        if (!paid && (b.status === 'hold' || b.status === 'pending_payment')) {
          stepDone.innerHTML = '';
          stepDone.appendChild(el('h4', { text: 'Your time is still held: ' + b.reference }));
          stepDone.appendChild(el('p', { class: 'bk-note', text: 'Payment wasn’t completed. Your time stays held until ' + fmtTime(b.hold_expires_at, tz) + '.' }));
          var pay = el('button', { type: 'button', class: 'btn btn-accent', text: 'Continue to payment →' });
          pay.addEventListener('click', function(){ startCheckout(b, pay); });
          stepDone.appendChild(pay);
          return;
        }
        if (++tries < 40) setTimeout(tick, 3000);
        else line.textContent = 'Still confirming. Your reference is ' + b.reference + '. You’ll get an email as soon as it’s done.';
      }).catch(function(){ if (++tries < 40) setTimeout(tick, 4000); });
    })();
  }
}

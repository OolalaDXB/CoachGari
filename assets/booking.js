/* =============================================================
   Coach Gari — booking flow (CG-002 / CG-003)
   service → date → slot → details → hold → payment → confirmation

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
  if (amount === null || amount === undefined) return 'On request';
  try { return new Intl.NumberFormat(undefined, { style: 'currency', currency: currency, maximumFractionDigits: 0 }).format(amount / 100); }
  catch (e) { return (amount / 100) + ' ' + currency; }
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
  var state = { services: [], tourStops: [], service: null, date: todayPlus(1), slots: [], slot: null, key: uuid(), booking: null };

  var status = el('p', { class: 'bk-status', role: 'status', 'aria-live': 'polite' });
  var stepService = el('div', { class: 'bk-step' });
  var stepDate = el('div', { class: 'bk-step' });
  var stepSlots = el('div', { class: 'bk-step' });
  var stepForm = el('div', { class: 'bk-step' });
  var stepDone = el('div', { class: 'bk-step bk-done' });
  root.appendChild(stepService); root.appendChild(stepDate); root.appendChild(stepSlots);
  root.appendChild(stepForm); root.appendChild(stepDone); root.appendChild(status);

  function say(msg, cls){ status.textContent = msg || ''; status.className = 'bk-status ' + (cls || ''); }

  // Returning from payment? ?booking=REF&t=TOKEN
  var q = new URLSearchParams(window.location.search);
  if (q.get('booking') && q.get('t')) {
    [stepService, stepDate, stepSlots, stepForm].forEach(function(s){ s.hidden = true; });
    pollState(q.get('booking'), q.get('t'));
    return;
  }

  Promise.all([api('?action=services'), api('?action=tour_stops')]).then(function(res){
    state.services = (res[0].body && res[0].body.services) || [];
    state.tourStops = (res[1].body && res[1].body.tour_stops) || [];
    if (!state.services.length) { say('Booking opens soon — message on WhatsApp in the meantime.', 'err'); return; }
    renderServices();
  }).catch(function(){ say('Could not load the booking options. Try again in a moment.', 'err'); });

  function renderServices(){
    stepService.innerHTML = '';
    stepService.appendChild(el('h4', { text: '1. What do you want to book?' }));
    var list = el('div', { class: 'bk-services' });
    state.services.forEach(function(s){
      var b = el('button', { type: 'button', class: 'bk-service' + (state.service && state.service.slug === s.slug ? ' on' : '') }, [
        el('b', { text: s.title }),
        el('span', { text: s.duration_minutes + ' min · ' + money(s.price_amount, s.currency) + ' · ' + (s.delivery_mode === 'online' ? 'online' : 'in person') }),
      ]);
      b.addEventListener('click', function(){ state.service = s; state.slot = null; renderServices(); renderDate(); loadSlots(); });
      list.appendChild(b);
    });
    stepService.appendChild(list);
    var stops = state.tourStops.filter(function(t){ return !state.service || t.services.indexOf(state.service.slug) !== -1; });
    if (stops.length) {
      var tour = el('div', { class: 'bk-tour' }, [el('h4', { text: 'Gari on tour' })]);
      stops.forEach(function(t){
        tour.appendChild(el('div', { class: 'bk-tourstop' }, [
          el('b', { text: t.city + ', ' + t.country }),
          el('span', { text: fmtDate(t.start_at, t.timezone) + ' → ' + fmtDate(t.end_at, t.timezone) + ' · ' + t.timezone + (t.venue ? ' · ' + t.venue : '') }),
          t.location_notes ? el('em', { text: t.location_notes }) : null,
        ]));
      });
      stepService.appendChild(tour);
    }
    if (!state.service && state.services.length === 1) { state.service = state.services[0]; renderServices(); renderDate(); loadSlots(); }
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

  function loadSlots(){
    if (!state.service || !state.date) return;
    stepSlots.innerHTML = ''; stepForm.innerHTML = ''; stepDone.innerHTML = '';
    stepSlots.appendChild(el('h4', { text: '3. Pick a time' }));
    var wait = el('p', { class: 'bk-note', text: 'Looking for free times…' });
    stepSlots.appendChild(wait);
    api('?action=slots&service=' + encodeURIComponent(state.service.slug) + '&from=' + state.date + '&to=' + state.date + '&tz=' + encodeURIComponent(tz))
      .then(function(res){
        stepSlots.removeChild(wait);
        state.slots = (res.body && res.body.slots) || [];
        if (!state.slots.length) { stepSlots.appendChild(el('p', { class: 'bk-note', text: 'Nothing free that day — try another one.' })); return; }
        var grid = el('div', { class: 'bk-slots' });
        state.slots.forEach(function(s){
          var label = fmtTime(s.start_at, tz) + (s.tour_stop_id ? ' · ' + s.city : '');
          var b = el('button', { type: 'button', class: 'bk-slot' + (s.tour_stop_id ? ' tour' : ''), text: label, title: s.tour_stop_id ? s.city + ', ' + s.country + ' (' + s.session_timezone + ')' : 'Online · ' + s.session_timezone });
          b.addEventListener('click', function(){ state.slot = s; renderForm(); Array.prototype.forEach.call(grid.children, function(c){ c.classList.remove('on'); }); b.classList.add('on'); });
          grid.appendChild(b);
        });
        stepSlots.appendChild(grid);
      })
      .catch(function(){ say('Could not load times. Try again in a moment.', 'err'); });
  }

  function renderForm(){
    stepForm.innerHTML = ''; stepDone.innerHTML = ''; say('');
    var s = state.slot, svc = state.service;
    stepForm.appendChild(el('h4', { text: '4. Your details' }));
    stepForm.appendChild(el('p', { class: 'bk-summary', html:
      '<b>' + svc.title + '</b> · ' + fmtDateTime(s.start_at, tz) +
      (s.tour_stop_id ? '<br>In person — ' + s.city + ', ' + s.country + ' (' + s.session_timezone + ')' + (s.venue ? ' · ' + s.venue : '') : '<br>Online · session timezone ' + s.session_timezone) +
      '<br>' + money(svc.price_amount, svc.currency) }));
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
          if (res.status === 429) { say('Too many attempts — give it a few minutes.', 'err'); return; }
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
    stepDone.appendChild(el('h4', { text: 'Time held — ' + b.reference }));
    stepDone.appendChild(el('p', { class: 'bk-summary', html: '<b>' + b.service.title + '</b> · ' + fmtDateTime(b.start_at, tz) + '<br>Session timezone: ' + b.session_timezone + (b.tour_stop ? '<br>' + b.tour_stop.city + ', ' + b.tour_stop.country + (b.tour_stop.venue ? ' · ' + b.tour_stop.venue : '') : '') }));
    if (b.price_amount === null || b.price_amount === undefined) {
      stepDone.appendChild(el('p', { class: 'bk-note', text: 'This session is priced on request. Coach Gari will confirm the price and the time with you directly.' }));
      return;
    }
    var mins = Math.max(1, Math.round((new Date(b.hold_expires_at) - Date.now()) / 60000));
    stepDone.appendChild(el('p', { class: 'bk-note', text: 'Held for ' + mins + ' minutes. Pay to confirm — ' + money(b.price_amount, b.currency) + '.' }));
    var pay = el('button', { type: 'button', class: 'btn btn-accent', text: 'Continue to payment →' });
    pay.addEventListener('click', function(){ startCheckout(b, pay); });
    stepDone.appendChild(pay);
  }

  function startCheckout(b, btn){
    if (!CONFIG.CHECKOUT_ENDPOINT) { say('Payment is not switched on yet — Coach Gari will confirm with you directly.', 'err'); return; }
    btn.disabled = true; say('Taking you to secure payment…');
    fetch(CONFIG.CHECKOUT_ENDPOINT, { method: 'POST', headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ ref: b.reference, token: b.manage_token }) })
      .then(function(r){ return r.json().then(function(j){ return { status: r.status, body: j }; }); })
      .then(function(res){
        if (res.status === 200 && res.body.ok && res.body.url) { window.location.href = res.body.url; return; }
        if (res.status === 409) { say('This hold has expired. Pick a time again.', 'err'); return; }
        throw new Error('status ' + res.status);
      })
      .catch(function(){ say('Could not start payment. Try again, or message on WhatsApp.', 'err'); btn.disabled = false; });
  }

  // After Stripe returns: the redirect is never proof. Poll the server state.
  function pollState(ref, token){
    var tries = 0;
    stepDone.innerHTML = '';
    stepDone.appendChild(el('h4', { text: 'Confirming your session…' }));
    var line = el('p', { class: 'bk-note', text: 'Payment received. We’re confirming your session now — you’ll receive the details by email shortly.' });
    stepDone.appendChild(line);
    (function tick(){
      api('?action=state&ref=' + encodeURIComponent(ref) + '&token=' + encodeURIComponent(token)).then(function(res){
        var b = res.body && res.body.booking;
        if (!b) { line.textContent = 'We could not find that booking.'; return; }
        if (b.status === 'confirmed') {
          stepDone.innerHTML = '';
          stepDone.appendChild(el('h4', { text: 'Booking confirmed — ' + b.reference }));
          stepDone.appendChild(el('p', { class: 'bk-summary', html: '<b>' + b.service.title + '</b> · ' + fmtDateTime(b.start_at, tz) + '<br>Session timezone: ' + b.session_timezone + (b.tour_stop ? '<br>' + b.tour_stop.city + ', ' + b.tour_stop.country + (b.tour_stop.venue ? ' · ' + b.tour_stop.venue : '') : '') }));
          stepDone.appendChild(el('p', { class: 'bk-note', text: 'The details are on their way by email.' }));
          return;
        }
        if (b.status === 'cancelled' || b.status === 'expired') { line.textContent = 'This booking is ' + b.status + '. Pick a time again if you still want it.'; return; }
        // Came back without paying (cancel_url): the hold is still live — offer payment again.
        if (q.get('paid') !== '1' && (b.status === 'hold' || b.status === 'pending_payment')) {
          stepDone.innerHTML = '';
          stepDone.appendChild(el('h4', { text: 'Your time is still held — ' + b.reference }));
          stepDone.appendChild(el('p', { class: 'bk-note', text: 'Payment wasn’t completed. Your time stays held until ' + fmtTime(b.hold_expires_at, tz) + '.' }));
          var pay = el('button', { type: 'button', class: 'btn btn-accent', text: 'Continue to payment →' });
          pay.addEventListener('click', function(){ startCheckout(b, pay); });
          stepDone.appendChild(pay);
          return;
        }
        if (++tries < 40) setTimeout(tick, 3000);
        else line.textContent = 'Still confirming. Your reference is ' + b.reference + ' — you’ll get an email as soon as it’s done.';
      }).catch(function(){ if (++tries < 40) setTimeout(tick, 4000); });
    })();
  }
}

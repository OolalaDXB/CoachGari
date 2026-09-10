/* =============================================================
   Coach Gari — Support Coach Gari (a generic BEAU PH payment, intent "support")
   country → amount → optional message → card payment (Stripe Embedded Checkout)

   The payment method and the currencies come from the server for the
   payer's COUNTRY (BEAU PH eligibility for the `support` intent) — nothing
   is assumed from the merchant's home. Nothing here is authoritative: the
   server validates country, currency, amount and rail and returns a
   session-scoped client secret; only the verified Stripe webhook marks the
   payment paid, and this page re-reads the state until it does. Not a
   booking, not a package, not a session.
   ============================================================= */
import { CONFIG } from '/config.js';
import { enhanceCountry, matchCountry, COUNTRY_CODES } from '/assets/site.js';

var root = document.querySelector('[data-support]');
if (root && CONFIG.SUPPORT_ENDPOINT) init();
else if (root) document.querySelectorAll('[data-support-open]').forEach(function(a){ a.hidden = true; });

// preset amounts per currency (minor units); any other currency the server offers gets "Other" only
var PRESETS = { AED: [2500, 5000, 10000], USD: [1000, 2500, 5000], EUR: [1000, 2500, 5000], GBP: [1000, 2500, 5000] };

function init(){
  var form = root.querySelector('[data-support-form]');
  var countryInput = root.querySelector('[data-support-country]');
  var hint = root.querySelector('[data-support-hint]');
  var amountsHost = root.querySelector('[data-support-amounts]');
  var other = root.querySelector('.sp-other');
  var otherInput = root.querySelector('#sp-other');
  var ccyLabel = root.querySelector('[data-support-ccy]');
  var msg = root.querySelector('#sp-msg');
  var status = root.querySelector('.sp-status');
  var pay = root.querySelector('[data-support-pay]');
  var checkout = root.querySelector('.sp-checkout');
  var mount = root.querySelector('[data-support-mount]');
  var done = root.querySelector('.sp-done');
  var state = { country: null, currency: null, options: null, amount: null };
  var instance = null, lastFocus = null;
  enhanceCountry(countryInput);

  function say(t, err){ status.textContent = t || ''; status.classList.toggle('err', !!err); }
  function money(minor, cur){ try { return new Intl.NumberFormat(undefined, { style: 'currency', currency: cur, maximumFractionDigits: 0 }).format(minor / 100); } catch (e) { return cur + ' ' + (minor / 100); } }
  function api(body){
    return fetch(CONFIG.SUPPORT_ENDPOINT, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body) })
      .then(function(r){ return r.json().then(function(j){ return { status: r.status, body: j }; }); });
  }

  function open(){ lastFocus = document.activeElement; root.hidden = false; document.body.classList.add('sp-open'); var t = root.querySelector('.cs-trigger'); if (t) t.focus(); }
  function close(){ destroy(); root.hidden = true; document.body.classList.remove('sp-open'); if (lastFocus && lastFocus.focus) lastFocus.focus(); }
  function destroy(){ if (instance) { try { instance.destroy(); } catch (e) {} instance = null; } mount.textContent = ''; }
  function reset(){ destroy(); checkout.hidden = true; done.hidden = true; form.hidden = false; pay.disabled = false; say(''); }

  document.querySelectorAll('[data-support-open]').forEach(function(a){ a.addEventListener('click', function(e){ e.preventDefault(); reset(); open(); }); });
  root.querySelectorAll('[data-support-close]').forEach(function(b){ b.addEventListener('click', close); });
  root.addEventListener('keydown', function(e){ if (e.key === 'Escape') close(); });
  root.querySelector('[data-support-cancel]').addEventListener('click', function(){ reset(); });

  // the country decides what can be offered: ask the server, then render the currency's presets
  var optSeq = 0;
  countryInput.addEventListener('change', function(){
    var name = matchCountry(countryInput.value); var code = name ? COUNTRY_CODES[name] : null;
    state.country = code; state.currency = null; state.options = null; state.amount = null;
    amountsHost.hidden = true; amountsHost.innerHTML = ''; other.hidden = true; hint.hidden = true; say('');
    if (!code) return;
    var seq = ++optSeq; say('Checking payment options…');
    api({ action: 'options', country: code }).then(function(res){
      if (seq !== optSeq) return;
      say('');
      var list = (res.status === 200 && res.body && res.body.ok && res.body.options && res.body.options.currencies) || [];
      if (!list.length) { hint.textContent = 'Card payment is not available for ' + name + ' yet. You can message Coach Gari on WhatsApp instead.'; hint.hidden = false; return; }
      state.options = list;
      state.currency = res.body.options.default_currency || list[0].currency;
      renderAmounts();
    }).catch(function(){ if (seq === optSeq) say('Could not check the payment options. Please try again.', true); });
  });

  function renderAmounts(){
    var cur = state.currency; var presets = PRESETS[cur] || [];
    amountsHost.innerHTML = ''; amountsHost.hidden = false; state.amount = null; other.hidden = true;
    ccyLabel.textContent = '(' + cur + ')';
    presets.concat(['other']).forEach(function(v){
      var b = document.createElement('button'); b.type = 'button'; b.className = 'sp-amt'; b.setAttribute('aria-pressed', 'false');
      b.textContent = v === 'other' ? 'Other' : money(v, cur);
      b.addEventListener('click', function(){
        Array.prototype.forEach.call(amountsHost.children, function(c){ c.classList.toggle('on', c === b); c.setAttribute('aria-pressed', c === b ? 'true' : 'false'); });
        if (v === 'other') { state.amount = null; other.hidden = false; otherInput.value = ''; otherInput.focus(); } else { state.amount = v; other.hidden = true; }
        say('');
      });
      amountsHost.appendChild(b);
    });
    if (!presets.length) amountsHost.firstChild.click();
  }
  otherInput.addEventListener('input', function(){ var v = Number(otherInput.value); state.amount = v > 0 ? Math.round(v * 100) : null; });

  var inFlight = false;
  form.addEventListener('submit', function(e){
    e.preventDefault(); if (inFlight) return;
    if (!state.country) { say('Choose your country first.', true); return; }
    if (!state.currency) { say('Card payment is not available for this country yet.', true); return; }
    if (!state.amount) { say('Choose an amount.', true); return; }
    inFlight = true; pay.disabled = true; say('Preparing secure payment…');
    api({ action: 'create', country: state.country, amount: state.amount, currency: state.currency, message: msg.value || '' })
      .then(function(res){
        if (res.status === 400 && res.body && res.body.error === 'validation') { say(res.body.message || 'Please check the amount.', true); return; }
        if (res.status === 503) { say('Card payment is not available right now. Please try again later.', true); return; }
        if (!(res.status === 200 && res.body.ok && res.body.client_secret && res.body.publishable_key)) throw new Error('status ' + res.status);
        var ref = res.body.reference, token = res.body.token, cur = res.body.currency;
        return loadStripeJs().then(function(Stripe){
          var stripe = Stripe(res.body.publishable_key);
          return stripe.initEmbeddedCheckout({ clientSecret: res.body.client_secret, onComplete: function(){ destroy(); confirm(ref, token, cur); } });
        }).then(function(inst){ instance = inst; form.hidden = true; checkout.hidden = false; say(''); inst.mount(mount); });
      })
      .catch(function(){ say('Could not start the payment. Please try again in a moment.', true); })
      .finally(function(){ inFlight = false; pay.disabled = false; });
  });

  // completion in the browser is never proof: re-read the server state until the webhook has landed
  function confirm(ref, token){
    checkout.hidden = true; form.hidden = true; done.hidden = false;
    done.innerHTML = ''; var h = document.createElement('h4'); h.textContent = 'Thank you'; var p = document.createElement('p'); p.textContent = 'Your payment is being confirmed…'; done.appendChild(h); done.appendChild(p);
    var tries = 0;
    (function tick(){
      api({ action: 'state', reference: ref, token: token }).then(function(res){
        var s = res.body && res.body.support;
        if (s && s.status === 'paid') { p.textContent = 'Received: ' + money(s.amount, s.currency) + '. Thank you for supporting Coach Gari.'; return; }
        if (s && (s.status === 'cancelled' || s.status === 'expired')) { p.textContent = 'This payment was not completed. You can close this window and try again.'; return; }
        if (++tries < 40) setTimeout(tick, tries < 5 ? 2000 : 4000);
        else p.textContent = 'Still confirming. Your reference is ' + ref + '. Coach Gari sees the payment as soon as it is confirmed.';
      }).catch(function(){ if (++tries < 40) setTimeout(tick, 4000); });
    })();
  }

  function loadStripeJs(){
    return new Promise(function(resolve, reject){
      if (window.Stripe) return resolve(window.Stripe);
      var s = document.createElement('script'); s.src = 'https://js.stripe.com/v3/'; s.async = true;
      s.onload = function(){ window.Stripe ? resolve(window.Stripe) : reject(new Error('stripe_js')); };
      s.onerror = function(){ reject(new Error('stripe_js')); };
      document.head.appendChild(s);
    });
  }

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

  // back from a Stripe-side redirect (bank / 3DS): ?support=REF&t=TOKEN — never proof, the state is re-read
  var q = new URLSearchParams(window.location.search);
  if (q.get('support') && q.get('t')) {
    var spRef = q.get('support'), spTok = q.get('t');
    scrubUrl();
    reset(); open(); confirm(spRef, spTok);
  }
}

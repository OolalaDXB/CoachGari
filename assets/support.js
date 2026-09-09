/* =============================================================
   Coach Gari — Support Coach Gari (a generic BEAU PH payment, intent "support")
   amount → optional message → card payment (Stripe Embedded Checkout)

   Nothing here is authoritative: the server validates the amount, currency
   and rail and returns a session-scoped client secret; only the verified
   Stripe webhook marks the payment paid, and this page re-reads the state
   until it does. Not a booking, not a package, not a session.
   ============================================================= */
import { CONFIG } from '/config.js';

var root = document.querySelector('[data-support]');
if (root && CONFIG.SUPPORT_ENDPOINT) init();
else if (root) document.querySelectorAll('[data-support-open]').forEach(function(a){ a.hidden = true; });

function init(){
  var CURRENCY = 'AED';
  var form = root.querySelector('[data-support-form]');
  var amounts = root.querySelectorAll('.sp-amt');
  var other = root.querySelector('.sp-other');
  var otherInput = root.querySelector('#sp-other');
  var msg = root.querySelector('#sp-msg');
  var status = root.querySelector('.sp-status');
  var pay = root.querySelector('[data-support-pay]');
  var checkout = root.querySelector('.sp-checkout');
  var mount = root.querySelector('[data-support-mount]');
  var done = root.querySelector('.sp-done');
  var amount = null, instance = null, lastFocus = null;

  function say(t, err){ status.textContent = t || ''; status.classList.toggle('err', !!err); }
  function money(minor){ return CURRENCY + ' ' + (minor / 100).toLocaleString(undefined, { maximumFractionDigits: 2 }); }
  function api(body){
    return fetch(CONFIG.SUPPORT_ENDPOINT, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body) })
      .then(function(r){ return r.json().then(function(j){ return { status: r.status, body: j }; }); });
  }

  function open(){
    lastFocus = document.activeElement;
    root.hidden = false; document.body.classList.add('sp-open');
    var first = root.querySelector('.sp-amt'); if (first) first.focus();
  }
  function close(){
    destroy();
    root.hidden = true; document.body.classList.remove('sp-open');
    if (lastFocus && lastFocus.focus) lastFocus.focus();
  }
  function destroy(){ if (instance) { try { instance.destroy(); } catch (e) {} instance = null; } mount.textContent = ''; }
  function reset(){ destroy(); checkout.hidden = true; done.hidden = true; form.hidden = false; pay.disabled = false; say(''); }

  document.querySelectorAll('[data-support-open]').forEach(function(a){
    a.addEventListener('click', function(e){ e.preventDefault(); reset(); open(); });
  });
  root.querySelectorAll('[data-support-close]').forEach(function(b){ b.addEventListener('click', close); });
  root.addEventListener('keydown', function(e){ if (e.key === 'Escape') close(); });
  root.querySelector('[data-support-cancel]').addEventListener('click', function(){ reset(); });

  amounts.forEach(function(b){
    b.addEventListener('click', function(){
      amounts.forEach(function(c){ c.classList.toggle('on', c === b); c.setAttribute('aria-pressed', c === b ? 'true' : 'false'); });
      if (b.getAttribute('data-amount') === 'other') { amount = null; other.hidden = false; otherInput.focus(); }
      else { amount = parseInt(b.getAttribute('data-amount'), 10); other.hidden = true; }
      say('');
    });
  });
  otherInput.addEventListener('input', function(){ var v = Number(otherInput.value); amount = v > 0 ? Math.round(v * 100) : null; });

  var inFlight = false;
  form.addEventListener('submit', function(e){
    e.preventDefault(); if (inFlight) return;
    if (!amount) { say('Choose an amount first.', true); return; }
    inFlight = true; pay.disabled = true; say('Preparing secure payment…');
    api({ action: 'create', amount: amount, currency: CURRENCY, message: msg.value || '' })
      .then(function(res){
        if (res.status === 400 && res.body && res.body.error === 'validation') { say(res.body.message || 'Please check the amount.', true); return; }
        if (res.status === 503) { say('Card payment is not available right now. Please try again later.', true); return; }
        if (!(res.status === 200 && res.body.ok && res.body.client_secret && res.body.publishable_key)) throw new Error('status ' + res.status);
        var ref = res.body.reference, token = res.body.token;
        return loadStripeJs().then(function(Stripe){
          var stripe = Stripe(res.body.publishable_key);
          return stripe.initEmbeddedCheckout({ clientSecret: res.body.client_secret, onComplete: function(){ destroy(); confirm(ref, token, res.body.amount); } });
        }).then(function(inst){
          instance = inst; form.hidden = true; checkout.hidden = false; say('');
          inst.mount(mount);
        });
      })
      .catch(function(){ say('Could not start the payment. Please try again in a moment.', true); })
      .finally(function(){ inFlight = false; pay.disabled = false; });
  });

  // completion in the browser is never proof: re-read the server state until the webhook has landed
  function confirm(ref, token, minor){
    checkout.hidden = true; form.hidden = true; done.hidden = false;
    done.innerHTML = ''; var h = document.createElement('h4'); h.textContent = 'Thank you'; var p = document.createElement('p'); p.textContent = 'Your payment is being confirmed…'; done.appendChild(h); done.appendChild(p);
    var tries = 0;
    (function tick(){
      api({ action: 'state', reference: ref, token: token }).then(function(res){
        var s = res.body && res.body.support;
        if (s && s.status === 'paid') { p.textContent = 'Received: ' + money(s.amount) + '. Thank you for supporting Coach Gari.'; return; }
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

  // back from a Stripe-side redirect (bank / 3DS): ?support=REF&t=TOKEN — never proof, the state is re-read
  var q = new URLSearchParams(window.location.search);
  if (q.get('support') && q.get('t')) { reset(); open(); confirm(q.get('support'), q.get('t'), null); }
}

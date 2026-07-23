/* =============================================================
   Coach Gari — shared behaviour for all four pages.

   Reads everything it needs from /config.js, the single source
   of truth. Loaded as an ES module:
     <script type="module" src="/assets/site.js"></script>

   Responsibilities:
     1. Reveal-on-scroll (IntersectionObserver)
     2. SHOWCASE <-> SHOP toggle (CONFIG.COMMERCE)
     3. WhatsApp links built from CONFIG.WHATSAPP + button context
     4. Enquiry form -> CONFIG.FORM_ENDPOINT
     5. Config-driven text / href injection (commission, studio URL)

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
      ? 'Hi Gari — ' + context
      : 'Hi Gari, I found you online.';
    el.setAttribute('href', 'https://wa.me/' + num + '?text=' + encodeURIComponent(text));
    el.setAttribute('rel', 'noopener');
    el.setAttribute('target', '_blank');
  });
})();

/* ---- 4. enquiry form -------------------------------------- */
(function enquiry(){
  var form = document.querySelector('form[data-enquiry]');
  if (!form) return;

  var status = form.querySelector('.form-status');
  function say(msg, cls){
    if (!status) return;
    status.textContent = msg;
    status.className = 'form-status ' + (cls || '');
  }

  form.addEventListener('submit', function(e){
    e.preventDefault();

    if (!CONFIG.FORM_ENDPOINT) {
      say('The form isn’t connected yet. Reach Gari on WhatsApp in the meantime.', 'err');
      return;
    }

    var btn = form.querySelector('button[type="submit"]');
    var payload = Object.fromEntries(new FormData(form).entries());
    payload.page = document.title;

    if (btn) { btn.disabled = true; }
    say('Sending…');

    fetch(CONFIG.FORM_ENDPOINT, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(payload),
    })
    .then(function(r){ if (!r.ok) throw new Error(r.status); return r; })
    .then(function(){
      form.reset();
      say('Thanks — that’s with Gari. You’ll hear back soon.', 'ok');
    })
    .catch(function(){
      say('Something went wrong sending that. Try again, or message on WhatsApp.', 'err');
    })
    .finally(function(){ if (btn) { btn.disabled = false; } });
  });
})();

/* ---- 5. config-driven text / href ------------------------- */
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

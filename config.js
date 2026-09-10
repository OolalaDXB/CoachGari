/* =============================================================
   Coach Gari — single source of truth.
   Every href="#", price, WhatsApp link and commercial value on
   the pages reads from here. Nothing in here is a secret: this
   file is served to every visitor. Secrets (Resend key, Supabase
   service role) live only in the Supabase Edge Function env.
   ============================================================= */
export const CONFIG = {
  // Public price display for enquiry-only products (not a commerce on/off switch —
  // booking and Checkout run regardless of this flag).
  //   false = the price of an enquiry-only product is hidden ("On request");
  //           every CTA goes to the enquiry form / WhatsApp.
  //   true  = prices shown, buy buttons use each item's data-checkout and the
  //           main CTA points to the programme grid instead of the form.
  // Bookable (slot) services never show a price on their card either way: it is
  // disclosed in the booking recap once a time is held.
  SHOW_PUBLIC_ENQUIRY_PRICES: false,

  // wa.me format, digits only. Buttons build
  // https://wa.me/<WHATSAPP>?text=<pre-filled message>.
  WHATSAPP: '971521365065',

  // Public Edge Function that receives the enquiry form POST.
  FORM_ENDPOINT: 'https://acrjrlgeeyseyolmofuq.supabase.co/functions/v1/contact',

  // Public booking API (services, slots, holds, state, cancel).
  BOOKING_ENDPOINT: 'https://acrjrlgeeyseyolmofuq.supabase.co/functions/v1/booking',

  // Signed uploads for enquiry attachments (photos / videos, 3 files, 50 MB).
  // Empty = the attachment field is hidden.
  UPLOAD_ENDPOINT: 'https://acrjrlgeeyseyolmofuq.supabase.co/functions/v1/upload',

  // Server-side Stripe Checkout creation (mode = the deployment's PAYMENTS_MODE: test | live).
  // Empty = payment step disabled; holds are still created.
  CHECKOUT_ENDPOINT: 'https://acrjrlgeeyseyolmofuq.supabase.co/functions/v1/checkout',
  SUPPORT_ENDPOINT: 'https://acrjrlgeeyseyolmofuq.supabase.co/functions/v1/support',     // Support Coach Gari (card, via BEAU PH); '' = the surface is hidden,

  // Client-facing progress-tracking consent link (CG-010). The /consent page
  // reads a one-time token from the URL and POSTs here to view the notice and
  // record accept/decline. Token-authorised only — no CRM access.
  CONSENT_ENDPOINT: 'https://acrjrlgeeyseyolmofuq.supabase.co/functions/v1/consent',

  // Client-facing session recap + payment page (CG-012). The /r/<token> page
  // reads a secure token from the URL and POSTs here to view the commercial
  // recap and start a card (Stripe) payment. Token-authorised only — no CRM
  // access, and never any body-metrics/health/notes.
  REPORT_ENDPOINT: 'https://acrjrlgeeyseyolmofuq.supabase.co/functions/v1/report',

  // Collaborations. The /collab page POSTs a partnership enquiry here; the
  // private /c/<token> deal room reads and negotiates through the same
  // function. Token-authorised for the room — no CRM access, no admin
  // internals; only the verified Stripe webhook marks a payment paid.
  COLLAB_ENDPOINT: 'https://acrjrlgeeyseyolmofuq.supabase.co/functions/v1/collab',

  // Back-office (/admin): Supabase project URL + publishable key. The
  // publishable key is public by design; every row is protected by RLS and
  // a signed-in email only sees what app_permissions grants it.
  SUPABASE_URL: 'https://acrjrlgeeyseyolmofuq.supabase.co',
  SUPABASE_PUBLISHABLE_KEY: 'sb_publishable_d84Nn7V7TB1cPs5mJRX3ZA_7LljnzBm',

  // URL behind the "Studio MT" footer credit.
  STUDIO_URL: 'https://thestudio.mt',

  // Oolala (Oo) social-follow link used in every footer.
  SOCIAL_URL: 'https://myoolala.com/u/coachgari',

  // Replaces the "__ %" in the proposal.
  COMMISSION_RATE: '10%',

  // Plausible (aggregate, cookie-free analytics). Empty = script not loaded.
  // The site's own script URL from the Plausible dashboard (the site id is
  // in the file name; nothing secret). Loaded by site.js, never inline.
  PLAUSIBLE_SCRIPT: 'https://plausible.io/js/pa--Hs8UsMcvjjnXmKx7lcTL.js',
};

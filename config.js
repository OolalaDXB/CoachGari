/* =============================================================
   Coach Gari — single source of truth.
   Every href="#", price, WhatsApp link and commercial value on
   the pages reads from here. Nothing in here is a secret: this
   file is served to every visitor. Secrets (Resend key, Supabase
   service role) live only in the Supabase Edge Function env.
   ============================================================= */
export const CONFIG = {
  // false = prices hidden, every CTA goes to the enquiry form / WhatsApp.
  // true  = prices shown, buy buttons use each item's data-checkout.
  COMMERCE: false,

  // wa.me format, digits only. Buttons build
  // https://wa.me/<WHATSAPP>?text=<pre-filled message>.
  WHATSAPP: '971521365065',

  // Public Edge Function that receives the enquiry form POST.
  FORM_ENDPOINT: 'https://acrjrlgeeyseyolmofuq.supabase.co/functions/v1/contact',

  // URL behind the "Studio MT" footer credit.
  STUDIO_URL: '',

  // Oolala (Oo) social-follow link used in every footer.
  SOCIAL_URL: 'https://myoolala.com/u/coachgari',

  // Replaces the "__ %" in the proposal.
  COMMISSION_RATE: '10%',
};

/* =============================================================
   Coach Gari — single source of truth.
   Every href="#", price, WhatsApp link and commercial value on
   the four pages reads from here. Fill these in and nothing in
   the pages needs to change.

   Status: values marked "" are pending (see README → P2).
   ============================================================= */
export const CONFIG = {
  // false = prices hidden, every CTA goes to the enquiry form / WhatsApp.
  // true  = prices shown, buy buttons use each item's data-checkout.
  COMMERCE: false,

  // wa.me format, digits only, no "+" or spaces. e.g. '971500000000'.
  // Buttons build https://wa.me/<WHATSAPP>?text=<pre-filled message>.
  WHATSAPP: '',

  // Supabase Edge Function URL that receives the enquiry form POST.
  FORM_ENDPOINT: '',

  // URL behind the "Studio MT" footer credit.
  STUDIO_URL: '',

  // Oolala (Oo) social-follow link used in every footer.
  SOCIAL_URL: 'https://myoolala.com/u/coachgari',

  // Replaces the "__ %" in the proposal (index.html). e.g. '20%'.
  COMMISSION_RATE: '10%',
};

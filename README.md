# Coach Gari

Static site: one commercial proposal (Studio MT) and three prototype routes for
Coach Gari. Two distinct design systems, one shared config, deployed on Vercel.

## Structure

```
/
├── index.html              → the Studio MT proposal (noindex)
├── routes/
│   ├── a/index.html        → Route A — one page, everything to WhatsApp
│   ├── b/index.html        → Route B — four offers, prices hidden, enquiry form
│   └── c/index.html        → Route C — online-first, group sessions, live dates
├── assets/
│   ├── coach-gari.css      → Coach Gari design system (white / #1540E8 / Manrope)
│   ├── studio-mt.css       → Studio MT design system (platinum / #1A3832 / Cormorant)
│   ├── site.js             → reveal-on-scroll · COMMERCE toggle · WhatsApp · form · config injection
│   └── img/gari.jpg        → the single shared photo (placeholder until real shots arrive)
├── config.js               → single source of truth (see below)
├── vercel.json             → security headers + redirects from the old file names
└── .github/workflows/ci.yml
```

The two design systems are deliberately **not** merged: the proposal is Studio MT,
the routes are Coach Gari.

## `config.js` — the one place to fill in values

```js
export const CONFIG = {
  COMMERCE: false,        // false = prices hidden, CTAs go to form/WhatsApp
  WHATSAPP: '',           // digits only, e.g. '971500000000'
  FORM_ENDPOINT: '',      // Supabase Edge Function URL for the enquiry form
  STUDIO_URL: '',         // link behind the "Studio MT" footer credit (Route C)
  COMMISSION_RATE: '',    // replaces "__ %" in the proposal, e.g. '20%'
};
```

Every `href="#"`, price, WhatsApp link and commercial value on the pages reads from
here. While a value is empty the page keeps its existing placeholder — nothing
breaks, it just isn't wired yet.

## Status by phase

- **P1 — structure & factorisation — done.** Shared CSS extracted to `coach-gari.css`,
  shared behaviour (reveal + COMMERCE toggle, previously duplicated) unified in
  `site.js`, single `config.js`. `index.html` is `noindex`.
- **P2 — branchements — mechanism ready, waiting on values.** `site.js` already
  builds WhatsApp links from `CONFIG.WHATSAPP`, POSTs the enquiry form to
  `CONFIG.FORM_ENDPOINT`, and switches to shop mode from `CONFIG.COMMERCE` reading
  each `.item`'s `data-checkout`. Nothing is activated — fill the values in
  `config.js` (and, for Stripe, paste each Payment Link into `data-checkout`) to
  turn it on. No code changes needed.
- **P3 — déploiement — configured.** `vercel.json` carries security headers and
  301 redirects from the old file names. CI lints HTML, checks internal links, and
  validates `config.js`.

## Blocking values (needed before P2 is live)

1. WhatsApp number
2. Enquiry form endpoint (Supabase Edge Function + Resend notification)
3. Studio MT URL for the footer credit
4. Commission rate for the proposal
5. Target domain

## Notes

- **Vercel access protection** for the proposal can't be set in `vercel.json` — enable
  *Password Protection* (or Vercel Authentication) on the project in the Vercel
  dashboard. `noindex` (meta + `X-Robots-Tag` header) is already in place.
- **Testimonials** on Route B are withheld (commented out) until real, named quotes
  are supplied — placeholders are intentionally not published.
- **`gari.jpg`** is a placeholder used four times until the real photos arrive; don't
  replace it piecemeal.

## Local checks

```
npx htmlhint "index.html" "routes/**/*.html"
node scripts/check-links.mjs
```

# Coach Gari

Static site for Coach Gari, plus one public Edge Function that receives the
enquiry form. Two design systems, one shared config, no secrets in the repo.

Sprint log and blockers: [`docs/DECISIONS.md`](docs/DECISIONS.md).

## Structure

```
/
├── index.html                    → the site (Route C) — served at coachgari.com/
├── p/studio-mt-4e7a/index.html   → Studio MT proposal — unlinked, noindex, public by URL
├── routes/
│   ├── a/index.html              → archived Route A (noindex, still served)
│   └── b/index.html              → archived Route B (noindex, still served)
├── assets/
│   ├── coach-gari.css            → Coach Gari design system (white / #1540E8 / Manrope)
│   ├── studio-mt.css             → Studio MT design system (platinum / #1A3832 / Cormorant)
│   ├── site.js                   → reveal · COMMERCE toggle · WhatsApp · attribution · form · config injection
│   └── img/                      → gari.jpg (placeholder photo), oo-icon-*.svg
├── config.js                     → single source of truth for public values (never secrets)
├── supabase/
│   ├── migrations/               → public.contacts
│   └── functions/contact/        → the enquiry Edge Function
├── emails/                       → lead notification (live) + session templates (prepared, not wired)
├── scripts/
│   ├── check-links.mjs           → CI: internal links & assets
│   └── test-contact.mjs          → CG-001 gate test against the deployed function
├── docs/DECISIONS.md             → decisions & documented blockers
├── vercel.json                   → clean URLs, redirects, security headers, noindex headers
└── .github/workflows/ci.yml
```

`/routes/c` redirects permanently to `/`. The old file names
(`coach-gari-*.html`, `studio-mt-coach-gari.html`) redirect to their new homes.

## `config.js` — public values only

```js
export const CONFIG = {
  COMMERCE: false,                       // prices hidden, CTAs go to the form / WhatsApp
  WHATSAPP: '971521365065',              // digits only → wa.me links with a pre-filled message
  FORM_ENDPOINT: 'https://acrjrlgeeyseyolmofuq.supabase.co/functions/v1/contact',
  STUDIO_URL: '',                        // "Studio MT" footer credit — pending
  SOCIAL_URL: 'https://myoolala.com/u/coachgari',
  COMMISSION_RATE: '10%',                // shown in the proposal
};
```

This file is served to every visitor. It must never contain a key, a token or
a service role. All secrets live in the Supabase Edge Function environment.

## Emails

| Address | Role |
|---|---|
| `letsgo@coachgari.com` | Leads and every human exchange. Shown on the site. Reply-To on all mail. |
| `yoursession@coachgari.com` | Transactional sender: confirmations, reminders, changes, session links. |

Templates in `emails/`. Only the lead notification is live; the `session-*`
templates are prepared for the booking sprint. Resend DNS verification and the
Migadu mailboxes are set up separately when the domain is connected.

## The enquiry form (CG-001)

**Browser** (`assets/site.js`) → **Edge Function** `contact` → **`public.contacts`**
→ optional **Resend** notification to `letsgo@coachgari.com`.

- **Attribution**: on first visit the browser stores UTM parameters,
  `document.referrer`, the landing page and a first-visit timestamp in
  `localStorage` (`cg_first_touch`). It is sent only with a submission. First
  touch wins; nothing else is tracked.
- **No duplicates**: one `submission_id` (UUID) per form fill, unique in the
  table. A double click, a retry or a slow network returns the same row. A second
  guard treats an identical contact + message from the same IP within 2 minutes
  as the same enquiry.
- **Anti-spam**: honeypot field (`website`), 2-second minimum fill time, 5
  submissions per 10 minutes per hashed IP, 16 KB body cap, server-side
  validation (`name` required; `contact` must look like an email or a phone
  number). Bot submissions get `200 {ok:true}` with no id.
- **CORS**: `https://coachgari.com`, `https://www.coachgari.com`, `*.vercel.app`
  (previews), `localhost` (dev). Edit the list at the top of
  `supabase/functions/contact/index.ts`.
- **Privacy**: only a salted SHA-256 of the IP is stored, for rate limiting.
  Logs carry event names and record ids — never the message, contact or IP.
- **Location**: the single "City and country" field is stored verbatim in
  `location_raw` and split on the last comma into `city` / `country`.

## Supabase set-up (no secrets in this repo)

Project: `acrjrlgeeyseyolmofuq` (eu-central-1).

1. **Migration** — apply `supabase/migrations/20260903_cg001_contacts.sql`
   (`supabase db push`, the dashboard SQL editor, or the MCP `apply_migration`).
   Creates `public.contacts` with RLS on and **no** anon/authenticated access:
   only the Edge Function (service role, injected by the platform) reads/writes.
2. **Function** — deploy `supabase/functions/contact` **publicly**:
   `supabase functions deploy contact --no-verify-jwt`
   (or the MCP `deploy_edge_function` with `verify_jwt: false`).
   The function uses `SUPABASE_URL` / `SUPABASE_SERVICE_ROLE_KEY` that Supabase
   injects automatically — do not set or copy them anywhere.
3. **Secrets** — set by the operator, never committed:
   ```
   supabase secrets set RESEND_API_KEY=re_...          # required for notifications
   supabase secrets set LEAD_TO_EMAIL=letsgo@coachgari.com          # optional (default)
   supabase secrets set MAIL_FROM="Coach Gari <yoursession@coachgari.com>"  # optional (default)
   supabase secrets set IP_HASH_SALT=<random string>   # optional; changes the IP hash
   ```
   Without `RESEND_API_KEY` the lead is still stored and the function logs
   `notify_skipped`. Nothing breaks.
4. `config.js` → `FORM_ENDPOINT` = `https://<project-ref>.supabase.co/functions/v1/contact`.

## Deploy (Vercel, git-connected)

1. Vercel → Add New → Project → import `OolalaDXB/CoachGari`
   (Framework preset **Other**, no build command, output = repo root).
2. Deploy. Pushes to `main` auto-deploy. Add `coachgari.com` under Project → Domains
   when the DNS is ready.

The CSP in `vercel.json` only allows `connect-src` to the Supabase project host.
If the project ref ever changes, update it there too.

## CG-001 technical gate — how to run it

The gate is a **real submission from the frontend**. Run it first on the Vercel
preview, then again on `coachgari.com`.

**A. API checks (reproducible, ~5 s)**

```
node scripts/test-contact.mjs
# or against a preview origin:
CONTACT_ORIGIN=https://<preview>.vercel.app node scripts/test-contact.mjs
```

Proves: valid submission accepted (200 + id) · same `submission_id` returns the
same id · honeypot silently dropped · invalid → 400 + fields · foreign origin →
403 · GET → 405. Test rows carry `interest = 'TEST — safe to delete'`.

**B. Browser check** — open the site with UTMs, e.g.
`https://<preview>.vercel.app/?utm_source=test&utm_medium=gate`, fill the form,
**double-click** Send. Expected: one "Thanks — that's with Coach Gari" message,
one network POST (the second click is ignored while the first is in flight).

**C. Row check** — in the Supabase SQL editor:

```sql
select id, name, city, country, interest, utm_source, utm_medium, referrer,
       landing_page, first_visit_at, notified_at, created_at
from public.contacts order by created_at desc limit 5;
```

Expected: exactly one row per submission, attribution populated, `notified_at`
set once `RESEND_API_KEY` is configured (and the inbox at `letsgo@` has the mail).

**D. Clean-up** — `delete from public.contacts where interest = 'TEST — safe to delete';`

> Note: the Claude Code web sandbox's egress policy does not allow
> `*.supabase.co`, so steps A–B cannot be run from there. Run them from a
> laptop or from the deployed preview. Everything else (migration, function,
> schema, advisors) was verified through the Supabase API.

## Local checks

```
npx htmlhint "index.html" "p/**/*.html" "routes/**/*.html"
node scripts/check-links.mjs
```

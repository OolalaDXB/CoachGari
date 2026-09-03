# Coach Gari

Static site for Coach Gari, plus one public Edge Function that receives the
enquiry form. Two design systems, one shared config, no secrets in the repo.

Sprint log and blockers: [`docs/DECISIONS.md`](docs/DECISIONS.md).

**Status — CG-001 code complete / production-domain pending; CG-002 booking,
CG-003 Stripe test payments and CG-002.5 back-office built and tested on the
Vercel production alias + Supabase.** The open gates are `GATE-DOMAIN-001`
(DNS, Resend domain, mailboxes, CORS tightening, re-test on `coachgari.com`),
the Stripe test secrets and the first back-office grants — all owner actions
listed in `docs/DECISIONS.md`.

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
├── admin/                        → back-office (noindex): magic-link sign-in, tabs by permission
├── config.js                     → single source of truth for public values (never secrets)
├── supabase/
│   ├── migrations/               → contacts · booking engine · payments/ledger · permissions/RLS
│   ├── functions/                → contact · booking · checkout · stripe-webhook (Edge Functions)
│   └── tests/                    → rollback DB suites: cg002_booking · cg003_payments · cg0025_permissions
├── emails/                       → lead notification (live) + session templates (prepared, not wired)
├── scripts/
│   ├── check-links.mjs           → CI: internal links & assets
│   ├── test-contact.mjs          → CG-001 gate test against the deployed function
│   ├── test-booking.mjs          → CG-002 API test incl. the capacity race
│   └── test-checkout.mjs         → CG-003 Stripe test-mode round trip
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
  BOOKING_ENDPOINT: '…/functions/v1/booking',   // CG-002 public booking API
  CHECKOUT_ENDPOINT: '…/functions/v1/checkout', // CG-003 Stripe Checkout (test mode); '' = payment step off
  SUPABASE_URL: 'https://acrjrlgeeyseyolmofuq.supabase.co',   // back-office
  SUPABASE_PUBLISHABLE_KEY: 'sb_publishable_…',               // public by design; RLS protects every row
  STUDIO_URL: '',                        // "Studio MT" footer credit — pending
  SOCIAL_URL: 'https://myoolala.com/u/coachgari',
  COMMISSION_RATE: '10%',                // shown in the proposal
  PLAUSIBLE_DOMAIN: '',                  // '' = analytics off; 'coachgari.com' once the property exists
};
```

## Analytics (Plausible)

Aggregate, cookie-free website analytics. Prepared, **off** until the Plausible
property exists. To activate: set `PLAUSIBLE_DOMAIN: 'coachgari.com'` in
`config.js` and push — `site.js` then loads `https://plausible.io/js/script.js`,
already allowed by the CSP (`script-src` + `connect-src`). No key, no secret.
No other tracker is, or should be, added. Conversion attribution stays the
first-touch UTM data captured with each enquiry.

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

## Booking (CG-002)

Internal engine, no external scheduler. Flow on the homepage (`#book`):
service → day → time → details → 10-minute hold → payment (CG-003).

- **Tables**: `services`, `availability_rules`, `availability_exceptions`,
  `tour_stops`, `tour_stop_services`, `bookings`
  (`supabase/migrations/20260904_cg002_booking.sql`).
- **RPCs** (service role only): `available_slots(service, from, to, tz)`,
  `create_hold(...)`, `get_booking(ref, token)`, `cancel_booking(ref, token, reason)`,
  `expire_holds()` (also run by `pg_cron` every minute).
- **API** `supabase/functions/booking` — `GET ?action=services|tour_stops|slots|state`,
  `POST {action:"hold"|"cancel"}`. The database decides price, duration,
  capacity and availability; the request only carries identity and intent.
- **Timezones**: UTC in the database, IANA zone kept on every row, slots
  returned in the visitor's zone with the session zone spelled out.
- **Tour stops**: insert a `tour_stops` row (`status = 'open'`), link services in
  `tour_stop_services`, add `availability_exceptions` rows with `kind = 'open'`
  and `tour_stop_id` for the bookable windows. Until CG-002.5's back-office, do
  this in the SQL editor.
- **Placeholder hours**: Mon–Fri 09:00–17:00 Asia/Dubai are seeded so the engine
  has something to offer — edit them in `availability_rules`.

### Booking tests

```
# database suite — one transaction, always rolls back, prints CG002_TESTS ok=N fail=N
psql "$DATABASE_URL" -f supabase/tests/cg002_booking.sql
# (or paste it in the SQL editor / run it through the MCP apply_migration tool — a raised exception is never recorded)

# live API from a laptop — includes the two-parallel-holds race
node scripts/test-booking.mjs
```

## Payments (CG-003) — Stripe TEST mode only

Server-side Stripe Checkout, verified webhook, financial ledger. Live mode is
blocked in code (CHECK-LICENCE-001): `checkout` refuses non-`sk_test_` keys,
`stripe-webhook` refuses `livemode: true` events.

- **Tables**: `orders`, `payments`, `refunds`, `chargebacks`, `webhook_events`,
  `partner_earnings`, `partner_settlements`, `partner_settlement_items`,
  `email_events` (`supabase/migrations/20260904_cg003_payments.sql`).
- **RPCs** (service role only): `create_order_for_booking(ref, token)`,
  `attach_checkout(...)`, `process_stripe_event(jsonb)` (idempotent),
  `recompute_earning(order_id)`, `create_settlement(partner, from, to, currency)`,
  `mark_settlement_paid(ref, bank_ref)`, `mark_settlement_reconciled(ref)`.
- **`supabase/functions/checkout`** — `POST {ref, token}` → `{url}`. Amount and
  currency come from the database; request amounts are ignored. Returns 503
  `payments_not_configured` until the test key is set.
- **`supabase/functions/stripe-webhook`** — verifies `stripe-signature`,
  enriches the fee from the balance transaction, calls `process_stripe_event`,
  sends queued emails through Resend when configured. Returns 500 on a
  processing error so Stripe retries (processing is idempotent).
- **Frontend** (`assets/booking.js`): after the hold, "Pay" calls `checkout`
  and redirects; back on `/?booking=REF&t=TOKEN&paid=1#book` the page polls
  `state` until the webhook confirms. The success page is never authoritative.
- **Ledger** (minor units): net = gross − Stripe fee − refunds − lost
  chargebacks − tax; Oolala commission = max(0, round(net × 10 %)); Gari
  payable = net − commission. Settlements are manual bank transfers recorded
  with `mark_settlement_paid`.

Secrets (Supabase, never committed): `STRIPE_SECRET_KEY` (`sk_test_…`),
`STRIPE_WEBHOOK_SECRET` (`whsec_…`), optional `SITE_URL` (default
`https://coachgariv0.vercel.app`). Webhook endpoint:
`https://<project-ref>.supabase.co/functions/v1/stripe-webhook`, events
`checkout.session.completed`, `checkout.session.expired`, `refund.created`,
`refund.updated`, `charge.dispute.created`, `charge.dispute.updated`,
`charge.dispute.closed`.

### Payment tests

```
psql "$DATABASE_URL" -f supabase/tests/cg003_payments.sql
node scripts/test-checkout.mjs --wait
```

The database suite prints `CG003_TESTS ok=24 fail=0` and always rolls back.
The laptop script creates a hold, proves a forged amount is ignored, prints
the Checkout URL (pay with `4242 4242 4242 4242`) and waits for the webhook to
confirm the booking.

## Back-office (CG-002.5) — `/admin`

Lightweight operational back-office, no CMS. Sign-in by Supabase Auth magic
link; what a person sees is decided by the database, not by the page.

| Permission | Who | Gives |
|---|---|---|
| `coach:operations` | Gari | Leads (read + status), Calendar, Bookings (cancel / complete / no-show / confirm an unpriced hold), Availability, Exceptions, Tour stops |
| `finance:view` | Oolala | Orders (`finance_orders()`), payments, refunds, chargebacks, partner ledger, settlements, webhook log (`finance_webhook_log()`) — **without customer identity** |
| `finance:manage` | Oolala | Create settlements, mark paid (bank reference), mark reconciled |
| `analytics:view` | either | Aggregates only (leads per week / interest / country / source, bookings by status / service, revenue by month) |

There is no `content:*` permission: the website is edited in Git.

- **Mechanics** (`supabase/migrations/20260905_cg0025_backoffice.sql`):
  `app_users` + `app_permissions` keyed by email; `has_permission(text)` reads
  the JWT; grants to `authenticated` are on explicit column lists (never
  `manage_token`, `ip_hash`, `idempotency_key`, webhook payloads, and no
  customer columns on `orders`); RLS policies gate rows by permission;
  state changes go through `ops_set_booking_status`, `finance_*` and
  `analytics_summary` RPCs that check the permission themselves. `anon` keeps
  zero access.
- **Granting access** (owner, SQL editor — the person signs in with the same
  email afterwards):
  ```sql
  insert into public.app_users (email, display_name, party) values ('gari@example.com', 'Gari', 'gari');
  insert into public.app_permissions (email, permission) values ('gari@example.com', 'coach:operations');
  insert into public.app_users (email, display_name, party) values ('finance@example.com', 'Oolala', 'oolala');
  insert into public.app_permissions (email, permission) values ('finance@example.com', 'finance:view'), ('finance@example.com', 'finance:manage'), ('finance@example.com', 'analytics:view');
  ```
  Revoke by deleting the permission row or setting `app_users.active = false`.
- **Auth set-up** (owner, Supabase dashboard → Authentication → URL
  configuration): add `https://coachgariv0.vercel.app/admin/` and, later,
  `https://coachgari.com/admin/` to *Redirect URLs*. Magic links use Supabase's
  built-in mailer until a custom SMTP (Resend) is configured there.
- **Frontend**: `admin/index.html` + `admin/admin.js` (supabase-js UMD from
  jsdelivr, allowed by a dedicated CSP on `/admin*`), publishable key and
  project URL from `config.js`. Times are shown and entered in a chosen IANA
  zone and stored in UTC.

### Permission tests

```
psql "$DATABASE_URL" -f supabase/tests/cg0025_permissions.sql
```

Prints `CG0025_TESTS ok=73 fail=0` and rolls back. It switches role and JWT
claims per persona (anon, signed-in stranger, inactive user, coach, finance,
analytics) and asserts the negatives: anon is refused everywhere; a coach
cannot read orders, payments, the ledger or `manage_token`; finance cannot
read leads, bookings or customer names; analytics sees no row-level data and
its output contains no lead body or contact.

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

The repo is linked to the Vercel project **`coachgari_v0`**
(`prj_YCx9wcCieYVzzc1NBp2oRWoW8Zwp`, team *Mickael's projects*, framework
*Other*, no build step). Every push builds automatically.

| URL | What |
|---|---|
| `https://coachgariv0.vercel.app` | production alias (follows the production branch) |
| `https://coachgariv0-git-claude-coach-325c7d-mickaels-projects-6a9e3bf2.vercel.app` | stable alias of the dev branch |

Three project settings only the owner can change (the MCP token gets `403`):

1. **Deployment Protection → Vercel Authentication → Off.** It is currently on
   for all deployment URLs (`all_except_custom_domains`), so every preview
   redirects to a Vercel login — nobody outside the team can open the link, and
   the browser gate test cannot be run. (Custom domains are never affected.)
2. **Git → Production Branch → `main`** (currently `claude/coach-gari-repo-setup-e4d7ep`).
3. **Domains → `coachgari.com` + `www`** once DNS is ready.

The CSP in `vercel.json` only allows `connect-src` to the Supabase project host.
If the project ref ever changes, update it there too.

## CG-001 gates

Three separate gates — only the last depends on the production domain.

| Gate | Proves | Status |
|---|---|---|
| `GATE-HTTP-001` | frontend → Edge Function → validation → `contacts`; idempotent; attribution kept | API steps passed 2026-09-03 (7/7); browser double-click step: run below |
| `GATE-EMAIL-001` | Resend configured, sender validated, real mail to `letsgo@`, `notified_at` set | owner config (`RESEND_API_KEY`) |
| `GATE-DOMAIN-001` | all of the above on `coachgari.com`, CORS tightened, Plausible verified | owner config (DNS, Vercel domain, Migadu, SPF/DKIM) |

### GATE-HTTP-001 — how to run it

No domain needed: run it on `https://coachgariv0.vercel.app`.

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

### Verified (2026-09-03)

- **Step A passed from a laptop — 7/7 checks** on function **v2**: accepted
  (200 + id), same `submission_id` deduplicated to the same id, honeypot
  silently dropped, validation 400 with fields, foreign origin 403, GET 405,
  CORS header echoed.
- **Step C passed**: exactly one row in `contacts`
  (`4c74846a-c0ea-4983-9094-3b823c413498`), `city`/`country` split from the
  location field, all five attribution fields + `first_visit_at` + `page`
  stored, `notified_at` null with the expected `notify_skipped`
  (`RESEND_API_KEY` not configured) log line. Function logs contain only event
  names and record ids — no message, contact or IP.
- Schema: `submission_id` unique index; `status` check constraint; RLS on with
  **zero** policies and **no** grants to `anon`/`authenticated`; `updated_at`
  trigger with pinned `search_path`. Security advisors: only the intentional
  "RLS enabled, no policy" notice.
- Vercel: `main` deployed to production (`coachgariv0.vercel.app`), Vercel
  Authentication off. Checked on the live deployment: homepage 200 with the
  full security header set (CSP, HSTS, nosniff, frame DENY, referrer,
  permissions); `/routes/c` resolves to the homepage; proposal and archived
  routes carry `noindex` both as meta and `X-Robots-Tag`; `config.js` and the
  photo are served; no secret in any served file. The old-filename redirects
  needed clean-URL-aware sources (`cleanUrls` strips `.html` before redirects
  are evaluated) — fixed in `vercel.json`.

v1 of the function returned `502` on every call: the `jsr:` types-only import
made the worker fail to boot. v2 dropped it. Nothing else changed.

Clean-up of the test row: `delete from public.contacts where interest = 'TEST — safe to delete';`

### Not yet run — and why

- **Step B (browser, visible success state, double-click)**: needs the Vercel
  preview to be reachable, i.e. *Deployment Protection → Vercel Authentication
  → Off* (owner-only setting). Not domain-dependent.
- **Step D / GATE-DOMAIN-001**: the same run on `https://coachgari.com`, after
  DNS, Resend domain verification, mailboxes and CORS tightening. See
  `docs/DECISIONS.md`.

## Local checks

```
npx htmlhint "index.html" "p/**/*.html" "routes/**/*.html"
node scripts/check-links.mjs
```

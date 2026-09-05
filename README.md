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
│   ├── migrations/               → contacts · booking engine · payments/ledger · permissions/RLS · enquiry media
│   ├── functions/                → contact · booking · checkout · stripe-webhook · upload (Edge Functions)
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
  UPLOAD_ENDPOINT: '…/functions/v1/upload',     // CG-004 signed uploads for enquiry attachments; '' = field hidden
  SUPABASE_URL: 'https://acrjrlgeeyseyolmofuq.supabase.co',   // back-office
  SUPABASE_PUBLISHABLE_KEY: 'sb_publishable_…',               // public by design; RLS protects every row
  STUDIO_URL: 'https://thestudio.mt',    // "Studio MT" footer credit
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

## Enquiry attachments (CG-004 / CG-006)

Every category of the enquiry form accepts up to **3 photos or videos, 50 MB
in total**. The lead is stored first; files follow and never block it.

- **Flow**: `contact` stores the enquiry and returns a one-off `upload_token`
  (256-bit random, only its SHA-256 is stored on the enquiry, valid 30
  minutes, one enquiry only) → for each file the browser calls
  `supabase/functions/upload` with `{action:"sign", upload_token, filename,
  content_type, size}` → gets a signed upload URL for the private bucket
  `enquiry-media` → `PUT`s the raw file → calls `{action:"confirm",
  upload_token, path}`. The browser-generated `submission_id` is only an
  idempotency key; it is never accepted as an upload credential. A duplicate
  or retried enquiry never receives a token again.
- **Limits, enforced three times**: browser (validation before Send), database
  (`reserve_contact_media`: token, 3 files, 50 MB total, strict MIME
  allowlist, advisory lock) and bucket (`file_size_limit` 50 MB,
  `allowed_mime_types`). Allowlist: `image/jpeg, png, webp, heic, heif, gif`
  and `video/mp4, quicktime, webm, x-m4v, 3gpp` — no SVG, no PDF, nothing
  executable, no `image/*` wildcard. A check constraint on `contact_media`
  uses the same list.
- **Table** `public.contact_media` (`storage_path`, `original_name`,
  `content_type`, `size_bytes`, `status` pending/uploaded/failed).
- **Access**: only `coach:operations` reads rows and objects (RLS on the table
  and on `storage.objects`); the Leads tab lists the files and opens each one
  with a 10-minute signed URL. Finance, analytics, `platform:admin` and anon
  see nothing. No browser holds a privileged key.
- **Off switch**: empty `UPLOAD_ENDPOINT` in `config.js` hides the field.
- Not done on purpose: virus scanning, transcoding.

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
node scripts/test-webhook-signature.mjs                                # offline, CI: Stripe signature scheme, 24 cases
STRIPE_WEBHOOK_SECRET=whsec_… node scripts/test-webhook.mjs            # laptop: signed probes against the deployed function
psql "$DATABASE_URL" -f supabase/tests/cg003_payments.sql              # ledger / idempotency, rolls back
node scripts/test-checkout.mjs --wait                                  # real Stripe round trip
```

Signature verification is Stripe's own scheme, implemented in
`supabase/functions/stripe-webhook/signature.js` and imported by the Edge
Function: `Stripe-Signature: t=…,v1=…`, HMAC-SHA256 over `${t}.${raw body}`
with `STRIPE_WEBHOOK_SECRET`, constant-time compare against every `v1`, 300 s
tolerance on `t`. The raw request body is verified before any parsing.

The database suite prints `CG003_TESTS ok=24 fail=0` and always rolls back.
The laptop script creates a hold, proves a forged amount is ignored, prints
the Checkout URL (pay with `4242 4242 4242 4242`) and waits for the webhook to
confirm the booking.

## Back-office (CG-002.5 → CG-009) — one cockpit at `/admin`

One operating cockpit: a sidebar of destinations (a drawer on mobile), a
minimal top header with the page name and an account menu (Sign Out lives
inside it), and — for people — a large client-profile popup. Every
destination is a permission-gated tab; sign-in is a Supabase Auth magic link
with `shouldCreateUser: false`, so an email the owner has not invited cannot
even create an auth user. What a person sees is decided by the database, not
the page; the page never writes permissions directly. Navigation:
**Overview · CRM · Schedule · Bookings · Services · Finance · Analytics ·
Access**. Schedule merges the four time-management domains (Calendar, Weekly
availability, Exceptions, Tour stops) as sub-tabs; CRM has Leads + Contacts.

| Permission | What it unlocks in `/admin` |
|---|---|
| `coach:operations` | CRM › Leads (enquiries, clickable to the client popup), Schedule (Calendar / Availability / Exceptions / Tour stops), Bookings; the Enquiries / Bookings / Media / Attribution sections of a client profile |
| `client_profile:view` | CRM › Contacts (canonical people with enquiry/booking counts) and the profile Overview / Notes |
| `client_profile:manage` | Edit a canonical profile, create a contact, add / edit internal notes (all through audited RPCs) |
| `health_metrics:view` | The Progress section of a profile: weight, BMI, body-fat, muscle history |
| `health_metrics:manage` | Record / correct body measurements (BMI is derived, never typed) |
| `catalog:view` | Services — the whole commercial catalogue, listed or not, and its change log |
| `catalog:manage` | Services — create / edit through the audited `catalog_save_service` RPC (title, descriptions, price, currency, duration, delivery, capacity, booking mode, active, listed, order, features) |
| `finance:view` | Finance — Orders (`finance_orders()`), payments, refunds, chargebacks, partner ledger, settlements, webhook log (`finance_webhook_log()`). No name, no contact, no enquiry — only a masked `customer_hint` (`p***@example.com`, `•••••••00`) to match a Stripe receipt |
| `finance:manage` | Finance — create settlements, mark paid (bank reference), mark reconciled |
| `analytics:view` | Analytics — aggregates only (leads per week / interest / country / source, bookings by status / service, revenue by month); output asserted free of names, emails, phones, references |
| `platform:admin` | Access — list application users, activate / deactivate, grant / revoke permissions. **Nothing else**: no lead, booking, order or ledger row becomes visible through it (tested) |

**One cockpit, independent permissions (CG-008).** Finance is a tab in
`/admin`, not a separate app — the earlier `/admin` vs `/finance` split
reflected a superseded access model. `/finance` is kept only as a deep link
that redirects to the Finance tab (`/admin#finance`). Merging the *UI* does
not merge the *rights*: `finance:view` and `finance:manage` remain
independent permissions, tab visibility is permission-driven, and the
Finance tab plus its RPCs (under RLS) disappear the moment the permission is
removed. Permissions are additive; a person simply sees one tab per
permission they hold. There is no owner, superadmin or RLS-bypass role, and
no `content:*` permission: the website is edited in Git.

- **Mechanics** (`20260905_cg0025_backoffice.sql`, `20260907_cg006_access_and_upload_tokens.sql`, `20260908_cg007_catalogue.sql`; navigation unified in CG-008):
  `app_users` + `app_permissions` keyed by email; `has_permission(text)` reads
  the JWT; grants to `authenticated` are on explicit column lists (never
  `manage_token`, `ip_hash`, `idempotency_key`, `upload_token_hash`, webhook
  payloads, and no customer columns on `orders`); RLS policies gate rows by
  permission; state changes go through `ops_set_booking_status`, `finance_*`,
  `analytics_summary` and `admin_*` RPCs that check the permission
  themselves. `anon` keeps zero access.
- **Provisioning is operational data, never a migration.** Invitation only,
  no fake records: every provisioning path refuses an email that has no
  `auth.users` identity (`P0002`). Two steps for the owner:
  1. Supabase → Authentication → Users → *Invite user* (also turn off *Allow
     new users to sign up* under Auth settings as belt and braces).
  2. Attach access, idempotently (re-running replaces the permission set):
  ```sql
  -- SQL editor (runs as service role). Placeholders — real emails are never committed.
  select public.set_app_access('<owner-email>',   'Name', 'studio', array['coach:operations','finance:view','finance:manage','analytics:view','catalog:view','catalog:manage','client_profile:view','client_profile:manage','health_metrics:view','health_metrics:manage','coaching_sensitive:view','coaching_sensitive:manage','platform:admin']);
  select public.set_app_access('<coach-email>',   'Name', 'gari',   array['coach:operations','finance:view','finance:manage','analytics:view','catalog:view','catalog:manage','client_profile:view','client_profile:manage','health_metrics:view','health_metrics:manage','coaching_sensitive:view','coaching_sensitive:manage']);
  ```
  From then on a `platform:admin` can do the same from the Access tab
  (`admin_set_user`, `admin_grant`, `admin_revoke`); a person can never
  deactivate themselves or revoke their own `platform:admin`, and nobody can
  write `app_users` / `app_permissions` directly through the API. Revoke by
  unticking a permission or deactivating the user; effect is immediate.
- **Auth set-up** (owner, Supabase dashboard → Authentication → URL
  configuration): add `https://coachgariv0.vercel.app/admin/` and, later, the
  `https://coachgari.com` equivalent to *Redirect URLs*. Sign-in always lands
  on `/admin/` now; `/finance` is a Vercel redirect to `/admin#finance`, not a
  sign-in target. Magic links use Supabase's built-in mailer until a custom
  SMTP (Resend) is configured there.
- **Frontend**: `admin/index.html` + `admin/admin.js` (supabase-js UMD from
  jsdelivr, allowed by a dedicated CSP on `/admin*`), publishable key and
  project URL from `config.js`. Times are shown and
  entered in a chosen IANA zone and stored in UTC.

### Permission tests — fail the build on a boundary violation

```
psql "$DATABASE_URL" -f supabase/tests/cg0025_permissions.sql   # one suite
DATABASE_URL=postgresql://… scripts/db-tests.sh                   # all three suites, exit 1 on any fail
```

`CG0025_TESTS ok=236 fail=0`, always rolled back. It switches role and JWT
claims per persona and asserts the negatives: anon is refused on every private
table and RPC (including the `admin_*`, `set_app_access`, `issue_upload_token`
and `reserve_contact_media` functions); a stranger or inactive user gets zero
rows and every RPC refused; a coach cannot read orders, payments, refunds,
chargebacks, settlements, settlement items, the webhook log, `manage_token`,
`ip_hash` or `upload_token_hash`, cannot issue upload tokens, and cannot
insert, update or delete permissions (directly or through `admin_grant`);
finance cannot read leads, the message column, bookings, customer names or
`email_events`, and cannot grant itself operations; analytics output contains
no lead body and matches no email, phone or booking-reference pattern.
CG-006 adds a **composite launch persona** (operations + finance + analytics
in one identity reaches leads, bookings, calendar, attachments, orders,
payments, ledger, settlements, webhook log and analytics, still without
`manage_token`, customer columns, raw payloads or access administration) and a
**`platform:admin`-only persona** (lists and edits access; sees zero rows in
every business table and is refused every business RPC; cannot write the
access tables directly, cannot call `set_app_access`, cannot revoke its own
`platform:admin`, cannot create a user without an auth identity; a business
permission it grants itself is the only thing that opens business data, and
revoking it closes them again), and a **catalogue persona** (reads unlisted
services and the audit log; cannot read leads, bookings, orders or call
finance RPCs; cannot write `services` or `catalog_audit` directly; the RPC
validates slug, title, price and booking mode, audits a price change with
before / after, writes nothing on an identical save, creates a new service;
the existing paid booking, order, ledger and finance view keep 4500 and the
old title after the change while a new hold takes 9900 / 90 min / the new
title; an enquiry-only product cannot be held). The upload-token block proves the
`submission_id` and the contact id are refused as credentials, wrong, null and
expired tokens are refused, re-issuing rotates the token, and PDF, SVG, EXE,
HTML, octet-stream and MKV are rejected by the RPC, the table constraint and
the bucket. It also proves booking correctness does not depend on `pg_cron`.
CI runs `scripts/db-tests.sh` when the `SUPABASE_DB_URL` repository secret
(session-pooler URI) is set and fails the build otherwise-than-`fail=0`;
without the secret the job is skipped with a notice. The suite runner also
runs `cg002_booking` (28), `cg003_payments` (24) and `cg009_crm` (43).

## CRM, client profile & progress (CG-009)

An enquiry is a submission, not a person. `public.crm_contacts` is the
canonical person; many enquiries (`public.contacts`) and many bookings link
to it through a back-filled `crm_contact_id`.

- **Conservative matching, never a name merge.** A `before insert` trigger
  on `contacts` and `bookings` calls `crm_link_contact`, which normalises the
  email and matches it only when a *single* contact has it; else it
  normalises the phone and matches that when unambiguous; else it creates a
  new person. Two people that merely share a name are never merged; an
  ambiguous match (an email already on two people) creates a fresh record
  flagged `needs_review` for a manual merge later. A direct booking with no
  prior enquiry still lands a CRM contact. Enquiry rows are never rewritten.
- **Client profile popup.** Leads and Contacts rows open a large responsive
  dialog over the list (the list keeps its tab, filters, search and scroll).
  Sections are permission-gated: Overview / Notes (`client_profile:*`),
  Progress (`health_metrics:*`), Enquiries / Bookings / Media / Attribution
  (`coach:operations`), Payments (`finance:view`). Media reuses the private
  enquiry bucket via 10-minute signed URLs — no second copy.
- **Notes are a history**, not one overwriteable field: `public.crm_notes`
  keeps author, timestamp, optional category and pin; edits are audited.
- **Body measurements** (`public.body_measurements`) are longitudinal: each
  row snapshots the height used, and **BMI is a generated column**
  (`weight / (height/100)²`, rounded) — never typed or independently
  editable, so historical BMI stays reproducible. Ranges are validated
  (height 50–260 cm, weight 20–500 kg, percentages within limits); a partial
  measurement (weight only) is accepted; absurd values are rejected, not
  coerced. No medical interpretation is produced.
- **Permissions stay independent.** `finance:*` and `analytics:*` never imply
  the profile or the metrics; `analytics_summary` output is asserted free of
  note bodies and measurements. Writes go only through permission-checked
  RPCs (`crm_save_contact`, `crm_add_note`, `crm_edit_note`, `metrics_add`,
  `metrics_edit`); the tables have no direct write grant, anon has nothing,
  and changes are recorded in `public.admin_audit`.
- **Tests** (`supabase/tests/cg009_crm.sql`, `CG009_TESTS ok=43 fail=0`):
  matching (email / phone / ambiguous / same-name), enquiry immutability,
  direct-booking linkage, note authz + audit, metric history + height
  snapshot + BMI correctness + BMI-not-writable + partial + range rejection,
  and that coach / finance / analytics personas cannot reach profiles, notes
  or metrics.

## Service catalogue (CG-007) — the one admin-editable content

The commercial catalogue lives in `public.services` and is the **only**
content edited from the back-office. Everything else on the website stays
in Git. No CMS, no `site_content` table.

- **Route C renders from it.** The four programme cards and the booking
  picker are built by `assets/site.js` / `assets/booking.js` from the
  public booking function (`?action=services`, active + listed rows). No
  price, title, duration, description or feature list is hard-coded in
  `index.html`. The Conversation shows `60 min · 100 USD · online` because
  the row says so.
- **Fields**: slug (identity, immutable), title, tagline, short description
  (card), long description, features (max 8), price (minor units, empty =
  on request), currency, price unit (`per session` / `per month` /
  `one-off` / `per person`), duration, delivery mode, default capacity,
  booking mode, featured, CTA label, active, listed, display order.
- **Booking mode**: `slot` = offered in the picker at the listed price and
  charged exactly that amount at Checkout; `enquiry` = a card whose button
  opens the enquiry form with the matching interest preselected. An
  enquiry-only product can never be held (`create_hold` refuses it). Prices
  of enquiry-only products are shown only while `COMMERCE: true` in
  `config.js`; a bookable service always shows its price.
- **Writes** go only through `catalog_save_service(jsonb)` (requires
  `catalog:manage`; `authenticated` has no insert / update / delete grant on
  `services`; anon has nothing). Values are validated by the table
  constraints. Services are never deleted — deactivate and hide instead.
- **Audit**: every create / update writes a `catalog_audit` row (who, when,
  changed fields, before / after JSON); identical saves write nothing. The
  Services tab shows the change log; `catalog:view` can read it, nobody can
  write it directly.
- **Historical integrity**: `create_hold` snapshots slug, title, duration
  and price on the booking (a `before insert` trigger fills them for any
  other insert path); `create_order_for_booking` copies the title and the
  amount to the order. `finance_orders()`, `booking_to_json`,
  `order_to_json` and the Stripe line item read the snapshot. Changing a
  service afterwards affects future bookings only — tested: after a price
  and title change, the existing paid booking, its order, its ledger row and
  its finance view keep the original values; a new hold takes the new ones.

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

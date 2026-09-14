# Coach Gari

Static site for Coach Gari, plus one public Edge Function that receives the
enquiry form. Two design systems, one shared config, no secrets in the repo.

Sprint log and blockers: [`docs/DECISIONS.md`](docs/DECISIONS.md).

**Status — what the code implements.** Canonical customer origin
`https://coachgari28.com` (`supabase/functions/_shared/cors.ts`, the `SITE_URL`
default of every payment function); `coachgari.com` / `www` are kept in the
CORS allowlist as the earlier / future apex, to be served as a redirect to the
canonical host. Payments run through Stripe Embedded Checkout with the mode
declared by `PAYMENTS_MODE` (`test` | `live`): the key's mode must match it,
a webhook whose `livemode` differs is refused, an unset mode refuses
everything — the code never guesses. Booking, back-office, CRM, calendar,
reports, BEAU PH payment hub and the transactional-email outbox are built and
covered by the suites listed below.

**What only the owner can confirm** (infrastructure, not visible in this
repo — nothing below is asserted as done):

- Vercel domains: `coachgari28.com` + `www` attached to `coachgari_v0`, and
  `coachgari.com` + `www` attached as a redirect to the canonical host.
- The value of `PAYMENTS_MODE` and the Stripe key pair on the Supabase project
  (secrets are write-only; the deployed function reports only
  `{configured, mode, reason}`).
- Resend sender domain verified, with SPF / DKIM / DMARC published; the
  sender domain itself (see "Emails" below).
- The mailboxes behind `letsgo@` and `yoursession@`.
- The first back-office grants (`platform:admin` for the owner, see
  "Back-office").

The historical gates `GATE-DOMAIN-001` and `CHECK-LICENCE-001` in
`docs/DECISIONS.md` are superseded by the above; they are kept there as the
decision trail.

## Structure

```
/
├── index.html                    → the site (Route C) — served at coachgari28.com/ (canonical)
├── p/studio-mt-4e7a/index.html   → Studio MT proposal — unlinked, noindex, public by URL
├── routes/
│   ├── a/index.html              → archived Route A (noindex, still served)
│   └── b/index.html              → archived Route B (noindex, still served)
├── assets/
│   ├── coach-gari.css            → Coach Gari design system (white / #1540E8 / Manrope)
│   ├── studio-mt.css             → Studio MT design system (platinum / #1A3832 / Cormorant)
│   ├── site.js                   → reveal · catalogue (SHOW_PUBLIC_ENQUIRY_PRICES) · WhatsApp · attribution · form · config injection
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
│   ├── test-booking-picker.mjs   → booking picker: 3 families → child → availability (Playwright, offline)
│   └── test-checkout.mjs         → CG-003 Stripe Checkout round trip (in the project's PAYMENTS_MODE)
├── docs/DECISIONS.md             → decisions & documented blockers
├── vercel.json                   → clean URLs, redirects, security headers, noindex headers
└── .github/workflows/ci.yml
```

`/routes/c` redirects permanently to `/`. The old file names
(`coach-gari-*.html`, `studio-mt-coach-gari.html`) redirect to their new homes.

## `config.js` — public values only

```js
export const CONFIG = {
  SHOW_PUBLIC_ENQUIRY_PRICES: false,     // enquiry-only product prices hidden ("On request"), CTAs go to the form / WhatsApp; true = prices + data-checkout buttons. Not a commerce switch: booking + Checkout run regardless
  WHATSAPP: '971521365065',              // digits only → wa.me links with a pre-filled message
  FORM_ENDPOINT: 'https://acrjrlgeeyseyolmofuq.supabase.co/functions/v1/contact',
  BOOKING_ENDPOINT: '…/functions/v1/booking',   // CG-002 public booking API
  CHECKOUT_ENDPOINT: '…/functions/v1/checkout', // CG-003 Stripe Checkout (mode = PAYMENTS_MODE secret); '' = payment step off
  UPLOAD_ENDPOINT: '…/functions/v1/upload',     // CG-004 signed uploads for enquiry attachments; '' = field hidden
  SUPABASE_URL: 'https://acrjrlgeeyseyolmofuq.supabase.co',   // back-office
  SUPABASE_PUBLISHABLE_KEY: 'sb_publishable_…',               // public by design; RLS protects every row
  STUDIO_URL: 'https://thestudio.mt',    // "Studio MT" footer credit
  SOCIAL_URL: 'https://myoolala.com/u/coachgari28',
  COMMISSION_RATE: '10%',                // shown in the proposal
  PLAUSIBLE_SCRIPT: 'https://plausible.io/js/pa--….js',   // '' = analytics off; the site's script URL from Plausible
};
```

## Analytics (Plausible)

Aggregate, cookie-free website analytics, **on**. `config.js` carries the
site's own script URL (`PLAUSIBLE_SCRIPT`, the `pa--<site id>.js` file from the
Plausible dashboard; the id is public, nothing secret). `site.js` runs
Plausible's queue/init bootstrap and loads that script; it lives in `site.js`
rather than inline in the HTML because the CSP allows scripts from `'self'`
and `plausible.io` only, never inline. Set `PLAUSIBLE_SCRIPT: ''` to switch
analytics off. No other tracker is, or should be, added. Conversion
attribution stays the first-touch UTM data captured with each enquiry.

This file is served to every visitor. It must never contain a key, a token or
a service role. All secrets live in the Supabase Edge Function environment.

## Emails

| Address | Role |
|---|---|
| `letsgo@` | Leads and every human exchange. Shown on the site. Reply-To on all mail by default. |
| `yoursession@` | Transactional sender: confirmations, cancellations, reschedules, receipts. |
| `collab@` | Reply-To on every collaboration mail (`collab_*` kinds), to the requester and to the owner alike. |
| `hugs@` | Reply-To on the support thank-you (`support_thanks`). |

`collab@` and `hugs@` are routed by message kind in
`reply_to_for()` (`supabase/functions/_shared/email.ts`) and each stays
overridable by its own secret — `EMAIL_REPLY_TO_COLLAB`, `EMAIL_REPLY_TO_HUGS`
— exactly like `EMAIL_REPLY_TO` for the general mailbox. A lead notification
still replies to the customer who wrote in; everything else falls back to
`letsgo@`. **Both mailboxes must exist and be read** — the repo cannot check
that.

**Sender domain — to be confirmed by the owner.** The site's `mailto:` link
and the code defaults use `@coachgari28.com`
(`supabase/functions/_shared/email.ts`, `email_owner_address()` in
`20261009_cg_email_outbox.sql`); older, already-applied migrations still
carry `@coachgari.com` in comments and seed defaults. The address that actually sends is the
one behind the `EMAIL_FROM` / `EMAIL_REPLY_TO` secrets, on a domain the owner
has verified in Resend (SPF / DKIM / DMARC); neither the verification nor the
mailboxes can be checked from this repo.

Templates and rendering live in `supabase/functions/_shared/email.ts` (the
`emails/` folder holds the original HTML drafts). Which kinds are wired is
listed under "Transactional email" below.

## The enquiry form (CG-001)

**Browser** (`assets/site.js`) → **Edge Function** `contact` → **`public.contacts`**
→ **Resend** lead notification to `letsgo@` and acknowledgement to the
customer through the email outbox (sent when `RESEND_API_KEY` is configured,
queued otherwise).

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
- **Card payments**: Stripe **Embedded** Checkout mounted in the page (report
  `/r/<token>` and the booking flow); dynamic `price_data` from the order
  snapshot, no Stripe Products / Prices; only the verified webhook marks paid.
  Config (Supabase secrets): `PAYMENTS_MODE`, `STRIPE_SECRET_KEY`,
  `STRIPE_WEBHOOK_SECRET`, `STRIPE_PUBLISHABLE_KEY` (public, mode-checked),
  `SITE_URL` (default `https://coachgari28.com`).
- **CORS**: `https://coachgari28.com` (canonical), `https://www.coachgari28.com`,
  `https://coachgari.com`, `https://www.coachgari.com`,
  `https://coachgariv0.vercel.app` + `coachgariv0-*` branch previews,
  `localhost` (dev). One shared allowlist for every browser-facing function:
  `supabase/functions/_shared/cors.ts` (never `*`; allowed origin echoed).
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

## Payments (CG-003) — Stripe, mode gated by `PAYMENTS_MODE`

Server-side Stripe Checkout, verified webhook, financial ledger. The payment
mode is declared, never guessed: `PAYMENTS_MODE=test` accepts only an
`sk_test_` key and only `livemode:false` events; `PAYMENTS_MODE=live` accepts
only an `sk_live_` key and only `livemode:true` events; unset/unknown refuses
payment creation and every webhook (`payments_not_configured` /
`payments_mode_unset`). The BEAU PH merchant `coach_gari` is intended **live**
(`beau_ph.merchants.mode`); the DB refuses a runtime or an event whose mode
differs from it. Oolala's Stripe account is the merchant (no Connect).

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

Secrets (Supabase, never committed): `STRIPE_SECRET_KEY` (mode must match
`PAYMENTS_MODE`), `STRIPE_WEBHOOK_SECRET` (`whsec_…`), `PAYMENTS_MODE`
(`test` | `live`; set with `supabase secrets set PAYMENTS_MODE=live`), `STRIPE_PUBLISHABLE_KEY` (`pk_…` of the same mode; public, needed for the
embedded card form), `SITE_URL` (default `https://coachgari28.com`, the
canonical customer origin; set it only for a preview / dev fallback). Webhook endpoint:
`https://<project-ref>.supabase.co/functions/v1/stripe-webhook`, events
`checkout.session.completed`, `checkout.session.expired`, `refund.created`,
`refund.updated`, `charge.dispute.created`, `charge.dispute.updated`,
`charge.dispute.closed`.

### Payment tests

```
node scripts/test-webhook-signature.mjs                                # offline, CI: Stripe signature scheme, 24 cases
STRIPE_WEBHOOK_SECRET=whsec_… node scripts/test-webhook.mjs            # laptop: signed probes against the deployed function
REPORT_TOKEN=<64-hex> node scripts/e2e-runtime.mjs [--pay] [--wait]    # laptop: BEAU PH runtime E2E on the deployed /r page (view, Aani/bank without payment, Stripe checkout in the project's PAYMENTS_MODE — --pay charges a real card when the mode is live, webhook → pack)
psql "$DATABASE_URL" -f supabase/tests/cg003_payments.sql              # ledger / idempotency, rolls back
node scripts/test-checkout.mjs --wait                                  # real Stripe round trip
node scripts/test-admin-workspace.mjs                                  # offline (Playwright, mocked Supabase): Finance / BEAU PH workspace lazy loading, 34 checks
node scripts/test-admin-pwa.mjs                                        # offline (Playwright): back-office PWA — manifest, icons, /admin/-scoped worker, shell cache, no data cached, offline shell, code sign-in, 18 checks
node scripts/test-booking-picker.mjs                                   # offline (Playwright, mocked booking API): picker hierarchy, availability timing, error/retry, 390 px, 40 checks
psql "$DATABASE_URL" -f supabase/tests/beau_ph_contract.sql            # BEAU PH contract incl. rail configuration + FX, rolls back
psql "$DATABASE_URL" -f supabase/tests/cg013_support.sql               # Support Coach Gari: server-side amount / rail authority, webhook-only paid, no side effects
psql "$DATABASE_URL" -f supabase/tests/cg014_email.sql                 # email outbox: one row per event, replay-safe, send failure never touches booking / payment, 47 checks
node scripts/test-email.mjs                                            # offline: Resend module (config presence, templates, Idempotency-Key, retry, no key in logs), 34 checks
node scripts/test-anchors.mjs                                          # offline (Playwright): header / footer anchors, aliases, header-aware landing, reduced motion, 33 checks
```

### Transactional email (Resend)

One outbox, `public.email_events`, queued by the authoritative state change and
drained by the Edge Functions (`supabase/functions/_shared/email.ts`):

| Event | Queued by | Kind → recipient |
|---|---|---|
| booking paid (Stripe webhook, BEAU PH reconciled) | `process_stripe_event` → `email_on_order_paid` | `booking_confirmed` → customer · `payment_received` → letsgo@ |
| pack paid (Stripe, or Aani / bank / cash / PSP receipt) | `process_stripe_event` / `payment_record_manual` | `payment_confirmed` → client (CRM email) · `payment_received` → letsgo@ |
| Support Coach Gari paid | `process_stripe_event` | `support_thanks` → the email Stripe Checkout captured · `payment_received` → letsgo@ |
| confirmed booking cancelled (customer or coach) | `cancel_booking` / `ops_set_booking_status` | `booking_cancelled` → customer |
| the session of a confirmed booking moved in Schedule | trigger `sync_booking_from_session` | `reschedule` → customer (booking follows the session) |
| enquiry stored | `contact` function → `email_on_enquiry` | `lead_notification` → letsgo@ (Reply-To the customer) · `enquiry_received` → customer |

Every row carries a `dedupe_key` (`on conflict do nothing`), so a replayed
webhook or a re-run never queues twice; the same key is Resend's
`Idempotency-Key`. `stripe-webhook`, `contact` and `booking` drain their own
rows right away; `email-outbox` (called every two minutes by pg_cron → pg_net
with a database-issued key, `public.outbox_keys`) drains the rest and retries
failures with exponential backoff (6 attempts → `failed`, retryable from
`email_outbox_retry`). A send failure is only ever a row state. Delivery state:
`status`, `attempts`, `provider_message_id`, `error` — no address in the
operator view (`email_outbox_status`). Templates live in the shared module
(`emails/` mirrors them for review).

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
**Overview · CRM · Schedule · Bookings · Services · Finance · BEAU PH ·
Analytics · Access**. Schedule merges the four time-management domains
(Calendar, Weekly availability, Exceptions, Tour stops) as sub-tabs; CRM has
Leads + Contacts; Finance has Transactions (default) + Payment methods; BEAU PH
has Rails + FX (the embedded payment hub's operator workspace, see
`beau-ph/docs/`). Both launch users — Gari (`grej28roux@gmail.com`) and Mickaël
(`mickael@thestudio.mt`) — hold `finance:view` + `finance:manage`, so both see
Finance and BEAU PH; Gari's auth invite exists and completes on the first
magic-link sign-in.

| Permission | What it unlocks in `/admin` |
|---|---|
| `coach:operations` | CRM › Leads (enquiries, clickable to the client popup), Schedule (Calendar / Availability / Exceptions / Tour stops), Bookings; the Enquiries / Bookings / Media / Attribution sections of a client profile |
| `client_profile:view` | CRM › Contacts (canonical people with enquiry/booking counts) and the profile Overview / Notes |
| `client_profile:manage` | Edit a canonical profile, create a contact, add / edit internal notes (all through audited RPCs) |
| `health_metrics:view` | The Progress section of a profile: weight, BMI, body-fat, muscle history |
| `health_metrics:manage` | Record / correct body measurements (BMI is derived, never typed) |
| `catalog:view` | Services — the whole commercial catalogue, listed or not, and its change log |
| `catalog:manage` | Services — create / edit through the audited `catalog_save_service` RPC (title, descriptions, price, currency, duration, delivery, capacity, booking mode, active, listed, order, features) |
| `finance:view` | Finance — **Transactions** (one list across every rail: type, method, amount in the collected currency, normalised status, lazy detail drawer), Orders / ledger (`finance_orders()`), settlements, webhook log; **Payment methods** (the configured rails, read); **BEAU PH** — Rails (provider capability vs merchant configuration, deployment readiness as secret *presence*) and FX (rates, freshness, quotes). No name, no contact, no enquiry — only a masked `customer_hint` (`p***@example.com`, `•••••••00`) to match a Stripe receipt |
| `finance:manage` | Finance — create settlements, mark paid (bank reference), mark reconciled; configure / add / remove payment methods (inline editor, one confirmation, field-level audit); BEAU PH — configure rails, settlement destinations, FX settings, start a rate refresh |
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
  configuration): add `https://coachgari28.com/admin/` (canonical) and, while
  still in use, `https://coachgariv0.vercel.app/admin/` to *Redirect URLs* —
  owner to confirm which are present. Sign-in always lands
  on `/admin/` now; `/finance` is a Vercel redirect to `/admin#finance`, not a
  sign-in target. Magic links use Supabase's built-in mailer until a custom
  SMTP (Resend) is configured there.
- **Frontend**: `admin/index.html` + `admin/admin.js` (supabase-js 2.116.0 UMD
  self-hosted at `admin/vendor/`, exact version, served from `'self'` under the
  dedicated `/admin*` CSP — no CDN), publishable key and
  project URL from `config.js`. Times are shown and
  entered in a chosen IANA zone and stored in UTC.

### Permission tests — fail the build on a boundary violation

```
psql "$DATABASE_URL" -f supabase/tests/cg0025_permissions.sql   # one suite
DATABASE_URL=postgresql://… scripts/db-tests.sh                   # every database suite, exit 1 on any fail
```

`CG0025_TESTS ok=288 fail=0`, always rolled back. It switches role and JWT
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
The suite runner also runs `cg002_booking` (28), `cg003_payments` (24) and
`cg009_crm` (43).

**These suites are run by hand, not by CI** — see "Continuous integration"
below for why, and what CI does gate instead.

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
  of enquiry-only products are shown only while `SHOW_PUBLIC_ENQUIRY_PRICES: true` in
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
2. **Function** — deploy `supabase/functions/contact` **publicly** (every
   function deploys with `verify_jwt: false` and enforces its own boundary):
   `SUPABASE_ACCESS_TOKEN=… SUPABASE_PROJECT_REF=acrjrlgeeyseyolmofuq node scripts/deploy-functions.mjs --only contact`
   — the script builds the same multi-file bundle (entrypoint + relative
   imports from `_shared/` and `beau-ph/`) the project has always deployed;
   `--list` shows the bundles without deploying, `--changed <ref>` picks only
   the functions a diff touched. CI runs it on every push to `main`, and on
   demand — see "Continuous integration" below.
   The function uses `SUPABASE_URL` / `SUPABASE_SERVICE_ROLE_KEY` that Supabase
   injects automatically — do not set or copy them anywhere.
3. **Secrets** — set by the operator, never committed:
   ```
   supabase secrets set RESEND_API_KEY=re_...                                   # transactional email (Resend), server-side only
   supabase secrets set EMAIL_FROM="Coach Gari <yoursession@<sender domain>>"  # transactional sender — a domain verified in Resend (owner)
   supabase secrets set EMAIL_REPLY_TO=letsgo@<sender domain>                  # Reply-To on every customer email
   supabase secrets set IP_HASH_SALT=<random string, 32+ chars>                 # REQUIRED (owner) — salt for the contact/booking rate-limit IP hash; fail-closed like consent: without it ip_hash is null (submissions still work; the per-IP limit relies on the identity-independent global back-stop) and the function logs ip_salt_missing. Never the service-role key.
   supabase secrets set CONSENT_IP_SALT=<random string, 32+ chars>              # REQUIRED (owner) — consent/collab evidence salt (dedicated, never the service-role key); without it the consent is still recorded but its ip_hash is null (logs consent_ip_salt_missing)
   ```
   Without `RESEND_API_KEY` the lead is still stored, its emails wait in the
   outbox (`public.email_events`) and the function logs `email_skipped`.
   Nothing breaks. See "Transactional email" below.
4. `config.js` → `FORM_ENDPOINT` = `https://<project-ref>.supabase.co/functions/v1/contact`.

## Deploy (Vercel, git-connected)

The repo is linked to the Vercel project **`coachgari_v0`**
(`prj_YCx9wcCieYVzzc1NBp2oRWoW8Zwp`, team *Mickael's projects*, framework
*Other*, no build step). Every push builds automatically.

| URL | What |
|---|---|
| `https://coachgari28.com` | canonical customer origin (the code's `SITE_URL` default and CORS canonical) |
| `https://coachgari.com` (+ `www`) | earlier / future apex — kept in CORS; intended as a redirect to the canonical host |
| `https://coachgariv0.vercel.app` | Vercel production alias (follows the production branch) |
| `https://coachgariv0-git-claude-coach-325c7d-mickaels-projects-6a9e3bf2.vercel.app` | stable alias of the dev branch |

Project settings only the owner can see or change (the MCP token gets `403`),
so their state is **not** asserted here:

1. **Deployment Protection → Vercel Authentication → Off** for preview URLs
   (custom domains are never affected).
2. **Git → Production Branch → `main`** (the site auto-deploys from `main`).
3. **Domains** — `coachgari28.com` + `www` attached and serving;
   `coachgari.com` + `www` attached as a redirect to `coachgari28.com`; DNS
   finalised at the registrar.

The CSP in `vercel.json` only allows `connect-src` to the Supabase project host.
If the project ref ever changes, update it there too.

## CG-001 gates

Three separate gates. `GATE-DOMAIN-001` as originally written (everything on
`coachgari.com`) is superseded: the canonical origin is `coachgari28.com` and
the CORS allowlist is already the shared `_shared/cors.ts` (no wildcard). What
remains of it is owner infrastructure, listed under "Status" at the top.

| Gate | Proves | Status |
|---|---|---|
| `GATE-HTTP-001` | frontend → Edge Function → validation → `contacts`; idempotent; attribution kept | API steps passed 2026-09-03 (7/7); browser double-click step: run below |
| `GATE-EMAIL-001` | Resend configured, sender validated, real mail to `letsgo@`, `notified_at` set | code path built (outbox, `scripts/test-email.mjs`); delivery depends on owner config (`RESEND_API_KEY`, verified sender domain) — to confirm |
| `GATE-DOMAIN-001` | *superseded* — the same run on the canonical origin `https://coachgari28.com`; Plausible verified | owner to confirm (DNS, Vercel domains, mailboxes, SPF/DKIM/DMARC) |

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
- **Step D** (formerly `GATE-DOMAIN-001`): the same run on
  `https://coachgari28.com` — `CONTACT_ORIGIN=https://coachgari28.com node
  scripts/test-contact.mjs` from a laptop — once the owner confirms DNS, the
  Vercel domains, the Resend sender domain and the mailboxes. Not recorded as
  run in this repo.

## Local checks

```
npx htmlhint "index.html" "routes/**/*.html"
node scripts/check-links.mjs
```

Every offline suite, the same ones CI runs:

```
node scripts/test-webhook-signature.mjs   # WEBHOOK_SIGNATURE_TESTS ok=24
node scripts/test-collab.mjs              # COLLAB_TESTS ok=59
node scripts/test-url-scrub.mjs           # URL_SCRUB_TESTS ok=21
node scripts/test-contact-ip.mjs          # CONTACT_IP_TESTS ok=31
node scripts/test-email.mjs               # EMAIL_TESTS ok=41
node scripts/test-admin-workspace.mjs     # ADMIN_WORKSPACE_TESTS ok=34   ┐
node scripts/test-admin-pwa.mjs           # ADMIN_PWA_TESTS ok=18         ├ need Playwright
node scripts/test-booking-picker.mjs      # BOOKING_PICKER_TESTS ok=41    ┘
node --experimental-strip-types scripts/test-stripe-embedded.mjs   # STRIPE_EMBEDDED_TESTS ok=42
```

The three marked suites drive a real browser. They find Playwright in the
project if it is installed there, otherwise through `npm root -g` — no
download, no network. Without it they fail loudly rather than skipping.

## Push notifications for the back-office (CG-017)

A buzz on the phone when an enquiry, a booking, a payment or a collaboration comes
in. Offered from the back-office itself, to someone already signed in with access —
the browser shows the permission prompt once and remembers the answer, so it is
never spent on whoever loads the URL.

**A notification carries a kind, never a row.** `push_events` has no payload column
at all; the Edge Function turns the kind into a fixed sentence — "New booking",
"Payment received", "New enquiry". A notification lands on a lock screen, which is
not a private place, and the service worker already makes a point of keeping no
data on the device. Tapping one opens `/admin/`, which asks for a session as
usual: the notification carries no access of its own.

**One hook, not a dozen.** A trigger on `email_events` queues a push whenever a row
is addressed to `email_owner_address()`. Every owner-facing event, present and
future, reaches the phone without a second wiring to remember.

| Piece | Where |
|---|---|
| Sender: VAPID (RFC 8292) + aes128gcm (RFC 8188/8291), Web Crypto only | `supabase/functions/_shared/webpush.ts` |
| Drain + status, keyed like the email outbox | `supabase/functions/push/index.ts` |
| Subscriptions, outbox, trigger, RLS | `supabase/migrations/20261033_cg_push_notifications.sql` |
| `push` / `notificationclick` handlers | `admin/sw.js` |
| Banner, permission request, subscribe | `admin/admin.js` (`offerNotifications`) |

**Keys.** The VAPID private key and the drain key live in Supabase Vault
(`push_vapid_private`, `outbox_push_key`); `public.outbox_keys` keeps only a
SHA-256 and authorisation compares in constant time, the shape 20261018 set for
the email drain. Only the public half sits in a table, because the browser needs
it to subscribe. Rotating either is a Vault update plus the matching hash.

```
node --experimental-strip-types scripts/test-push.mjs   # PUSH_TESTS ok=22 — encryption round-trip, VAPID
psql "$DATABASE_URL" -f supabase/tests/cg017_push.sql   # CG017_TESTS ok=25 — boundaries, queue, rolls back
```

The offline suite plays the browser: it generates a subscription keypair, has the
sender encrypt to it, decrypts with the private half and compares, and checks
another browser's keys cannot read the same record. If any of the five key
derivation steps were wrong the decryption would fail and the suite would go red.

**Installing the back-office** is offered by the same banner, under the same gate.
On Android Chrome it is a button; on iOS there is no such browser event, so it
shows Safari's Share → Add to Home Screen instruction instead. iOS also only
delivers push to a site added to the Home Screen, so the notifications banner
waits until the app is installed there.

## Continuous integration

`.github/workflows/ci.yml`, three jobs.

**`static-checks`** — every offline suite listed above, plus HTML lint, the
link/asset check, and a parse of `config.js`. Runs on every push and pull
request. It installs Playwright and Chromium itself (pinned, ~20 s), because
the runner has neither and the repo has no `package.json` to install from.

**`db-boundary-tests`** — runs `scripts/db-tests.sh` **only if** a
`SUPABASE_DB_URL` secret is set. It is deliberately **not** set: this project
has one database and it is production, so satisfying that job would mean
storing a production Postgres password in GitHub Actions — readable by every
workflow — to automate suites that are already run by hand on every change,
against the live schema, in rolled-back transactions. The job therefore emits
a `::warning::` saying the boundaries were not verified here, and passes. It
does not gate the deploy. Setting the secret (session-pooler URI, IPv4 —
GitHub runners have no IPv6) starts running them for real with no other
change. Reasoning in `docs/DECISIONS.md`.

**`deploy-edge-functions`** — `main` only, after `static-checks`, when
`SUPABASE_ACCESS_TOKEN` is set. On a push it deploys only the functions whose
bundle contains a changed file. It can also be run from the Actions tab
(*Run workflow*) with a `functions` input — `all`, or a comma-separated list
passed to `--only` — for when something changed outside a push: a secret
added late, or a function deployed by hand that has drifted from the repo.

Repository secrets, both optional, neither committed:

| Secret | Effect when set | When missing |
|---|---|---|
| `SUPABASE_ACCESS_TOKEN` | Edge Functions deploy from `main` | job notices and skips |
| `SUPABASE_DB_URL` | database suites run in CI | job warns and passes |

`SUPABASE_PROJECT_REF` is optional too — the workflow defaults to
`acrjrlgeeyseyolmofuq`.

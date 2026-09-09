# Decisions & blockers — Coach Gari

Running log of product/technical decisions and of the blockers that are
documented but deliberately **not** implemented. Newest sprint first.

---

## Canonical product rule (applies to every sprint)

- **People belong to Gari.** Enquiries, messages, client communication,
  availability, calendar, bookings, sessions and day-to-day coaching operations
  are Gari's. Mickaël does not need general access to lead messages or
  conversations.
- **Payments belong to Oolala.** Stripe account, payments, refunds,
  chargebacks, reconciliation, the Oolala commission, Gari's payable and
  settlements are operated by Oolala / Mickaël.
- **Public website content is controlled by Mickaël / The Studio MT through
  Git.** No CMS, no content-editing role for Gari.
- **Aggregate analytics may be shared.** Never enquiry bodies, never
  identifiable contact data.

This rule drives the schema, the RLS policies and the permission model.

---

## Back-office as an installable app (PWA, /admin only) (2026-09-09)

`admin/manifest.webmanifest` (scope and start_url `/admin/`, standalone,
icons 192 / 512 / maskable, generated from a black "CG." tile) and
`admin/sw.js`, registered from admin.js with scope `/admin/`. The public site
has no manifest and no service worker (asserted by the suite). The worker
caches the SHELL only — HTML, styles, scripts, config, manifest, icons, the
supabase-js UMD build and the web fonts — stale-while-revalidate, versioned;
every request to `*.supabase.co` (data, auth, functions) is left to the
network and never stored, so nothing from the CRM, calendar, finance or
emails lives on the device outside the running page. Offline, the shell opens
and data calls fail with the app's own errors.

Sign-in from the installed app: on iOS the home-screen app has its own
storage, so a magic link opened in Safari cannot sign it in. The sign-in form
now also accepts the 6-digit code from the same email (`verifyOtp`, type
`email`). Owner action: the Supabase "Magic Link" email template must include
`{{ .Token }}` next to the link, otherwise the email carries no code.

Headers: `Cache-Control: no-cache` + `Service-Worker-Allowed: /admin/` on the
worker, manifest content type, `worker-src` / `manifest-src 'self'` and the
CDN / font hosts in `connect-src` for the admin CSP (the worker fetches them).
Safe-area padding in standalone mode. `scripts/test-admin-pwa.mjs` (18).

---

## Legal pages + editorial footer (2026-09-09)

`/legal` (terms & legal notice: operator, what is sold, booking, prices and
payment, cancellation / rescheduling / refunds, Support Coach Gari as a
voluntary non-refundable payment that is not a donation, health and age,
liability, content, law) and `/privacy` (controller, data and purposes, legal
basis, processors, retention, rights, security, cookies). Operator on every
page: Oolala Next FZ-LLC · Licence 47017963 RAK (U.A.E.) · PO Box 644762 The
Sustainable City, Dubai (U.A.E.), contact letsgo@coachgari28.com. "By paying
you agree to the terms" at the three pay points (booking hold, /r, Support
dialog). Defaults chosen pending the owner's confirmation: 24-hour cancellation
rule with full refund or reschedule, no refund inside 24 h or on no-show,
14-day window for a Support payment made in error, 24-month / 5-year retention.
VAT: "where U.A.E. VAT applies it is included" — a TRN is added on receipts
once the owner confirms registration.

Footer, editorial version: two tight link columns on the left, the "Next live
session" signup as a white card on the right (full width under 900 px), the
operator line above the bottom bar, Terms · Privacy next to the copyright.

---

## Shoot photos + Zimbabwe Bird signature (2026-09-09)

Three approved photos, one section each — never a gallery: the smiling cardio
portrait is the About Coach Gari image (4:5, editorial, beside the copy on
desktop); the dumbbell front raise is the Book a session visual (4:5, beside
the intro, the picker below — personal training is booked there); the twist in
the tropical gym is the Online coaching image (wide 2:1 editorial band inside
the existing bigcard, 4:3 on mobile — movement and adaptability, not a feature
card). The hero and the Conversation portrait are untouched. Object positions
are set per photo (smile, raised dumbbell + face, lunge + raised arm).

Zimbabwe Bird: used exactly once, as a small monochrome signature (26 px wide,
grayscale, ~55 % opacity, static, `aria-hidden`) in front of the "Zimbabwe to
Dubai, and back again" heading. Not a logo, not in the header, footer, hero,
booking or Support; no favicon, no lockup, no pattern, no animation.

Delivery: sources in `assets/img/source/` (kept as delivered),
`scripts/build-images.mjs` writes AVIF + WebP ladders (640 / 960 / 1280 where
the source allows) and a JPEG fallback to `assets/img/shoot/`, `<picture>` with
explicit width / height, `sizes`, lazy loading (none of the three is in the
initial viewport), no JS. The link checker now resolves every `srcset`
candidate and refuses a `<source>` without type / srcset or a responsive
`<img>` without dimensions or alt. Sources 1122×1402 (portraits) and 1448×1086
(movement): ladders 640 / 960 and 640 / 960 / 1280; 2.1 MB of derivatives for
6.4 MB of PNG, the SVG served as delivered (33 KB, no viewBox — sized by its
width / height attributes).

---

## Footer + anchors — 3 columns, Support row, normalised ids (2026-09-09)

Footer = a direct map of the main site sections, never the catalogue:
**Services** (The Programme, Online coaching, The Conversation, Personal
training, Padel, Corporate) · **Coach Gari** (Book a session, About Coach Gari,
Contact, TikTok, Instagram, Support Coach Gari — an emphasised link with an
arrow that opens the Support flow, not a button) · **Next live session** (email
box). Headings in sentence case. Removed from footer navigation: the Train
online / In person / More groupings, Live events, Live group sessions, Zimbabwe
& Southern Africa, Dubai one-to-one, Padel & corporate; subcategories (Padel
one-to-one / group, package variants) never appear — the section or the picker
handles them. `#corporate` is the Corporate panel inside the Padel & corporate
section; `#booking` is an alias of `#book`.

Section ids normalised: `programme`, `online-coaching`, `conversation`,
`group-sessions`, `padel`, `contact` (`about`, `book`, `top` unchanged). The old
ids keep working as **aliases** declared once on `<body data-anchor-aliases>`:
site.js normalises the hash in place (`/#enquiry` → `/#contact`) and the link
checker accepts a declared alias only when its target exists.
`#personal-training` resolves to `#book` with that family preselected in the
picker. The Stripe return URLs (`#book`) are untouched.

Scroll position: `scroll-margin-top: calc(var(--nav-h) + 20px)` on sections;
`--nav-h` follows the real header height through a ResizeObserver (so the
compact scrolled header and any viewport are honoured, nothing hard-coded).
A deep link stays aligned while async sections (catalogue, picker) render, until
the visitor scrolls. CSS smooth scrolling, history and reduced motion preserved;
an alias landing moves focus to the section. `scripts/test-anchors.mjs` (33).

---

## Transactional email — Resend outbox (2026-09-09)

**Shape.** One outbox, `public.email_events`, queued by the authoritative state
change and drained by the Edge Functions through a shared module
(`supabase/functions/_shared/email.ts`). The database decides *whether* an email
is due; the module only renders and sends. Sender `Coach Gari
<yoursession@coachgari28.com>` (`EMAIL_FROM`), Reply-To `letsgo@coachgari28.com`
(`EMAIL_REPLY_TO`), key `RESEND_API_KEY` — Supabase secrets, never in the repo,
never logged or returned.

**Events wired.** Booking paid → confirmation (customer) + notice (owner);
package paid on any rail (Stripe webhook or operator-confirmed Aani / bank /
cash / PSP) → receipt (client's CRM email) + notice; Support Coach Gari paid →
"Thank you for supporting Coach Gari" to the email Stripe Checkout captured
(the order carries no identity) + notice; confirmed booking cancelled by the
customer or the coach → cancellation (a cancelled hold sends nothing); the
coaching session of a confirmed booking moved in Schedule → the booking follows
and the customer gets the new details, once per actual change (trigger
`sync_booking_from_session`; the reverse sync never fires it); enquiry → lead to
letsgo@ with Reply-To the customer + acknowledgement to the customer.
`reminder` / `session_link` stay unwired (no producer).

**Idempotency.** Every row carries a `dedupe_key` (`order:<id>:<kind>`,
`booking:<id>:booking_cancelled`, `booking:<id>:reschedule:<new start>`,
`contact:<id>:<kind>`), queued `on conflict do nothing`; the old
`unique (order_id, kind)` is dropped (it swallowed the second reschedule). The
same key is Resend's `Idempotency-Key`. A replayed or re-delivered webhook, a
double click or a re-run of the producer never queues or sends twice.

**Failure.** Claim leases a row for two minutes (`for update skip locked`), so
the webhook drain and the scheduled drain cannot both send it. A failed send is
a row state — pending with exponential backoff, `failed` after six attempts,
operator retry through `email_outbox_retry` (coach:operations) — never an
exception in the booking / payment flow, and never a rollback of a reconciled
payment. Delivery state kept: status, attempts, provider message id, a short
error text. `email_outbox_status` shows counts and recent rows with masked
addresses and no payload.

**Scheduled drain.** pg_cron (`cg-email-outbox`, every two minutes) → pg_net →
`email-outbox` function, authenticated with a 64-hex key the migration generated
into `public.outbox_keys` (deny-all RLS; `email_outbox_authorize` is
service_role only). No Supabase secret, nothing to paste. The same function
answers `status`: configuration *presence* and the sending domain's state as
Resend reports it — never a value.

**Data minimisation.** The payload is the render data only: name, reference,
service, time, timezone, duration, delivery, amount, currency, method. No notes,
no manage token, no IP hash, no CRM content, no health data. Support rows carry
no name and no message.

**Auth email.** Supabase Auth still sends the admin magic link from the
platform's default sender; switching it to Resend SMTP is an owner action in
the dashboard (Authentication → SMTP settings: host `smtp.resend.com`, port
`465`, user `resend`, password = the Resend API key, sender
`yoursession@coachgari28.com`, name `Coach Gari`) once the domain is verified —
not changed from code, so the current admin login cannot break.

**Tests.** `supabase/tests/cg014_email.sql` (47) and `scripts/test-email.mjs`
(34); cg003 / cg013 / cg012 / cg0025 re-run on the redefined functions.

---

## Coach Gari — Support Coach Gari, Corporate CTA copy, CRM country picker (2026-09-09)

**Support Coach Gari** is a generic BEAU PH payment with intent `support`
— not a service, booking, package or session, and it never appears in the
booking picker or the catalogue. A discreet link in the footer opens a
compact dialog: AED 25 / 50 / 100 / Other, an optional "Message to Coach
Gari", card payment (Stripe Embedded Checkout). No reason is required.
Vocabulary is "Support Coach Gari" only: no donation, charity, fundraiser
or tax wording, no receipt of that kind, no supporter list, target,
leaderboard or recurring support.

### Data model

- Host record: an `orders` row with `order_reason = 'support'`, no booking
  and no session pack (constraint `orders_target_ck`), `service_title`
  "Support Coach Gari", a payer-held state token (sha256 in
  `access_token_hash`). It is the host's generic money record, so the
  existing payment / refund / chargeback / earning handling applies
  unchanged; nothing downstream can confirm a booking, mark a pack paid or
  consume a credit (proven).
- BEAU PH: `payment_requests` with `intent = 'support'`, the optional
  message in `metadata.message` (trimmed, capped at 500 characters). The
  message never goes to Stripe: the Checkout description carries the public
  reference `SUP-xxxxxx` only.
- Amount authority: the browser proposes; `support_create()` validates the
  currency BEAU PH can offer for `support` right now, the floor / ceiling
  (AED 10 – 5,000 in minor units, same magnitude for other currencies) and
  the rail, then creates the order and the request; the Checkout Session is
  built from the DB row. Only the verified Stripe webhook marks it paid.
- Rails opt in explicitly: Stripe lists `service, package, support`; Aani,
  cash and bank transfer list `service, package` — so only card is offered
  for support (proven).
- Currency: AED presets today; the same flow reads what BEAU FX can offer
  when merchant FX is enabled, no support-specific FX logic.
- Finance › Transactions shows Type **Support** with amount, currency,
  method, normalised status, timestamp and the message (already handled by
  `finance_transactions` / the detail drawer).
- Commission: **confirmed by the owner** — a Stripe-collected support
  payment carries the standard Oolala commission like any Stripe payment,
  Gari payable via settlements. Finance › **Commissions** (new,
  `finance_commissions`, finance:view) reports the Oolala commission by
  month × currency × type (service / package / support), settled vs open,
  never summed across currencies; manual rails carry none.
- **Country first.** The dialog asks the payer's country (the same
  searchable picker as the enquiry form) and asks the server what BEAU PH
  can offer for `support` in that country (`support_options`: currencies,
  and the eligible methods per currency). Presets follow the offered
  currency (AED 25 / 50 / 100, USD 10 / 25 / 50, otherwise "Other" only);
  an uncovered country is told card payment is not available yet.
  `support_create` requires the country and validates the currency against
  it; the request records the customer country.
  `cg_ph_request_for_order` gained an explicit `p_country` (8th argument).
- Payer identity: the order carries "Supporter" / "n/a"; Stripe knows the
  card holder. Capturing the Checkout email into the order is a possible
  follow-up, not done here.

### Also in this change

- Corporate CTA copy: "Discuss a corporate session" → **"Let's energise
  your team"**; same `#enquiry` link with the Corporate preselect, still
  enquiry-led, no product, slot or price.
- Admin › CRM contact editor: the Country field is the same searchable
  dropdown as the public enquiry form (an existing free-text value is kept
  until the operator picks).

### Tests

`supabase/tests/cg013_support.sql` — `CG013_TESTS ok=32 fail=0`: not a
service; options by country (AE, ZW covered; BR not), country required; floor, ceiling, unsupported currency and no-rail refused
server-side; order and request shape, message persisted safely (trimmed,
capped, absent when empty); Aani and cash refused for the intent; token
reads state only; a forged webhook amount is ignored, the verified event
pays once, a re-delivery does not double-pay; no booking / pack / session /
credit moved; Finance row and detail; RPCs are service-role only.
Regression: `CG003_TESTS ok=24 fail=0`, `CG012_TESTS ok=36 fail=0`.
Edge Function `support` v1 (card via the Stripe adapter, CORS allowlist).

---

## BEAU PH — Cash is a rail (2026-09-09)

**Before.** Cash was only a host "source" on `payment_record_manual`: the
receipt went straight into `public.payments` with no BEAU PH request, no
evidence and no reconciliation, and cash appeared nowhere in Finance ›
Payment methods, BEAU PH › Rails, the client's payment options or the
"Collect in person" options.

**Now** (`20261005`, forward only). Cash is a first-class **manual,
in-person** rail, operator-confirmed like Aani and bank transfer:

- capability vocabulary gains `cash` (in person; SQL and TypeScript);
- provider `cash`: manual, operator, available, any country / currency
  (the merchant scopes it), one optional instruction text, no secret;
- Coach Gari: enabled and listed, AE, AED + USD, with a client note —
  the report page shows "Pay in cash" with the amount in the chosen
  currency and the human reference; "Collect in person" offers Cash next
  to the Tap to Pay apps, with no receipt reference required;
- `payment_record_manual('cash')` goes through BEAU PH: request →
  operator confirmation (identity, amount, currency, date, note) → host
  payment → reconciled once; a second receipt on a paid pack is refused;
  no Oolala earning (the money never passed through Oolala). `manual` and
  `external` stay host-only sources.

**Also fixed** (`20261006`). Bank transfer had been added from the admin
this morning through "+ Add payment method", which creates the row with
no markets; a save that then *enables* the rail without naming markets
left it enabled but eligible nowhere, and a bank receipt failed with
"needs_configuration". Enabling a rail that still has no market now gives
it the same explicit default as a brand-new row (provider coverage or the
merchant's home country; provider currencies or the settlement currency);
explicit values always win.

Tests: contract §25 (catalogue, not offered until configured, market
scope, in-person collect option, fabricated "cash paid" event refused,
wrong amount refused, operator confirms once), `cg012` §4b (client
option, collect option, receipt through BEAU PH, ledger, double receipt
refused) — `CG012_TESTS ok=36 fail=0`. The Edge bundles are unchanged:
the report function passes the database's method list through verbatim.

---

## Coach Gari — booking picker: three choices, progressive disclosure (2026-09-09)

**What changed.** The first booking step shows exactly **The Conversation ·
Personal training · Padel**, in that order, with a one-word context (Online /
Dubai) and no price, currency or duration. **Every** top-level choice
collapses the other two out of the layout (opacity and width, one easing,
~300 ms) and stays as the current context with **← Back**; The Conversation
and Personal training then go straight to the day and time; Padel slides
**One-to-one / Group session** in from the right. Back (or the context
button itself) reverses it without a reload and keeps the date already
picked. Price appears only once a time is held (the recap and payment
stage), as before.

**Fixed the same day.** The first build only collapsed for Padel, and the
Padel context kept its original "open" handler, so a second click stacked a
second children row and brought the siblings back — which also made the
Padel choices appear under The Conversation. The picker is now one state
machine (root → selected family → back) with fresh buttons on every render
and a guard during transitions; a regression check proves exactly one
children row and one Back after re-opening.

### Decisions

- **The public hierarchy is the page's, not the catalogue's.**
  `assets/booking.js` holds a `FAMILIES` map — family → optional child →
  canonical service slug — with nothing commercial in it. Any family can
  have children later (online coaching, live session, replay, tour formats)
  without adding a top-level choice. A family whose canonical service is not
  bookable right now is simply not offered.
- **Mapping.** The Conversation → `conversation`; Personal training →
  `personal-training-dubai` (title stays "Personal training in Dubai");
  Padel › One-to-one → `padel-one-to-one`; Padel › Group session →
  `padel-group-session`.
- **Three canonical services were created** (`20261004`), because only The
  Conversation was bookable: active, slot-bookable, **unlisted** (booking
  entries, not marketing cards — the page's Padel surface stays an enquiry)
  and **priced on request** (`price_amount` null). No price was invented; a
  hold on them takes the existing "request this time" path until the owner
  sets a price in Services. Duration 60 min, capacity 1, in person, Dubai.
  Audited as catalogue creates.
- **A dedicated booking catalogue.** `?action=bookable` returns every active
  slot-bookable service, listed or not; `?action=services` (the marketing
  cards) is unchanged.
- **Availability loads only for a final service.** Choosing Padel sends no
  request. A slots response that arrives after a newer choice is dropped.
- **One availability state at a time.** A failed request renders an error
  with a Retry button and no time buttons; a successful one renders times
  and clears the error. The previous build could show both.
- **Motion.** Opacity and a 26 px translate, ~280–300 ms, one easing curve,
  no library. `prefers-reduced-motion` switches states immediately. Hidden
  choices leave the layout and the tab order; the chosen family carries
  `aria-expanded` / `aria-pressed`; focus moves to the first child and back
  to the family; a status line announces the family choice.

### Not changed

Prices, durations, availability rules, hold logic, package consumption,
BEAU PH, Stripe, Finance, authentication. The placeholder availability rules
apply to every active service (`service_ids` null), so the new Dubai
services inherit the same hours until Gari scopes them in Schedule.

### Tests

`scripts/test-booking-picker.mjs` (Playwright, mocked booking API):
`BOOKING_PICKER_TESTS ok=36 fail=0` — order and content of the initial
step, availability timing per choice, transition and Back, error/retry
exclusivity, 390 px without horizontal overflow, touch, reduced motion.
`available_slots` returns times for all four canonical services in
production; the booking Edge Function is version 13.

### Owner actions

- Set a price on the three Dubai services in Services when ready; until
  then a booking on them is a request Gari confirms directly.
- Scope availability per service in Schedule if court hours differ from
  online hours; Group session capacity is 1 until changed in Services.

---

## Coach Gari / BEAU PH — Finance workspace, rails configuration, BEAU FX (2026-09-09)

**What changed.** The Finance tab is now two sub-tabs — **Transactions**
(default) and **Payment methods** — and a new **BEAU PH** tab holds the
operator workspace: **Rails** (every provider BEAU PH knows, with the
merchant's real state) and **FX**. BEAU PH stays embedded in Coach Gari for
V0; every screen calls a host RPC in `public` that wraps `beau_ph.*` with
the merchant key fixed to `coach_gari`. Nothing was extracted.

### Decisions

- **Access is the finance pair, never `platform:admin`.** Every workspace
  RPC checks `finance:view` (read) or `finance:manage` (write) inside a
  SECURITY DEFINER function. Gari (`grej28roux@gmail.com`) is provisioned
  with the launch set (`20260928`, audited under `permission/provision`);
  Mickaël already held it. Proven for both persona shapes in `cg0025` §10.
- **Transactions are one list across every rail.** `finance_transactions()`
  joins the host order to its most relevant BEAU PH request and the host
  payment: type (`service` / `package` / `support` / `other`, from the
  order reason), method, the amount **in the currency actually collected**,
  BEAU PH status normalised to the host vocabulary, and a pending action
  (`confirm_receipt`, `fee_pending`, `partial_refund`). The drawer
  (`finance_transaction_detail`) is lazy and carries requests, events,
  payments, earning, refunds and chargebacks — no CRM note, no health data,
  no enquiry body, no provider secret, no raw webhook payload.
- **Payment methods list only what the merchant configured**
  (`merchant_methods.listed`); the provider catalogue appears only behind
  "+ Add payment method". Rows are compact; Edit / Remove reveal on hover
  (and behind `•••` on touch); the editor is inline, lazy, schema-driven
  (`providers.config_schema`) and asks for **one** confirmation on Save
  with a change summary. **Remove** deactivates and unlists when history
  exists (the rail's requests, events and audit stay); it deletes only an
  unused configuration.
- **Merchant configuration is the intersection with provider capability.**
  `merchant_methods` now persists ISO `countries[]`, `currencies[]`,
  `intents[]` and per-currency `limits`; `null` is "needs configuration",
  never "any" — a rail without a market is not eligible anywhere. A brand
  new rail starts in **one** explicit market: the provider's own coverage
  or the merchant's home country (`20260929`). Structural reasons
  (`coming_soon`, `not_configured`) come before merchant reasons in
  `method_matrix` (`20261001`). The single write path is
  `merchant_method_configure`, which refuses a country, currency, intent or
  capability the provider does not support and writes a **field-level**
  audit row (`beau_ph.config_audit`: actor, field, old, new — CHECKed free
  of secrets).
- **Secrets never leave the server.** The catalogue stores secret **names**;
  the `ph-admin` Edge Function answers presence and mode per name for a
  signed-in user holding `finance:view`, and trips a guard if anything
  secret-shaped would be returned. No value, prefix or length travels.
- **Settlement destinations are distinct from methods**
  (`settlement_destinations`, `method_settlements`); removal deactivates
  when a method still maps to it.
- **BEAU FX is server-side and fails closed.** Modelled on the Maisons FX
  subsystem: EUR-base daily rates from Frankfurter (ECB), USD pegs derived
  from the same day's USD rate (AED 3.6725, SAR, QAR), NBG defined but
  disabled; rate-on-or-before lookup; ±20 % day-on-day anomaly rejection;
  per-source isolation (one source failing never blocks another); freshness
  ≤36 h fresh · 36–72 h acceptable · >72 h stale; refresh through `pg_net`
  (06:05 UTC daily, collected every minute) with run observability and a
  manual refresh from the workspace. A stale or missing rate means **no
  quote** — the currency is simply not offered. Quotes are immutable
  snapshots (trigger-guarded; only lifecycle fields change), expire after
  15 minutes by default, and separate the reference rate, an optional
  provider rate, the merchant adjustment (bps) and the customer rate. The
  order keeps its **pricing** amount and currency; the request carries the
  quoted **payment** amount and currency plus the quote id; the ledger
  stamps the earning in the currency actually collected. `report_view`
  offers the pricing currency first and every currency FX can quote right
  now; the payer's choice is a request parameter that the server validates
  against those options — the browser can never set an amount or a rate.
- **Merchant FX is disabled by default.** `merchant_fx.enabled = false` for
  Coach Gari until the owner switches it on in BEAU PH › FX. With it off,
  the report page offers the pricing currency only (proven in `cg012`).
- **Support intent exists as vocabulary only.** `intent = support` is a
  first-class value in the eligibility and request model (rails may be
  scoped to it), but the public "Support Coach Gari" flow is **not built**
  in this sprint.

### Found by the new tests

- `attach_checkout()` re-derived the BEAU PH request without a payment
  currency, so a Checkout Session created for an AED payment of a USD
  package was attached to a fresh USD request and the AED webhook was
  refused as an amount mismatch. It now attaches to the order's **live**
  Stripe request whatever its currency (`20261002`). No client had used
  the currency choice yet.
- Switching the payment currency **back** to the pricing currency hit the
  "live request with another amount" guard; the rule is now symmetric —
  one live request per rail and order, in the currency last chosen
  (`20260930`).

### Tests

`BEAU_PH_TESTS ok=142` (rail configuration §22, FX §23, host FX payment
§24), `CG0025_TESTS ok=288` (§10 workspace personas: both launch-user
shapes reach every workspace RPC, coach-only / platform:admin-only / anon
refused, outputs free of secret-shaped values, every change audited with
its actor, production rows for both launch users hold the finance pair),
`CG012_TESTS ok=31`, `CG003_TESTS ok=24` (count assertions are now deltas
over the live ledger), `CG002 28`, `CG009 43`, `CG010 48`, `CG011 31`,
`ADMIN_WORKSPACE_TESTS ok=34` (Playwright, lazy loading and no secret ever
requested).

### Owner actions

- Gari's auth invite exists but is unconfirmed; the first magic-link sign-in
  completes it. No permission change is needed.
- Enable BEAU FX (BEAU PH › FX › Settings) only when a second payment
  currency should be offered on the report page.
- Bank transfer stays unconfigured until real account details are entered
  in Finance › Payment methods (nothing is seeded).

---

## Coach Gari / BEAU PH — the Stripe fee was recorded as zero (2026-09-09)

**Root cause.** The Stripe adapter's `enrich()` asked for the payment intent
with `expand[]=latest_charge.balance_transaction` and only read a fee when
Stripe returned that balance transaction as an expanded object. On the live
payment it came back as an id string, so `fee_amount` stayed null and the
ledger stored a zero fee. A second cause sits behind the first: the balance
transaction can lag the charge by a moment, so even a correct read can be
too early.

**Fix** (`beau-ph/providers/stripe/adapter.ts`). A `feeEvidence()` helper
now resolves the fee properly: it accepts the balance transaction either
expanded or as an id, fetches `/v1/balance_transactions/{id}` directly when
it only has the id, and retries up to three times 800 ms apart when the
transaction is not there yet. It also keeps the settlement currency
straight — `fee_amount` is set only when Stripe's fee is denominated in the
payment currency; a foreign settlement currency is carried as
`fee_settlement_amount` with its own currency and never silently mixed with
the payment amount.

**An unknown fee is now visibly unknown.** `public.payments.fee_known`
already distinguished "the fee is zero" from "we do not know it yet", and
its upsert already lets a later, better reading fill an unknown fee in.
Nothing surfaced the flag, so a missing fee looked like a real zero.
`finance_orders()` returns `fee_known`
(`20260925_finance_orders_fee_known.sql`, forward only, with the same
explicit PUBLIC/anon revokes the previous migration needed), and the
Finance tab shows "pending" instead of 0.00 for an earning whose fee has
not arrived. Reporting and evidence only: no amount, earning, commission or
settlement logic changed.

---

## Coach Gari — Finance list was blind to session-pack orders (2026-09-09)

**Found by the first live payment.** `public.finance_orders()` joined orders
to bookings with an INNER join. A session-pack order carries
`session_pack_id` and no `booking_id`, so every pack payment was dropped
from the Finance tab. The AED 10 live payment was in the ledger, had its
Oolala earning, and showed nothing on screen. The same inner assumption hid
pack orders from a client's Payments section in the profile, which matched
rows by booking reference.

Settlements were never affected: `create_settlement()` reads
`partner_earnings` joined to `orders` and already included pack orders, so
Gari's payable was correct throughout. This was a reporting defect only.

**Fix** (`20260924_finance_orders_pack_orders.sql`, forward only): the join
becomes a LEFT join, and three columns are added so the surfaces can tell
the two apart without guessing — `order_reason` (`booking` |
`session_pack`), `pack_reference` (the CG-#### public reference) and
`crm_contact_id` (from the booking or the pack). The Finance table labels a
pack row and omits the session date it does not have; the profile matches a
client's payments by contact as well as by booking reference. No amount,
earning or settlement logic changed.

Changing the return type meant dropping the function, which clears its
grants and re-grants EXECUTE to PUBLIC by default. The migration therefore
revokes PUBLIC and anon explicitly and re-grants `authenticated` and
`service_role` — the surface it had before. Advisors are back to baseline.

**Carried, not changed:** the Stripe fee arrived as null on the live
payment (the balance transaction did not exist yet when
`checkout.session.completed` fired), so the ledger recorded a zero fee. It
did not matter under a full refund, but on a payment that is kept it would
overstate net collected and the commission basis. Reading the fee later is
a separate task. And a refunded pack returns to `unpaid` while keeping its
`paid_at` and `payment_source`, which is an entitlement policy question for
the owner, not a bug.

---

## Coach Gari / BEAU PH — Stripe V0 with EMBEDDED Checkout (2026-09-09)

**Decision.** The card rail keeps Stripe Checkout but in its embedded mode:
the report page (`/r/<token>`) and the booking flow mount Stripe's Checkout
surface inside coachgari28.com (Stripe.js `initEmbeddedCheckout` with a
session-scoped client secret). No Stripe custom domain is bought or
configured. The customer leaves the page only when Stripe itself must run a
bank / 3DS redirect (`redirect_on_completion=if_required`, `return_url` on
the canonical origin with `{CHECKOUT_SESSION_ID}`).

**Catalogue authority.** Coach Gari's database stays the only commercial
catalogue. Every Checkout Session is priced dynamically from the BEAU PH
payment-request snapshot (`line_items[].price_data` + `product_data.name`),
which itself comes from the pack / booking snapshot. No permanent Stripe
Product or Price was created and none is required. Permanent Prices are
only justified later for subscriptions / Billing / recurring or specific tax
reporting; none applies to V0. Stripe is payment infrastructure, not a
catalogue.

**Data sent to Stripe.** Line item: name, unit amount, currency, quantity 1.
Customer email (for the receipt) when it looks like an email. Metadata,
identifiers only: `order_reference`, `public_reference`,
`beau_ph_request_id`, `host_app`, `merchant_key` (mirrored on the
PaymentIntent). `client_reference_id` = order reference. Nothing from the
CRM, notes, consent, measurements or health data can reach Stripe: the
adapter builds the form body from the request snapshot and whitelists the
metadata keys (proved by `scripts/test-stripe-embedded.mjs`).

**Configuration.** `PAYMENTS_MODE` (test|live) and `STRIPE_SECRET_KEY` as
before; new `STRIPE_PUBLISHABLE_KEY` (public by design, still mode-checked:
a `pk_` of the other mode refuses everything, a missing `pk_` disables the
embedded surface only). `SITE_URL` defaults to `https://coachgari28.com`
and only overrides it for dev / previews. Secrets never leave the server;
the browser receives the publishable key and one Checkout client secret.

**Authority unchanged.** Amount and currency come from the order snapshot,
resolved from the report token or the booking's manage token. The browser's
completion callback and the return URL are never proof: the page re-reads
the authoritative view / booking state until the verified webhook has moved
it. Webhook: same seven events, same signature / mode / livemode /
idempotency / evidence handling. A still-open session is re-opened
(`resumePaymentRequest`) rather than duplicated; an attempt carries the
session id with a null redirect URL.

**BEAU PH boundary.** The adapter knows `uiMode`, `hostApp` and
`merchantKey` as generic inputs; nothing about packs, coaches or contacts.
Extraction of BEAU PH into a standalone service starts only after the live
payment + refund gate is green.

**Live gate:** PAUSED, owner configuration required (see the report of
2026-09-09 for the exact Stripe Dashboard / Supabase checklist).

---

## Coach Gari — lighter page, Padel + Corporate, motion polish (2026-09-09)

**Padel and Corporate** live in one compact surface, `#together` ("Work
together from anywhere"), in the slot the dark "In Dubai?" strip used to
occupy: heading, one sentence, two editorial panels (Padel coaching /
Coaching for teams). No price, package, duration, group size or claim was
invented; both CTAs go to the existing enquiry form with the new "Padel
coaching" / "Corporate session" categories preselected (free-text
`interest`, no schema change). The programmes heading became "Four
programmes" so "train with me" is not repeated three times on the page.
Net page length: about +460 px desktop, +700 px mobile.

**Scrolling** stays native (`scroll-behavior: smooth` for anchors). No
Lenis or other library: the target feel is reached with a refined reveal
easing, one staggered sequence and a calmer header, at zero dependency cost.
Three signature treatments, nothing else animated: (A) section reveal,
once, one block per section, `cubic-bezier(.2,.7,.2,1)`, staggered only
inside `#together` (heading, copy, then the two panels, about 0.8 s total);
(C) one ambient brand glow (accent tint radial) that fades in behind
`#together`; (D) the sticky header turns compact and translucent with a
light blur once the page has scrolled, driven by an IntersectionObserver
sentinel rather than a scroll listener. Panel hover is a plain link hover
(colour + 4 px arrow shift). `prefers-reduced-motion: reduce` removes every
transition and shows all content immediately; nothing depends on motion.

---

## Coach Gari — production domains added to CORS (2026-09-08)

**Incident.** The public site is now served from `https://www.coachgari28.com`
(apex `coachgari28.com` redirects to `www`). That host is a different Vercel
project than `coachgari_v0`, whose only domains are the `*.vercel.app` aliases.
Every browser-facing Edge Function carried its own inline origin allowlist
(`coachgari.com`, `www.coachgari.com`, `*.vercel.app`, localhost), so
`booking?action=services` — the source of the Programmes catalogue — answered
`403 origin_not_allowed` to the new origin and the page showed no programmes.
Booking, contact, consent, upload and the payment page were rejected the same
way; admin login was unaffected (Supabase Auth / PostgREST, not Edge Functions).

**Decision.** One allowlist, in one file: `supabase/functions/_shared/cors.ts`
(`ALLOWED_ORIGINS`, `ALLOWED_ORIGIN_PATTERNS`, `originAllowed`, `corsHeaders`).
Allowed: `https://coachgari28.com`, `https://www.coachgari28.com`,
`https://coachgari.com`, `https://www.coachgari.com`,
`https://coachgariv0.vercel.app`, the `coachgariv0-*.vercel.app` branch
previews, localhost / 127.0.0.1 for development. The old `*.vercel.app`
wildcard is gone: an arbitrary `<x>.vercel.app` origin is refused. The allowed
origin is echoed (`Vary: Origin`); `Access-Control-Allow-Origin: *` is never
sent. Canonical production domain: `https://coachgari28.com` (`www` allowed
during the cut-over). Functions importing the helper: booking, contact,
consent, upload, checkout, report (all six redeployed). `stripe-webhook` is
server-to-server and has no CORS.

**Carried.** `SITE_URL` stays `https://coachgariv0.vercel.app` by owner rule
until `coachgari.com` is attached to the production Vercel project; Stripe
return URLs therefore land on the Vercel alias, not on `coachgari28.com`.

---

## Coach Gari / BEAU PH — Stripe LIVE cut-over (2026-09-08)

**Decision: the categorical live-key refusal (CHECK-LICENCE-001) is replaced
by a declared payment mode.** `PAYMENTS_MODE` (`test` | `live`) is the
deployment's intent; the key's mode must match it (`sk_test_` ↔ test,
`sk_live_` ↔ live) or the Stripe adapter reports `key_mode_mismatch`; an unset
or unknown mode reports `payments_mode_unset`. In both cases payment creation is
refused and every webhook is refused — never guessed. The adapter never exposes
a key or a prefix, only `{configured, mode, reason}`.

- **Both directions, both layers.** The Edge refuses an event whose `livemode`
  differs from `PAYMENTS_MODE`; the DB core refuses evidence whose `livemode`
  differs from the merchant's mode (`20260922_beau_ph_stripe_live.sql`,
  previously one-way); eligibility refuses a runtime whose mode differs from
  the merchant's. `beau_ph.merchants.mode` for `coach_gari` is now **live**;
  `attach_checkout` declares the merchant's own mode instead of a hardcoded
  test runtime.
- **Merchant identity unchanged**: Oolala's Stripe account collects; Coach
  Gari is the host; no Stripe Connect. Ledger, commission and settlements as
  before (CG-003).
- **Success page never authoritative**: `?paid=1` only makes the page poll;
  the verified webhook (`checkout.session.completed`) is the only paid source.
- **Webhook events handled** (deployed code): `checkout.session.completed`,
  `checkout.session.expired`, `refund.created`, `refund.updated`,
  `charge.dispute.created`, `charge.dispute.updated`, `charge.dispute.closed`.
  Anything else → `ignored: unhandled type` (200).
- **Diagnostics**: logs carry event id/type, livemode, Checkout Session id,
  order reference, BEAU PH request id, normalized outcome, mode and refusal
  reason — never a key, a signing secret, or card data.
- **Suites** pin the merchant to test mode inside their transaction; §20 proves
  the mode gate both ways. Contract 84/0, CG003 24/0, CG012 26/0, CG0025
  236/0, signature 24/0; security advisor 0 ERROR.
- **SITE_URL**: `coachgari.com` is **not** attached to the Vercel project
  (`coachgari_v0` domains: `coachgariv0.vercel.app` + git aliases). The
  configured value cannot be read from here (secrets are write-only);
  the code default is `https://coachgariv0.vercel.app`. Decision: **do not
  change it** until the domain is attached and serves the app (GATE-DOMAIN-001).
- **Owner actions (no secret ever displayed)**: set `PAYMENTS_MODE=live` on the
  Supabase project (`supabase secrets set PAYMENTS_MODE=live --project-ref
  acrjrlgeeyseyolmofuq`) — it cannot be written from this session (no secrets
  tool; egress blocked); confirm the production webhook endpoint subscribes to
  the seven events; run `PAYMENTS_MODE=live STRIPE_WEBHOOK_SECRET=… node
  scripts/test-webhook.mjs` from a laptop; make the first live payment
  deliberately (a small real amount) and check `payments` / the pack projection.
  Until `PAYMENTS_MODE` is set, checkout and report answer 503
  `payments_not_configured` (`payments_mode_unset`) and the webhook refuses
  everything — payments are closed, not guessed.

---

## BEAU PH V0 — final runtime / merge gate (2026-09-08)

**Decision: BEAU PH V0 is complete at the database / contract level; the runtime
round trip on the deployed stack is owner-run.** No feature was added at the gate;
two guards were closed by a forward migration.

### What the gate found

- **Multi-tenant isolation gap (core).** Every request-addressed core function
  (`confirm_manual`, `cancel_request`, `expire_request`, `attach_attempt`,
  `mark_reconciled`, `get_request`, `request_events`) was keyed by the request
  uuid alone. Reachable only by `service_role` and the host's definer functions,
  but nothing in the core stopped a host from acting on another merchant's
  request, and the Coach Gari webhook path would have paid a Coach Gari order
  from a Stripe session that belonged to another merchant's request if the
  event named that order (`client_reference_id`).
- **Reverse-race double pay (host).** After Stripe settled a pack, a manual
  receipt (`payment_record_manual`) created a *new* order for the same pack and
  paid it again — the core's "one paid request per external order" rule could
  not see it because the host had minted a second external reference.
- **Runtime state.** The live project holds zero orders, zero payments and zero
  BEAU PH requests; the only Edge invocations in the last 24 h were the booking
  function. The Vercel production alias serves `main` (`f6052b8`); the branch
  preview serves the SoftPOS step (`002544b`). The sandbox cannot reach
  `*.supabase.co` or `*.vercel.app`, so no HTTP probe was possible from here.

### What was done (migration `20260921_beau_ph_tenant_scope.sql`, applied)

- `beau_ph.owned_by(request, merchant)`; every request-addressed core function
  takes an optional `p_merchant_key` and answers `P0002` (not found) for a
  request of another merchant — never revealed, never acted on. Signatures
  changed by drop + recreate (defaulted parameter, callers unchanged); grants
  re-swept (`service_role` only).
- Coach Gari host adapter passes `'coach_gari'` everywhere; the Stripe webhook
  path ignores a normalized event whose request is foreign (`foreign_merchant`,
  evidence kept, ledger untouched); `payment_record_manual` refuses a receipt on
  a pack that is already paid or that already has a paid order (`P0003`).
- Contract suite §18 (multi-rail race, both orders) and §19 (tenant isolation:
  config leak, reference scope, read/use/cancel/expire/confirm/reconcile,
  cross-host webhook, application-user reachability) → `BEAU_PH_TESTS ok=77`.
- `scripts/e2e-runtime.mjs` for the owner-run runtime E2E (report view, no
  health data / secrets, Aani + bank instructions without payment, `--pay`
  Stripe TEST Checkout, `--wait` webhook → ledger → pack).

### Gate results

| Check | Result |
|---|---|
| `beau_ph_contract.sql` | ok=77 fail=0 |
| `cg003_payments.sql` | ok=24 fail=0 |
| `cg012_payments.sql` | ok=26 fail=0 |
| `cg0025_permissions.sql` (RLS) | ok=236 fail=0 |
| `cg010_privacy.sql` | ok=48 fail=0 |
| `test-webhook-signature.mjs` | ok=24 fail=0 |
| Supabase security advisor | 0 ERROR (INFO: deny-all RLS on `beau_ph` by design; WARN: permission-gated definer RPCs, accepted pattern; WARN: leaked-password protection — owner auth setting) |
| Supabase performance advisor | 0 ERROR (INFO unindexed FKs, unused indexes; 1 pre-existing WARN on `services` policies) |

### SoftPOS status at the gate

`softpos`, `card_present`, `tap_to_pay` stay in the model as supported future
capabilities. **No in-person method is active**: no PSP is enabled for
`coach_gari` (`merchant_methods` holds `stripe` and `aani` only); `tap_to_pay`
is a placeholder on `ios_app`; `card_present` is `not_configured` on every PSP;
the `softpos` handoff exists at product level but stays inert until the owner
onboards a PSP and enables it in Finance. Nothing in-person ever reaches the
client page (proven).

### Active vs placeholder providers (live DB)

- **Active for Coach Gari:** `stripe` (test mode, webhook path proven),
  `aani` (V1 static instructions, manual reconciliation).
- **Available, not configured by the owner:** `bank_transfer` (no account
  details entered — nothing seeded).
- **Boundary only (`not_configured`):** `paynow`, `mpesa`, `ozow`, `payshap`,
  `network_international`, `magnati`, `adyen`.
- **Placeholder:** `beau_wallet`.

### Known limitations carried

See `beau-ph/docs/ROADMAP.md` "Known gaps" 1–10 — notably: provider-side cancel
on supersede not invoked; legacy `no_request` webhook path; `cash/manual/
external` host-only sources; SoftPOS V0 operator-attested; runtime E2E
owner-run; tenant scope host-cooperative until V2 derives the merchant from the
caller's credential.

---

## BEAU PH — in-person / SoftPOS acceptance (capability model + V0 handoff)

**Status: built, applied and proven — `BEAU_PH_TESTS ok=59 fail=0` (16 new
checks), `CG003_TESTS ok=24 fail=0`, `CG012_TESTS ok=26 fail=0`. Advisors:
0 ERROR. Investigation with sources in `beau-ph/docs/SOFTPOS.md`. Forward
migrations `20260919_beau_ph_capabilities.sql` (core) and
`20260920_beau_ph_coach_gari_collect.sql` (host).**

### Decision
`card_present` / `softpos` / `tap_to_pay` are first-class **future**
capabilities of BEAU PH. Providers now declare **capabilities** (the generic
vocabulary `online_checkout · payment_link · manual_instructions · wallet ·
bank_transfer · mobile_money · softpos · card_present · tap_to_pay · qr ·
crypto`), each with its own readiness, confirmation mode, platform restriction,
initiator and an explicit `handoff` flag. Eligibility now considers merchant,
country, currency, **device/platform**, **who initiates** and readiness.

### UAE facts (verified)
Apple launched Tap to Pay on iPhone in the UAE on 10 Dec 2024; launch platforms
Adyen, Magnati (SwipeX app), Network International (N-Genius One app); iPhone
XS+. A native integration needs an organisation Apple Developer account, the
Tap to Pay entitlement, a supported PSP SDK, PSP-owned certification.

### V0 = provider-app handoff (implemented)
Session / package → **Collect in person** → amount + `CG-####` → the operator
takes the tap in the PSP's certified app → enters the app's receipt reference
→ `payment_record_manual(source = magnati | network_international, capability
softpos)` → BEAU PH request (`in_person`, merchant-initiated) → operator
attestation (`verification = operator_attested_provider_receipt`, receipt
**mandatory**) → ledger once, pack source `card_present`, **no Oolala
earning** (PSP settles to Gari). BEAU PH never sees card/PIN data; nothing NFC
runs in the PWA; only the app name + optional app link are stored (no MID, no
key). Adyen is SDK-only → no handoff. Providers `network_international`,
`magnati`, `adyen` are readiness boundaries for their API paths.

### Reserved, not built
`tap_to_pay` native (PSP SDK inside a BEAU PH Merchant iOS app) is a
placeholder gated to `ios_app` — proven never offered on web/PWA even when
hypothetically live. Stated limit: V0 is operator-attested, not
provider-verified, until a PSP API integration exists (V1).

### Owner actions
Choose and onboard one PSP (recommendation: Magnati / SwipeX for self-serve
onboarding, or Network International if already an N-Genius merchant); enable
it in Finance → In-person acceptance; do a first tap on a test package.

---

## BEAU PH — BEAU Payment Hub: productisation decision (V0, embedded)

**Status: built, applied and proven — `BEAU_PH_TESTS ok=43 fail=0`; the existing
financial suites stay green on the new path (`CG003_TESTS ok=24 fail=0`,
`CG012_TESTS ok=26 fail=0`); Node signature suite `ok=24 fail=0`. Advisors:
0 ERROR. Edge Functions `report`, `checkout`, `stripe-webhook` redeployed on the
adapter layer. Product docs live in `beau-ph/` (PRODUCT.md + docs/). No
standalone dashboard/API/service — by decision.**

### The decision
Payment orchestration is no longer Coach-Gari-specific code. **BEAU PH** (BEAU
Payment Hub) is the reusable multi-rail orchestration + reconciliation layer;
Coach Gari is its first host and proof environment. Naming: *BEAU* = the wallet
/ product ecosystem; *BEAU PH* = this hub; *BEAU Wallet adapter* = one future
crypto rail inside the hub. The BEAU Wallet project itself is not renamed.

### The boundary (enforced by construction)
- **Core = Postgres schema `beau_ph`** (merchants, providers, merchant_methods,
  payment_requests, payment_attempts, provider_events, payment_events,
  reconciliations; method_matrix / eligible_methods, create_request,
  attach_attempt, ingest_provider_event + normalize_stripe_event,
  confirm_manual, cancel/expire, mark_reconciled). Not API-exposed; deny-all
  RLS; owner/service_role only. **No reference to packs, bookings, CRM or
  health data** — the host is known only as `external_reference`,
  `public_reference`, `metadata`.
- **Provider adapters** = `beau-ph/providers/*` (TS: I/O, verification,
  readiness by secret *presence*) + SQL normalizers (evidence → state).
- **Host adapter (Coach Gari)** = `public.cg_ph_*`, patched `attach_checkout`,
  `process_stripe_event`, `payment_record_manual`, `report_view`, method
  configuration RPCs — the only code naming both sides. Traceability from the
  ledger to the hub is by plain uuid columns (`payments.ph_request_id`,
  `ph_event_id`), no cross-schema FK, so extraction stays possible.
- `public.payment_methods` moved into `beau_ph.merchant_methods` (data
  preserved, nothing seeded); the Finance screen reads it via
  `payment_methods_list` and shows the rails matrix via `payment_rails`.

### Money truth unchanged
Coach Gari's orders / payments / refunds / earnings / settlements / pack
entitlement remain authoritative. BEAU PH emits normalized events; the host
reconciles a `paid` event **exactly once** (`beau_ph.reconciliations` is the
receipt). Stripe stays Oolala-collected (commission); Aani/bank stay direct
to Gari (no earning row).

### Rules that are now tested, not just written
Server-side eligibility by merchant × country × currency × readiness (the
`/r` page renders the list verbatim — no country logic in JS); disabled and
not-configured rails omitted and unable to act; the amount is the host's and
cannot be overridden (evidence of the refused claim kept); one live request
per order + rail, one paid request per order, and a paid request cancels its
sibling rails; manual rails never self-confirm — an authenticated
`finance:manage` operator confirms with identity, amount, currency,
reference recorded; a differing manual receipt explicitly supersedes a
pending card intent (never converted); no secret-like key/value can be
stored in the hub or reach a payer; BEAU Wallet and the four African rails
cannot fake a payment while unconfigured; duplicates never duplicate the
host payment.

### Africa as a first-class requirement
Paynow (ZW), M-PESA (KE), Ozow / PayShap (ZA) exist as adapter boundaries
with their country/currency/secret declarations; activating one is a forward
migration flipping `readiness` plus a real integration + tests — the client
page needs no change. No per-country commerce model.

### Not built, by decision
Standalone dashboard / API / SDK / MCP / service (V2–V3 in
`beau-ph/docs/ROADMAP.md`); BEAU Wallet implementation (future contract
documented; separate approval). Known V0 gaps are listed honestly in the
roadmap (provider-side cancel on supersede, legacy `no_request` path,
`cash/manual/external` host-only sources).

---

## CG-012 — Client session recap + payment requests (Stripe + Aani), renewal

**Status: DB built, applied and proven — `CG012_TESTS ok=26 fail=0` (22 from
CG-012 + 4 from CG-012b bank transfer / public reference), plus the CG-003
payments suite re-run green after `process_stripe_event` was patched
(booking-optional + pack projection). Advisors: no new ERROR; the two hardening
findings raised on CG-011 were fixed (see below). `report` Edge Function
deployed (`verify_jwt=false`, token-authorised). `/r/<token>` client page and
admin UI shipped. Forward migration `20260912_cg012_reports_payments.sql`;
existing booking→order behaviour preserved. Stripe stays TEST mode
(CHECK-LICENCE-001).**

### Financial architecture (unchanged, enforced)

`session_packs` is the operational **projection**. `orders + payments + refunds
+ chargebacks + partner ledger` remain the **authoritative** financial truth
(CG-003). An order now belongs to a booking **or** a pack
(`orders.booking_id` made nullable + `orders.session_pack_id` + `order_reason`,
guarded by a CHECK). A paid order projects onto the pack
(`payment_status`/`paid_at`/`order_id`/`payment_source`) via
`project_pack_payment`. No second ledger lives in `session_packs`.

### Two money paths (who collected decides the ledger)

- **Stripe — Oolala collects.** `pack → create_order_for_pack (amount/currency
  from the pack snapshot, never the client) → Checkout → webhook →
  process_stripe_event → payment + recompute_earning (Oolala commission) →
  project onto pack`. A forged/ mismatched amount is refused (proven). Only the
  webhook can mark a card payment paid — the success URL never does.
- **Aani / manual — paid straight to Gari.** An **authorised operator**
  records the money actually received (`payment_record_manual`, finance:manage):
  a payment row with the source stored (`aani`/`bank_transfer`/`cash`/…), **no
  Stripe id fabricated**, order marked paid, pack projected. **No Oolala
  earning** is created — the money never passed through Oolala's Stripe (settle
  Oolala's share separately if ever agreed; flagged for the owner). Viewing or
  copying Aani details **never** marks anything paid.

### Aani (UAE instant payment) — V1

Config-driven, in `payment_methods` (managed under **finance:manage**, seeded
with Gari's Aani mobile; the number is **not** hardcoded in frontend code and is
**not** committed to the repo). The report page shows the registered number, a
payment reference, and Copy buttons. **No invented Aani API / deep link /
Request-to-Pay / auto-confirmation.** **No silent USD→AED conversion** — the
Aani amount is shown only when the pack is priced in Aani's currency (AED);
otherwise the client is asked to confirm the AED amount with the coach. A
verified QR can be added later (`qr_url`), never a fabricated one.

### Bank transfer — CG-012b (same money path as Aani)

A second manual option, in English: **Account holder / IBAN / BIC-SWIFT / Bank
name**, stored in `payment_methods` (`method='bank_transfer'`; migration
`20260913_cg012b_bank_transfer.sql`). Same rules as Aani, deliberately: details
are **admin-configured under finance:manage and never seeded** (the repo holds no
real IBAN); they appear **only** in the authenticated Finance configuration and
on the tokenised `/r/<token>` page when enabled — **never** on the public
marketing site. Viewing/copying **never** marks an order paid; the operator
reconciles the received transfer manually (`payment_record_manual`, source
stored as **`bank_transfer`**), which creates **no Stripe earning/transaction**.
The amount is shown in the pack's own currency — **no silent conversion**.

**Human public reference (CG-012c).** Manual payments need a reference a client
can type into a bank app, so every pack gets `session_packs.public_ref`
(`CG-####`, from `pack_ref_seq` starting at 1001; migration
`20260914_cg012c_pack_public_ref.sql`). It is quoted by `report_view` as
`pay_ref` and by both the Aani and bank panels, in the share message, and shown
on the pack card — a UUID is never surfaced to the client. Applied migrations are
never rewritten: CG-012c was added as a new file rather than editing CG-012b.

### Secure client report page (`/r/<token>`)

`report_tokens` (256-bit, sha256 stored, revocable, expiring). The `report`
Edge Function (service role, token only — no JWT, no CRM access) serves the
authoritative recap and starts a card payment. The recap **never** exposes body
metrics, BMI, health data or private notes — proven: it is built only from
`session_packs` (money) and `coaching_sessions` (dates), and the leakage test
asserts a private note and a weight value never appear. `pack_recap` is
finance-gated for staff; the client page legitimately shows the client's own
amount due.

### Renewal

`pack_renew` creates a **new** pack (`renewed_from_pack_id`, unpaid, price
copied only with finance:view) and leaves the old pack **immutable** — historic
cycles stay correct.

### Advisor hardening (fixed this sprint)

The CG-011 trigger functions (`coaching_sessions_pack_guard`,
`sync_session_from_booking`) had EXECUTE exposed to anon via PostgREST — revoked
(they only ever run as triggers). And `pack_recap_data(uuid, boolean)` /
`project_pack_payment(uuid)` are now revoked from `authenticated` so a
signed-in user cannot bypass the finance gate by passing `p_finance=true`
directly; they are reachable only through the gated `pack_recap`, the
service-role `report_view`, and the definer payment functions. New
`report_tokens` shows the accepted deny-all `rls_enabled_no_policy` INFO
(service-role only), like `consent_tokens`.

### Flagged for the owner

Commercial treatment of Oolala's commission on Aani/manual payments (currently
none, as the money bypasses Oolala) — confirm the intended split. Set
`STRIPE_SECRET_KEY` (test) and `SITE_URL` on the `report` function for card
payments; without them the page shows Aani only.

---

## CG-011 — Schedule as Gari's operating calendar; sessions + packages

**Status: DB built, applied and proven — `CG011_TESTS ok=31 fail=0`; advisors
carry no new ERROR (new functions are the same accepted SECURITY DEFINER
pattern, each `search_path=''` + `has_permission()`). Frontend calendar shipped.
Forward migration `20260911_cg011_calendar_sessions.sql`; nothing from
CG-002/003/009/010 dropped or rewritten. Reports / Stripe payment-requests /
renewals UI are deliberately CG-012 — only the schema hooks they need are here.**

### Canonical model

- **`coaching_sessions`** is the actual session occurrence — created from a
  website booking or entered manually. Structured location
  (name/address/lat/lng/meeting_url), `delivery_mode` online/in_person,
  `status` scheduled/completed/cancelled/no_show, a `chargeable` flag, an
  optional link to a `session_pack`, and a unique `booking_id` link.
- **`session_packs`** is the purchased/agreed entitlement: `total_sessions`
  (10 is a common configuration, **not** a schema constant), and a financial
  **snapshot** (`price_amount`, `currency`, `payment_status`, `payment_source`,
  `order_id`, `paid_at`) kept independent of session dates and of the
  `agreement_date`. **Renewal is a NEW pack** (`renewed_from_pack_id`); the old
  pack is never overwritten, so historical cycles ("sessions since last
  payment") stay correct.

### Consumption is authoritative, never date arithmetic

`X / total` is counted from sessions **explicitly linked** to the pack:
completed consumes one unit, scheduled and cancelled consume nothing, and a
no-show consumes only when explicitly marked chargeable. A trigger forbids a
session linking to a pack that belongs to a **different** client, so a
wrong-client session can never consume another client's package.

### One authoritative source of unavailability

"Block time" is stored as an existing **`availability_exceptions`** row
(`kind='closed'`, `source='calendar_block'`) — not a second concept. The public
`available_slots` engine already suppresses rule slots overlapping an active
closed exception, so a block immediately removes the period from public booking.
Private block notes live in a new `private_note` column that **no public API
returns** (proven).

### Website bookings integrate without duplicates

A confirmed/completed booking materialises exactly one `coaching_session`
(dedup by the unique `booking_id`); cancel/expire cancels it. Existing bookings
were backfilled idempotently. Manual/direct clients and sessions work with no
website booking and no Stripe transaction.

### Permissions

Session and block mutations need **`coach:operations`**; pack **financial**
fields need **`finance:manage`**, and price/paid are shown only with
`finance:view` (the pack read RPC shapes the payload; financial columns are not
column-granted). `platform:admin` alone grants **neither** — proven. All write
paths are `SECURITY DEFINER` RPCs (`session_write`, `session_set_status`,
`session_delete`, `pack_create`, `pack_set_payment`, `packs_for_contact`,
`calendar_range`, `sessions_upcoming`, `sessions_list`, `block_create/update/
remove`), `search_path=''`, permission-checked and audited.

### Frontend

Schedule → **Calendar** is a real Day (default) / Week / Month calendar
(remembered per browser, first-run Day). Day/Week are hour-grid timelines;
Month is an indicator grid; iPhone gets a day-selector + timeline for Week.
Tapping empty offers Add session / Block time (prefilled). A session popup
(bottom sheet) carries session/client/package/location with Maps + Waze (from
coordinates or the encoded address) or the meeting link, and quick actions. A
Sessions sub-tab lists/searches history; the client profile gains a Sessions &
packages tab; Overview shows a prominent Next-session card. **iPhone/iPad
responsive behaviour is verified manually** (see the E2E checklist) — the
authenticated calendar can't be exercised by the sandbox's tooling.

### Deferred to CG-012 (not built)

Session recap / shareable client report, secure `/r/<token>` report page,
Stripe payment-request flow (order → Checkout → webhook → pack paid), renewal
UI. Stripe stays **test mode** (CHECK-LICENCE-001).

### Financial architecture guardrail (canonical — applies to CG-012)

`session_packs` is the **coaching entitlement / operational projection**. It is
**not** a ledger. The authoritative financial truth stays where it already
lives: **`orders`, `payments`, `refunds`, `chargebacks`, and the partner
ledger / earnings / settlements** (CG-003). CG-012 must link a Stripe or manual
payment to those authoritative records and **project** the resulting state onto
the pack (`payment_status`, `paid_at`, `order_id`, `payment_source` are a
snapshot/projection, not a second source of truth). **Do not** build a second
independent payment ledger inside `session_packs`. A pack may *reference* an
order/payment; financial events remain authoritative in the finance domain.

### CG-012 readiness — schema check (verified 2026-09-07)

The CG-011 model already exposes everything CG-012's report + payment request
needs: completed/upcoming session dates (`coaching_sessions.start_at`+`status`),
X/total and remaining (`pack_used()` + `total_sessions`), price snapshot
(`price_amount`/`currency`), `agreement_date`, payment date/status projection
(`paid_at`/`payment_status`/`payment_source`), order relation
(`session_packs.order_id`), and renewal as a new pack (`renewed_from_pack_id`).

**Two things CG-012 must add (not gaps in the canonical model, but required for
CG-012 and flagged now):**
1. **`orders.booking_id` is `NOT NULL`** — orders currently assume a website
   booking. A pack/report payment request creates an order **not** tied to a
   booking, so CG-012's first forward migration must make `orders.booking_id`
   nullable and add a nullable `session_pack_id` (or an order-source
   discriminator) so a pack can own an order. Until then a pack cannot mint a
   Checkout order.
2. **No report-token table yet** — the secure `/r/<token>` client report page
   needs a new revocable, expiring, high-entropy token table following the
   existing `consent_tokens` / upload-token pattern (SHA-256 stored, no
   sequential ids). This is a normal CG-012 addition.

---

## CG-010 — Consent gate for sensitive coaching data, CRM hardening

**Status: DB layer built, applied and proven — `CG010_TESTS ok=48 fail=0`,
plus a CG-009 regression re-run (consent gate integrated, still green).
Advisors carry no new ERROR; new findings are the same accepted patterns as the
rest of the cockpit (see below). Consent Edge Function `consent` deployed
(`verify_jwt=false`, token-authorised). Client `/consent` page and admin UI
wired. Forward migration `20260910_cg010_consent_sensitive.sql`; nothing in
CG-009 was dropped or rewritten (`body_measurements` and derived BMI are
untouched).**

### Sensitive-data permission model

- Two new granular permissions: **`coaching_sensitive:view`** and
  **`coaching_sensitive:manage`**. They gate private coaching notes
  (note `scope = 'coach_private'`) and the consent-management actions.
- **Both launch users (Mickaël and Gari) receive `coaching_sensitive:view`
  and `coaching_sensitive:manage`** — an explicit, documented launch decision,
  not an implicit consequence of any other permission.
- **Independence is enforced and tested.** No permission implies another.
  `platform:admin`, `finance:*`, `analytics:view` and `coach:operations` grant
  **nothing** in `health_metrics:*` or `coaching_sensitive:*`. The suite proves
  a `platform:admin`-only persona can read no notes, no measurements, no
  consents, and cannot record or export anything sensitive.
- Every sensitive permission is **independently revocable** — each is its own
  row in `app_permissions` and its own checkbox on the Access screen. Removing
  one never removes another; removing `platform:admin` does not touch them.
- We deliberately did **not** redesign the schema to tighten this further (no
  super-admin/owner role, no ownership hierarchy). Granular permissions checked
  inside `SECURITY DEFINER` RPCs remain the model.

### Note scope

- `crm_notes.scope ∈ {operational, coach_private}`, default `operational`.
- RLS: an operational note needs `client_profile:view`; a `coach_private` note
  additionally needs `coaching_sensitive:view`. Enforced in RLS and in the
  add/edit RPCs — **not** hidden in the UI. Someone without the sensitive grant
  cannot read the row at all.

### Consent — auditable history, not a boolean

- `client_consents` is an append-style **history** (status
  `active | withdrawn | declined`, `source client_link | admin_recorded`,
  `notice_version`, `consented_at`, `withdrawn_at`, `evidence` jsonb, audit
  columns). A partial unique index keeps at most **one active** consent per
  `(contact, type)`.
- Consent type for this sprint: **`fitness_progress_tracking`**. The notice is
  **versioned** (`fitness-progress-v1-2026-09`) and states: what is recorded
  (height, weight, derived BMI, body-fat %, muscle %, progress history), the
  purpose, who may access it, how to withdraw, retention, the client's
  access/export/deletion rights, and a privacy contact.
- **Fitness, not medical.** The notice and the admin UI both carry the
  fitness-not-medical disclaimer. No health/medical judgement is made or shown;
  BMI is never auto-labelled healthy/overweight/etc.
- **Client link is the primary path.** `consent_issue_link` mints a scoped,
  single-use, 7-day, 256-bit token (only its SHA-256 is stored). The client
  opens `/consent?t=…`, reads the versioned notice and makes an **explicit
  affirmative** accept/decline (tick + confirm) on the public site. The link
  gives **no** CRM/admin access and exposes only a first name.
- **Admin "record consent" is an exceptional, clearly-marked fallback**
  (`source = admin_recorded`, evidence `method = admin_fallback`), for when a
  client consented in person/writing and cannot use the link.
- **Server-side enforcement (not UI-only).** `metrics_add` refuses with a
  distinct error when there is no active consent (`P0004`) or the contact is a
  minor (`P0005`). Reads via `platform:admin` / `finance:*` / `analytics:view`
  are denied at the RLS/RPC layer regardless.

### Withdrawal, export, deletion — three distinct actions

- **Withdrawal** is a timestamped event that flips the active consent to
  `withdrawn`; it **stops future collection** and **retains** all prior
  measurements as evidence. It is not deletion.
- **Export** (`metrics_export`, needs `health_metrics:view`) and **deletion**
  (`metrics_delete_history`, needs `health_metrics:manage`) are separate,
  each **scoped to one contact** and **audited**; one client's action cannot
  affect another's data (proven). Sensitive data never appears in Analytics.

### Minors

- V1 does **not** enable Progress for known minors (`crm_contacts.is_minor`):
  `consent_issue_link`, `consent_record_admin` and `metrics_add` all refuse a
  minor (`P0005`). No guardian workflow is built.

### Data-leakage posture

- Sensitive values never enter Analytics/Plausible, finance, telemetry, or logs.
  Audit rows and Edge-Function logs record only the **entity id, action and
  status** — never a measurement value or note body. The consent function
  captures a **salted hash of the client IP** plus a truncated user-agent as
  evidence, never the raw IP.

### Advisors (investigated)

- `consent_tokens` shows `rls_enabled_no_policy` (INFO) — **intentional**: RLS
  on with no policy = deny-all to `authenticated`/`anon`; only the service role
  (Edge Function) reads it. Same accepted pattern as `email_events` /
  `webhook_events`.
- New `SECURITY DEFINER` functions appear under
  `authenticated_security_definer_function_executable` (WARN) — the cockpit's
  established design: every privileged RPC is `SECURITY DEFINER` with
  `set search_path = ''` and an internal `has_permission()` check. Verified for
  each CG-010 function; `consent_view` / `consent_submit` are **service-role
  only** (not executable by `authenticated` or `anon`).
- `auth_leaked_password_protection` (WARN) is pre-existing auth config, unrelated
  to CG-010 — see owner actions.

### Legal (flagged for the owner — no conclusion drawn in code)

- The notice text, retention wording, the Controller/Processor characterisation
  between Coach Gari / Oolala / The Studio MT, and any minors policy are **legal
  items for the owner** to validate. This document deliberately makes **no**
  definitive legal claim about Controller/Processor status.

### Owner action

Grant the new permissions with the same `set_app_access` pattern as CG-009
(see the launch provisioning block). Both launch users get
`coaching_sensitive:view` and `coaching_sensitive:manage`; Gari does **not** get
`platform:admin`. The consent Edge Function needs the existing
`SUPABASE_URL` / `SUPABASE_SERVICE_ROLE_KEY` env (already set for `upload`).

### Not built (deliberately out of CG-010 scope)

Guardian/minor consent workflow; wearable/device import; fuzzy identity
matching; any medical assessment; new monetisation. Automated DB suites are
**not** pointed at production — CI runs them only when a `SUPABASE_DB_URL`
staging secret is present (none is created without approval).

---

## CG-009 — Admin cockpit, CRM canonical model, client profile, progress

**Status: built and deployed; DB suite `CG009_TESTS ok=43 fail=0` plus a
regression probe (9/0) confirming the existing per-persona RLS is unchanged;
advisors clean of new findings. Frontend is a vanilla-JS rewrite of the
back-office shell and CRM; no browser-run e2e in this environment.**

### Pattern source

The `OolalaDXB/maison-collection` React app was used strictly as a **UI
pattern library** (sidebar `AdminLayout`, `GuestProfileDialog`, contacts
list, calendar tabs). No logic, schema, permissions, environment values or
secrets were copied; its `.env` was never read. Patterns were re-implemented
in Coach Gari's existing vanilla-JS + Supabase stack. The repo is attached
read-only and not registered (its CLAUDE.md/plugins are not loaded).

### Decisions

- **One cockpit.** The dense horizontal nav is replaced by a sidebar
  (desktop) / drawer (mobile) with a minimal top header carrying the page
  name and an account menu; Sign Out moved into that menu. Destinations:
  Overview, CRM, Schedule, Bookings, Services, Finance, Analytics, Access
  (platform:admin). Visibility stays permission-driven. Calendar,
  Availability, Exceptions and Tour stops are no longer four top-level
  items — they are sub-tabs of **Schedule**. Finance stays one destination
  (CG-008). No booking-engine change; the UI only reorganises.
- **An enquiry is not a person.** New `crm_contacts` canonical model;
  `contacts.crm_contact_id` and `bookings.crm_contact_id` link to it, added
  and back-filled without rewriting a single enquiry. A `before insert`
  trigger keeps new rows linked, including a **direct booking** with no prior
  enquiry.
- **Conservative matching only.** `crm_link_contact` matches an exact
  normalised email (single match), then an exact normalised phone (single
  match), else creates. Never a fuzzy name merge; two same-name people stay
  separate. An ambiguous match creates a fresh record flagged
  `needs_review` — a manual merge can be added later, but no merge engine is
  built now.
- **Client profile is a popup, not a page.** Clicking a Lead or Contact opens
  a large responsive dialog over the list, so closing it returns to the exact
  tab / filters / search / scroll. Sections: Overview, Notes, Progress,
  Enquiries, Bookings, Payments, Media, Attribution — each gated by its own
  permission. Media reuses the private `enquiry-media` bucket via short-lived
  signed URLs; no second bucket.
- **Notes are a history.** `crm_notes` (author, timestamp, category, pin);
  editable, edits audited. Internal only; never in analytics or public paths.
- **Body metrics are longitudinal, BMI is derived.** `body_measurements`
  snapshots the height used per row; `bmi` is a generated column, never
  typed or independently editable, so historical BMI is reproducible. Server
  validates plausible ranges (rejects, does not coerce), accepts partial
  measurements, and produces no medical interpretation. Height also lives as
  the current value on `crm_contacts`.
- **Sensitive data is independently permissionable.** New
  `client_profile:view/manage` and `health_metrics:view/manage`. `finance:*`
  and `analytics:*` never imply either. Both launch users get all four; only
  Mickaël keeps `platform:admin`. Permissions stay granular.
- **Writes are RPC-only and audited.** `crm_save_contact`, `crm_add_note`,
  `crm_edit_note`, `metrics_add`, `metrics_edit` check the permission and log
  to `admin_audit` (who / what / when). The CRM tables have no direct
  insert/update/delete grant for `authenticated`; anon has nothing. The two
  link trigger functions are not callable as RPCs (advisor 0028 addressed).
- **Overview** is a light `admin_overview` RPC returning only the cards the
  caller may see (new leads, today's sessions, upcoming bookings, pending
  payments, unsettled payable, CRM counts). No vanity charts.

### Not built (backlog)

A manual merge engine, fuzzy matching, medical interpretation, meal plans,
paid Video Review, and every other item on the sprint's out-of-scope list.

### Owner action

Re-run the two `set_app_access(...)` lines from the README — they now include
`client_profile:*` and `health_metrics:*`. Mickaël's existing Auth identity
and access are untouched; the call is idempotent.

---

## CG-008 — One back-office cockpit (`/admin`), Finance as a tab

**Status: built and deployed. UI/navigation change only — no schema, RLS,
RPC, permission or data-model change.**

### Decisions

- **A single operational workspace.** The `/admin` vs `/finance` split
  reflected the earlier access model (Gari operational, Oolala/Mickaël
  finance, strongly separated). Launch users now hold the same full business
  access, so two back-offices were artificial. Everything lives in `/admin`
  as tabs, in order: Leads, Calendar, Bookings, Availability, Exceptions,
  Tour stops, Services, Finance, Analytics, Access.
- **Finance is a tab, not a merge of rights.** `finance:view` and
  `finance:manage` stay independent permissions in the database. Tab
  visibility is permission-driven (`has('finance:view')`), and the Finance
  tab plus its RPCs (`finance_orders`, `finance_webhook_log`,
  `finance_*settlement*`) remain gated by RLS and their own
  `has_permission` checks. Remove `finance:view` and the tab and its data
  disappear — the security boundary is unchanged and still independently
  tested (the single-permission personas in the suite are untouched).
- **`/finance` kept as a deep link.** A Vercel redirect sends `/finance`
  (and `/finance/*`) to `/admin#finance`; the hash selects the Finance tab
  when the person has it, else the back-office opens on their first tab. The
  separate `finance/index.html` is removed — one UI, not two. Sign-in always
  lands on `/admin/`.
- **No Overview tab built.** An Overview/dashboard was floated but is a new
  feature; Analytics already covers the aggregate view. Left for the backlog.
- **Nothing else touched.** No change to the finance data model, the ledger,
  the catalogue, the booking engine or any permission definition. The
  `access:` and `analytics:` tabs, and the platform-admin narrowness, are
  exactly as in CG-006.

### Owner action

Redirect URLs in Supabase Auth now only need `/admin/` (sign-in always lands
there). The `/finance/` redirect URL, if already added, is harmless.

---

## CG-007 — Admin-editable service catalogue

**Status: built and deployed; suites 236 / 28 / 24 green. Attaching
`catalog:view` + `catalog:manage` to the two launch users is part of the same
owner provisioning step as CG-006 (Auth invitations first).**

### Decisions

- **Scope change, deliberately narrow.** The commercial service catalogue is
  now editable from `/admin` (Services tab). This is *not* a CMS: no
  `site_content`, no page or copy editor. Everything outside the catalogue
  stays in Git under The Studio MT's control.
- **The database is the only source of the catalogue.** `index.html` no
  longer contains any price, title, duration, description or feature list
  for the bookable catalogue; the four cards and the picker render from
  `?action=services`. The Conversation renders `60 min · 100 USD · online`
  from `services.price_amount = 10000`. The three non-bookable offers
  (Programme, Online Coaching, Live Group) were moved into the catalogue as
  `booking_mode = 'enquiry'` rows with the exact copy and figures the page
  already carried; their prices stay hidden while `COMMERCE` is false, as
  before.
- **Two explicit permissions**, `catalog:view` and `catalog:manage`, added
  to the same granular model (no widening of any existing permission).
  Both launch users receive both. A pure coach, finance, analytics or
  platform:admin persona cannot edit the catalogue (tested).
- **Historical integrity is structural, not procedural.** Bookings snapshot
  slug, title, duration and price at hold time (trigger-backed for any
  insert path); orders snapshot the title and amount; the finance view, the
  booking JSON, the order JSON and the Stripe line item read the snapshots.
  A catalogue change can only affect future holds. Tested end to end:
  price 4500 → 9900 and a rename leave the paid booking, the order, the
  ledger (payable 3905) and `finance_orders()` unchanged; the next hold
  takes 9900 / 90 min / the new title.
- **Auditability.** One write path (`catalog_save_service`), permission
  checked inside, values validated by table constraints, every change
  recorded in `catalog_audit` (email, timestamp, changed fields, before /
  after). No direct insert / update / delete on `services` for any browser
  role; anon has no read either (the public reads through the booking
  function). Services are never deleted: deactivate + hide keeps history
  intact. The Services tab shows the change log.
- **Not built**: rich text, images per service, per-service pages, variants
  or bundles, scheduled price changes, approval workflow.

### Owner actions

Same as CG-006: invite the two users in Supabase Auth, then run the two
`set_app_access(...)` lines from the README (they now include
`catalog:view` and `catalog:manage`).

---

## CG-006 — Launch access model, platform:admin, upload credential hardening

**Status: built and deployed; suite 206/206. Attaching the two launch users is
an owner action (Auth invitations first — see Owner actions).**

### Decisions

- **Launch access is identical full business access for both principals,
  expressed as the existing granular permissions, not as a role.** The owner
  (The Studio MT) and the coach each hold `coach:operations`, `finance:view`,
  `finance:manage` and `analytics:view`, so both can run `/admin` (leads,
  calendar, bookings, availability, exceptions, tour stops, attachments) and
  `/finance` (orders, payments, refunds, chargebacks, earnings, commission,
  payable, settlements, reconciliation). The permission model, the column
  grants and the RLS policies are unchanged: nobody gets `manage_token`,
  `ip_hash`, raw webhook payloads or customer columns on `orders`. The
  canonical rule still governs the *schema*; at launch the two people have
  simply chosen to share the operational view. Any permission can be taken
  back later without a code change.
- **`platform:admin` is narrow and belongs to the owner only.** It unlocks an
  Access tab (list application users, activate / deactivate, grant / revoke)
  through `admin_list_access`, `admin_set_user`, `admin_grant`,
  `admin_revoke`. It is not a superadmin: it opens no business row and no
  business RPC (tested persona), it cannot write the access tables directly,
  it cannot call the service-role `set_app_access`, cannot revoke its own
  `platform:admin` and cannot deactivate itself. If a platform admin grants
  themself a business permission, that explicit permission — and only it —
  opens the corresponding data; revoking it closes them. No service-role key
  ever reaches a browser.
- **Invitation only, no fake records.** `auth.users` is empty today. Rather
  than inserting `app_users` rows for emails that cannot sign in, every
  provisioning path (`set_app_access`, `admin_set_user`) refuses an email with
  no auth identity (`P0002`). Provisioning is operational data run in the SQL
  editor or the Access tab; **no personal email is committed to a migration or
  to this repository**. `set_app_access` is idempotent: re-running it replaces
  the permission set.
- **Cross navigation, not a redesign.** A single understated "Finance ↗" /
  "Operations ↗" link in the back-office header, rendered only when the
  person actually holds the other permission.
- **Upload authorisation no longer relies on the client `submission_id`.**
  `contact` now returns a server-issued `upload_token` (256 random bits,
  hex; only its SHA-256 is stored on the enquiry; 30-minute expiry; one
  enquiry). `reserve_contact_media` / `confirm_contact_media` take the token;
  the `submission_id`, the contact id, wrong, null and expired tokens are
  refused (tested), re-issuing rotates the credential, and a duplicate or
  retried enquiry never receives a token. `upload_token_hash` is not granted
  to any browser role.
- **Strict MIME allowlist, three layers.** `image/jpeg, png, webp, heic,
  heif, gif` and `video/mp4, quicktime, webm, x-m4v, 3gpp`. No SVG, no PDF,
  nothing executable, no `image/*` wildcard — enforced by
  `media_type_allowed()` in the RPC and a check constraint on
  `contact_media`, by the bucket's `allowed_mime_types`, and by the Edge
  Function. Unchanged: 3 files, 50 MB total, private bucket, 10-minute
  signed read URLs for `coach:operations` only. Still no antivirus or
  transcoding.
- **Booking picker incident stays "mitigated / root cause open."** The retry
  strategy is kept as is; no clock-skew claim, no wider auth workaround.
- **Stripe remains TEST mode only**; every CG-003 hardening is preserved.

### Tests

`CG0025_TESTS ok=206 fail=0` on 2026-09-04 (rollback harness). New blocks:
upload-token issuance, refusal of `submission_id` / contact id / wrong / null
/ expired tokens, token rotation, six rejected MIME types at RPC, table and
bucket level; anon refused on all new RPCs; stranger / inactive refused on
`admin_list_access` and see no other user's row; coach refused on
`issue_upload_token`, `upload_token_hash`, `admin_*`, `set_app_access`;
**composite launch persona** (21 checks); **platform:admin-only persona**
(37 checks, no bypass); `set_app_access` refusing a ghost email. Webhook
signature suite 24/24, htmlhint and link check clean. Supabase advisors: no
ERROR; the WARN class "signed-in users can execute SECURITY DEFINER function"
is the documented, intentional pattern (every such function checks
`has_permission` first); INFO items unchanged.

### Owner actions

1. Supabase → Authentication → Users → *Invite user* for the owner and for the
   coach (their emails are known to the parties and deliberately not written
   here).
2. SQL editor: the two `set_app_access(...)` lines from the README with the
   real emails (owner: all five permissions; coach: the four business
   permissions). Re-run at any time; refuses until the invitation exists.
3. Redirect URLs for `/admin/` and `/finance/`; *Allow new users to sign up*
   off.
4. Unchanged from earlier sprints: `SUPABASE_DB_URL` secret for CI, Plausible
   activation, Resend / custom SMTP, production domain.

---

## CG-005 — The Conversation: 100 USD / 60 min

Approved Route C price applied where it lives: `services.price_amount = 10000`
(`20260906_cg005_conversation_price.sql`). The chain that makes the frontend
irrelevant to the amount is unchanged: `create_hold` snapshots the service
price on the booking, `create_order_for_booking` copies the snapshot to the
order, `checkout` creates the Stripe session with the order's amount, and
`process_stripe_event` refuses a `checkout.session.completed` whose
`amount_total`/currency differ from the order (logged `ignored`, never
confirms). The card renders the API value as `60 min · 100 USD · online`.
Commission stays 10 % of net. Verified in the suite: snapshot 10000, order
10000, a 4500 completion ignored, ledger 10000 / fee 320 → net 9680,
commission 968, payable 8712. Since CG-007 the homepage card also renders
this price from the database; the HTML constant is gone.

---

## Incident 2026-09-04 — booking picker replaced by "Booking opens soon"

**Status: mitigated, root cause OPEN (monitoring).**

**What happened.** The `booking` Edge Function answered `?action=services`
with HTTP 500 three times (2026-09-03 23:14:36, 2026-09-04 06:01:36 and
06:50:49 UTC). The page treated the 500 as an empty catalogue and showed
the "opens soon" message, hiding the cause. Catalogue, config, CORS and RLS
were correct throughout.

**Evidence (API-gateway `edge_logs`, `function_logs`).** Each failure is a
`GET /rest/v1/services…` answered **401** with
`proxy_status: PostgREST; error=PGRST303` (JWT expired / not yet valid),
`origin_time` 302–947 ms. In the same second, from the same boot, the
`GET /rest/v1/tour_stops…` request with the **same credential hash**
(`request.sb.apikey.*.hash` identical) returned 200. PostgREST's own logs
show nothing for those seconds. Each failure was the first `services` call
of a fresh isolate (`booted` logged just before).

**Credential facts (verified in code and in the gateway logs).**
- The client is `createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, {auth:{persistSession:false}})`.
  `SUPABASE_SERVICE_ROLE_KEY` is injected by the platform; the gateway logs
  show it is a **new-format secret key** (`sb_secret_…` prefix), not a
  legacy JWT. supabase-js sends it verbatim as `apikey` and as the
  `Authorization: Bearer` value on every request.
- No user JWT is involved anywhere in `booking`; no session is created,
  refreshed or cached; nothing is memoised across the isolate lifecycle. A
  "new client" therefore carries the **same static credential** — the retry
  is a retry of the same request, not a different credential.
- With `sb_secret_` keys, the JWT that PostgREST validates is minted by the
  Supabase API gateway per request, not by our code. A `PGRST303` on that
  minted token, intermittent, first-request-after-boot, with the same key
  succeeding 30 ms later, points at the gateway/PostgREST side (token
  minting or validation timing). Clock skew is one hypothesis consistent
  with the evidence; it is **not proven** and is not recorded as the cause.

**Mitigation in place.** `booking` retries `PGRST301/303`, `PGRST00x` and
connection errors up to twice (150/300 ms) with a fresh client before
returning 500, and logs `transient_retry` with the error message, the
isolate time and the credential's public claims (kind / role / iat / exp —
never the key). `assets/booking.js` separates outage from empty catalogue,
retries once, and logs `booking_init_failed: <reason>`.

**Monitoring.** Watch `function_logs` for `transient_retry` (retry absorbed
it) and `rpc_failed` (retry did not). If `PGRST303` recurs with the
diagnostics attached, open a Supabase support ticket with the
`request_id`s above rather than adding an auth workaround here.

---

## CG-004 — Enquiry attachments (photos / videos)

**Status: built and deployed; covered by the permissions suite.**

### Decisions

- **Every category, 3 files, 50 MB in total, images and videos only.** The
  same limits live in the browser, in `reserve_contact_media` (with an
  advisory lock per enquiry) and on the bucket itself.
- **Lead first, files second.** The enquiry is stored by `contact` exactly as
  before; uploads follow one by one and a failed upload never loses the lead.
  The success message says how many files were attached.
- **No key in the browser.** The `upload` Edge Function issues signed upload
  URLs for the private bucket `enquiry-media`; ownership was originally
  proven with the browser's `submission_id` — **superseded by CG-006**, which
  issues a server-side upload token instead. `confirm` checks the object
  exists before marking the row `uploaded`, and removes stray objects.
- **People belong to Gari.** Only `coach:operations` can read
  `contact_media` rows and the objects (policy on `storage.objects`); the
  Leads tab opens each file with a short-lived signed URL. Finance,
  analytics and anon are tested to see nothing.
- **Off switch**: `UPLOAD_ENDPOINT: ''` hides the field without touching
  the backend.
- Not done on purpose: virus scanning, transcoding, thumbnails, attachments
  on the lead email (it is sent before the files arrive; the back-office is
  the place to view them).

---

## CG-002.5 — Back-office, permissions, RLS

**Status: built; database suite 118/118 at the time (206/206 after CG-006, rollback harness, persona switching);
`/admin` (Gari) and `/finance` (Oolala) deployed (noindex). Inviting the first
auth users, granting their permissions and adding the redirect URLs in
Supabase Auth are owner actions.**

### Decisions

- **Permissions are the canonical rule, encoded.** `coach:operations` (Gari),
  `finance:view` / `finance:manage` (Oolala), `analytics:view` (shared). No
  `content:*` — the site is Git. A signed-in email with no `app_permissions`
  row sees nothing.
- **Magic link, no passwords, no self-registration, no roles in the JWT.**
  `signInWithOtp` runs with `shouldCreateUser: false`: only an auth user the
  owner invited can receive a link. Authorisation is looked up by email in
  `app_users`/`app_permissions` at query time, so revocation is immediate
  (`active = false` or delete the row) without touching Auth. Those two tables
  have no insert/update/delete grant for `authenticated` — permissions are
  never writable from the browser (tested). No personal email is hardcoded in
  any migration.
- **Two routes, one script.** `/admin` shows only the six operational tabs;
  `/finance` shows only Finance. Analytics appears on whichever area the
  person has, when granted. No super-admin: a person with both permissions
  simply has both areas. *Superseded by CG-008: a single `/admin` workspace
  with Finance as one tab; `/finance` redirects there. Permissions stay
  independent.*
- **Column grants, not table grants.** `authenticated` is granted explicit
  column lists: leads without `ip_hash`; bookings without `manage_token`,
  `idempotency_key`, `ip_hash`; orders without `customer_name` /
  `customer_contact`; webhook events only through `finance_webhook_log()`, without payloads.
  Both are SECURITY DEFINER *functions* that check the permission (the
  linter rates definer *views* as errors; definer functions callable by
  `authenticated` are a documented warning — every one of ours checks
  `has_permission` first).
  The UI therefore never uses `select *` on a table.
- **People vs money.** Finance reads `finance_orders()` (order, booking
  reference, service, session time, ledger figures, and a masked
  `customer_hint` such as `p***@example.com` for matching a Stripe receipt) —
  never the name, the full contact or an enquiry. Finance has no grant at all
  on `contacts`, `bookings` or `email_events`. The
  coach reads people and the calendar — never orders, payments or the ledger.
  Cancelling a booking as coach never touches a paid order; refunds are
  Oolala's decision in Stripe and arrive through the webhook.
- **Coach state changes are an RPC with a state machine**
  (`ops_set_booking_status`): cancel a hold/pending/confirmed booking
  (`cancelled_by = 'coach'`, queues a `booking_cancelled` email event —
  prepared, not sent), complete / no-show only a confirmed session that has
  started, confirm by hand only an unpriced hold (paid bookings confirm through
  payment only).
- **Calendar edits are direct table access under RLS** (rules, exceptions,
  tour stops, eligible services) — simplest thing that works, fully covered
  by policies.
- **Analytics is a single aggregate function**; its output is asserted PII-free
  in the suite.
- **Services stay read-only in the back-office**: prices and the catalogue are
  a Git/migration change (public content rule). *Superseded by CG-007: the
  catalogue is the one admin-editable content, with audit and snapshots.*

### Tests

`supabase/tests/cg0025_permissions.sql` — `CG0025_TESTS ok=118 fail=0` on
2026-09-03, rolled back. Personas: anon (10 refusals), stranger and inactive
user (11 each), coach (35: intended reads and edits, refusals on orders,
payments, refunds, chargebacks, settlements, settlement items, webhook log,
`manage_token`, `ip_hash`, finance RPCs, and any write to the permission
tables), finance (19: ledger reads, masked hint, refusals on leads, the
message column, bookings, customer names, `email_events`, self-granting),
analytics (6, including an email/phone/reference regex over the output).
A pg_cron-independence check (3) proves an expired hold frees capacity
before `expire_holds()` runs. CI job `db-boundary-tests` runs all three
suites through `scripts/db-tests.sh` when `SUPABASE_DB_URL` is set and fails
the build on any `fail>0`.

### Owner actions

1. Supabase → Authentication → URL configuration → Redirect URLs: add
   `https://coachgariv0.vercel.app/admin/` and `…/finance/` (and the
   `coachgari.com` equivalents once live). Auth settings: turn off *Allow new
   users to sign up*.
2. Authentication → Users → *Invite user* for Gari and for Oolala.
3. SQL editor: attach access with `set_app_access(...)` (CG-006; snippet in
   README — direct inserts are no longer the documented path).
4. GitHub → repository secret `SUPABASE_DB_URL` (session-pooler URI) so CI
   enforces the boundary tests on every push.
5. Optional: custom SMTP for auth emails (Resend) once the domain is verified.

---

## CG-003 — Orders, Stripe TEST mode, partner ledger

**Status: built; database suite 24/24 (rollback harness); `checkout` and
`stripe-webhook` Edge Functions deployed; Stripe secrets are an owner action
(test keys only). No live payment is possible by construction.**

### Decisions

- **Stripe TEST mode only, enforced in code.** `checkout` refuses any key that
  is not `sk_test_…` (`live_mode_blocked`) and `stripe-webhook` refuses any
  event with `livemode: true`. Switching to live requires a code change on top
  of CHECK-LICENCE-001 — not just a secret.
- **No Stripe Connect.** Stripe = Oolala's account. Gari's share is computed in
  our ledger and paid by manual bank transfer, tracked in `partner_settlements`.
- **Server-side Checkout, trusted amount.** The browser sends `{ref, token}`
  only; price and currency come from the booking's price snapshot
  (`create_order_for_booking`). Any amount field in the request is ignored.
  One live order per booking; a still-valid Checkout Session is reused.
- **The webhook is the source of truth; the success page is not.** The return
  URL only makes the page poll `state`; a booking becomes `confirmed` solely
  when `process_stripe_event` records a verified `checkout.session.completed`
  whose `amount_total`/currency equal the order. A mismatch is logged as
  `ignored` and never confirms.
- **Idempotent, transactional processing.** `webhook_events.event_id` is
  unique; payments are unique per `payment_intent`; refunds per refund id;
  disputes per dispute id. Re-deliveries (same or new event id) never create a
  second payment, earning or email.
- **Hold ↔ checkout.** Creating a session moves the booking to
  `pending_payment` and aligns the hold with the session expiry (30 min,
  Stripe's minimum). `checkout.session.expired` or the minute sweep releases
  the slot and cancels the orphan order.
- **Ledger (minor units):** `net_collected = gross − stripe_fee − refunds −
  chargebacks(lost) − tax`; `oolala_commission = max(0, round(net × 10 %))`;
  `gari_payable = net − commission`. The Stripe fee is read from the balance
  transaction (`fee_known`); the fee is never refunded, so a full refund leaves
  a small negative payable that the next settlement nets off. Only a *lost*
  dispute hits the ledger; open disputes are visible but neutral. CHECK
  constraints enforce the formulas in the database.
- **Settlements**: `create_settlement(partner, from, to, currency)` freezes the
  open earnings of the period (`ready`), `mark_settlement_paid(ref, bank_ref)`
  → `paid`, `mark_settlement_reconciled` → `reconciled`. A settled earning that
  changes later (refund after payout) is flagged with `adjusted_at` and its
  delta is carried into the next settlement rather than rewriting history.
- **Emails are queued, not implied.** `email_events` rows
  (`booking_confirmed` to the customer if the contact is an email,
  `payment_received` to letsgo@) are written inside the same transaction and
  sent by the webhook only if `RESEND_API_KEY` is set; otherwise `skipped`.
- **Webhook signature = Stripe's scheme, verified on the raw body.**
  `signature.js` (shared by the Edge Function and a Node unit test) parses
  `Stripe-Signature` (`t`, every `v1`; `v0` ignored), computes
  HMAC-SHA256(`STRIPE_WEBHOOK_SECRET`, `${t}.${raw body}`) and compares in
  constant time; `|now − t| > 300 s` is rejected (replay / stale / far future).
  The body is read with `req.text()` and verified before `JSON.parse`. 24
  offline cases (`scripts/test-webhook-signature.mjs`, run by CI) cover
  tampering, wrong secret, stale, future, replay, missing / malformed / v0-only
  headers, truncated and bit-flipped signatures, secret rotation; a laptop
  probe (`scripts/test-webhook.mjs`) sends the same cases to the deployed
  function and expects 400 `bad_signature` with the reason, plus live-mode and
  duplicate-event handling.
- **Security**: RLS on every new table, zero grants to anon/authenticated,
  RPCs `SECURITY DEFINER` with pinned `search_path`, executable by the service
  role only; PII-free logs.

### Tests

| Gate item | Where |
|---|---|
| order from a hold, trusted amount, idempotent | `supabase/tests/cg003_payments.sql` §1 |
| checkout attach → pending_payment, hold extended, slot still taken | §2 |
| paid → one payment, order paid, booking confirmed, emails queued | §3 |
| ledger 4500 / fee 161 → net 4339, commission 434, payable 3905 | §3 |
| duplicate event and re-delivery under a new id | §4 |
| amount mismatch never confirms | §5 |
| expired checkout and time-based expiry release capacity | §6 |
| partial refund, `refund.updated` not double-counted | §7 |
| full refund → commission 0, payable −161 | §8 |
| dispute open neutral, dispute lost hits ledger | §9 |
| settlement aggregate (2 items, gross 9000, fee 322, payable −322), paid, reconciled, post-settlement adjustment flag | §10 |
| unknown order / unhandled type ignored | §11 |
| `state` exposes the order for polling | §12 |
| forged amount ignored, real Stripe round trip | `scripts/test-checkout.mjs` (laptop, after secrets) |

Result `CG003_TESTS ok=24 fail=0` on 2026-09-03, rolled back, no probe
migration recorded. Security advisor: only the intentional "RLS enabled, no
policy" notices (service role only until CG-002.5).

### Owner actions (Stripe, test mode)

1. Stripe dashboard → **Test mode** → Developers → API keys: copy the
   `sk_test_…` secret key.
2. Developers → Webhooks → add endpoint
   `https://acrjrlgeeyseyolmofuq.supabase.co/functions/v1/stripe-webhook`,
   events `checkout.session.completed`, `checkout.session.expired`,
   `refund.created`, `refund.updated`, `charge.dispute.created`,
   `charge.dispute.updated`, `charge.dispute.closed`; copy the `whsec_…`.
3. `supabase secrets set STRIPE_SECRET_KEY=sk_test_… STRIPE_WEBHOOK_SECRET=whsec_…`
   (and `SITE_URL=https://coachgari.com` once the domain is live).
4. `node scripts/test-checkout.mjs --wait`, pay with 4242 4242 4242 4242.

---

## CG-002 — Internal booking engine

**Status: built; database suite 28/28 (rollback harness); public API deployed;
front flow live on the homepage; laptop API script ready.**

### Decisions

- **No external scheduler.** PostgreSQL is authoritative for price, duration,
  capacity and availability; the browser never supplies them. Everything
  mutating goes through SECURITY DEFINER RPCs callable by the service role only
  (`available_slots`, `create_hold`, `get_booking`, `cancel_booking`,
  `expire_holds`), fronted by the public `booking` Edge Function.
- **Services normalised from the Route C catalogue, no invented prices.** Only
  **The Conversation** is bookable and payable now (USD 100, 60 min, online,
  capacity 1). `online-coaching-session` and `onsite-one-to-one` exist but are
  inactive and unpriced: the catalogue prices coaching per month and in-person
  "on request", so a per-session price is a business decision before
  activation. A service with `price_amount = NULL` can be held but not paid
  ("priced on request").
- **Capacity-aware, individual only.** `default_capacity`, `participant_count`
  and the concurrency logic work for capacity N (tested with capacity 3); the
  public flow only creates single-participant bookings. Group sessions remain a
  prepared capability, not a product: no page, price, CTA, product or calendar.
- **Availability = rules + exceptions.** Rules: ISO weekday, local start/end,
  IANA timezone, optional service list, validity dates, active flag. Exceptions:
  `closed` (blocked time, holidays) or `open` (exceptional openings). **Closed
  exceptions suppress rule-generated slots only; explicit openings are never
  suppressed.** Placeholder hours (Mon–Fri 09:00–17:00 Asia/Dubai) are seeded
  and flagged for Gari to edit in the back-office.
- **Gari on tour = `tour_stops` + open exceptions bound to the stop.** A stop
  has a destination timezone, dates, optional booking window, venue/address,
  status (`draft/open/closed/completed/cancelled`) and eligible services. Its
  windows produce slots only while the stop is `open`, inside the booking
  window, for eligible services, in the destination timezone. Tour slots and
  the normal online calendar coexist (tested). No demand aggregation, no city
  voting, no travel automation.
- **Timezones**: all timestamps UTC; every rule/exception/stop/booking keeps
  its IANA zone (validated by trigger); slots are returned with `local_start`
  in the visitor's zone and `session_timezone` spelled out.
- **Holds**: 10 minutes; capacity ignores expired holds lazily and `pg_cron`
  sweeps statuses every minute (`cg-expire-holds`). One advisory lock per
  service serialises capacity checks. `idempotency_key` is unique — a retry
  returns the same booking. Customers get a `CG-XXXXXX` reference plus a secret
  `manage_token` to read or cancel.
- **Minimum notice** 2 hours; horizon 60 days in the UI (62 in the RPC).
- **Cancellation**: the customer can cancel a hold, a pending or a confirmed
  booking until the session starts; money questions belong to CG-003/finance.
- **Enquiry link**: a booking is matched to an existing `contacts` row when the
  contact string is identical; no new contact row is created.
- **Security**: RLS on every table, zero grants to anon/authenticated, no
  policies yet (CG-002.5 adds role-based policies), `search_path` pinned,
  PII-free logs, per-IP hold rate limit (10 / 10 min).

### Tests

| Gate item | Where |
|---|---|
| recurring availability, exceptions, exceptional openings | `supabase/tests/cg002_booking.sql` §1, 3, 4 |
| timezone conversion (Dubai ↔ UTC ↔ Johannesburg) | §2 |
| tour-stop availability (draft vs open, eligibility, destination tz) | §5 |
| coexistence travel / normal calendar | §6 |
| hold creation, idempotence | §7, 8 |
| concurrent capacity-1 race | `scripts/test-booking.mjs` (two parallel holds → one winner); DB: §9 serial refusal |
| capacity > 1 technical case | §10 (capacity 3: 2 + 1 ok, 3rd refused) |
| hold expiration releases capacity | §11 |
| cancellation releases capacity | §12 |
| frontend cannot forge duration / price / capacity | §7, 13 (DB) + API script (extra fields ignored) |

The DB suite runs in one transaction and always rolls back; result
`CG002_TESTS ok=28 fail=0` on 2026-09-03. A defect it caught: `create_hold`
could not see `gen_random_bytes` under `search_path = ''` → fixed by
`20260904_cg002_fix_random_bytes.sql`.

---

## CG-001 — Route C becomes the site, form goes live

**Status: code complete / production-domain pending.**

Three separate validation areas — only the last depends on the domain.

### GATE-HTTP-001 — independent of the domain

Proves frontend → Edge Function → validation → `public.contacts`.

| Proof | Status (2026-09-03) |
|---|---|
| valid submission accepted (200 + id) | ✅ from a laptop, function v2 |
| exactly one `contacts` row created | ✅ verified in SQL |
| same `submission_id` idempotent | ✅ same id returned |
| honeypot rejected (silently) | ✅ |
| 400 / 403 / 405 behaviours | ✅ |
| UTM / referrer / landing / first-visit attribution preserved | ✅ verified in SQL |
| double-click from the browser creates one enquiry | ⏳ to run on `https://coachgariv0.vercel.app` (30 s, any browser); row then verified by SQL |

The Claude Code sandbox's egress policy blocks `*.supabase.co` and
`*.vercel.app`, so HTTP steps are run from a laptop / the deployed site and
verified server-side. v1 of the function failed to boot (`502`) because of a
`jsr:` types-only import; v2 dropped it.

### GATE-EMAIL-001 — separate, owner configuration

Requires Resend configured, sender domain validated, a real email delivered to
`letsgo@coachgari.com` from `yoursession@coachgari.com`, `notified_at` set.
Code path is live and fails gracefully (`notify_skipped` when the key is
absent). Owner action: `supabase secrets set RESEND_API_KEY=…`.

### GATE-DOMAIN-001 — tomorrow's production-domain work

`coachgari.com` on Vercel, DNS, Migadu mailboxes, SPF/DKIM, Resend domain
validation, final CORS tightening (replace the `*.vercel.app` wildcard in
`supabase/functions/contact/index.ts` and `booking`), production form and email
validation, Plausible property activation + verification. Owner-only Vercel
settings already done: production branch = `main`, Vercel Authentication off.

None of CG-002 / CG-003 / CG-002.5 waits for this gate.

### Analytics — Plausible, prepared, activated tomorrow

Plausible is the approved website analytics. Integration is in place and
disabled: `CONFIG.PLAUSIBLE_DOMAIN` is empty; `site.js` loads the official
script only when it is set; the CSP already allows `https://plausible.io` for
`script-src` and `connect-src`. Activation = set `PLAUSIBLE_DOMAIN:
'coachgari.com'` in `config.js` once the property exists. No cookies, no
personal data. Not added: Google Analytics, Meta/TikTok pixels, any advertising
stack, social analytics tables. The application's first-touch UTM attribution
remains the conversion source.

### Decisions

- **Route C is the homepage.** `/routes/c` → `/` (301); never the reverse.
- **The proposal** lives at `/p/studio-mt-4e7a/`, `noindex` (meta + header),
  unlinked, intentionally public by URL. No password.
- **Routes A and B** archived, served at `/routes/a` and `/routes/b`, `noindex`.
- **Form storage**: Supabase `acrjrlgeeyseyolmofuq`, `public.contacts`, written
  only by the `contact` Edge Function (service role injected by the platform).
  RLS on, no anon/authenticated grants. Not a CRM.
- **Attribution is first-touch**, captured in `localStorage`, sent only with a
  submission. No proprietary analytics.
- **Idempotency**: one `submission_id` per form fill, unique in the table; plus
  an identical contact + message from the same IP within 2 minutes is treated
  as the same enquiry.
- **Anti-spam**: honeypot, 2 s minimum fill time, 5 submissions / 10 min per
  hashed IP, 16 KB body cap, server-side validation.
- **CORS**: `coachgari.com`, `www.coachgari.com`, `*.vercel.app`, localhost.
- **Emails**: `letsgo@coachgari.com` receives leads and human replies;
  `yoursession@coachgari.com` is the transactional sender.
- **Location** stays one field; stored verbatim + best-effort split.
- **IP handling**: salted SHA-256 hash only, for rate limiting.
- **Old file-name redirects** use clean-URL-aware sources (`cleanUrls` strips
  `.html` before redirects are evaluated).

---

## Blockers (documented, not implemented)

### CHECK-LICENCE-001 — LIVE payment collection only

Live collection of payments for Coach Gari services by **Oolala Next FZ-LLC**
is blocked until the activities authorised under UAE licence **47017963** are
verified as compatible with the commercial model.

**Blocked until explicitly cleared**: Stripe live keys, Stripe live mode, real
client payment collection, production payment activation.

**Explicitly allowed now** (development and testing): Stripe architecture,
Stripe Checkout, Stripe **test mode**, test webhooks, orders, payment records,
refunds, chargeback model, financial ledger, partner earnings, settlements.

There is no ambiguity: CG-003 is built and tested in Stripe test mode; nothing
in the repository can switch to live mode without new secrets being set by the
owner.

### PERMIT-CHARITY-001 — Charitable collection / third-party fundraising

Donations, crowdfunding, charity collection and community-project payments are
out of scope and blocked until legal/regulatory validation. No tables, no
speculative fields. No legal conclusion is drawn here about other kinds of
optional contributions.

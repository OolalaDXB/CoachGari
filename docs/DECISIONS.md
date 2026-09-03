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

## CG-002.5 — Back-office, permissions, RLS

**Status: built; database suite 73/73 (rollback harness, persona switching);
`/admin` deployed (noindex). Granting the first emails and adding the
redirect URL in Supabase Auth are owner actions.**

### Decisions

- **Permissions are the canonical rule, encoded.** `coach:operations` (Gari),
  `finance:view` / `finance:manage` (Oolala), `analytics:view` (shared). No
  `content:*` — the site is Git. A signed-in email with no `app_permissions`
  row sees nothing.
- **Magic link, no passwords, no roles in the JWT.** Authorisation is looked
  up by email in `app_users`/`app_permissions` at query time, so revocation is
  immediate (`active = false` or delete the row) without touching Auth.
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
  reference, service, session time, ledger figures) — never the person. The
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
  a Git/migration change (public content rule).

### Tests

`supabase/tests/cg0025_permissions.sql` — `CG0025_TESTS ok=73 fail=0` on
2026-09-03. Personas: anon (10 refusals), stranger and inactive user (11 each),
coach (22: reads, column refusals, calendar edits, state machine), finance
(13: ledger reads, identity refusals, settlement flow), analytics (5).

### Owner actions

1. Supabase → Authentication → URL configuration → Redirect URLs: add
   `https://coachgariv0.vercel.app/admin/` (and `https://coachgari.com/admin/`
   once live).
2. SQL editor: insert Gari's and Oolala's emails in `app_users` +
   `app_permissions` (snippet in README).
3. Optional: custom SMTP for auth emails (Resend) once the domain is verified.

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
- **Security**: RLS on every new table, zero grants to anon/authenticated,
  RPCs `SECURITY DEFINER` with pinned `search_path`, executable by the service
  role only; PII-free logs; signature verification with 5-minute tolerance and
  timing-safe compare.

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
  **The Conversation** is bookable and payable now (USD 45, 60 min, online,
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

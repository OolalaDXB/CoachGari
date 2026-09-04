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

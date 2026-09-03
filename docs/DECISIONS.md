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

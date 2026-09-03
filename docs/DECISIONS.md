# Decisions & blockers — Coach Gari

Running log of product/technical decisions and of the blockers that are
documented but deliberately **not** implemented. Newest sprint first.

---

## CG-001 — Route C becomes the site, form goes live

**Decisions**

- **Route C is the homepage.** Served at `/` (`index.html`). `/routes/c` → `/` is a
  permanent redirect; the reverse never exists.
- **The proposal moves off the root** to `/p/studio-mt-4e7a/`. It is `noindex`
  (meta + `X-Robots-Tag`), unlinked from the public site, and intentionally
  reachable by anyone who has the URL. No password.
- **Routes A and B are archived**, kept in the repo, still served at
  `/routes/a` and `/routes/b`, marked `noindex` so they do not compete with the
  homepage in search. Not deleted.
- **Form storage: Supabase project `acrjrlgeeyseyolmofuq`**, table
  `public.contacts`, written only by the `contact` Edge Function (service role
  injected by the platform). RLS on, no anon/authenticated grants. Not a CRM:
  a `status` column and attribution fields are the only concession to later use.
- **Attribution is first-touch**, captured in the browser (`localStorage`) on the
  first visit: UTM parameters, `document.referrer`, landing page, first-visit
  timestamp. It is sent only with a form submission. No proprietary analytics.
- **Idempotency**: the browser generates one `submission_id` per form fill; the
  table has a unique constraint on it. A second guard treats an identical
  contact + message from the same IP within 2 minutes as the same enquiry.
- **Anti-spam**: honeypot field (`website`), minimum fill time (2 s from page
  load), 5 submissions / 10 min per hashed IP, 16 KB body cap, server-side
  validation. Bot submissions are answered `200 {ok:true}` without an id so they
  learn nothing.
- **CORS** is limited to `https://coachgari.com`, `https://www.coachgari.com`,
  `*.vercel.app` (previews) and localhost (dev). Tighten the Vercel pattern to
  the project's preview domain once known.
- **Emails**: `letsgo@coachgari.com` receives leads and human replies;
  `yoursession@coachgari.com` is the transactional sender. Lead notifications
  go to `letsgo@` via Resend when `RESEND_API_KEY` is configured; without it the
  lead is still stored and the function logs `notify_skipped`.
- **Location field stays a single input** ("City and country") as in the mockup.
  The server stores it verbatim in `location_raw` and splits on the last comma
  into `city` / `country` on a best-effort basis.
- **IP handling**: only a salted SHA-256 hash is stored, and only for rate
  limiting. Raw IPs are never logged or stored.

**Out of scope for CG-001** (explicitly deferred): agenda, booking,
availability, orders, Stripe, Gari settlement, LiveKit, member area, donations,
fundraising pots, full CRM.

---

## Blockers (documented, not implemented)

### CHECK-LICENCE-001 — Payment collection by Oolala Next FZ-LLC

Activating the collection of payments for Coach Gari services by
**Oolala Next FZ-LLC** is blocked until the activities authorised under UAE
licence **47017963** have been verified as compatible with the commercial
model retained.

- Status: **blocked**, pending licence verification.
- Scope: everything under "turn payment on" (Stripe, COMMERCE toggle, checkout
  links, settlement).
- Does **not** affect CG-001.

### PERMIT-CHARITY-001 — Charitable collection / third-party fundraising

Any feature involving charitable collection or fundraising for projects on
behalf of third parties is out of scope and blocked until legal/regulatory
validation.

- Status: **blocked**, pending legal/regulatory validation.
- Not implemented in CG-001.
- No legal conclusion is drawn here, in code or in documentation, about other
  kinds of optional contributions.

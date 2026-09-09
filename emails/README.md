# Email templates

Two addresses, two roles:

| Address | Role |
|---|---|
| `letsgo@coachgari28.com` | The human mailbox (Migadu). Receives leads and payment notices. Reply-To on every customer email. |
| `yoursession@coachgari28.com` | Transactional sender (Resend). Confirmations, receipts, changes, thank-yous. |

The canonical templates are **code**: `supabase/functions/_shared/email.ts`
(`render(kind, payload)`), shared by the `stripe-webhook`, `contact`, `booking`
and `email-outbox` functions and exercised by `scripts/test-email.mjs`. The
files here mirror the prepared markup for review; a copy change is made in
the module, not here.

Wired kinds: `booking_confirmed`, `reschedule`, `booking_cancelled`,
`payment_confirmed` (package receipt), `support_thanks`, `enquiry_received`,
and the owner-facing `lead_notification`, `payment_received`.
Not wired (no producer yet): `session-link`, `session-reminder`.

Rules: "Coach Gari" in every customer-facing line, never the first name alone;
no health data, notes or CRM content in any email — the payload is the render
data only (name, reference, service, time, amount). Support copy never uses
donation / charity / fundraiser / tax-deductible vocabulary.

Configuration (Supabase Edge Function secrets, never in the repo):
`RESEND_API_KEY`, `EMAIL_FROM`, `EMAIL_REPLY_TO`. Domain verification records
come from the Resend dashboard (Domains → coachgari28.com); Migadu's own MX /
SPF / DKIM stay as they are, Resend's DKIM is an additional selector and its
SPF include must be merged into the single existing SPF record, never a second
`v=spf1` TXT at the same host.

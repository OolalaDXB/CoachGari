# Email templates

Two addresses, two roles:

| Address | Role |
|---|---|
| `letsgo@coachgari.com` | Receives leads and every human exchange. Reply-to on everything. |
| `yoursession@coachgari.com` | Transactional sender: confirmations, reminders, changes, session links. |

`lead-notification` is live in CG-001 — it is what the `contact` Edge Function
sends to `letsgo@` (the canonical copy lives in
`supabase/functions/contact/index.ts`; this file mirrors it for review).

The `session-*` templates are **prepared, not wired**. Sending them belongs to the
booking sprint. They use `{{placeholders}}` and are written to be sent from
`yoursession@coachgari.com` with `Reply-To: letsgo@coachgari.com`.

Placeholders: `{{name}}`, `{{session_title}}`, `{{session_date}}`,
`{{session_time}}`, `{{timezone}}`, `{{duration}}`, `{{join_url}}`,
`{{change_summary}}`, `{{manage_url}}`.

DNS verification for Resend and the Migadu mailbox set-up happen separately when
the domain is connected — nothing here depends on them being done first.

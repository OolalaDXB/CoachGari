# BEAU PH — Test strategy (V0)

## Harness
Every database suite is a single `DO $$ … $$` block that ends with `RAISE EXCEPTION '<NAME>_TESTS ok=… fail=…'`, so it **always rolls back** — safe against the live project. Run them all with `DATABASE_URL=… scripts/db-tests.sh` (fails unless every suite reports `fail=0`), or one at a time through the Supabase MCP `apply_migration` tool (the RAISE aborts the migration; nothing is persisted).

## Suites and what they prove

| Suite | Scope | Latest run |
|---|---|---|
| `supabase/tests/beau_ph_contract.sql` | **BEAU PH contract** — generic core with a throw-away merchant, then the Coach Gari host adapter | `BEAU_PH_TESTS ok=43 fail=0` |
| `supabase/tests/cg003_payments.sql` | Coach Gari booking checkout + Stripe webhook + ledger + settlements, now routed through BEAU PH | `CG003_TESTS ok=24 fail=0` |
| `supabase/tests/cg012_payments.sql` | Coach Gari recap page, pack payments (card / Aani / bank), renewal, permissions | `CG012_TESTS ok=26 fail=0` |
| `scripts/test-webhook-signature.mjs` (Node) | Stripe signature scheme in `beau-ph/providers/stripe/signature.js` | `WEBHOOK_SIGNATURE_TESTS ok=24 fail=0` |

The contract suite covers every item required for productisation:

- provider eligibility by country / currency (AE/AED vs ZW/USD, explicit reasons in the matrix)
- disabled provider omitted; undeployed online rail omitted; live runtime omitted for a test merchant
- `not_configured` provider cannot act as active (even when the merchant enabled it)
- authoritative amount cannot be overridden (event with another amount refused, evidence kept; live request amount cannot be changed; UUID public reference refused)
- provider request scoped to one external order (live request reused; a foreign order's event finds no request)
- provider event maps to normalized state (`requires_action → paid`; paid → expired refused; partial refund = evidence; full refund → `refunded`; live-mode event refused)
- provider-native evidence preserved (raw payload, `provider_status`, fee/charge evidence, outcome per event)
- manual provider never self-confirms (event refused; anonymous confirm refused; wrong amount refused; operator identity recorded; second confirm refused)
- provider secrets never appear in public output (CHECK on write; regex sweep of every public projection)
- BEAU Wallet placeholder cannot mark paid
- unconfigured Paynow / M-PESA / Ozow / PayShap cannot fake a payment (and their evidence is still kept)
- host adapter reconciles once, idempotently (same Stripe event, re-delivery under a new id, direct `mark_reconciled` again)
- duplicate provider event does not duplicate the host payment (one `payments` row, one earning, one reconciliation)
- host manual receipt: operator identity, no Stripe earning, sibling card intent cancelled; a differing amount supersedes the pending intent; a late card webhook on the superseded intent is refused

## Rules
- Preserve all existing Coach Gari financial suites; a change to the host adapter must keep `cg003` and `cg012` green.
- A new provider adapter ships with: its `normalize_<provider>_event`, a "cannot fake a payment while unconfigured" check, an amount-mismatch check, and an idempotency check, before its readiness may move from `not_configured` to `available`.
- Frontend: `admin/admin.js` and the `/r` page's inline module are syntax-checked with `node --check`; the page renders only the server-side `methods` list (no eligibility logic to test client-side).

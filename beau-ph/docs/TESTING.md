# BEAU PH — Test strategy (V0)

## Harness
Every database suite is a single `DO $$ … $$` block that ends with `RAISE EXCEPTION '<NAME>_TESTS ok=… fail=…'`, so it **always rolls back** — safe against the live project. Run them all with `DATABASE_URL=… scripts/db-tests.sh` (fails unless every suite reports `fail=0`), or one at a time through the Supabase MCP `apply_migration` tool (the RAISE aborts the migration; nothing is persisted).

## Suites and what they prove

| Suite | Scope | Latest run |
|---|---|---|
| `supabase/tests/beau_ph_contract.sql` | **BEAU PH contract** — generic core with a throw-away merchant, the Coach Gari host adapter, in-person / SoftPOS, the multi-rail race and multi-tenant isolation | `BEAU_PH_TESTS ok=77 fail=0` |
| `supabase/tests/cg003_payments.sql` | Coach Gari booking checkout + Stripe webhook + ledger + settlements, now routed through BEAU PH | `CG003_TESTS ok=24 fail=0` |
| `supabase/tests/cg012_payments.sql` | Coach Gari recap page, pack payments (card / Aani / bank), renewal, permissions | `CG012_TESTS ok=26 fail=0` |
| `supabase/tests/cg0025_permissions.sql` | RLS / permissions per persona (anon, stranger, coach, finance, analytics, launch, platform:admin, catalogue) | `CG0025_TESTS ok=236 fail=0` |
| `supabase/tests/cg010_privacy.sql` | consent, coaching-sensitive boundary, export/deletion, merge, analytics leakage | `CG010_TESTS ok=48 fail=0` |
| `scripts/test-webhook-signature.mjs` (Node) | Stripe signature scheme in `beau-ph/providers/stripe/signature.js` | `WEBHOOK_SIGNATURE_TESTS ok=24 fail=0` |
| `scripts/e2e-runtime.mjs` (Node, laptop) | **runtime E2E against the deployed stack**: `/r/<token>` view (no health data, no secrets, server-side method list, `CG-####`), Aani / bank instructions without any payment being recorded, `--pay` Stripe TEST Checkout, `--wait` webhook → ledger → pack projection | owner-run (the sandbox cannot reach `*.supabase.co`) |

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
- in-person / SoftPOS: the capability vocabulary and the reserved keys exist on the UAE PSPs; a customer page never sees an in-person capability (initiator); merchant-initiated handoff is offered when enabled, native `tap_to_pay` is not (placeholder); the **platform gate** is real (made hypothetically live and rolled back: `ios_app` only, never `web`/`ios_pwa`, and still needs deployed PSP credentials); a handoff request is `in_person` / `merchant` with the app + reference + amount in its instructions; a PSP "event" is refused (no verified API path) and the request stays pending; confirming without the app receipt is refused; the attested event carries `verification = operator_attested_provider_receipt`
- host collect: no options before setup; a bad app link is refused; options list the enabled PSP with its app and the pack's `CG-####`; the receipt is mandatory; a confirmed tap marks the pack `paid` with source `card_present`, `payments.capability = softpos`, reconciled once, no Stripe earning; the client report page still never lists an in-person capability
- **multi-rail race / idempotency (§18)** — one order with a Stripe request (Checkout attached) and an Aani receipt: Aani settles first → one host payment, the sibling Stripe request `cancelled`, pack `paid` (source `aani`); a late Stripe webhook for that session (and a re-delivery under another event id) is refused (`illegal_transition`), evidence kept, **no duplicate host payment, no partner earning, one reconciliation, one paid event, one order for the pack**. Reverse: Stripe settles first → a manual confirmation of the same amount, of another amount, and a core-level request on the paid order are all refused (`P0003`); one payment, one earning, one order, pack source stays `stripe`
- **multi-tenant isolation (§19)** — merchant B's configuration never appears in merchant A's eligibility output (and vice-versa, incl. the Coach Gari Aani number and SwipeX handoff); public and external references are scoped per merchant (B reuses A's `ORD-2` / `REF-2003` without collision; `requests_for` never crosses); B cannot read (`get_request` null, `request_events` empty), attach, cancel, expire, confirm or reconcile A's request (`P0002`, A's state untouched); a Stripe event whose Checkout Session belongs to B's request but names a Coach Gari order is ignored by the host as `foreign_merchant` (B's request paid, not reconciled here; the Coach Gari order stays pending, no payment); an application user cannot execute the core or read its tables at all

## Rules
- Preserve all existing Coach Gari financial suites; a change to the host adapter must keep `cg003` and `cg012` green.
- A new provider adapter ships with: its `normalize_<provider>_event`, a "cannot fake a payment while unconfigured" check, an amount-mismatch check, and an idempotency check, before its readiness may move from `not_configured` to `available`.
- Frontend: `admin/admin.js` and the `/r` page's inline module are syntax-checked with `node --check`; the page renders only the server-side `methods` list (no eligibility logic to test client-side).

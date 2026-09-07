# BEAU PH — Architecture (V0)

## 1. The boundary, as a diagram

```
                         PAYER (client page /r/<token>, booking page)
                                        │  renders exactly the list it is given
                                        ▼
┌──────────────────────────── Supabase Edge Functions (Deno) ────────────────────────────┐
│  report · checkout · stripe-webhook                                                    │
│     │ uses                                                                             │
│     ▼                                                                                  │
│  beau-ph/host-adapters/coach-gari/adapter.ts   ← names the host RPCs, nothing else     │
│  beau-ph/core/registry.ts                       ← provider registry, runtimeMap(env)   │
│  beau-ph/providers/<rail>/adapter.ts            ← provider I/O: create redirect,       │
│        stripe · aani · bank-transfer ·             verify webhook, enrich evidence,    │
│        paynow · mpesa · ozow · payshap ·           report deployment readiness         │
│        beau-wallet                                 (presence of secrets, never values) │
└──────────────┬──────────────────────────────────────────────────────┬──────────────────┘
               │ RPC (service role)                                   │ HTTPS
               ▼                                                      ▼
┌───────────── Postgres: schema public (HOST = Coach Gari) ─────┐   Stripe (test) …
│  orders · payments · refunds · chargebacks · partner ledger   │   future: Paynow, M-PESA,
│  bookings · session_packs · crm_contacts (health: never here) │   Ozow, PayShap, BEAU Wallet
│                                                               │
│  HOST ADAPTER (SQL):                                          │
│   cg_ph_request_for_order / _for_pack / _for_booking          │
│   attach_checkout · process_stripe_event ·                    │
│   payment_record_manual · report_view · payment_method_set    │
│   payment_methods_list · payment_rails · cg_country_code      │
└───────────────┬───────────────────────────────────────────────┘
                │ owner-only calls (definer functions) — no API exposure
                ▼
┌───────────── Postgres: schema beau_ph (BEAU PH CORE) ─────────────────────────────────┐
│  merchants · providers · merchant_methods                                             │
│  payment_requests · payment_attempts · provider_events · payment_events               │
│  reconciliations                                                                      │
│  method_matrix / eligible_methods · create_request · attach_attempt ·                 │
│  ingest_provider_event (+ normalize_stripe_event) · confirm_manual ·                  │
│  cancel_request / expire_request · mark_reconciled / is_reconciled · request_events   │
│  ── knows: merchant, provider, external_reference, public_reference, amount,          │
│     currency, country, status, evidence.  ── never: packs, bookings, CRM, health.     │
└───────────────────────────────────────────────────────────────────────────────────────┘
```

Two translations, and only two, cross the boundary (both in the host adapter):

```
host order (booking | session pack)  ──▶  beau_ph.create_request(merchant, rail, external_ref, public_ref, amount, currency, country, runtime)
beau_ph normalized "paid" event      ──▶  public.payments (+ orders, earnings, pack projection) once  ──▶  beau_ph.mark_reconciled(event, payments.id)
```

## 2. Generic domain model (schema `beau_ph`)

| Entity | Table | Key fields |
|---|---|---|
| Merchant / tenant | `merchants` | `key` (e.g. `coach_gari`), `country`, `default_currency`, `mode` (test/live) |
| Payment provider | `providers` | `key`, `kind` (online/manual/crypto), `confirmation` (provider_event/operator/unavailable), `countries[]`, `currencies[]`, `readiness` (available/not_configured/placeholder) |
| Payment method (merchant × provider) | `merchant_methods` | `enabled`, `currency` (settlement), `countries[]` override, `instructions` (public), `settings` (non-secret) |
| Payment request | `payment_requests` | `external_reference` (host order ref), `public_reference` (payer-facing, never a UUID), `amount`, `currency`, `customer_country`, `status`, `provider_reference`, `payment_reference`, `instructions`/redirect payload, `metadata`, `expires_at`, `paid_at` |
| Payment attempt | `payment_attempts` | `n`, `provider_reference` (e.g. Checkout Session), `redirect_url`, `expires_at`, `status` |
| Provider event (raw evidence) | `provider_events` | `provider_key`, `provider_event_id` (unique per provider), `event_type`, `payload` (verbatim), `outcome` |
| Normalized payment event | `payment_events` | `from_status → to_status`, `amount`, `currency`, `provider_status` (native, kept), `provider_reference`, `actor` (provider/operator/system), `actor_id`, `evidence` |
| Reconciliation | `reconciliations` | `payment_event_id` (unique — once), `host_reference` (the host's ledger id) |

Invariants (indexes/CHECKs): one **live** request per (merchant, order, provider); one **paid** request per (merchant, order); `public_reference` is not a UUID; no secret-like key/value in any JSON column; `amount > 0`; ISO currency/country.

## 3. Event model — states and transitions

Normalized, provider-independent states: `created · pending · requires_action · paid · failed · expired · cancelled · refunded`.

```
created ──▶ pending | requires_action | paid | failed | expired | cancelled
pending ──▶ requires_action | paid | failed | expired | cancelled
requires_action ──▶ pending | paid | failed | expired | cancelled
paid ──▶ refunded
(same → same is an idempotent no-op; everything else is an illegal transition and is refused — evidence kept)
```

Every change goes through one internal path (`beau_ph.record_event`), which writes the `payment_events` row, updates the request, closes open attempts, and — when a request becomes **paid** — cancels the sibling live requests of the same order on other rails (`settled via <rail>`).

`provider_status` and the raw `provider_events.payload` keep the provider-native truth alongside the normalized state; a partial refund or a dispute is an **evidence-only** event (no state change), a full refund transitions to `refunded`.

## 4. Eligibility model (server-side, the only authority)

`beau_ph.method_matrix(merchant, country, currency, runtime)` evaluates every provider and returns `eligible` + `reason`:

| Check (in order) | Reason when it fails |
|---|---|
| provider readiness = placeholder | `coming_soon` |
| provider readiness = not_configured | `not_configured` |
| merchant method missing or disabled | `disabled` |
| country ∉ (merchant override ∪ provider countries) | `country` |
| currency ∉ provider currencies | `currency` |
| online rail and adapter not configured in this deployment | `runtime_not_configured` |
| online rail whose runtime mode ≠ merchant mode | `mode_mismatch` |

Inputs: merchant configuration, customer country (host-derived; unknown → merchant country), request currency, provider readiness, and `runtime` — the deployment readiness map the Edge adapters compute from **secret presence and mode** (`{"stripe":{"configured":true,"mode":"test"}}`), never values. `eligible_methods` is the filtered list the client page renders verbatim (with public instructions only). `create_request` re-checks eligibility, so a client cannot force a rail.

## 5. Flows

**Card (online, provider-confirmed)**
`host order → create_request(stripe) [created] → adapter.createPaymentRequest → attach_attempt [requires_action] → payer pays → adapter.verifyWebhook + enrich → ingest_provider_event: evidence, guards (rail enabled, mode, amount/currency, already paid, transition) → payment_event [paid] → host reconciles once → mark_reconciled`.

**Manual (Aani / bank transfer, operator-confirmed)**
`instructions shown from eligible_methods (read-only) → payer pays outside → operator (authenticated, finance:manage) records receipt → host creates/reuses order → create_request(rail) [pending, instructions snapshot] → confirm_manual(operator, amount, currency, reference) → operator.confirmed evidence + payment_event [paid] → host ledger once → mark_reconciled`. A receipt whose amount differs from a pending card intent **supersedes** that intent explicitly (order cancelled, request cancelled); nothing is converted or guessed.

## 6. Extraction seams (what makes V2 possible)

- The core schema has no foreign key to any host table; the host references BEAU PH by plain `uuid` columns (`payments.ph_request_id`, `ph_event_id`).
- The host adapter is the only code that names both sides; the Edge Functions only ever call host RPCs and provider adapters.
- The TypeScript layer has no runtime dependency (Deno-native, Web Crypto only).
- Provider knowledge is split into an I/O adapter (TS) and a normalizer (SQL) — both per provider, both replaceable.

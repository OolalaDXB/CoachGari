# BEAU PH — Provider readiness matrix (V0)

Readiness is a **product** property (is the adapter implemented and onboardable?). "Enabled" is a **merchant** property. "Configured" is a **deployment** property reported by the adapter at request time (secret presence + mode). A rail is offered only when all three line up *and* country/currency match.

| Rail | Key | Kind | Confirmed by | Readiness | Countries | Currencies | Secrets (names only) | Coach Gari today | Owner action |
|---|---|---|---|---|---|---|---|---|---|
| Card (Stripe) | `stripe` | online | signature-verified webhook | **available** | any | any | `STRIPE_SECRET_KEY` (sk_test_… only), `STRIPE_WEBHOOK_SECRET` | implemented · enabled · **test mode** · webhook path proven | keep test mode until CHECK-LICENCE-001 is cleared; set `SITE_URL` |
| Aani (UAE instant payment) | `aani` | manual | authorised operator | **available** | AE | AED | none | implemented · enabled · V1 static instructions (registered mobile), manual reconciliation | none (verified QR optional later) |
| Bank transfer | `bank_transfer` | manual | authorised operator | **available** | any | any | none | implemented · **not yet configured** (no account details entered — nothing is seeded) | enter Account holder / IBAN / BIC-SWIFT / Bank name in Finance and enable |
| Paynow (Zimbabwe) | `paynow` | online | provider event | **not_configured** | ZW | USD, ZWG | `PAYNOW_INTEGRATION_ID`, `PAYNOW_INTEGRATION_KEY` | adapter boundary only — refuses to act | Paynow merchant onboarding; then V1 integration (Initiate Transaction, hash-verified result handler) |
| M-PESA (Kenya) | `mpesa` | online | provider event | **not_configured** | KE | KES | `MPESA_CONSUMER_KEY`, `MPESA_CONSUMER_SECRET`, `MPESA_SHORTCODE`, `MPESA_PASSKEY` | adapter boundary only — refuses to act | Safaricom Daraja onboarding (go-live); then V1 integration (STK push + callback verification) |
| Ozow (South Africa) | `ozow` | online | provider event | **not_configured** | ZA | ZAR | `OZOW_SITE_CODE`, `OZOW_PRIVATE_KEY`, `OZOW_API_KEY` | adapter boundary only — refuses to act | Ozow merchant onboarding; then V1 integration (hosted page, hash-verified notification) |
| PayShap (South Africa) | `payshap` | online | provider event | **not_configured** | ZA | ZAR | `PAYSHAP_SPONSOR_CLIENT_ID`, `PAYSHAP_SPONSOR_CLIENT_SECRET` | adapter boundary only — refuses to act | choose a sponsoring bank/PSP exposing PayShap request-to-pay; then V1 integration |
| BEAU Wallet | `beau_wallet` | crypto | unavailable | **placeholder** | any | any | none | visible as "coming soon"; cannot create or confirm; no static address; no client tx hash | separate approval before any implementation (see the future contract in `providers/beau-wallet/adapter.ts`) |

What "refuses to act" means, proven by `supabase/tests/beau_ph_contract.sql`: `eligible_methods` omits the rail with an explicit reason; `create_request` raises; a fabricated provider event is stored as evidence with `outcome = rejected:provider_not_configured` / `rejected:provider_cannot_confirm` and never changes a request's state.

## Manual rails — the confirmation record

For Aani and bank transfer, confirming a receipt writes: the **operator** (authenticated email), the **timestamp** (paid_at, defaults to now), the **amount** and **currency** (must equal the request's — no conversion), the **provider**, the **reference** the operator typed, an optional note — as an `operator.confirmed` provider event (verbatim payload) plus a normalized `paid` payment event with `actor = operator`. Opening or copying instructions writes nothing.

## Money paths for Coach Gari

- Stripe: Oolala collects → `recompute_earning` (commission) → Gari payable via settlements.
- Aani / bank transfer: paid straight to Gari → **no** Oolala earning row (the money never passed through Oolala's Stripe). Owner decision pending on the commercial treatment.

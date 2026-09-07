# BEAU PH — Security model (V0)

## Secrets
- Provider credentials live **only** in the Edge Function environment (Supabase secrets): never in the frontend, never on the client report page, never in logs, never in git, never in the database.
- The adapters' `runtime(env)` reports **presence and mode** (`configured`, `test|live`) — never a value. That map is the only thing that travels from the Edge to the DB (`p_runtime`).
- The core refuses to store anything secret-like: every JSON column in `beau_ph` (`merchant_methods.instructions/settings`, `payment_requests.instructions/metadata`, `payment_events.evidence`) carries `CHECK (beau_ph.no_secret_keys(...))` — keys such as `api_key`, `secret`, `private_key`, `password`, `webhook_secret`, and values shaped like `sk_test_…`/`sk_live_…`/`whsec_…` are rejected at write time.
- A last-line guard on the way out: `beau-ph/core/registry.ts#assertPublic` is applied by the `report` function to everything a payer receives.
- The Stripe adapter refuses a live key by construction (CHECK-LICENCE-001) and refuses live-mode events for a test merchant; the DB core independently refuses `livemode:true` evidence for a `mode = test` merchant.

## Exposure
- Schema `beau_ph` is **not** exposed through PostgREST; `USAGE` is revoked from `anon` and `authenticated`; every table has RLS enabled with no policies (deny-all); every function has `EXECUTE` revoked from `public/anon/authenticated`. The only callers are the host's `SECURITY DEFINER` functions (owner) and `service_role`.
- Host RPCs follow the cockpit pattern: `SECURITY DEFINER`, `set search_path = ''`, an explicit `public.has_permission(...)` gate (`finance:manage` to configure rails or confirm receipts, `finance:view` to read configuration, `coach:operations` for recaps), and grants restricted to `authenticated`/`service_role`. Client-facing RPCs (`report_view`, `cg_ph_request_for_pack/_booking`, `report_pack_id`) are `service_role` only and are reached through token-authorised Edge Functions.
- Public payment instructions (an Aani number, an IBAN) are shown **only** on the authenticated Finance screen and on the tokenised `/r/<token>` page when the rail is enabled and eligible — never on the marketing site (`/r/*` is `noindex`, `no-store`).

## Verification and confirmation
- Only a **verified** provider event enters the normalized path: the Stripe adapter checks Stripe's own signature scheme over the exact raw body (HMAC-SHA256, `v1`, 300 s tolerance, constant-time compare). Unconfigured adapters return `ok:false` from `verifyWebhook` and the DB refuses their events anyway.
- Manual rails **never self-confirm**: an event that claims "paid" for `aani`/`bank_transfer` is stored as evidence and rejected (`manual_provider_requires_operator`). Confirmation requires an authenticated operator with `finance:manage`; the core records the identity and refuses a null operator (`42501`).
- A paid claim must match the request's **amount and currency** exactly; otherwise it is rejected and the evidence kept. Amounts never come from the payer or the page.
- Idempotency: `provider_events` is unique per `(provider, provider_event_id)`; `payment_events` allows one normalized event per provider event; `reconciliations` is unique per payment event — the host ledger cannot be written twice for one payment. The host additionally dedups on Stripe `event_id` (`webhook_events`) and on `payment_intent`.

## Tokens
- Report links: 256-bit random tokens, stored as SHA-256, revocable, expiring; the page has no other authority (no JWT, no CRM access). The recap never includes body metrics, BMI, health data or private notes (proven by test).

## What is logged
- Edge logs carry action, status, outcome and provider keys — never contact data, never instructions, never secrets.

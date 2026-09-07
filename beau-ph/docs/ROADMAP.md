# BEAU PH — Roadmap and extraction path

## V0 — embedded core inside Coach Gari (this step) ✔
- Generic core in schema `beau_ph`; provider adapters in `beau-ph/providers`; Coach Gari host adapter in `public` + `beau-ph/host-adapters/coach-gari`.
- Real proof on Stripe (test), Aani (manual) and bank transfer (manual), with the existing CG-003/CG-012 behaviour preserved and tested.
- Readiness boundary for Paynow, M-PESA, Ozow, PayShap; placeholder for BEAU Wallet.
- Operational UI stays Coach Gari's Finance screen (methods + rails matrix).

## V1 — first real African rail + a second host
- Onboard one rail for real (Paynow for Zimbabwe is the natural first: Gari's audience, USD-capable): implement `providers/paynow/adapter.ts` (initiate + hash-verified result) and `beau_ph.normalize_paynow_event`; flip `providers.readiness` to `available` by forward migration; add its contract tests; the Coach Gari page needs **no change** — the server-side list simply starts including it for ZW clients.
- Consume BEAU PH from a second host (a Studio/Oolala product) through its own host adapter, proving the boundary. Candidates: Maisons, SILLON commercial flows. Not integrated now.
- Close the V0 gaps listed below.

## V2 — extract as a standalone reusable service/package
- Move schema `beau_ph` + adapters into their own deployable (own Postgres schema/database + a small service exposing the host contract), publish the TypeScript contracts as a package, replace the in-process definer calls with an authenticated API; hosts keep their adapters.

## V3 — only if justified
- Public API + SDK + MCP surface; merchant configuration UI; reconciliation/evidence dashboard; hosted payment-method discovery; outbound webhooks to hosts.

**V2/V3 are not built now** — a standalone dashboard, API or service requires separate approval.

## Known gaps carried from V0 (honest list)
1. **Provider-side cancel on supersede** — when a request is cancelled (paid on another rail, or superseded by a manual receipt of another amount) the core marks it cancelled but does not call the adapter's `cancel()` to expire an open Stripe Checkout Session; a late card payment would then be refused by BEAU PH (ledger untouched, evidence kept) and would need a manual refund. V1: the Edge/host calls `adapter.cancel(provider_reference)` on cancellation events.
2. **Legacy `no_request` path** — orders created before BEAU PH (or through `create_order_for_pack` without going through the request flow) are still validated by the host's original amount check when their webhook arrives. Remove once no pre-BEAU order can be in flight.
3. **`cash` / `manual` / `external` sources** remain host-only ledger sources (not approved BEAU PH provider keys). Decide: promote `cash` to a manual provider or drop it.
4. **Deployment readiness is reported by the Edge**, not stored — correct (secrets never touch the DB) but means the Finance rails matrix cannot show "configured"; it shows product readiness + merchant enablement.
5. **Customer country for bookings** is unknown (the booking flow captures no country) → merchant country applies. Packs use the CRM contact's country through a small text→ISO mapping (`public.cg_country_code`), which is host knowledge.
6. **BEAU Wallet** remains a placeholder by decision; its future request contract is documented in the adapter file.
7. **Edge bundles** are deployed from the repo sources through the Management API; code is identical to git, header comments were condensed in the upload. A CLI deploy (`supabase functions deploy`) from the repo produces the same graph.

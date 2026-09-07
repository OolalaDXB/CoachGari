/* =============================================================
   BEAU PH host adapter — Coach Gari (TypeScript side, used by Edge Functions)

   The translation itself lives in SQL (public.cg_ph_* and the patched
   attach_checkout / process_stripe_event / payment_record_manual /
   report_view — supabase/migrations/20260917_beau_ph_coach_gari_adapter.sql).
   This module only names those entry points so the Edge Functions never
   call BEAU PH tables directly and never carry Coach Gari business rules.

   Boundary: everything Coach Gari-specific (packs, bookings, CRM country,
   recap) is behind these RPCs. BEAU PH core never imports this file.
   ============================================================= */
import type { ProviderKey, RuntimeMap } from "../../contracts/provider.ts";
import type { EligibleMethod, PaymentRequest } from "../../contracts/host.ts";

export const MERCHANT_KEY = "coach_gari";

// deno-lint-ignore no-explicit-any
type Rpc = { rpc: (fn: string, args?: Record<string, unknown>) => PromiseLike<{ data: any; error: { code?: string; message?: string } | null }> };

export interface HostOrder {
  reference: string; status: string; gross_amount: number; currency: string;
  checkout_url: string | null; checkout_expires_at: string | null; checkout_attempts: number;
  customer_name: string; customer_contact: string;
  booking?: { reference: string; service_title?: string } | null;
}

export interface ReportView {
  ok: true; recap: Record<string, unknown>; pay_ref: string; currency: string; customer_country: string | null;
  methods: EligibleMethod[];
  aani: Record<string, unknown>; bank: Record<string, unknown>;   // legacy blocks, derived from `methods`
}

/** Client recap + authoritative eligible-method list for a report token. */
export async function reportView(sb: Rpc, token: string, runtime: RuntimeMap) {
  return await sb.rpc("report_view", { p_token: token, p_runtime: runtime });
}

/** Pack → order (amount from the pack snapshot) → BEAU PH request for the chosen rail. */
export async function requestForPack(sb: Rpc, packId: string, provider: ProviderKey, runtime: RuntimeMap) {
  return await sb.rpc("cg_ph_request_for_pack", { p_pack_id: packId, p_provider: provider, p_runtime: runtime }) as
    { data: { request: PaymentRequest; order: HostOrder } | null; error: { code?: string; message?: string } | null };
}

/** Resolve a report token to its pack id (service role). */
export async function packIdForToken(sb: Rpc, token: string) {
  return await sb.rpc("report_pack_id", { p_token: token });
}

/** Booking (CG-003): held booking → trusted order (amount from the booking's price snapshot) → BEAU PH request. */
export async function requestForBooking(sb: Rpc, reference: string, manageToken: string, provider: ProviderKey, runtime: RuntimeMap) {
  return await sb.rpc("cg_ph_request_for_booking", { p_reference: reference, p_manage_token: manageToken, p_provider: provider, p_runtime: runtime }) as
    { data: { request: PaymentRequest; order: HostOrder } | null; error: { code?: string; message?: string } | null };
}

/** Record the Checkout Session on the order and as a BEAU PH attempt (also aligns the booking hold). */
export async function attachCheckout(sb: Rpc, orderReference: string, sessionId: string, url: string, expiresAt: string) {
  return await sb.rpc("attach_checkout", { p_order_reference: orderReference, p_session_id: sessionId, p_url: url, p_expires_at: expiresAt });
}

/** Verified + enriched Stripe event → BEAU PH evidence/normalization → Coach Gari ledger, exactly once. */
export async function processStripeEvent(sb: Rpc, event: Record<string, unknown>) {
  return await sb.rpc("process_stripe_event", { p_event: event });
}

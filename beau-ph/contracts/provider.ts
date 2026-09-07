/* =============================================================
   BEAU PH — BEAU Payment Hub
   Provider adapter contract (V0)

   One generic contract for every rail. Not every provider implements every
   capability: a manual rail (Aani, bank transfer) only issues instructions
   and is confirmed by an authorised OPERATOR; an online rail (Stripe, later
   Paynow / M-PESA / Ozow / PayShap) creates a redirect and is confirmed by a
   signature-VERIFIED provider event; a placeholder rail (BEAU Wallet) can
   do nothing yet and must say so.

   The DATABASE core (schema beau_ph) is the authority for state, eligibility,
   evidence, idempotency and reconciliation. An adapter is provider I/O only:
   it talks to the provider, verifies what comes back, and reports
   deployment readiness — never a secret value.
   ============================================================= */

export type ProviderKey = "stripe" | "aani" | "bank_transfer" | "paynow" | "mpesa" | "ozow" | "payshap" | "beau_wallet";
export type ProviderKind = "online" | "manual" | "crypto";
export type Confirmation = "provider_event" | "operator" | "unavailable";
export type Readiness = "available" | "not_configured" | "placeholder";
export type Mode = "test" | "live";

/** Provider-independent request states (mirrors beau_ph.payment_requests.status). */
export type PaymentStatus = "created" | "pending" | "requires_action" | "paid" | "failed" | "expired" | "cancelled" | "refunded";

/** Reads a deployment secret by name. Adapters never log, return or store the value. */
export type EnvReader = (name: string) => string | undefined;

export interface ProviderCapabilities {
  key: ProviderKey;
  displayName: string;
  kind: ProviderKind;
  confirmation: Confirmation;
  /** Product-level readiness (is the adapter implemented and onboardable?). Deployment readiness is `runtime()`. */
  readiness: Readiness;
  supports: { checkout: boolean; instructions: boolean; webhook: boolean; statusPoll: boolean; cancel: boolean; refundEvents: boolean };
  /** null = any */
  countries: string[] | null;
  currencies: string[] | null;
  /** Names of the secrets the adapter needs (documentation + presence checks only). */
  secrets: string[];
}

/** What the adapter reports about THIS deployment. Presence only — never a value. */
export interface RuntimeReadiness {
  configured: boolean;
  mode?: Mode;
  reason?: string;
}
export type RuntimeMap = Partial<Record<ProviderKey, RuntimeReadiness>>;

export interface EligibilityInput { country: string | null; currency: string; mode: Mode }
export interface EligibilityResult { eligible: boolean; reason?: string }

export interface CreateRequestInput {
  /** BEAU PH request id — opaque to the provider, useful as metadata. */
  requestId: string;
  /** Human reference the payer sees (e.g. CG-1048). Never a UUID. */
  publicReference: string;
  /** The host's order reference — used as the provider's client reference. */
  externalReference: string;
  /** Minor units. Comes from the host/DB. A payer-supplied amount is never accepted. */
  amount: number;
  currency: string;
  description: string;
  customerEmail?: string | null;
  returnUrls: { success: string; cancel: string };
  /** 1-based attempt number (idempotency keys). */
  attempt: number;
  expiresInSeconds?: number;
}

export type CreateRequestResult =
  | { kind: "redirect"; providerReference: string; url: string; expiresAt: string }
  | { kind: "instructions"; instructions: Record<string, unknown> }
  | { kind: "unavailable"; reason: string };

export interface StatusResult { providerStatus: string; status: PaymentStatus | null; evidence?: Record<string, unknown> }

export type VerifiedEvent =
  | { ok: true; providerEventId: string; eventType: string; payload: Record<string, unknown> }
  | { ok: false; reason: string };

/** A public instruction field (manual rails): how the payer-facing page should show and copy it. */
export interface InstructionField { key: string; label: string; copyable: boolean }

export interface ProviderAdapter {
  readonly key: ProviderKey;
  capabilities(): ProviderCapabilities;
  /** Deployment readiness of this adapter (secret presence + mode). Feeds beau_ph.method_matrix(p_runtime). */
  runtime(env: EnvReader): RuntimeReadiness;
  /** Adapter-side extra rules (rare). The DB matrix remains the authority. */
  eligibility?(input: EligibilityInput, runtime: RuntimeReadiness): EligibilityResult;
  /** Online rails: create the provider-side payment (redirect). Manual rails: describe instructions. */
  createPaymentRequest?(input: CreateRequestInput, env: EnvReader): Promise<CreateRequestResult>;
  getStatus?(providerReference: string, env: EnvReader): Promise<StatusResult>;
  cancel?(providerReference: string, env: EnvReader): Promise<{ ok: boolean; reason?: string }>;
  /** Verify a provider callback. Only a verified event may reach beau_ph.ingest_provider_event. */
  verifyWebhook?(req: { headers: Headers; rawBody: string }, env: EnvReader): Promise<VerifiedEvent>;
  /** reconcile(): add provider evidence (fees, balance transactions) BEFORE the DB normalizer runs. Never mutates state. */
  enrich?(event: Record<string, unknown>, env: EnvReader): Promise<Record<string, unknown>>;
  /** Manual rails: the public fields the merchant configures and the payer sees. */
  instructionFields?(): InstructionField[];
}

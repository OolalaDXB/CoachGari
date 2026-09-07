-- =====================================================================
-- BEAU PH — BEAU Payment Hub — generic core (V0, embedded in Coach Gari)
--
-- Multi-rail payment ORCHESTRATION + RECONCILIATION layer. Answers: given
-- this merchant/order, customer country, currency and the providers that
-- are actually ready, which payment methods can be offered, how is payment
-- initiated, and how does the result get reconciled back into the HOST
-- application's authoritative commerce model?
--
-- Boundary rules (enforced by construction):
--   * Nothing in this schema references Coach Gari (no session packs, no
--     CRM, no bookings, no orders). The host is known only through
--     external_reference / public_reference / metadata.
--   * BEAU PH is NOT a ledger. It produces normalized payment EVENTS; the
--     host adapter reconciles them into its own authoritative ledger,
--     exactly once (beau_ph.reconciliations).
--   * Provider evidence is kept verbatim (provider_events) and never
--     discarded because it mapped to a normalized state.
--   * Manual providers (Aani, bank transfer) never self-confirm: only an
--     authenticated, authorised operator (identity recorded) confirms.
--   * Not-configured / placeholder providers cannot create or confirm.
--   * No provider secret is ever stored here (CHECK-guarded JSON).
--   * The schema is NOT exposed through the API; only host-adapter
--     functions in `public` (and service_role) can reach it.
-- Forward migration only. Product docs: beau-ph/PRODUCT.md
-- =====================================================================

create schema if not exists beau_ph;
revoke all on schema beau_ph from public;
revoke all on schema beau_ph from anon, authenticated;
grant usage on schema beau_ph to service_role;
alter default privileges in schema beau_ph revoke execute on functions from public;
alter default privileges in schema beau_ph revoke all on tables from public;

-- ---------- guards ----------
-- No secret may live in any BEAU PH JSON column. Public payment instructions
-- (an Aani number, an IBAN) are not secrets; API keys / webhook secrets are.
create or replace function beau_ph.no_secret_keys(p jsonb)
returns boolean language sql immutable set search_path = '' as $$
  select p is null
      or not (p::text ~* '"(secret|api_?key|private_?key|password|passkey|access_?token|client_?secret|signing_?secret|webhook_?secret)"\s*:'
              or p::text ~ '(sk|rk)_(live|test)_[A-Za-z0-9]{8,}'
              or p::text ~ 'whsec_[A-Za-z0-9]{8,}')
$$;

-- Provider-independent state machine. Same→same is an idempotent no-op.
create or replace function beau_ph.transition_allowed(p_from text, p_to text)
returns boolean language sql immutable set search_path = '' as $$
  select p_from = p_to or (p_from, p_to) in (
    ('created','pending'), ('created','requires_action'), ('created','paid'), ('created','failed'), ('created','expired'), ('created','cancelled'),
    ('pending','requires_action'), ('pending','paid'), ('pending','failed'), ('pending','expired'), ('pending','cancelled'),
    ('requires_action','pending'), ('requires_action','paid'), ('requires_action','failed'), ('requires_action','expired'), ('requires_action','cancelled'),
    ('paid','refunded'))
$$;

-- ---------- entities ----------
create table if not exists beau_ph.merchants (
  id               uuid primary key default gen_random_uuid(),
  key              text not null unique check (key ~ '^[a-z][a-z0-9_]{1,40}$'),
  name             text not null,
  country          text not null check (country ~ '^[A-Z]{2}$'),          -- home country (ISO 3166-1 alpha-2)
  default_currency text not null check (default_currency ~ '^[A-Z]{3}$'),
  mode             text not null default 'test' check (mode in ('test','live')),
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now()
);

create table if not exists beau_ph.providers (
  key          text primary key check (key in ('stripe','aani','bank_transfer','paynow','mpesa','ozow','payshap','beau_wallet')),
  display_name text not null,
  kind         text not null check (kind in ('online','manual','crypto')),
  confirmation text not null check (confirmation in ('provider_event','operator','unavailable')),
  countries    text[],                     -- null = any
  currencies   text[],                     -- null = any
  readiness    text not null check (readiness in ('available','not_configured','placeholder')),
  sort         int  not null default 100,
  notes        text
);

-- Merchant-level configuration of a provider: enabled flag, public
-- instructions (shown to payers), non-secret settings. Never credentials.
create table if not exists beau_ph.merchant_methods (
  id           uuid primary key default gen_random_uuid(),
  merchant_id  uuid not null references beau_ph.merchants(id) on delete cascade,
  provider_key text not null references beau_ph.providers(key),
  enabled      boolean not null default false,
  currency     text check (currency ~ '^[A-Z]{3}$'),      -- settlement / account currency (manual rails)
  countries    text[],                                     -- optional override of the provider's countries
  instructions jsonb not null default '{}'::jsonb check (beau_ph.no_secret_keys(instructions)),
  settings     jsonb not null default '{}'::jsonb check (beau_ph.no_secret_keys(settings)),
  updated_by   text,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now(),
  unique (merchant_id, provider_key)
);

create table if not exists beau_ph.payment_requests (
  id                 uuid primary key default gen_random_uuid(),
  merchant_id        uuid not null references beau_ph.merchants(id),
  provider_key       text not null references beau_ph.providers(key),
  external_reference text not null,                       -- the host's authoritative object (its order reference)
  public_reference   text not null,                       -- what the payer sees/types (e.g. CG-1048) — never a UUID
  amount             int  not null check (amount > 0),    -- minor units, decided by the host, never by the payer
  currency           text not null check (currency ~ '^[A-Z]{3}$'),
  customer_country   text check (customer_country ~ '^[A-Z]{2}$'),
  status             text not null default 'created'
                     check (status in ('created','pending','requires_action','paid','failed','expired','cancelled','refunded')),
  provider_reference text,                                -- provider's handle for the request (e.g. Checkout Session id)
  payment_reference  text,                                -- provider's handle for the money (e.g. PaymentIntent id)
  instructions       jsonb not null default '{}'::jsonb check (beau_ph.no_secret_keys(instructions)),  -- snapshot shown to the payer / redirect payload
  metadata           jsonb not null default '{}'::jsonb check (beau_ph.no_secret_keys(metadata)),
  paid_at            timestamptz,
  expires_at         timestamptz,
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now(),
  check (public_reference !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' and length(public_reference) between 3 and 40)
);
-- one LIVE request per (merchant, order, provider); one PAID request per (merchant, order)
create unique index if not exists payment_requests_live_idx on beau_ph.payment_requests (merchant_id, provider_key, external_reference)
  where status in ('created','pending','requires_action');
create unique index if not exists payment_requests_paid_idx on beau_ph.payment_requests (merchant_id, external_reference)
  where status in ('paid','refunded');
create index if not exists payment_requests_provider_ref_idx on beau_ph.payment_requests (provider_key, provider_reference);
create index if not exists payment_requests_payment_ref_idx  on beau_ph.payment_requests (provider_key, payment_reference);

create table if not exists beau_ph.payment_attempts (
  id                 uuid primary key default gen_random_uuid(),
  request_id         uuid not null references beau_ph.payment_requests(id) on delete cascade,
  n                  int  not null,
  provider_reference text,
  redirect_url       text,
  expires_at         timestamptz,
  status             text not null default 'open' check (status in ('open','superseded','completed','expired','cancelled')),
  created_at         timestamptz not null default now(),
  unique (request_id, n)
);

-- Raw provider evidence, verbatim, idempotent on the provider's own event id.
create table if not exists beau_ph.provider_events (
  id                uuid primary key default gen_random_uuid(),
  provider_key      text not null references beau_ph.providers(key),
  provider_event_id text not null,
  event_type        text not null,
  payload           jsonb not null,
  request_id        uuid references beau_ph.payment_requests(id),
  outcome           text,                                  -- normalized | evidence | ignored:<why> | rejected:<why> | no_request
  received_at       timestamptz not null default now(),
  processed_at      timestamptz,
  unique (provider_key, provider_event_id)
);

-- Normalized events: every state change (and evidence-only touches) of a request.
create table if not exists beau_ph.payment_events (
  id                 uuid primary key default gen_random_uuid(),
  request_id         uuid not null references beau_ph.payment_requests(id) on delete cascade,
  provider_event_id  uuid references beau_ph.provider_events(id),
  from_status        text,
  to_status          text not null,
  amount             int,
  currency           text,
  provider_status    text,                                 -- provider-native status kept alongside the normalized one
  provider_reference text,
  actor              text not null check (actor in ('provider','operator','system')),
  actor_id           text,                                 -- operator identity for manual confirmations
  evidence           jsonb not null default '{}'::jsonb check (beau_ph.no_secret_keys(evidence)),
  created_at         timestamptz not null default now()
);
create unique index if not exists payment_events_provider_event_idx on beau_ph.payment_events (provider_event_id) where provider_event_id is not null;
create index if not exists payment_events_request_idx on beau_ph.payment_events (request_id, created_at);

-- The host reconciled a normalized event into its ledger — exactly once.
create table if not exists beau_ph.reconciliations (
  id               uuid primary key default gen_random_uuid(),
  payment_event_id uuid not null unique references beau_ph.payment_events(id),
  request_id       uuid not null references beau_ph.payment_requests(id),
  merchant_id      uuid not null references beau_ph.merchants(id),
  host_reference   text not null,                         -- the host's ledger object (its payment id / reference)
  note             text,
  reconciled_at    timestamptz not null default now()
);

-- deny-all RLS on every core table (owner/definer functions bypass; nothing is API-exposed)
alter table beau_ph.merchants        enable row level security;
alter table beau_ph.providers        enable row level security;
alter table beau_ph.merchant_methods enable row level security;
alter table beau_ph.payment_requests enable row level security;
alter table beau_ph.payment_attempts enable row level security;
alter table beau_ph.provider_events  enable row level security;
alter table beau_ph.payment_events   enable row level security;
alter table beau_ph.reconciliations  enable row level security;
revoke all on all tables in schema beau_ph from public, anon, authenticated;

-- ---------- provider registry (product-level readiness; merchants enable per rail) ----------
insert into beau_ph.providers (key, display_name, kind, confirmation, countries, currencies, readiness, sort, notes) values
  ('stripe',        'Card (Stripe)',               'online', 'provider_event', null,     null,          'available',      10, 'Hosted Checkout; a payment is confirmed only by a signature-verified webhook. TEST mode until CHECK-LICENCE-001.'),
  ('aani',          'Aani (UAE instant payment)',  'manual', 'operator',       '{AE}',   '{AED}',       'available',      20, 'V1: static instructions (registered mobile number); an authorised operator confirms receipt. No Aani API / deep link / request-to-pay is used.'),
  ('bank_transfer', 'Bank transfer',               'manual', 'operator',       null,     null,          'available',      30, 'Account holder / IBAN / BIC-SWIFT / bank name instructions; an authorised operator confirms receipt.'),
  ('paynow',        'Paynow (Zimbabwe)',           'online', 'provider_event', '{ZW}',   '{USD,ZWG}',   'not_configured', 40, 'Adapter boundary only. Needs Paynow merchant onboarding (integration id + key) before it can act.'),
  ('mpesa',         'M-PESA (Kenya)',              'online', 'provider_event', '{KE}',   '{KES}',       'not_configured', 50, 'Adapter boundary only. Needs Safaricom Daraja onboarding (consumer key/secret, shortcode, passkey).'),
  ('ozow',          'Ozow (South Africa)',         'online', 'provider_event', '{ZA}',   '{ZAR}',       'not_configured', 60, 'Adapter boundary only. Needs Ozow merchant onboarding (site code, private key, API key).'),
  ('payshap',       'PayShap (South Africa)',      'online', 'provider_event', '{ZA}',   '{ZAR}',       'not_configured', 70, 'Adapter boundary only. Needs a sponsoring bank/PSP exposing PayShap request-to-pay.'),
  ('beau_wallet',   'BEAU Wallet',                 'crypto', 'unavailable',    null,     null,          'placeholder',    80, 'Future stablecoin-capable crypto rail. Placeholder: cannot create or confirm a payment; no static wallet address; no client-submitted tx hash.')
on conflict (key) do nothing;

-- ---------- JSON projections ----------
create or replace function beau_ph.request_json(r beau_ph.payment_requests)
returns jsonb language sql stable set search_path = '' as $$
  select jsonb_build_object(
    'id', r.id, 'merchant_id', r.merchant_id, 'provider', r.provider_key,
    'external_reference', r.external_reference, 'public_reference', r.public_reference,
    'amount', r.amount, 'currency', r.currency, 'customer_country', r.customer_country,
    'status', r.status, 'provider_reference', r.provider_reference, 'payment_reference', r.payment_reference,
    'instructions', r.instructions, 'metadata', r.metadata,
    'paid_at', r.paid_at, 'expires_at', r.expires_at, 'created_at', r.created_at,
    'attempts', (select count(*) from beau_ph.payment_attempts a where a.request_id = r.id),
    'attempt', (select jsonb_build_object('n', a.n, 'provider_reference', a.provider_reference, 'redirect_url', a.redirect_url,
                                          'expires_at', a.expires_at, 'status', a.status)
                  from beau_ph.payment_attempts a where a.request_id = r.id and a.status = 'open'
                 order by a.created_at desc limit 1))
$$;

-- ---------- eligibility (server-side, the only authority on "what can be offered") ----------
-- p_runtime: deployment readiness reported by the provider adapters, e.g.
--   {"stripe": {"configured": true, "mode": "test"}}   — presence only, never secret values.
create or replace function beau_ph.method_matrix(p_merchant_key text, p_country text default null, p_currency text default null, p_runtime jsonb default '{}'::jsonb)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare m beau_ph.merchants%rowtype; ctry text; cur text; res jsonb := '[]'::jsonb; r record;
  ok boolean; why text; rt jsonb; configured boolean; rmode text; countries text[]; currencies text[];
begin
  select * into m from beau_ph.merchants where key = p_merchant_key;
  if not found then raise exception 'unknown merchant' using errcode = 'P0002'; end if;
  ctry := coalesce(nullif(upper(p_country), ''), m.country);
  cur  := coalesce(nullif(upper(p_currency), ''), m.default_currency);
  for r in
    select p.*, mm.id as mm_id, mm.enabled as m_enabled, mm.countries as m_countries, mm.currency as m_currency, mm.instructions as m_instructions
      from beau_ph.providers p
      left join beau_ph.merchant_methods mm on mm.provider_key = p.key and mm.merchant_id = m.id
     order by p.sort, p.key
  loop
    ok := true; why := null;
    countries := coalesce(r.m_countries, r.countries); currencies := r.currencies;
    rt := coalesce(p_runtime -> r.key, '{}'::jsonb);
    configured := coalesce((rt ->> 'configured')::boolean, false); rmode := rt ->> 'mode';
    if    r.readiness = 'placeholder'                       then ok := false; why := 'coming_soon';
    elsif r.readiness = 'not_configured'                    then ok := false; why := 'not_configured';
    elsif r.mm_id is null or not r.m_enabled                then ok := false; why := 'disabled';
    elsif countries  is not null and not (ctry = any(countries))  then ok := false; why := 'country';
    elsif currencies is not null and not (cur  = any(currencies)) then ok := false; why := 'currency';
    elsif r.kind = 'online' and not configured              then ok := false; why := 'runtime_not_configured';
    elsif r.kind = 'online' and rmode is not null and rmode <> m.mode then ok := false; why := 'mode_mismatch';
    end if;
    res := res || jsonb_build_object(
      'provider', r.key, 'display_name', r.display_name, 'kind', r.kind, 'confirmation', r.confirmation,
      'readiness', r.readiness, 'enabled', coalesce(r.m_enabled, false), 'eligible', ok, 'reason', why,
      'countries', to_jsonb(countries), 'currencies', to_jsonb(currencies), 'settlement_currency', r.m_currency,
      'instructions', case when ok then coalesce(r.m_instructions, '{}'::jsonb) else null end);
  end loop;
  return res;
end $$;

create or replace function beau_ph.eligible_methods(p_merchant_key text, p_country text default null, p_currency text default null, p_runtime jsonb default '{}'::jsonb)
returns jsonb language sql stable security definer set search_path = '' as $$
  select coalesce(jsonb_agg(e), '[]'::jsonb)
    from jsonb_array_elements(beau_ph.method_matrix(p_merchant_key, p_country, p_currency, p_runtime)) e
   where (e ->> 'eligible')::boolean
$$;

-- ---------- merchant method configuration ----------
create or replace function beau_ph.merchant_method_set(p_merchant_key text, p_provider text, p_enabled boolean, p_currency text,
                                                       p_instructions jsonb, p_settings jsonb, p_countries text[], p_updated_by text)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare m beau_ph.merchants%rowtype; row beau_ph.merchant_methods%rowtype;
begin
  select * into m from beau_ph.merchants where key = p_merchant_key;
  if not found then raise exception 'unknown merchant' using errcode = 'P0002'; end if;
  if not exists (select 1 from beau_ph.providers where key = p_provider) then raise exception 'unknown provider' using errcode = '22023'; end if;
  insert into beau_ph.merchant_methods (merchant_id, provider_key, enabled, currency, instructions, settings, countries, updated_by)
  values (m.id, p_provider, coalesce(p_enabled, false), nullif(upper(p_currency), ''), coalesce(p_instructions, '{}'::jsonb), coalesce(p_settings, '{}'::jsonb), p_countries, p_updated_by)
  on conflict (merchant_id, provider_key) do update set
    enabled = excluded.enabled, currency = excluded.currency, instructions = excluded.instructions, settings = excluded.settings,
    countries = excluded.countries, updated_by = excluded.updated_by, updated_at = now()
  returning * into row;
  return to_jsonb(row);
end $$;

-- ---------- state changes (single internal path; every change is an event) ----------
create or replace function beau_ph.record_event(p_request_id uuid, p_to text, p_actor text, p_actor_id text, p_provider_event_id uuid,
                                                p_amount int, p_currency text, p_provider_status text, p_provider_reference text,
                                                p_payment_reference text, p_evidence jsonb)
returns beau_ph.payment_events language plpgsql volatile security definer set search_path = '' as $$
declare r beau_ph.payment_requests%rowtype; ev beau_ph.payment_events%rowtype;
begin
  select * into r from beau_ph.payment_requests where id = p_request_id for update;
  if not found then raise exception 'request not found' using errcode = 'P0002'; end if;
  if not beau_ph.transition_allowed(r.status, p_to) then
    raise exception 'illegal transition % -> %', r.status, p_to using errcode = 'P0003';
  end if;
  insert into beau_ph.payment_events (request_id, provider_event_id, from_status, to_status, amount, currency, provider_status,
                                      provider_reference, actor, actor_id, evidence)
  values (r.id, p_provider_event_id, r.status, p_to, p_amount, p_currency, p_provider_status,
          coalesce(p_payment_reference, p_provider_reference), p_actor, p_actor_id, coalesce(p_evidence, '{}'::jsonb))
  returning * into ev;
  update beau_ph.payment_requests set
    status = p_to,
    paid_at = case when p_to = 'paid' then coalesce(paid_at, now()) else paid_at end,
    provider_reference = coalesce(p_provider_reference, provider_reference),
    payment_reference  = coalesce(p_payment_reference, payment_reference),
    updated_at = now()
  where id = r.id;
  if p_to in ('paid','expired','cancelled','failed') then
    update beau_ph.payment_attempts set status = case when p_to = 'paid' then 'completed' else p_to end
     where request_id = r.id and status = 'open';
  end if;
  return ev;
end $$;

-- ---------- create a payment request (the host decides amount/currency/references) ----------
create or replace function beau_ph.create_request(
  p_merchant_key text, p_provider text, p_external_reference text, p_public_reference text,
  p_amount int, p_currency text, p_country text default null, p_expires_at timestamptz default null,
  p_metadata jsonb default '{}'::jsonb, p_runtime jsonb default '{}'::jsonb)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare m beau_ph.merchants%rowtype; pv beau_ph.providers%rowtype; r beau_ph.payment_requests%rowtype;
  mm beau_ph.merchant_methods%rowtype; elig jsonb; ctry text;
begin
  select * into m from beau_ph.merchants where key = p_merchant_key;
  if not found then raise exception 'unknown merchant' using errcode = 'P0002'; end if;
  select * into pv from beau_ph.providers where key = p_provider;
  if not found then raise exception 'unknown provider' using errcode = 'P0002'; end if;
  if p_amount is null or p_amount <= 0 then raise exception 'amount required' using errcode = '22023'; end if;
  if coalesce(p_currency, '') !~ '^[A-Z]{3}$' then raise exception 'currency required (ISO 4217)' using errcode = '22023'; end if;
  if coalesce(p_external_reference, '') = '' then raise exception 'external reference required' using errcode = '22023'; end if;
  if coalesce(p_public_reference, '') = '' then raise exception 'public reference required' using errcode = '22023'; end if;
  ctry := coalesce(nullif(upper(p_country), ''), m.country);

  -- an external order is paid once, whatever the rail
  if exists (select 1 from beau_ph.payment_requests where merchant_id = m.id and external_reference = p_external_reference and status in ('paid','refunded')) then
    raise exception 'already paid' using errcode = 'P0003';
  end if;
  -- idempotent: reuse the live request for this order + provider
  select * into r from beau_ph.payment_requests
   where merchant_id = m.id and provider_key = p_provider and external_reference = p_external_reference
     and status in ('created','pending','requires_action');
  if found then
    if r.amount <> p_amount or r.currency <> p_currency then
      raise exception 'a live request for % exists with a different amount/currency', p_external_reference using errcode = 'P0003';
    end if;
    return beau_ph.request_json(r);
  end if;
  -- the provider must be eligible for this merchant / country / currency / runtime — server-side, never the payer's choice alone
  select e into elig from jsonb_array_elements(beau_ph.method_matrix(p_merchant_key, ctry, p_currency, p_runtime)) e where e ->> 'provider' = p_provider;
  if not coalesce((elig ->> 'eligible')::boolean, false) then
    raise exception 'provider % not available: %', p_provider, coalesce(elig ->> 'reason', 'unknown') using errcode = 'P0003';
  end if;
  select * into mm from beau_ph.merchant_methods where merchant_id = m.id and provider_key = p_provider;

  insert into beau_ph.payment_requests (merchant_id, provider_key, external_reference, public_reference, amount, currency, customer_country,
                                        status, instructions, metadata, expires_at)
  values (m.id, p_provider, p_external_reference, p_public_reference, p_amount, p_currency, ctry,
          case when pv.kind = 'manual' then 'pending' else 'created' end,
          case when pv.kind = 'manual'
               then coalesce(mm.instructions, '{}'::jsonb) || jsonb_build_object('reference', p_public_reference, 'amount', p_amount, 'currency', p_currency, 'settlement_currency', mm.currency)
               else '{}'::jsonb end,
          coalesce(p_metadata, '{}'::jsonb), p_expires_at)
  returning * into r;
  insert into beau_ph.payment_events (request_id, from_status, to_status, amount, currency, actor, evidence)
  values (r.id, null, r.status, r.amount, r.currency, 'system', jsonb_build_object('created', true, 'kind', pv.kind));
  return beau_ph.request_json(r);
end $$;

-- ---------- attach a provider attempt (e.g. a Checkout Session) ----------
create or replace function beau_ph.attach_attempt(p_request_id uuid, p_provider_reference text, p_redirect_url text, p_expires_at timestamptz)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare r beau_ph.payment_requests%rowtype; a beau_ph.payment_attempts%rowtype; n int;
begin
  select * into r from beau_ph.payment_requests where id = p_request_id for update;
  if not found then raise exception 'request not found' using errcode = 'P0002'; end if;
  if r.status not in ('created','pending','requires_action') then raise exception 'request not open' using errcode = 'P0003'; end if;
  update beau_ph.payment_attempts set status = 'superseded' where request_id = r.id and status = 'open';
  select coalesce(max(n), 0) + 1 into n from beau_ph.payment_attempts where request_id = r.id;
  insert into beau_ph.payment_attempts (request_id, n, provider_reference, redirect_url, expires_at)
  values (r.id, n, p_provider_reference, p_redirect_url, p_expires_at) returning * into a;
  perform beau_ph.record_event(r.id, 'requires_action', 'system', null, null, null, null, 'attempt_open', p_provider_reference, null,
                               jsonb_build_object('attempt', a.n, 'expires_at', p_expires_at));
  update beau_ph.payment_requests set expires_at = coalesce(p_expires_at, expires_at) where id = r.id;
  select * into r from beau_ph.payment_requests where id = r.id;
  return beau_ph.request_json(r);
end $$;

-- ---------- ingest a VERIFIED provider event (evidence first; then normalize) ----------
-- p_normalized is produced by the provider's normalizer (adapter knowledge):
--   {status, request_id | provider_reference | payment_reference | (merchant, external_reference),
--    amount, currency, provider_status, payment_reference, refund_amount, evidence} or {ignore: why}
-- status 'evidence' = attach evidence without a state change.
create or replace function beau_ph.ingest_provider_event(p_provider text, p_provider_event_id text, p_event_type text, p_payload jsonb, p_normalized jsonb)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare pv beau_ph.providers%rowtype; pe beau_ph.provider_events%rowtype; pe_id uuid; r beau_ph.payment_requests%rowtype; m beau_ph.merchants%rowtype;
  ev beau_ph.payment_events%rowtype; v_to text; v_amount int; v_currency text; v_outcome text; existing_ev uuid;
begin
  select * into pv from beau_ph.providers where key = p_provider;
  if not found then raise exception 'unknown provider' using errcode = 'P0002'; end if;
  if coalesce(p_provider_event_id, '') = '' or coalesce(p_event_type, '') = '' then raise exception 'malformed event' using errcode = '22023'; end if;

  -- 1. evidence, verbatim, idempotent
  insert into beau_ph.provider_events (provider_key, provider_event_id, event_type, payload)
  values (p_provider, p_provider_event_id, p_event_type, coalesce(p_payload, '{}'::jsonb))
  on conflict (provider_key, provider_event_id) do nothing returning id into pe_id;
  if pe_id is null then
    select * into pe from beau_ph.provider_events where provider_key = p_provider and provider_event_id = p_provider_event_id;
    select id into existing_ev from beau_ph.payment_events where provider_event_id = pe.id;
    return jsonb_build_object('ok', true, 'duplicate', true, 'outcome', pe.outcome, 'provider_event_id', pe.id,
                              'request_id', pe.request_id, 'payment_event_id', existing_ev);
  end if;

  -- 2. can this provider confirm by event at all?
  if pv.confirmation <> 'provider_event' then
    v_outcome := 'rejected:' || case when pv.kind = 'manual' then 'manual_provider_requires_operator' else 'provider_cannot_confirm' end;
  elsif pv.readiness <> 'available' then
    v_outcome := 'rejected:provider_' || pv.readiness;
  elsif p_normalized ? 'ignore' then
    v_outcome := 'ignored:' || (p_normalized ->> 'ignore');
  end if;
  if v_outcome is not null then
    update beau_ph.provider_events set outcome = v_outcome, processed_at = now() where id = pe_id;
    return jsonb_build_object('ok', false, 'duplicate', false, 'outcome', v_outcome, 'provider_event_id', pe_id);
  end if;

  -- 3. locate the request (by id, provider handle, money handle, or merchant + external reference)
  if (p_normalized ->> 'request_id') is not null then
    select * into r from beau_ph.payment_requests where id = (p_normalized ->> 'request_id')::uuid and provider_key = p_provider;
  end if;
  if r.id is null and (p_normalized ->> 'provider_reference') is not null then
    select * into r from beau_ph.payment_requests where provider_key = p_provider and provider_reference = p_normalized ->> 'provider_reference';
  end if;
  if r.id is null and (p_normalized ->> 'payment_reference') is not null then
    select * into r from beau_ph.payment_requests where provider_key = p_provider and payment_reference = p_normalized ->> 'payment_reference';
  end if;
  if r.id is null and (p_normalized ->> 'external_reference') is not null then
    select pr.* into r from beau_ph.payment_requests pr
      join beau_ph.merchants mm on mm.id = pr.merchant_id
     where pr.provider_key = p_provider and pr.external_reference = p_normalized ->> 'external_reference'
       and (p_normalized ->> 'merchant' is null or mm.key = p_normalized ->> 'merchant')
     order by case when pr.status in ('created','pending','requires_action') then 0 else 1 end, pr.created_at desc limit 1;
  end if;
  if r.id is null then
    update beau_ph.provider_events set outcome = 'no_request', processed_at = now() where id = pe_id;
    return jsonb_build_object('ok', false, 'duplicate', false, 'outcome', 'no_request', 'provider_event_id', pe_id);
  end if;
  select * into m from beau_ph.merchants where id = r.merchant_id;

  -- 4. guards: disabled rail, live/test mode, amount & currency for a paid claim
  v_to := p_normalized ->> 'status'; v_amount := (p_normalized ->> 'amount')::int; v_currency := upper(p_normalized ->> 'currency');
  if not exists (select 1 from beau_ph.merchant_methods where merchant_id = r.merchant_id and provider_key = p_provider and enabled) then
    v_outcome := 'rejected:provider_disabled';
  elsif coalesce((p_normalized -> 'evidence' ->> 'livemode')::boolean, false) and m.mode = 'test' then
    v_outcome := 'rejected:mode_mismatch';
  elsif v_to = 'paid' and (v_amount is null or v_amount <> r.amount or v_currency is null or v_currency <> r.currency) then
    v_outcome := 'rejected:amount_mismatch';
  elsif v_to = 'paid' and r.status in ('paid','refunded') then
    v_outcome := 'ignored:already_paid';
  elsif v_to = 'refunded' and coalesce((p_normalized ->> 'refund_amount')::int, r.amount) < r.amount then
    v_to := 'evidence';                                   -- partial refund: evidence, no state change (the host ledger tracks totals)
  end if;
  if v_outcome is not null then
    update beau_ph.provider_events set request_id = r.id, outcome = v_outcome, processed_at = now() where id = pe_id;
    return jsonb_build_object('ok', false, 'duplicate', false, 'outcome', v_outcome, 'provider_event_id', pe_id, 'request_id', r.id,
                              'status', r.status, 'external_reference', r.external_reference, 'public_reference', r.public_reference, 'merchant', m.key);
  end if;
  if v_to = 'evidence' or v_to is null then v_to := r.status; end if;
  if not beau_ph.transition_allowed(r.status, v_to) then
    v_outcome := 'rejected:illegal_transition:' || r.status || '->' || v_to;
    update beau_ph.provider_events set request_id = r.id, outcome = v_outcome, processed_at = now() where id = pe_id;
    return jsonb_build_object('ok', false, 'duplicate', false, 'outcome', v_outcome, 'provider_event_id', pe_id, 'request_id', r.id, 'status', r.status);
  end if;

  -- 5. normalized event (state change or evidence-only)
  ev := beau_ph.record_event(r.id, v_to, 'provider', null, pe_id, v_amount, v_currency, p_normalized ->> 'provider_status',
                             p_normalized ->> 'provider_reference', p_normalized ->> 'payment_reference', coalesce(p_normalized -> 'evidence', '{}'::jsonb));
  v_outcome := case when ev.from_status = ev.to_status then 'evidence' else 'normalized' end;
  update beau_ph.provider_events set request_id = r.id, outcome = v_outcome, processed_at = now() where id = pe_id;
  return jsonb_build_object('ok', true, 'duplicate', false, 'outcome', v_outcome, 'provider_event_id', pe_id, 'request_id', r.id,
                            'payment_event_id', ev.id, 'from', ev.from_status, 'to', ev.to_status,
                            'external_reference', r.external_reference, 'public_reference', r.public_reference, 'merchant', m.key,
                            'amount', r.amount, 'currency', r.currency);
end $$;

-- ---------- operator confirmation for MANUAL providers (never self-confirming) ----------
-- The HOST authenticates and authorises the operator; the core records who,
-- when, how much, in which currency, under which provider and reference.
create or replace function beau_ph.confirm_manual(p_request_id uuid, p_operator text, p_amount int, p_currency text,
                                                  p_reference text default null, p_paid_at timestamptz default null, p_note text default null)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare r beau_ph.payment_requests%rowtype; pv beau_ph.providers%rowtype; pe_id uuid; ev beau_ph.payment_events%rowtype; m beau_ph.merchants%rowtype;
begin
  if coalesce(p_operator, '') = '' then raise exception 'operator identity required' using errcode = '42501'; end if;
  select * into r from beau_ph.payment_requests where id = p_request_id for update;
  if not found then raise exception 'request not found' using errcode = 'P0002'; end if;
  select * into pv from beau_ph.providers where key = r.provider_key;
  if pv.confirmation <> 'operator' then raise exception 'provider % is not operator-confirmed', r.provider_key using errcode = 'P0003'; end if;
  if pv.readiness <> 'available' then raise exception 'provider % is %', r.provider_key, pv.readiness using errcode = 'P0003'; end if;
  if r.status in ('paid','refunded') then raise exception 'already paid' using errcode = 'P0003'; end if;
  if r.status not in ('created','pending','requires_action') then raise exception 'request not open' using errcode = 'P0003'; end if;
  if p_amount is null or p_amount <> r.amount or upper(coalesce(p_currency, '')) <> r.currency then
    raise exception 'received amount/currency differ from the request (% %)', r.amount, r.currency using errcode = 'P0003';
  end if;
  select * into m from beau_ph.merchants where id = r.merchant_id;
  -- the confirmation itself is evidence, auditable like any provider event
  insert into beau_ph.provider_events (provider_key, provider_event_id, event_type, payload, request_id, outcome, processed_at)
  values (r.provider_key, 'operator:' || gen_random_uuid()::text, 'operator.confirmed',
          jsonb_build_object('operator', p_operator, 'amount', p_amount, 'currency', upper(p_currency), 'reference', p_reference,
                             'paid_at', coalesce(p_paid_at, now()), 'note', p_note), r.id, 'normalized', now())
  returning id into pe_id;
  ev := beau_ph.record_event(r.id, 'paid', 'operator', p_operator, pe_id, p_amount, upper(p_currency), 'confirmed_by_operator', null, p_reference,
                             jsonb_build_object('reference', p_reference, 'paid_at', coalesce(p_paid_at, now()), 'note', p_note));
  if p_paid_at is not null then update beau_ph.payment_requests set paid_at = p_paid_at where id = r.id; end if;
  return jsonb_build_object('ok', true, 'outcome', 'normalized', 'request_id', r.id, 'payment_event_id', ev.id, 'from', ev.from_status, 'to', 'paid',
                            'provider', r.provider_key, 'external_reference', r.external_reference, 'public_reference', r.public_reference,
                            'merchant', m.key, 'amount', r.amount, 'currency', r.currency, 'paid_at', coalesce(p_paid_at, now()));
end $$;

-- ---------- reconciliation (host ledger wrote this event — exactly once) ----------
create or replace function beau_ph.mark_reconciled(p_payment_event_id uuid, p_host_reference text, p_note text default null)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare rid uuid; ex beau_ph.reconciliations%rowtype;
begin
  insert into beau_ph.reconciliations (payment_event_id, request_id, merchant_id, host_reference, note)
  select ev.id, ev.request_id, r.merchant_id, p_host_reference, p_note
    from beau_ph.payment_events ev join beau_ph.payment_requests r on r.id = ev.request_id
   where ev.id = p_payment_event_id
  on conflict (payment_event_id) do nothing returning id into rid;
  if rid is null then
    select * into ex from beau_ph.reconciliations where payment_event_id = p_payment_event_id;
    if ex.id is null then raise exception 'payment event not found' using errcode = 'P0002'; end if;
    return jsonb_build_object('ok', true, 'duplicate', true, 'id', ex.id, 'host_reference', ex.host_reference, 'reconciled_at', ex.reconciled_at);
  end if;
  return jsonb_build_object('ok', true, 'duplicate', false, 'id', rid, 'host_reference', p_host_reference);
end $$;

create or replace function beau_ph.is_reconciled(p_payment_event_id uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (select 1 from beau_ph.reconciliations where payment_event_id = p_payment_event_id)
$$;

-- ---------- history / lookups ----------
create or replace function beau_ph.request_events(p_request_id uuid)
returns jsonb language sql stable security definer set search_path = '' as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'id', ev.id, 'from', ev.from_status, 'to', ev.to_status, 'amount', ev.amount, 'currency', ev.currency,
           'provider_status', ev.provider_status, 'provider_reference', ev.provider_reference, 'actor', ev.actor, 'actor_id', ev.actor_id,
           'evidence', ev.evidence, 'reconciled', exists (select 1 from beau_ph.reconciliations rc where rc.payment_event_id = ev.id),
           'created_at', ev.created_at) order by ev.created_at), '[]'::jsonb)
    from beau_ph.payment_events ev where ev.request_id = p_request_id
$$;

create or replace function beau_ph.requests_for(p_merchant_key text, p_external_reference text)
returns jsonb language sql stable security definer set search_path = '' as $$
  select coalesce(jsonb_agg(beau_ph.request_json(r) order by r.created_at desc), '[]'::jsonb)
    from beau_ph.payment_requests r join beau_ph.merchants m on m.id = r.merchant_id
   where m.key = p_merchant_key and r.external_reference = p_external_reference
$$;

create or replace function beau_ph.get_request(p_request_id uuid)
returns jsonb language sql stable security definer set search_path = '' as $$
  select beau_ph.request_json(r) from beau_ph.payment_requests r where r.id = p_request_id
$$;

-- ---------- Stripe normalizer (provider knowledge, evidence-preserving) ----------
create or replace function beau_ph.normalize_stripe_event(p_event jsonb)
returns jsonb language plpgsql immutable set search_path = '' as $$
declare t text := p_event ->> 'type'; obj jsonb := p_event -> 'data' -> 'object'; enrich jsonb := coalesce(p_event -> '_enrich', '{}'::jsonb);
begin
  if t = 'checkout.session.completed' then
    if coalesce(obj ->> 'payment_status', '') <> 'paid' then return jsonb_build_object('ignore', 'payment_status ' || coalesce(obj ->> 'payment_status', 'null')); end if;
    return jsonb_build_object('status', 'paid',
      'provider_reference', obj ->> 'id', 'external_reference', obj ->> 'client_reference_id',
      'amount', (obj ->> 'amount_total')::int, 'currency', upper(obj ->> 'currency'),
      'provider_status', obj ->> 'payment_status', 'payment_reference', obj ->> 'payment_intent',
      'evidence', jsonb_build_object('payment_intent', obj ->> 'payment_intent', 'checkout_session', obj ->> 'id',
                                     'charge_id', enrich ->> 'charge_id', 'balance_transaction_id', enrich ->> 'balance_transaction_id',
                                     'fee_amount', (enrich ->> 'fee_amount')::int, 'livemode', coalesce((p_event ->> 'livemode')::boolean, false)));
  elsif t = 'checkout.session.expired' then
    return jsonb_build_object('status', 'expired', 'provider_reference', obj ->> 'id', 'provider_status', 'expired',
      'evidence', jsonb_build_object('checkout_session', obj ->> 'id', 'livemode', coalesce((p_event ->> 'livemode')::boolean, false)));
  elsif t in ('refund.created', 'refund.updated') then
    return jsonb_build_object('status', case when obj ->> 'status' = 'succeeded' then 'refunded' else 'evidence' end,
      'payment_reference', obj ->> 'payment_intent', 'refund_amount', (obj ->> 'amount')::int, 'currency', upper(obj ->> 'currency'),
      'provider_status', 'refund.' || coalesce(obj ->> 'status', 'unknown'),
      'evidence', jsonb_build_object('refund_id', obj ->> 'id', 'amount', (obj ->> 'amount')::int, 'status', obj ->> 'status', 'reason', obj ->> 'reason',
                                     'livemode', coalesce((p_event ->> 'livemode')::boolean, false)));
  elsif t like 'charge.dispute.%' then
    return jsonb_build_object('status', 'evidence', 'payment_reference', obj ->> 'payment_intent', 'provider_status', 'dispute.' || coalesce(obj ->> 'status', 'unknown'),
      'evidence', jsonb_build_object('dispute_id', obj ->> 'id', 'charge', obj ->> 'charge', 'amount', (obj ->> 'amount')::int, 'status', obj ->> 'status',
                                     'reason', obj ->> 'reason', 'livemode', coalesce((p_event ->> 'livemode')::boolean, false)));
  end if;
  return jsonb_build_object('ignore', 'unhandled type ' || coalesce(t, 'null'));
end $$;

create or replace function beau_ph.ingest_stripe_event(p_event jsonb)
returns jsonb language sql volatile security definer set search_path = '' as $$
  select beau_ph.ingest_provider_event('stripe', p_event ->> 'id', p_event ->> 'type', p_event, beau_ph.normalize_stripe_event(p_event))
$$;

-- ---------- privileges: core functions are callable by the owner (host-adapter definer functions) and service_role only ----------
do $$
declare f record;
begin
  for f in select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'beau_ph' loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;

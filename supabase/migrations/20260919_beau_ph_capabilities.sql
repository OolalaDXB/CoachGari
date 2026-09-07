-- =====================================================================
-- BEAU PH core — generic CAPABILITY model + in-person / SoftPOS acceptance
--
-- A provider is no longer a single rail: it carries CAPABILITIES
--   online_checkout · payment_link · manual_instructions · wallet ·
--   bank_transfer · mobile_money · softpos · card_present · tap_to_pay ·
--   qr · crypto
-- each with its own readiness, confirmation mode (verified provider event
-- or authorised operator), platform restriction, initiator (customer vs
-- merchant) and an explicit "handoff" flag.
--
-- Eligibility now considers: merchant configuration, country, currency,
-- DEVICE/PLATFORM, who initiates, provider onboarding/readiness and the
-- adapters' deployment readiness — server-side, for every capability.
--
-- In-person acceptance (softpos / card_present / tap_to_pay) is reserved
-- as a first-class future capability:
--   * V0 (UAE): PROVIDER-APP HANDOFF. The merchant takes the contactless
--     tap inside the PSP's own certified app (Apple Tap to Pay on iPhone
--     launch partners in the UAE, Dec 2024: Network International —
--     N-Genius One, Magnati — SwipeX, Adyen — SDK). An authorised operator
--     then attests the app's receipt / transaction reference in BEAU PH.
--     BEAU PH never sees card or PIN data; nothing NFC runs in the PWA.
--   * Future: native Tap to Pay on iPhone through a supported PSP SDK
--     inside a BEAU PH Merchant iOS app (Apple entitlement, PSP-certified
--     configuration, webhook/API verification) — placeholder, ios_app only.
-- Forward migration only.
-- =====================================================================

-- ---------- vocabularies ----------
create or replace function beau_ph.is_capability(p text)
returns boolean language sql immutable set search_path = '' as $$
  select p in ('online_checkout','payment_link','manual_instructions','wallet','bank_transfer','mobile_money','softpos','card_present','tap_to_pay','qr','crypto')
$$;
create or replace function beau_ph.is_platform(p text)
returns boolean language sql immutable set search_path = '' as $$
  select p is null or p in ('web','ios_pwa','android_pwa','ios_app','android_app')
$$;
create or replace function beau_ph.is_in_person(p text)
returns boolean language sql immutable set search_path = '' as $$
  select p in ('softpos','card_present','tap_to_pay')
$$;

-- ---------- providers: UAE Tap to Pay on iPhone PSPs (readiness boundaries) ----------
-- Provider-level readiness = API / online integration readiness (webhook-verified path).
alter table beau_ph.providers drop constraint if exists providers_key_check;
alter table beau_ph.providers add constraint providers_key_check
  check (key in ('stripe','aani','bank_transfer','paynow','mpesa','ozow','payshap','beau_wallet','network_international','magnati','adyen'));

insert into beau_ph.providers (key, display_name, kind, confirmation, countries, currencies, readiness, sort, notes) values
  ('network_international', 'Network International (N-Genius)', 'online', 'provider_event', '{AE}', '{AED}', 'not_configured', 90,
   'UAE acquirer. Apple Tap to Pay on iPhone launch partner (Dec 2024) through the N-Genius One app. Provider-level readiness = N-Genius API/online integration — not onboarded. SoftPOS handoff is a capability (see provider_capabilities).'),
  ('magnati', 'Magnati (SwipeX)', 'online', 'provider_event', '{AE}', '{AED}', 'not_configured', 91,
   'UAE acquirer (FAB group). Apple Tap to Pay on iPhone launch partner (Dec 2024) through the SwipeX app, digital onboarding. Provider-level readiness = API integration — not onboarded.'),
  ('adyen', 'Adyen', 'online', 'provider_event', null, null, 'not_configured', 92,
   'Global PSP. Apple Tap to Pay on iPhone launch partner in the UAE (Dec 2024) via the Adyen POS Mobile SDK / Terminal API — SDK-based, no standalone handoff app. Not onboarded.')
on conflict (key) do nothing;

-- ---------- capabilities per provider ----------
create table if not exists beau_ph.provider_capabilities (
  provider_key text not null references beau_ph.providers(key) on delete cascade,
  capability   text not null check (beau_ph.is_capability(capability)),
  readiness    text not null check (readiness in ('available','not_configured','placeholder')),
  confirmation text not null check (confirmation in ('provider_event','operator','unavailable')),
  platforms    text[],                                   -- null = any; each value per beau_ph.is_platform
  initiated_by text not null default 'any' check (initiated_by in ('customer','merchant','any')),
  handoff      boolean not null default false,           -- the acceptance happens in the provider's own certified app; the operator attests the receipt
  notes        text,
  primary key (provider_key, capability)
);
alter table beau_ph.provider_capabilities enable row level security;
revoke all on beau_ph.provider_capabilities from public, anon, authenticated;

insert into beau_ph.provider_capabilities (provider_key, capability, readiness, confirmation, platforms, initiated_by, handoff, notes) values
  ('stripe',        'online_checkout',     'available',      'provider_event', null, 'customer', false, 'Hosted Checkout; confirmed by a signature-verified webhook. TEST mode until CHECK-LICENCE-001.'),
  ('stripe',        'payment_link',        'not_configured', 'provider_event', null, 'merchant', false, 'Stripe Payment Links — not implemented.'),
  ('aani',          'manual_instructions', 'available',      'operator',       null, 'any',      false, 'Static Aani instructions; an authorised operator confirms receipt.'),
  ('bank_transfer', 'bank_transfer',       'available',      'operator',       null, 'any',      false, 'Account holder / IBAN / BIC; an authorised operator confirms receipt.'),
  ('bank_transfer', 'manual_instructions', 'available',      'operator',       null, 'any',      false, 'Same rail, instruction form.'),
  ('paynow',        'online_checkout',     'not_configured', 'provider_event', null, 'customer', false, 'Paynow hosted redirect — not onboarded.'),
  ('paynow',        'mobile_money',        'not_configured', 'provider_event', null, 'customer', false, 'EcoCash / OneMoney via Paynow Express — not onboarded.'),
  ('mpesa',         'mobile_money',        'not_configured', 'provider_event', null, 'customer', false, 'Lipa na M-PESA STK push — not onboarded.'),
  ('ozow',          'online_checkout',     'not_configured', 'provider_event', null, 'customer', false, 'Ozow instant EFT — not onboarded.'),
  ('payshap',       'qr',                  'not_configured', 'provider_event', null, 'customer', false, 'PayShap QR / ShapID request-to-pay — needs a sponsoring bank.'),
  ('payshap',       'bank_transfer',       'not_configured', 'provider_event', null, 'customer', false, 'PayShap rapid payment — needs a sponsoring bank.'),
  ('beau_wallet',   'crypto',              'placeholder',    'unavailable',    null, 'customer', false, 'Future stablecoin-capable rail — placeholder.'),
  ('beau_wallet',   'wallet',              'placeholder',    'unavailable',    null, 'customer', false, 'BEAU Wallet — placeholder.'),
  ('beau_wallet',   'qr',                  'placeholder',    'unavailable',    null, 'customer', false, 'Wallet QR — placeholder.'),
  -- in-person / SoftPOS (UAE)
  ('network_international', 'softpos',         'available',      'operator',       null,        'merchant', true,  'V0 handoff: the merchant takes the contactless tap in the N-Genius One app (Apple Tap to Pay on iPhone, iPhone XS+); an authorised operator attests the app receipt / RRN. No card or PIN data ever reaches BEAU PH.'),
  ('network_international', 'tap_to_pay',      'placeholder',    'provider_event', '{ios_app}', 'merchant', false, 'Native Tap to Pay on iPhone through the PSP SDK inside a future BEAU PH Merchant iOS app (Apple entitlement, PSP-certified configuration, webhook/API verification). ios_app only.'),
  ('network_international', 'card_present',    'not_configured', 'provider_event', null,        'merchant', false, 'N-Genius POS terminal with API reconciliation — not onboarded.'),
  ('network_international', 'online_checkout', 'not_configured', 'provider_event', null,        'customer', false, 'N-Genius Online — not onboarded.'),
  ('magnati',               'softpos',         'available',      'operator',       null,        'merchant', true,  'V0 handoff: the merchant takes the tap in the SwipeX app (Apple Tap to Pay on iPhone); an authorised operator attests the app receipt / transaction reference.'),
  ('magnati',               'tap_to_pay',      'placeholder',    'provider_event', '{ios_app}', 'merchant', false, 'Native Tap to Pay on iPhone via the Magnati SDK inside a future BEAU PH Merchant iOS app. ios_app only.'),
  ('magnati',               'card_present',    'not_configured', 'provider_event', null,        'merchant', false, 'Magnati terminal / Tap to Phone (Android) with API reconciliation — not onboarded.'),
  ('magnati',               'online_checkout', 'not_configured', 'provider_event', null,        'customer', false, 'Magnati online gateway — not onboarded.'),
  ('adyen',                 'softpos',         'not_configured', 'operator',       null,        'merchant', true,  'Adyen is SDK-based: no standalone handoff app for a small merchant. Needs an Adyen account + an Adyen-built app before any handoff.'),
  ('adyen',                 'tap_to_pay',      'placeholder',    'provider_event', '{ios_app}', 'merchant', false, 'Native via the Adyen POS Mobile SDK inside a future BEAU PH Merchant iOS app. ios_app only.'),
  ('adyen',                 'card_present',    'not_configured', 'provider_event', null,        'merchant', false, 'Adyen terminals / Terminal API — not onboarded.'),
  ('adyen',                 'online_checkout', 'not_configured', 'provider_event', null,        'customer', false, 'Adyen Checkout — not onboarded.')
on conflict do nothing;

create or replace function beau_ph.capabilities_json(p_provider text)
returns jsonb language sql stable set search_path = '' as $$
  select coalesce(jsonb_agg(jsonb_build_object('capability', c.capability, 'readiness', c.readiness, 'confirmation', c.confirmation, 'handoff', c.handoff,
                                               'platforms', to_jsonb(c.platforms), 'initiated_by', c.initiated_by, 'in_person', beau_ph.is_in_person(c.capability), 'notes', c.notes)
                            order by c.capability), '[]'::jsonb)
    from beau_ph.provider_capabilities c where c.provider_key = p_provider
$$;

-- ---------- merchant methods: optional narrowing; requests: capability / channel / initiator / platform ----------
alter table beau_ph.merchant_methods add column if not exists capabilities text[];      -- null = every capability of the provider

alter table beau_ph.payment_requests add column if not exists capability   text check (beau_ph.is_capability(capability));
alter table beau_ph.payment_requests add column if not exists channel      text not null default 'online' check (channel in ('online','in_person'));
alter table beau_ph.payment_requests add column if not exists initiated_by text not null default 'customer' check (initiated_by in ('customer','merchant'));
alter table beau_ph.payment_requests add column if not exists platform     text check (beau_ph.is_platform(platform));
update beau_ph.payment_requests r
   set capability = case p.kind when 'online' then 'online_checkout'
                                when 'manual' then case r.provider_key when 'bank_transfer' then 'bank_transfer' else 'manual_instructions' end
                                else 'crypto' end,
       initiated_by = case when p.kind = 'manual' then 'merchant' else 'customer' end
  from beau_ph.providers p where p.key = r.provider_key and r.capability is null;

create or replace function beau_ph.request_json(r beau_ph.payment_requests)
returns jsonb language sql stable set search_path = '' as $$
  select jsonb_build_object(
    'id', r.id, 'merchant_id', r.merchant_id, 'provider', r.provider_key,
    'capability', r.capability, 'channel', r.channel, 'initiated_by', r.initiated_by, 'platform', r.platform,
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

-- ---------- eligibility v2: per capability, with platform + initiator ----------
drop function if exists beau_ph.method_matrix(text, text, text, jsonb);
drop function if exists beau_ph.eligible_methods(text, text, text, jsonb);

create or replace function beau_ph.method_matrix(p_merchant_key text, p_country text default null, p_currency text default null, p_runtime jsonb default '{}'::jsonb,
                                                 p_platform text default null, p_initiated_by text default 'customer')
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare m beau_ph.merchants%rowtype; ctry text; cur text; res jsonb := '[]'::jsonb; r record; c record;
  caps jsonb; cap_why text; any_ok boolean; first_conf text; first_cap text; prov_why text;
  rt jsonb; configured boolean; rmode text; countries text[]; currencies text[]; init text := coalesce(p_initiated_by, 'customer');
begin
  select * into m from beau_ph.merchants where key = p_merchant_key;
  if not found then raise exception 'unknown merchant' using errcode = 'P0002'; end if;
  if not beau_ph.is_platform(p_platform) then raise exception 'unknown platform %', p_platform using errcode = '22023'; end if;
  if init not in ('customer','merchant') then raise exception 'initiated_by must be customer or merchant' using errcode = '22023'; end if;
  ctry := coalesce(nullif(upper(p_country), ''), m.country);
  cur  := coalesce(nullif(upper(p_currency), ''), m.default_currency);
  for r in
    select p.*, mm.id as mm_id, mm.enabled as m_enabled, mm.countries as m_countries, mm.currency as m_currency,
           mm.instructions as m_instructions, mm.settings as m_settings, mm.capabilities as m_caps
      from beau_ph.providers p
      left join beau_ph.merchant_methods mm on mm.provider_key = p.key and mm.merchant_id = m.id
     order by p.sort, p.key
  loop
    countries := coalesce(r.m_countries, r.countries); currencies := r.currencies;
    rt := coalesce(p_runtime -> r.key, '{}'::jsonb);
    configured := coalesce((rt ->> 'configured')::boolean, false); rmode := rt ->> 'mode';
    -- provider-level blockers apply to every capability
    prov_why := case when r.mm_id is null or not r.m_enabled                     then 'disabled'
                     when countries  is not null and not (ctry = any(countries))  then 'country'
                     when currencies is not null and not (cur  = any(currencies)) then 'currency'
                     else null end;
    caps := '[]'::jsonb; any_ok := false; first_conf := null; first_cap := null;
    for c in select * from beau_ph.provider_capabilities pc where pc.provider_key = r.key
              order by case pc.capability when 'online_checkout' then 1 when 'manual_instructions' then 2 when 'bank_transfer' then 3 when 'mobile_money' then 4
                                          when 'qr' then 5 when 'wallet' then 6 when 'payment_link' then 7 when 'softpos' then 8 when 'card_present' then 9
                                          when 'tap_to_pay' then 10 else 11 end
    loop
      cap_why := case
        when c.readiness = 'placeholder'                                                      then 'coming_soon'
        when c.readiness = 'not_configured'                                                   then 'not_configured'
        when prov_why is not null                                                             then prov_why
        when r.m_caps is not null and not (c.capability = any(r.m_caps))                      then 'disabled'
        when c.initiated_by <> 'any' and c.initiated_by <> init                               then 'initiator'
        when c.platforms is not null and (p_platform is null or not (p_platform = any(c.platforms))) then 'platform'
        when c.confirmation = 'provider_event' and not c.handoff and r.readiness <> 'available' then 'provider_' || r.readiness
        when c.confirmation = 'provider_event' and not c.handoff and not configured           then 'runtime_not_configured'
        when c.confirmation = 'provider_event' and not c.handoff and rmode is not null and rmode <> m.mode then 'mode_mismatch'
        else null end;
      if cap_why is null and not any_ok then any_ok := true; first_conf := c.confirmation; first_cap := c.capability; end if;
      caps := caps || jsonb_build_object('capability', c.capability, 'readiness', c.readiness, 'confirmation', c.confirmation, 'handoff', c.handoff,
                                         'platforms', to_jsonb(c.platforms), 'initiated_by', c.initiated_by, 'in_person', beau_ph.is_in_person(c.capability),
                                         'eligible', cap_why is null, 'reason', cap_why);
    end loop;
    res := res || jsonb_build_object(
      'provider', r.key, 'display_name', r.display_name, 'kind', r.kind,
      'confirmation', coalesce(first_conf, r.confirmation), 'capability', first_cap,
      'readiness', r.readiness, 'enabled', coalesce(r.m_enabled, false), 'eligible', any_ok,
      'reason', case when any_ok then null else coalesce(prov_why, (select e ->> 'reason' from jsonb_array_elements(caps) e limit 1), 'no_capability') end,
      'countries', to_jsonb(countries), 'currencies', to_jsonb(currencies), 'settlement_currency', r.m_currency,
      'instructions', case when any_ok then coalesce(r.m_instructions, '{}'::jsonb) else null end,
      'settings',     case when any_ok then coalesce(r.m_settings, '{}'::jsonb) else null end,
      'capabilities', caps);
  end loop;
  return res;
end $$;

-- providers with at least one eligible capability (customer-initiated by default — what a payer page renders)
create or replace function beau_ph.eligible_methods(p_merchant_key text, p_country text default null, p_currency text default null, p_runtime jsonb default '{}'::jsonb,
                                                    p_platform text default null, p_initiated_by text default 'customer')
returns jsonb language sql stable security definer set search_path = '' as $$
  select coalesce(jsonb_agg(e), '[]'::jsonb)
    from jsonb_array_elements(beau_ph.method_matrix(p_merchant_key, p_country, p_currency, p_runtime, p_platform, p_initiated_by)) e
   where (e ->> 'eligible')::boolean
$$;

-- flat (provider, capability) pairs — what a merchant-side "Collect payment" screen renders
create or replace function beau_ph.eligible_capabilities(p_merchant_key text, p_country text default null, p_currency text default null, p_runtime jsonb default '{}'::jsonb,
                                                         p_platform text default null, p_initiated_by text default 'merchant')
returns jsonb language sql stable security definer set search_path = '' as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'provider', e ->> 'provider', 'display_name', e ->> 'display_name', 'capability', c ->> 'capability',
           'confirmation', c ->> 'confirmation', 'handoff', (c ->> 'handoff')::boolean, 'in_person', (c ->> 'in_person')::boolean,
           'settlement_currency', e ->> 'settlement_currency', 'instructions', e -> 'instructions', 'settings', e -> 'settings')), '[]'::jsonb)
    from jsonb_array_elements(beau_ph.method_matrix(p_merchant_key, p_country, p_currency, p_runtime, p_platform, p_initiated_by)) e,
         jsonb_array_elements(e -> 'capabilities') c
   where (c ->> 'eligible')::boolean
$$;

-- ---------- create_request v2: capability-aware ----------
drop function if exists beau_ph.create_request(text, text, text, text, int, text, text, timestamptz, jsonb, jsonb);
create or replace function beau_ph.create_request(
  p_merchant_key text, p_provider text, p_external_reference text, p_public_reference text,
  p_amount int, p_currency text, p_country text default null, p_expires_at timestamptz default null,
  p_metadata jsonb default '{}'::jsonb, p_runtime jsonb default '{}'::jsonb,
  p_capability text default null, p_platform text default null, p_initiated_by text default null)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare m beau_ph.merchants%rowtype; pv beau_ph.providers%rowtype; r beau_ph.payment_requests%rowtype;
  mm beau_ph.merchant_methods%rowtype; cap beau_ph.provider_capabilities%rowtype; elig jsonb; ctry text; v_cap text; v_init text; v_status text; ins jsonb;
begin
  select * into m from beau_ph.merchants where key = p_merchant_key;
  if not found then raise exception 'unknown merchant' using errcode = 'P0002'; end if;
  select * into pv from beau_ph.providers where key = p_provider;
  if not found then raise exception 'unknown provider' using errcode = 'P0002'; end if;
  if p_amount is null or p_amount <= 0 then raise exception 'amount required' using errcode = '22023'; end if;
  if coalesce(p_currency, '') !~ '^[A-Z]{3}$' then raise exception 'currency required (ISO 4217)' using errcode = '22023'; end if;
  if coalesce(p_external_reference, '') = '' then raise exception 'external reference required' using errcode = '22023'; end if;
  if coalesce(p_public_reference, '') = '' then raise exception 'public reference required' using errcode = '22023'; end if;
  if not beau_ph.is_platform(p_platform) then raise exception 'unknown platform %', p_platform using errcode = '22023'; end if;
  ctry := coalesce(nullif(upper(p_country), ''), m.country);
  v_cap := coalesce(p_capability, case pv.kind when 'online' then 'online_checkout'
                                               when 'manual' then case p_provider when 'bank_transfer' then 'bank_transfer' else 'manual_instructions' end
                                               else 'crypto' end);
  if not beau_ph.is_capability(v_cap) then raise exception 'unknown capability %', v_cap using errcode = '22023'; end if;
  v_init := coalesce(p_initiated_by, case when pv.kind = 'manual' or beau_ph.is_in_person(v_cap) then 'merchant' else 'customer' end);

  if exists (select 1 from beau_ph.payment_requests where merchant_id = m.id and external_reference = p_external_reference and status in ('paid','refunded')) then
    raise exception 'already paid' using errcode = 'P0003';
  end if;
  select * into r from beau_ph.payment_requests
   where merchant_id = m.id and provider_key = p_provider and external_reference = p_external_reference
     and status in ('created','pending','requires_action');
  if found then
    if r.amount <> p_amount or r.currency <> p_currency then
      raise exception 'a live request for % exists with a different amount/currency', p_external_reference using errcode = 'P0003';
    end if;
    if r.capability is distinct from v_cap then
      raise exception 'a live % request for % exists (capability %)', p_provider, p_external_reference, r.capability using errcode = 'P0003';
    end if;
    return beau_ph.request_json(r);
  end if;

  -- the (provider, capability) must be eligible for this merchant / country / currency / platform / initiator / runtime
  select c into elig
    from jsonb_array_elements(beau_ph.method_matrix(p_merchant_key, ctry, p_currency, p_runtime, p_platform, v_init)) e,
         jsonb_array_elements(e -> 'capabilities') c
   where e ->> 'provider' = p_provider and c ->> 'capability' = v_cap;
  if not coalesce((elig ->> 'eligible')::boolean, false) then
    raise exception 'provider % capability % not available: %', p_provider, v_cap, coalesce(elig ->> 'reason', 'no_capability') using errcode = 'P0003';
  end if;
  select * into mm  from beau_ph.merchant_methods where merchant_id = m.id and provider_key = p_provider;
  select * into cap from beau_ph.provider_capabilities where provider_key = p_provider and capability = v_cap;

  if cap.confirmation = 'operator' then
    v_status := 'pending';
    ins := coalesce(mm.instructions, '{}'::jsonb)
        || jsonb_build_object('reference', p_public_reference, 'amount', p_amount, 'currency', p_currency, 'settlement_currency', mm.currency, 'capability', v_cap)
        || case when cap.handoff then jsonb_build_object('handoff', true, 'handoff_app', mm.settings ->> 'handoff_app', 'handoff_url', mm.settings ->> 'handoff_url') else '{}'::jsonb end;
  else
    v_status := 'created'; ins := '{}'::jsonb;
  end if;

  insert into beau_ph.payment_requests (merchant_id, provider_key, capability, channel, initiated_by, platform,
                                        external_reference, public_reference, amount, currency, customer_country,
                                        status, instructions, metadata, expires_at)
  values (m.id, p_provider, v_cap, case when beau_ph.is_in_person(v_cap) then 'in_person' else 'online' end, v_init, p_platform,
          p_external_reference, p_public_reference, p_amount, p_currency, ctry,
          v_status, jsonb_strip_nulls(ins), coalesce(p_metadata, '{}'::jsonb), p_expires_at)
  returning * into r;
  insert into beau_ph.payment_events (request_id, from_status, to_status, amount, currency, actor, evidence)
  values (r.id, null, r.status, r.amount, r.currency, 'system', jsonb_build_object('created', true, 'kind', pv.kind, 'capability', v_cap, 'channel', r.channel));
  return beau_ph.request_json(r);
end $$;

-- ---------- confirm_manual v2: capability-level confirmation; handoff requires the provider receipt ----------
create or replace function beau_ph.confirm_manual(p_request_id uuid, p_operator text, p_amount int, p_currency text,
                                                  p_reference text default null, p_paid_at timestamptz default null, p_note text default null)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare r beau_ph.payment_requests%rowtype; pv beau_ph.providers%rowtype; cap beau_ph.provider_capabilities%rowtype;
  pe_id uuid; ev beau_ph.payment_events%rowtype; m beau_ph.merchants%rowtype; v_conf text; v_ready text; v_handoff boolean;
begin
  if coalesce(p_operator, '') = '' then raise exception 'operator identity required' using errcode = '42501'; end if;
  select * into r from beau_ph.payment_requests where id = p_request_id for update;
  if not found then raise exception 'request not found' using errcode = 'P0002'; end if;
  select * into pv from beau_ph.providers where key = r.provider_key;
  select * into cap from beau_ph.provider_capabilities where provider_key = r.provider_key and capability = r.capability;
  v_conf := coalesce(cap.confirmation, pv.confirmation); v_ready := coalesce(cap.readiness, pv.readiness); v_handoff := coalesce(cap.handoff, false);
  if v_conf <> 'operator' then raise exception 'provider % (%) is not operator-confirmed', r.provider_key, coalesce(r.capability, '-') using errcode = 'P0003'; end if;
  if v_ready <> 'available' then raise exception 'provider % (%) is %', r.provider_key, coalesce(r.capability, '-'), v_ready using errcode = 'P0003'; end if;
  if r.status in ('paid','refunded') then raise exception 'already paid' using errcode = 'P0003'; end if;
  if r.status not in ('created','pending','requires_action') then raise exception 'request not open' using errcode = 'P0003'; end if;
  if p_amount is null or p_amount <> r.amount or upper(coalesce(p_currency, '')) <> r.currency then
    raise exception 'received amount/currency differ from the request (% %)', r.amount, r.currency using errcode = 'P0003';
  end if;
  if v_handoff and coalesce(btrim(p_reference), '') = '' then
    raise exception 'the provider app receipt / transaction reference is required for a % handoff', r.capability using errcode = '22023';
  end if;
  select * into m from beau_ph.merchants where id = r.merchant_id;
  insert into beau_ph.provider_events (provider_key, provider_event_id, event_type, payload, request_id, outcome, processed_at)
  values (r.provider_key, 'operator:' || gen_random_uuid()::text, 'operator.confirmed',
          jsonb_build_object('operator', p_operator, 'amount', p_amount, 'currency', upper(p_currency), 'reference', p_reference,
                             'paid_at', coalesce(p_paid_at, now()), 'note', p_note, 'capability', r.capability, 'handoff', v_handoff), r.id, 'normalized', now())
  returning id into pe_id;
  ev := beau_ph.record_event(r.id, 'paid', 'operator', p_operator, pe_id, p_amount, upper(p_currency), 'confirmed_by_operator', null, nullif(btrim(p_reference), ''),
                             jsonb_build_object('reference', p_reference, 'paid_at', coalesce(p_paid_at, now()), 'note', p_note, 'capability', r.capability,
                                                'verification', case when v_handoff then 'operator_attested_provider_receipt' else 'operator_attested' end));
  if p_paid_at is not null then update beau_ph.payment_requests set paid_at = p_paid_at where id = r.id; end if;
  return jsonb_build_object('ok', true, 'outcome', 'normalized', 'request_id', r.id, 'payment_event_id', ev.id, 'from', ev.from_status, 'to', 'paid',
                            'provider', r.provider_key, 'capability', r.capability, 'external_reference', r.external_reference, 'public_reference', r.public_reference,
                            'merchant', m.key, 'amount', r.amount, 'currency', r.currency, 'paid_at', coalesce(p_paid_at, now()));
end $$;

-- ---------- ingest v2: the request's capability must be provider-event-confirmed ----------
create or replace function beau_ph.ingest_provider_event(p_provider text, p_provider_event_id text, p_event_type text, p_payload jsonb, p_normalized jsonb)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare pv beau_ph.providers%rowtype; pe beau_ph.provider_events%rowtype; pe_id uuid; r beau_ph.payment_requests%rowtype; m beau_ph.merchants%rowtype;
  cap beau_ph.provider_capabilities%rowtype;
  ev beau_ph.payment_events%rowtype; v_to text; v_amount int; v_currency text; v_outcome text; existing_ev uuid;
begin
  select * into pv from beau_ph.providers where key = p_provider;
  if not found then raise exception 'unknown provider' using errcode = 'P0002'; end if;
  if coalesce(p_provider_event_id, '') = '' or coalesce(p_event_type, '') = '' then raise exception 'malformed event' using errcode = '22023'; end if;

  insert into beau_ph.provider_events (provider_key, provider_event_id, event_type, payload)
  values (p_provider, p_provider_event_id, p_event_type, coalesce(p_payload, '{}'::jsonb))
  on conflict (provider_key, provider_event_id) do nothing returning id into pe_id;
  if pe_id is null then
    select * into pe from beau_ph.provider_events where provider_key = p_provider and provider_event_id = p_provider_event_id;
    select id into existing_ev from beau_ph.payment_events where provider_event_id = pe.id;
    return jsonb_build_object('ok', true, 'duplicate', true, 'outcome', pe.outcome, 'provider_event_id', pe.id,
                              'request_id', pe.request_id, 'payment_event_id', existing_ev);
  end if;

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
  select * into cap from beau_ph.provider_capabilities where provider_key = r.provider_key and capability = r.capability;

  v_to := p_normalized ->> 'status'; v_amount := (p_normalized ->> 'amount')::int; v_currency := upper(p_normalized ->> 'currency');
  if cap.capability is not null and cap.confirmation <> 'provider_event' then
    v_outcome := 'rejected:capability_requires_operator';
  elsif cap.capability is not null and cap.readiness <> 'available' then
    v_outcome := 'rejected:capability_' || cap.readiness;
  elsif not exists (select 1 from beau_ph.merchant_methods where merchant_id = r.merchant_id and provider_key = p_provider and enabled) then
    v_outcome := 'rejected:provider_disabled';
  elsif coalesce((p_normalized -> 'evidence' ->> 'livemode')::boolean, false) and m.mode = 'test' then
    v_outcome := 'rejected:mode_mismatch';
  elsif v_to = 'paid' and (v_amount is null or v_amount <> r.amount or v_currency is null or v_currency <> r.currency) then
    v_outcome := 'rejected:amount_mismatch';
  elsif v_to = 'paid' and r.status in ('paid','refunded') then
    v_outcome := 'ignored:already_paid';
  elsif v_to = 'refunded' and coalesce((p_normalized ->> 'refund_amount')::int, r.amount) < r.amount then
    v_to := 'evidence';
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

  ev := beau_ph.record_event(r.id, v_to, 'provider', null, pe_id, v_amount, v_currency, p_normalized ->> 'provider_status',
                             p_normalized ->> 'provider_reference', p_normalized ->> 'payment_reference', coalesce(p_normalized -> 'evidence', '{}'::jsonb));
  v_outcome := case when ev.from_status = ev.to_status then 'evidence' else 'normalized' end;
  update beau_ph.provider_events set request_id = r.id, outcome = v_outcome, processed_at = now() where id = pe_id;
  return jsonb_build_object('ok', true, 'duplicate', false, 'outcome', v_outcome, 'provider_event_id', pe_id, 'request_id', r.id,
                            'payment_event_id', ev.id, 'from', ev.from_status, 'to', ev.to_status,
                            'external_reference', r.external_reference, 'public_reference', r.public_reference, 'merchant', m.key,
                            'amount', r.amount, 'currency', r.currency);
end $$;

-- ---------- privileges (idempotent sweep) ----------
do $$
declare f record;
begin
  for f in select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'beau_ph' loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;

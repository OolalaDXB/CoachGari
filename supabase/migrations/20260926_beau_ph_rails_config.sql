-- =====================================================================
-- BEAU PH core — rail configuration is real, persisted merchant state
--
-- Before this migration a merchant method carried an "enabled" flag, one
-- settlement currency and an optional country override whose null value was
-- silently read as "the provider's whole coverage" (global, for Stripe). A
-- merchant had no enabled-currency list at all, no per-rail limits, no
-- payment-type (intent) restriction, no settlement destination, and a
-- configuration change was audited as a one-line summary.
--
-- Now:
--   * providers carry data the operator screens can render without provider
--     specific code: a channel label, the NAMES of the deployment secrets they
--     need (never values), a non-secret configuration schema, an onboarding
--     note and the payment intents they can carry.
--   * merchant_methods persist enabled COUNTRIES and CURRENCIES (ISO codes),
--     supported INTENTS, per-currency LIMITS and a `listed` flag ("Remove" in
--     Finance deactivates + unlists; history is never deleted).
--   * eligibility = provider capability ∩ merchant configuration ∩ payment
--     context. Missing merchant countries or currencies = `needs_configuration`
--     and NOT eligible: nothing is ever read as "any" for a merchant.
--   * merchant configuration can never broaden a provider: countries,
--     currencies, intents and capabilities must be subsets of the provider's.
--   * settlement destinations are a separate concept from payment methods; a
--     rail maps each currency to a destination (bank account, PSP balance…).
--   * every configuration change is audited field by field (actor, time,
--     field, previous value, new value). Values pass the no-secret guard.
--
-- Coach Gari backfill: Stripe gets the audience Coach Gari already maps
-- (the countries cg_country_code() recognises) and the currencies observed
-- on packs / services / orders (AED, USD); Aani gets AE / AED. Both are
-- explicit, visible and editable — no silent "any" remains.
-- Forward migration only; nothing applied is rewritten.
-- =====================================================================

-- ---------- 0. vocabularies ----------
create or replace function beau_ph.is_intent(p text)
returns boolean language sql immutable set search_path = '' as $$
  select p in ('service','package','support','other')
$$;
create or replace function beau_ph.is_iso_country(p text)
returns boolean language sql immutable set search_path = '' as $$ select p ~ '^[A-Z]{2}$' $$;
create or replace function beau_ph.is_iso_currency(p text)
returns boolean language sql immutable set search_path = '' as $$ select p ~ '^[A-Z]{3}$' $$;
create or replace function beau_ph.array_is_subset(p_child text[], p_parent text[])
returns boolean language sql immutable set search_path = '' as $$
  -- null parent = the provider has no restriction; null child = nothing to check
  select p_child is null or p_parent is null or p_child <@ p_parent
$$;

-- ---------- 1. providers: data the screens render (no secret values, ever) ----------
alter table beau_ph.providers add column if not exists channel_label text;
alter table beau_ph.providers add column if not exists intents       text[];                          -- null = any intent
alter table beau_ph.providers add column if not exists secrets       text[] not null default '{}';    -- NAMES of deployment secrets
alter table beau_ph.providers add column if not exists config_schema jsonb  not null default '[]'::jsonb check (beau_ph.no_secret_keys(config_schema));
alter table beau_ph.providers add column if not exists onboarding    text;

-- config_schema entry: {key, label, store: instructions|settings, type: text|select|url|textarea, options, placeholder, help, mask, public}
update beau_ph.providers set channel_label = 'Online · Card', secrets = '{STRIPE_SECRET_KEY,STRIPE_WEBHOOK_SECRET,STRIPE_PUBLISHABLE_KEY}',
  onboarding = 'Stripe account (Oolala), secret + publishable keys and the webhook signing secret set as deployment secrets; PAYMENTS_MODE declares test or live.',
  config_schema = '[]'::jsonb where key = 'stripe';
update beau_ph.providers set channel_label = 'Manual · Instant payment (UAE)', secrets = '{}',
  onboarding = 'No API. Register the Aani proxy (mobile, email or merchant id) the client pays; an authorised operator confirms receipt.',
  config_schema = '[
    {"key":"proxy_type","label":"Proxy type","store":"instructions","type":"select","options":["mobile","email","merchant","qr"],"public":true},
    {"key":"proxy_value","label":"Aani value (machine)","store":"instructions","type":"text","placeholder":"+9715XXXXXXXX","mask":true,"public":true},
    {"key":"display_value","label":"Display value","store":"instructions","type":"text","placeholder":"+971 5X XXX XXXX","public":true},
    {"key":"instructions","label":"Instructions shown to the client","store":"instructions","type":"textarea","public":true},
    {"key":"qr_url","label":"QR image link (optional)","store":"instructions","type":"url","public":true}]'::jsonb where key = 'aani';
update beau_ph.providers set channel_label = 'Manual · Bank transfer', secrets = '{}',
  onboarding = 'No API. Enter the account the client transfers to; an authorised operator confirms receipt.',
  config_schema = '[
    {"key":"account_holder","label":"Account holder","store":"instructions","type":"text","public":true},
    {"key":"iban","label":"IBAN","store":"instructions","type":"text","mask":true,"public":true},
    {"key":"bic","label":"BIC / SWIFT","store":"instructions","type":"text","public":true},
    {"key":"bank_name","label":"Bank name","store":"instructions","type":"text","public":true},
    {"key":"instructions","label":"Instructions shown to the client","store":"instructions","type":"textarea","public":true}]'::jsonb where key = 'bank_transfer';
update beau_ph.providers set channel_label = 'Online · Redirect / mobile money', secrets = '{PAYNOW_INTEGRATION_ID,PAYNOW_INTEGRATION_KEY}',
  onboarding = 'Paynow merchant onboarding (integration id + key), then the adapter can act.' where key = 'paynow';
update beau_ph.providers set channel_label = 'Online · Mobile money', secrets = '{MPESA_CONSUMER_KEY,MPESA_CONSUMER_SECRET,MPESA_SHORTCODE,MPESA_PASSKEY}',
  onboarding = 'Safaricom Daraja onboarding (consumer key / secret, shortcode, passkey).' where key = 'mpesa';
update beau_ph.providers set channel_label = 'Online · Instant EFT', secrets = '{OZOW_SITE_CODE,OZOW_PRIVATE_KEY,OZOW_API_KEY}',
  onboarding = 'Ozow merchant onboarding (site code, private key, API key).' where key = 'ozow';
update beau_ph.providers set channel_label = 'Online · QR / request to pay', secrets = '{PAYSHAP_SPONSOR_CLIENT_ID,PAYSHAP_SPONSOR_CLIENT_SECRET}',
  onboarding = 'Needs a sponsoring bank before any PayShap request can be issued.' where key = 'payshap';
update beau_ph.providers set channel_label = 'Wallet', secrets = '{}', onboarding = 'Reserved. No onboarding path yet.' where key = 'beau_wallet';
update beau_ph.providers set channel_label = 'In person · Tap to Pay app', secrets = '{NGENIUS_API_KEY,NGENIUS_OUTLET_ID}',
  onboarding = 'V0 handoff needs only the N-Genius One app on the merchant phone. API keys are for the future online / terminal integration.',
  config_schema = '[
    {"key":"handoff_app","label":"App name","store":"settings","type":"text","placeholder":"N-Genius One"},
    {"key":"handoff_url","label":"App link (optional)","store":"settings","type":"url","placeholder":"app scheme or https:// link"}]'::jsonb where key = 'network_international';
update beau_ph.providers set channel_label = 'In person · Tap to Pay app', secrets = '{MAGNATI_MERCHANT_KEY,MAGNATI_API_SECRET}',
  onboarding = 'V0 handoff needs only the SwipeX app on the merchant phone. Keys are for the future online / terminal integration.',
  config_schema = '[
    {"key":"handoff_app","label":"App name","store":"settings","type":"text","placeholder":"SwipeX"},
    {"key":"handoff_url","label":"App link (optional)","store":"settings","type":"url","placeholder":"app scheme or https:// link"}]'::jsonb where key = 'magnati';
update beau_ph.providers set channel_label = 'In person · SDK', secrets = '{ADYEN_API_KEY,ADYEN_MERCHANT_ACCOUNT,ADYEN_HMAC_KEY}',
  onboarding = 'Adyen account plus an Adyen-built app; no standalone handoff app exists.',
  config_schema = '[
    {"key":"handoff_app","label":"App name","store":"settings","type":"text"},
    {"key":"handoff_url","label":"App link (optional)","store":"settings","type":"url"}]'::jsonb where key = 'adyen';

-- ---------- 2. merchant methods: persisted configuration ----------
alter table beau_ph.merchant_methods add column if not exists currencies text[];                                   -- null = needs configuration
alter table beau_ph.merchant_methods add column if not exists intents    text[];                                   -- null = every intent of the provider
alter table beau_ph.merchant_methods add column if not exists limits     jsonb not null default '{}'::jsonb check (beau_ph.no_secret_keys(limits));  -- {"AED":{"min":100,"max":2000000}} minor units
alter table beau_ph.merchant_methods add column if not exists listed     boolean not null default true;            -- false = removed from Finance, history kept
create or replace function beau_ph.intents_valid(p text[])
returns boolean language sql immutable set search_path = '' as $$
  select p is null or not exists (select 1 from unnest(p) i where not beau_ph.is_intent(i))
$$;
alter table beau_ph.merchant_methods drop constraint if exists merchant_methods_intents_check;
alter table beau_ph.merchant_methods add constraint merchant_methods_intents_check check (beau_ph.intents_valid(intents));

-- ---------- 3. settlement destinations (distinct from payment methods) ----------
create table if not exists beau_ph.settlement_destinations (
  id          uuid primary key default gen_random_uuid(),
  merchant_id uuid not null references beau_ph.merchants(id) on delete cascade,
  key         text not null check (key ~ '^[a-z][a-z0-9_]{1,40}$'),
  label       text not null,
  kind        text not null check (kind in ('bank_account','psp_balance','wallet','other')),
  currency    text not null check (beau_ph.is_iso_currency(currency)),
  details     jsonb not null default '{}'::jsonb check (beau_ph.no_secret_keys(details)),   -- non-secret: bank name, country, masked account
  active      boolean not null default true,
  updated_by  text,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  unique (merchant_id, key)
);
create table if not exists beau_ph.method_settlements (
  merchant_method_id uuid not null references beau_ph.merchant_methods(id) on delete cascade,
  currency           text not null check (beau_ph.is_iso_currency(currency)),
  destination_id     uuid not null references beau_ph.settlement_destinations(id) on delete cascade,
  primary key (merchant_method_id, currency)
);
alter table beau_ph.settlement_destinations enable row level security;
alter table beau_ph.method_settlements      enable row level security;
revoke all on beau_ph.settlement_destinations, beau_ph.method_settlements from public, anon, authenticated;

-- ---------- 4. configuration audit: one row per changed field ----------
create table if not exists beau_ph.config_audit (
  id          uuid primary key default gen_random_uuid(),
  merchant_id uuid references beau_ph.merchants(id) on delete cascade,
  area        text not null check (area in ('merchant_method','settlement_destination','merchant_fx','fx_currency','fx_source')),
  entity      text not null,
  actor       text not null,
  changed_at  timestamptz not null default now(),
  field       text not null,
  old_value   jsonb check (beau_ph.no_secret_keys(old_value)),
  new_value   jsonb check (beau_ph.no_secret_keys(new_value))
);
create index if not exists config_audit_merchant_idx on beau_ph.config_audit (merchant_id, changed_at desc);
alter table beau_ph.config_audit enable row level security;
revoke all on beau_ph.config_audit from public, anon, authenticated;

-- Compares two flat-ish JSON objects and records one audit row per changed key
-- (nested objects such as instructions/settings are compared key by key).
create or replace function beau_ph.audit_diff(p_merchant_id uuid, p_area text, p_entity text, p_actor text, p_old jsonb, p_new jsonb)
returns int language plpgsql volatile security definer set search_path = '' as $$
declare k text; n int := 0; ov jsonb; nv jsonb; sub text;
begin
  for k in select distinct key from (select jsonb_object_keys(coalesce(p_old, '{}'::jsonb)) key union select jsonb_object_keys(coalesce(p_new, '{}'::jsonb))) x loop
    ov := p_old -> k; nv := p_new -> k;
    if ov is distinct from nv then
      if jsonb_typeof(coalesce(ov, nv)) = 'object' and (ov is null or jsonb_typeof(ov) = 'object') and (nv is null or jsonb_typeof(nv) = 'object') then
        for sub in select distinct key from (select jsonb_object_keys(coalesce(ov, '{}'::jsonb)) key union select jsonb_object_keys(coalesce(nv, '{}'::jsonb))) y loop
          if (ov -> sub) is distinct from (nv -> sub) then
            insert into beau_ph.config_audit (merchant_id, area, entity, actor, field, old_value, new_value)
            values (p_merchant_id, p_area, p_entity, coalesce(p_actor, 'system'), k || '.' || sub, ov -> sub, nv -> sub);
            n := n + 1;
          end if;
        end loop;
      else
        insert into beau_ph.config_audit (merchant_id, area, entity, actor, field, old_value, new_value)
        values (p_merchant_id, p_area, p_entity, coalesce(p_actor, 'system'), k, ov, nv);
        n := n + 1;
      end if;
    end if;
  end loop;
  return n;
end $$;

-- ---------- 5. merchant method configuration (single write path, audited, capability-bounded) ----------
create or replace function beau_ph.merchant_method_json(mm beau_ph.merchant_methods)
returns jsonb language sql stable set search_path = '' as $$
  select jsonb_build_object('id', mm.id, 'provider', mm.provider_key, 'enabled', mm.enabled, 'listed', mm.listed, 'currency', mm.currency,
                            'countries', to_jsonb(mm.countries), 'currencies', to_jsonb(mm.currencies), 'intents', to_jsonb(mm.intents),
                            'capabilities', to_jsonb(mm.capabilities), 'limits', mm.limits, 'instructions', mm.instructions, 'settings', mm.settings,
                            'settlement', (select coalesce(jsonb_object_agg(ms.currency, d.key), '{}'::jsonb)
                                             from beau_ph.method_settlements ms join beau_ph.settlement_destinations d on d.id = ms.destination_id
                                            where ms.merchant_method_id = mm.id),
                            'updated_by', mm.updated_by, 'updated_at', mm.updated_at, 'created_at', mm.created_at)
$$;

-- p: {enabled, listed, currency, countries[], currencies[], intents[], capabilities[], limits{}, instructions{}, settings{}, settlement{ccy: destination key}}
-- Keys absent from p keep their current value; an explicit null clears (countries/currencies null = needs configuration).
create or replace function beau_ph.merchant_method_configure(p_merchant_key text, p_provider text, p jsonb, p_actor text)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare m beau_ph.merchants%rowtype; pv beau_ph.providers%rowtype; cur beau_ph.merchant_methods%rowtype; nxt beau_ph.merchant_methods%rowtype;
  v_countries text[]; v_currencies text[]; v_intents text[]; v_caps text[]; v_limits jsonb; v_ins jsonb; v_set jsonb; v_settle jsonb; k text; d beau_ph.settlement_destinations%rowtype;
  old_json jsonb; new_json jsonb; x text;
begin
  select * into m from beau_ph.merchants where key = p_merchant_key;
  if not found then raise exception 'unknown merchant' using errcode = 'P0002'; end if;
  select * into pv from beau_ph.providers where key = p_provider;
  if not found then raise exception 'unknown provider' using errcode = '22023'; end if;
  if p is null or jsonb_typeof(p) <> 'object' then raise exception 'configuration object required' using errcode = '22023'; end if;
  select * into cur from beau_ph.merchant_methods where merchant_id = m.id and provider_key = p_provider;
  old_json := case when cur.id is null then null else beau_ph.merchant_method_json(cur) end;

  -- arrays: absent = keep; null = clear; values normalised to upper case and validated
  v_countries  := case when p ? 'countries'  then (select array_agg(distinct upper(btrim(e))) from jsonb_array_elements_text(nullif(p -> 'countries',  'null'::jsonb)) e) else cur.countries  end;
  v_currencies := case when p ? 'currencies' then (select array_agg(distinct upper(btrim(e))) from jsonb_array_elements_text(nullif(p -> 'currencies', 'null'::jsonb)) e) else cur.currencies end;
  v_intents    := case when p ? 'intents'    then (select array_agg(distinct lower(btrim(e))) from jsonb_array_elements_text(nullif(p -> 'intents',    'null'::jsonb)) e) else cur.intents    end;
  v_caps       := case when p ? 'capabilities' then (select array_agg(distinct lower(btrim(e))) from jsonb_array_elements_text(nullif(p -> 'capabilities', 'null'::jsonb)) e) else cur.capabilities end;
  if v_countries  is not null and exists (select 1 from unnest(v_countries)  c where not beau_ph.is_iso_country(c))  then raise exception 'countries must be ISO 3166-1 alpha-2 codes' using errcode = '22023'; end if;
  if v_currencies is not null and exists (select 1 from unnest(v_currencies) c where not beau_ph.is_iso_currency(c)) then raise exception 'currencies must be ISO 4217 codes' using errcode = '22023'; end if;
  if v_intents    is not null and exists (select 1 from unnest(v_intents)    i where not beau_ph.is_intent(i))       then raise exception 'unknown intent' using errcode = '22023'; end if;
  if v_caps is not null and exists (select 1 from unnest(v_caps) c where not exists (select 1 from beau_ph.provider_capabilities pc where pc.provider_key = p_provider and pc.capability = c)) then
    raise exception 'capability not offered by provider %', p_provider using errcode = '22023';
  end if;
  -- a merchant can narrow a provider, never broaden it
  if not beau_ph.array_is_subset(v_countries,  pv.countries)  then raise exception 'countries outside provider % coverage', p_provider using errcode = 'P0003'; end if;
  if not beau_ph.array_is_subset(v_currencies, pv.currencies) then raise exception 'currencies outside provider % coverage', p_provider using errcode = 'P0003'; end if;
  if not beau_ph.array_is_subset(v_intents,    pv.intents)    then raise exception 'intents outside provider % support', p_provider using errcode = 'P0003'; end if;

  v_limits := case when p ? 'limits' then coalesce(p -> 'limits', '{}'::jsonb) else coalesce(cur.limits, '{}'::jsonb) end;
  if jsonb_typeof(v_limits) <> 'object' then raise exception 'limits must be an object keyed by currency' using errcode = '22023'; end if;
  for k in select jsonb_object_keys(v_limits) loop
    if not beau_ph.is_iso_currency(k) then raise exception 'limits keyed by ISO currency' using errcode = '22023'; end if;
    if (v_limits -> k ->> 'min') is not null and (v_limits -> k ->> 'min')::numeric < 0 then raise exception 'minimum must be >= 0' using errcode = '22023'; end if;
    if (v_limits -> k ->> 'max') is not null and (v_limits -> k ->> 'min') is not null and (v_limits -> k ->> 'max')::numeric < (v_limits -> k ->> 'min')::numeric then
      raise exception 'maximum below minimum for %', k using errcode = '22023';
    end if;
  end loop;
  v_ins := case when p ? 'instructions' then coalesce(p -> 'instructions', '{}'::jsonb) else coalesce(cur.instructions, '{}'::jsonb) end;
  v_set := case when p ? 'settings'     then coalesce(p -> 'settings',     '{}'::jsonb) else coalesce(cur.settings,     '{}'::jsonb) end;
  if not beau_ph.no_secret_keys(v_ins) or not beau_ph.no_secret_keys(v_set) or not beau_ph.no_secret_keys(v_limits) then
    raise exception 'secrets are never stored in merchant configuration' using errcode = '22023';
  end if;

  insert into beau_ph.merchant_methods (merchant_id, provider_key, enabled, listed, currency, countries, currencies, intents, capabilities, limits, instructions, settings, updated_by)
  values (m.id, p_provider,
          coalesce((p ->> 'enabled')::boolean, cur.enabled, false),
          coalesce((p ->> 'listed')::boolean, cur.listed, true),
          case when p ? 'currency' then nullif(upper(p ->> 'currency'), '') else cur.currency end,
          v_countries, v_currencies, v_intents, v_caps, v_limits, jsonb_strip_nulls(v_ins), jsonb_strip_nulls(v_set), p_actor)
  on conflict (merchant_id, provider_key) do update set
    enabled = excluded.enabled, listed = excluded.listed, currency = excluded.currency, countries = excluded.countries, currencies = excluded.currencies,
    intents = excluded.intents, capabilities = excluded.capabilities, limits = excluded.limits, instructions = excluded.instructions, settings = excluded.settings,
    updated_by = excluded.updated_by, updated_at = now()
  returning * into nxt;

  -- settlement mapping: {currency: destination key}; a destination must belong to the merchant and be in that currency
  if p ? 'settlement' then
    v_settle := coalesce(p -> 'settlement', '{}'::jsonb);
    delete from beau_ph.method_settlements where merchant_method_id = nxt.id;
    for k in select jsonb_object_keys(v_settle) loop
      if v_settle ->> k is null or v_settle ->> k = '' then continue; end if;
      select * into d from beau_ph.settlement_destinations where merchant_id = m.id and key = v_settle ->> k;
      if not found then raise exception 'unknown settlement destination %', v_settle ->> k using errcode = '22023'; end if;
      if d.currency <> upper(k) then raise exception 'destination % settles %, not %', d.key, d.currency, k using errcode = '22023'; end if;
      insert into beau_ph.method_settlements (merchant_method_id, currency, destination_id) values (nxt.id, upper(k), d.id);
    end loop;
  end if;

  new_json := beau_ph.merchant_method_json(nxt);
  perform beau_ph.audit_diff(m.id, 'merchant_method', p_provider, p_actor,
                             coalesce(old_json, '{}'::jsonb) - 'updated_at' - 'updated_by' - 'created_at' - 'id',
                             new_json - 'updated_at' - 'updated_by' - 'created_at' - 'id');
  return new_json;
end $$;

-- Legacy signature kept for existing callers and suites. A NEW row copies the
-- provider's explicit coverage when the provider has one (a real, visible
-- configuration, not a fallback at read time); a provider with open coverage
-- (Stripe) leaves countries/currencies null = needs configuration.
create or replace function beau_ph.merchant_method_set(p_merchant_key text, p_provider text, p_enabled boolean, p_currency text,
                                                       p_instructions jsonb, p_settings jsonb, p_countries text[], p_updated_by text)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare m beau_ph.merchants%rowtype; pv beau_ph.providers%rowtype; cur beau_ph.merchant_methods%rowtype; cfg jsonb;
begin
  select * into m from beau_ph.merchants where key = p_merchant_key;
  if not found then raise exception 'unknown merchant' using errcode = 'P0002'; end if;
  select * into pv from beau_ph.providers where key = p_provider;
  if not found then raise exception 'unknown provider' using errcode = '22023'; end if;
  select * into cur from beau_ph.merchant_methods where merchant_id = m.id and provider_key = p_provider;
  cfg := jsonb_build_object('enabled', coalesce(p_enabled, false), 'currency', nullif(upper(p_currency), ''),
                            'instructions', coalesce(p_instructions, '{}'::jsonb), 'settings', coalesce(p_settings, '{}'::jsonb));
  if p_countries is not null then cfg := cfg || jsonb_build_object('countries', to_jsonb(p_countries));
  elsif cur.id is null and pv.countries is not null then cfg := cfg || jsonb_build_object('countries', to_jsonb(pv.countries)); end if;
  if cur.id is null then
    if pv.currencies is not null then cfg := cfg || jsonb_build_object('currencies', to_jsonb(pv.currencies));
    elsif nullif(upper(p_currency), '') is not null then cfg := cfg || jsonb_build_object('currencies', to_jsonb(array[upper(p_currency)])); end if;
  end if;
  return beau_ph.merchant_method_configure(p_merchant_key, p_provider, cfg, p_updated_by) - 'settlement';
end $$;

-- "Remove": history keeps the row (deactivated + unlisted); a never-used configuration is deleted.
create or replace function beau_ph.merchant_method_remove(p_merchant_key text, p_provider text, p_actor text)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare m beau_ph.merchants%rowtype; cur beau_ph.merchant_methods%rowtype; n int;
begin
  select * into m from beau_ph.merchants where key = p_merchant_key;
  if not found then raise exception 'unknown merchant' using errcode = 'P0002'; end if;
  select * into cur from beau_ph.merchant_methods where merchant_id = m.id and provider_key = p_provider;
  if not found then raise exception 'method not configured' using errcode = 'P0002'; end if;
  select count(*) into n from beau_ph.payment_requests where merchant_id = m.id and provider_key = p_provider;
  if n > 0 then
    return beau_ph.merchant_method_configure(p_merchant_key, p_provider, '{"enabled":false,"listed":false}'::jsonb, p_actor) || jsonb_build_object('removed', 'unlisted', 'history', n);
  end if;
  perform beau_ph.audit_diff(m.id, 'merchant_method', p_provider, p_actor, beau_ph.merchant_method_json(cur) - 'updated_at' - 'updated_by' - 'created_at' - 'id', '{}'::jsonb);
  delete from beau_ph.merchant_methods where id = cur.id;
  return jsonb_build_object('provider', p_provider, 'removed', 'deleted', 'history', 0);
end $$;

-- ---------- 6. settlement destinations ----------
create or replace function beau_ph.settlement_destination_json(d beau_ph.settlement_destinations)
returns jsonb language sql stable set search_path = '' as $$
  select jsonb_build_object('id', d.id, 'key', d.key, 'label', d.label, 'kind', d.kind, 'currency', d.currency, 'details', d.details, 'active', d.active,
                            'updated_by', d.updated_by, 'updated_at', d.updated_at,
                            'used_by', (select coalesce(jsonb_agg(distinct mm.provider_key), '[]'::jsonb) from beau_ph.method_settlements ms join beau_ph.merchant_methods mm on mm.id = ms.merchant_method_id where ms.destination_id = d.id))
$$;
create or replace function beau_ph.settlement_destination_set(p_merchant_key text, p jsonb, p_actor text)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare m beau_ph.merchants%rowtype; cur beau_ph.settlement_destinations%rowtype; nxt beau_ph.settlement_destinations%rowtype; k text;
begin
  select * into m from beau_ph.merchants where key = p_merchant_key;
  if not found then raise exception 'unknown merchant' using errcode = 'P0002'; end if;
  k := lower(btrim(p ->> 'key'));
  if k !~ '^[a-z][a-z0-9_]{1,40}$' then raise exception 'destination key: lower-case letters, digits, underscore' using errcode = '22023'; end if;
  if not beau_ph.no_secret_keys(p -> 'details') then raise exception 'secrets are never stored in a settlement destination' using errcode = '22023'; end if;
  select * into cur from beau_ph.settlement_destinations where merchant_id = m.id and key = k;
  insert into beau_ph.settlement_destinations (merchant_id, key, label, kind, currency, details, active, updated_by)
  values (m.id, k, coalesce(nullif(btrim(p ->> 'label'), ''), cur.label, k), coalesce(p ->> 'kind', cur.kind, 'bank_account'),
          coalesce(nullif(upper(p ->> 'currency'), ''), cur.currency), coalesce(p -> 'details', cur.details, '{}'::jsonb), coalesce((p ->> 'active')::boolean, cur.active, true), p_actor)
  on conflict (merchant_id, key) do update set label = excluded.label, kind = excluded.kind, currency = excluded.currency, details = excluded.details,
    active = excluded.active, updated_by = excluded.updated_by, updated_at = now()
  returning * into nxt;
  perform beau_ph.audit_diff(m.id, 'settlement_destination', k, p_actor,
                             case when cur.id is null then '{}'::jsonb else beau_ph.settlement_destination_json(cur) - 'updated_at' - 'updated_by' - 'id' - 'used_by' end,
                             beau_ph.settlement_destination_json(nxt) - 'updated_at' - 'updated_by' - 'id' - 'used_by');
  return beau_ph.settlement_destination_json(nxt);
end $$;
create or replace function beau_ph.settlement_destination_remove(p_merchant_key text, p_key text, p_actor text)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare m beau_ph.merchants%rowtype; cur beau_ph.settlement_destinations%rowtype;
begin
  select * into m from beau_ph.merchants where key = p_merchant_key;
  if not found then raise exception 'unknown merchant' using errcode = 'P0002'; end if;
  select * into cur from beau_ph.settlement_destinations where merchant_id = m.id and key = p_key;
  if not found then raise exception 'unknown destination' using errcode = 'P0002'; end if;
  if exists (select 1 from beau_ph.method_settlements where destination_id = cur.id) then
    -- still mapped: deactivate, never orphan a rail's settlement
    return beau_ph.settlement_destination_set(p_merchant_key, jsonb_build_object('key', p_key, 'active', false), p_actor) || '{"removed":"deactivated"}'::jsonb;
  end if;
  perform beau_ph.audit_diff(m.id, 'settlement_destination', p_key, p_actor, beau_ph.settlement_destination_json(cur) - 'updated_at' - 'updated_by' - 'id' - 'used_by', '{}'::jsonb);
  delete from beau_ph.settlement_destinations where id = cur.id;
  return jsonb_build_object('key', p_key, 'removed', 'deleted');
end $$;
create or replace function beau_ph.settlement_destinations_list(p_merchant_key text)
returns jsonb language sql stable security definer set search_path = '' as $$
  select coalesce(jsonb_agg(beau_ph.settlement_destination_json(d) order by d.currency, d.key), '[]'::jsonb)
    from beau_ph.settlement_destinations d join beau_ph.merchants m on m.id = d.merchant_id where m.key = p_merchant_key
$$;

-- ---------- 7. eligibility v3: merchant configuration is explicit; intent is a dimension ----------
drop function if exists beau_ph.method_matrix(text, text, text, jsonb, text, text);
drop function if exists beau_ph.eligible_methods(text, text, text, jsonb, text, text);
drop function if exists beau_ph.eligible_capabilities(text, text, text, jsonb, text, text);

create or replace function beau_ph.method_matrix(p_merchant_key text, p_country text default null, p_currency text default null, p_runtime jsonb default '{}'::jsonb,
                                                 p_platform text default null, p_initiated_by text default 'customer', p_intent text default null)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare m beau_ph.merchants%rowtype; ctry text; cur text; res jsonb := '[]'::jsonb; r record; c record;
  caps jsonb; cap_why text; any_ok boolean; first_conf text; first_cap text; prov_why text; health text;
  rt jsonb; configured boolean; rmode text; init text := coalesce(p_initiated_by, 'customer');
begin
  select * into m from beau_ph.merchants where key = p_merchant_key;
  if not found then raise exception 'unknown merchant' using errcode = 'P0002'; end if;
  if not beau_ph.is_platform(p_platform) then raise exception 'unknown platform %', p_platform using errcode = '22023'; end if;
  if init not in ('customer','merchant') then raise exception 'initiated_by must be customer or merchant' using errcode = '22023'; end if;
  if p_intent is not null and not beau_ph.is_intent(p_intent) then raise exception 'unknown intent %', p_intent using errcode = '22023'; end if;
  ctry := coalesce(nullif(upper(p_country), ''), m.country);
  cur  := coalesce(nullif(upper(p_currency), ''), m.default_currency);
  for r in
    select p.*, mm.id as mm_id, mm.enabled as m_enabled, mm.listed as m_listed, mm.countries as m_countries, mm.currencies as m_currencies,
           mm.intents as m_intents, mm.currency as m_currency, mm.limits as m_limits,
           mm.instructions as m_instructions, mm.settings as m_settings, mm.capabilities as m_caps
      from beau_ph.providers p
      left join beau_ph.merchant_methods mm on mm.provider_key = p.key and mm.merchant_id = m.id
     order by p.sort, p.key
  loop
    rt := coalesce(p_runtime -> r.key, '{}'::jsonb);
    configured := coalesce((rt ->> 'configured')::boolean, false); rmode := rt ->> 'mode';
    health := case when r.mm_id is null then 'not_added'
                   when r.m_countries is null or r.m_currencies is null then 'needs_configuration'
                   else 'configured' end;
    -- provider-level blockers apply to every capability; merchant configuration is the intersection with provider coverage
    prov_why := case when r.mm_id is null or not r.m_enabled or not r.m_listed                  then 'disabled'
                     when health = 'needs_configuration'                                         then 'needs_configuration'
                     when r.countries  is not null and not (ctry = any(r.countries))             then 'country'
                     when not (ctry = any(r.m_countries))                                        then 'country'
                     when r.currencies is not null and not (cur = any(r.currencies))             then 'currency'
                     when not (cur = any(r.m_currencies))                                        then 'currency'
                     when p_intent is not null and r.intents   is not null and not (p_intent = any(r.intents))   then 'intent'
                     when p_intent is not null and r.m_intents is not null and not (p_intent = any(r.m_intents)) then 'intent'
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
      'provider', r.key, 'display_name', r.display_name, 'kind', r.kind, 'channel_label', r.channel_label,
      'confirmation', coalesce(first_conf, r.confirmation), 'capability', first_cap,
      'readiness', r.readiness, 'enabled', coalesce(r.m_enabled, false) and coalesce(r.m_listed, false), 'health', health, 'eligible', any_ok,
      'reason', case when any_ok then null else coalesce(prov_why, (select e ->> 'reason' from jsonb_array_elements(caps) e limit 1), 'no_capability') end,
      'countries', to_jsonb(r.m_countries), 'currencies', to_jsonb(r.m_currencies), 'intents', to_jsonb(r.m_intents),
      'provider_countries', to_jsonb(r.countries), 'provider_currencies', to_jsonb(r.currencies), 'provider_intents', to_jsonb(r.intents),
      'settlement_currency', r.m_currency, 'limits', case when any_ok then coalesce(r.m_limits -> cur, '{}'::jsonb) else null end,
      'instructions', case when any_ok then coalesce(r.m_instructions, '{}'::jsonb) else null end,
      'settings',     case when any_ok then coalesce(r.m_settings, '{}'::jsonb) else null end,
      'capabilities', caps);
  end loop;
  return res;
end $$;

create or replace function beau_ph.eligible_methods(p_merchant_key text, p_country text default null, p_currency text default null, p_runtime jsonb default '{}'::jsonb,
                                                    p_platform text default null, p_initiated_by text default 'customer', p_intent text default null)
returns jsonb language sql stable security definer set search_path = '' as $$
  select coalesce(jsonb_agg(e), '[]'::jsonb)
    from jsonb_array_elements(beau_ph.method_matrix(p_merchant_key, p_country, p_currency, p_runtime, p_platform, p_initiated_by, p_intent)) e
   where (e ->> 'eligible')::boolean
$$;

create or replace function beau_ph.eligible_capabilities(p_merchant_key text, p_country text default null, p_currency text default null, p_runtime jsonb default '{}'::jsonb,
                                                         p_platform text default null, p_initiated_by text default 'merchant', p_intent text default null)
returns jsonb language sql stable security definer set search_path = '' as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'provider', e ->> 'provider', 'display_name', e ->> 'display_name', 'capability', c ->> 'capability',
           'confirmation', c ->> 'confirmation', 'handoff', (c ->> 'handoff')::boolean, 'in_person', (c ->> 'in_person')::boolean,
           'settlement_currency', e ->> 'settlement_currency', 'instructions', e -> 'instructions', 'settings', e -> 'settings')), '[]'::jsonb)
    from jsonb_array_elements(beau_ph.method_matrix(p_merchant_key, p_country, p_currency, p_runtime, p_platform, p_initiated_by, p_intent)) e,
         jsonb_array_elements(e -> 'capabilities') c
   where (c ->> 'eligible')::boolean
$$;

-- Which payment currencies can this payer be offered at all (any eligible rail), for the given context.
create or replace function beau_ph.eligible_currencies(p_merchant_key text, p_country text default null, p_runtime jsonb default '{}'::jsonb,
                                                       p_platform text default null, p_initiated_by text default 'customer', p_intent text default null)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare m beau_ph.merchants%rowtype; c text; res jsonb := '[]'::jsonb; provs jsonb;
begin
  select * into m from beau_ph.merchants where key = p_merchant_key;
  if not found then raise exception 'unknown merchant' using errcode = 'P0002'; end if;
  for c in select distinct x from beau_ph.merchant_methods mm, unnest(mm.currencies) x where mm.merchant_id = m.id and mm.enabled and mm.listed order by x loop
    provs := (select coalesce(jsonb_agg(e ->> 'provider'), '[]'::jsonb)
                from jsonb_array_elements(beau_ph.eligible_methods(p_merchant_key, p_country, c, p_runtime, p_platform, p_initiated_by, p_intent)) e);
    if jsonb_array_length(provs) > 0 then res := res || jsonb_build_object('currency', c, 'providers', provs); end if;
  end loop;
  return res;
end $$;

-- ---------- 8. requests carry intent, pricing origin and an FX quote reference ----------
alter table beau_ph.payment_requests add column if not exists intent           text check (intent is null or beau_ph.is_intent(intent));
alter table beau_ph.payment_requests add column if not exists pricing_amount   int  check (pricing_amount is null or pricing_amount > 0);
alter table beau_ph.payment_requests add column if not exists pricing_currency text check (pricing_currency is null or beau_ph.is_iso_currency(pricing_currency));
alter table beau_ph.payment_requests add column if not exists fx_quote_id      uuid;
update beau_ph.payment_requests set intent = case metadata ->> 'reason' when 'booking' then 'service' when 'session_pack' then 'package' when 'support' then 'support' else null end where intent is null;

create or replace function beau_ph.request_json(r beau_ph.payment_requests)
returns jsonb language sql stable set search_path = '' as $$
  select jsonb_build_object(
    'id', r.id, 'merchant_id', r.merchant_id, 'provider', r.provider_key,
    'capability', r.capability, 'channel', r.channel, 'initiated_by', r.initiated_by, 'platform', r.platform, 'intent', r.intent,
    'external_reference', r.external_reference, 'public_reference', r.public_reference,
    'amount', r.amount, 'currency', r.currency, 'customer_country', r.customer_country,
    'pricing_amount', r.pricing_amount, 'pricing_currency', r.pricing_currency, 'fx_quote_id', r.fx_quote_id,
    'status', r.status, 'provider_reference', r.provider_reference, 'payment_reference', r.payment_reference,
    'instructions', r.instructions, 'metadata', r.metadata,
    'paid_at', r.paid_at, 'expires_at', r.expires_at, 'created_at', r.created_at,
    'attempts', (select count(*) from beau_ph.payment_attempts a where a.request_id = r.id),
    'attempt', (select jsonb_build_object('n', a.n, 'provider_reference', a.provider_reference, 'redirect_url', a.redirect_url,
                                          'expires_at', a.expires_at, 'status', a.status)
                  from beau_ph.payment_attempts a where a.request_id = r.id and a.status = 'open'
                 order by a.created_at desc limit 1))
$$;

-- The FX quote hook is defined by the FX migration; until then a quote id is refused (no silent conversion).
create or replace function beau_ph.fx_quote_consume(p_quote_id uuid, p_merchant_id uuid, p_request_id uuid, p_amount int, p_currency text, p_pricing_amount int, p_pricing_currency text)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
begin
  raise exception 'fx not available' using errcode = 'P0003';
end $$;

drop function if exists beau_ph.create_request(text, text, text, text, int, text, text, timestamptz, jsonb, jsonb, text, text, text);
create or replace function beau_ph.create_request(
  p_merchant_key text, p_provider text, p_external_reference text, p_public_reference text,
  p_amount int, p_currency text, p_country text default null, p_expires_at timestamptz default null,
  p_metadata jsonb default '{}'::jsonb, p_runtime jsonb default '{}'::jsonb,
  p_capability text default null, p_platform text default null, p_initiated_by text default null,
  p_intent text default null, p_pricing_amount int default null, p_pricing_currency text default null, p_fx_quote_id uuid default null)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare m beau_ph.merchants%rowtype; pv beau_ph.providers%rowtype; r beau_ph.payment_requests%rowtype;
  mm beau_ph.merchant_methods%rowtype; cap beau_ph.provider_capabilities%rowtype; elig jsonb; ctry text; v_cap text; v_init text; v_status text; ins jsonb;
  v_intent text; lim jsonb; v_pricing_amount int; v_pricing_currency text;
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
  v_intent := coalesce(p_intent, case p_metadata ->> 'reason' when 'booking' then 'service' when 'session_pack' then 'package' when 'support' then 'support' else null end);
  if v_intent is not null and not beau_ph.is_intent(v_intent) then raise exception 'unknown intent %', v_intent using errcode = '22023'; end if;
  ctry := coalesce(nullif(upper(p_country), ''), m.country);
  v_cap := coalesce(p_capability, case pv.kind when 'online' then 'online_checkout'
                                               when 'manual' then case p_provider when 'bank_transfer' then 'bank_transfer' else 'manual_instructions' end
                                               else 'crypto' end);
  if not beau_ph.is_capability(v_cap) then raise exception 'unknown capability %', v_cap using errcode = '22023'; end if;
  v_init := coalesce(p_initiated_by, case when pv.kind = 'manual' or beau_ph.is_in_person(v_cap) then 'merchant' else 'customer' end);

  -- pricing origin: a payment in another currency than the commercial price needs a server-side FX quote
  v_pricing_currency := nullif(upper(p_pricing_currency), ''); v_pricing_amount := p_pricing_amount;
  if v_pricing_currency is not null and v_pricing_currency <> p_currency and p_fx_quote_id is null then
    raise exception 'an FX quote is required to pay % in %', v_pricing_currency, p_currency using errcode = 'P0003';
  end if;
  if v_pricing_currency is null or v_pricing_currency = p_currency then v_pricing_currency := p_currency; v_pricing_amount := p_amount; end if;

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

  select c into elig
    from jsonb_array_elements(beau_ph.method_matrix(p_merchant_key, ctry, p_currency, p_runtime, p_platform, v_init, v_intent)) e,
         jsonb_array_elements(e -> 'capabilities') c
   where e ->> 'provider' = p_provider and c ->> 'capability' = v_cap;
  if not coalesce((elig ->> 'eligible')::boolean, false) then
    raise exception 'provider % capability % not available: %', p_provider, v_cap, coalesce(elig ->> 'reason', 'no_capability') using errcode = 'P0003';
  end if;
  select * into mm  from beau_ph.merchant_methods where merchant_id = m.id and provider_key = p_provider;
  select * into cap from beau_ph.provider_capabilities where provider_key = p_provider and capability = v_cap;

  -- merchant limits for this currency (minor units)
  lim := coalesce(mm.limits -> p_currency, '{}'::jsonb);
  if (lim ->> 'min') is not null and p_amount < (lim ->> 'min')::int then raise exception 'amount below the % minimum for %', p_currency, p_provider using errcode = 'P0003'; end if;
  if (lim ->> 'max') is not null and p_amount > (lim ->> 'max')::int then raise exception 'amount above the % maximum for %', p_currency, p_provider using errcode = 'P0003'; end if;

  if cap.confirmation = 'operator' then
    v_status := 'pending';
    ins := coalesce(mm.instructions, '{}'::jsonb)
        || jsonb_build_object('reference', p_public_reference, 'amount', p_amount, 'currency', p_currency, 'settlement_currency', mm.currency, 'capability', v_cap)
        || case when cap.handoff then jsonb_build_object('handoff', true, 'handoff_app', mm.settings ->> 'handoff_app', 'handoff_url', mm.settings ->> 'handoff_url') else '{}'::jsonb end;
  else
    v_status := 'created'; ins := '{}'::jsonb;
  end if;

  insert into beau_ph.payment_requests (merchant_id, provider_key, capability, channel, initiated_by, platform, intent,
                                        external_reference, public_reference, amount, currency, customer_country,
                                        pricing_amount, pricing_currency, fx_quote_id,
                                        status, instructions, metadata, expires_at)
  values (m.id, p_provider, v_cap, case when beau_ph.is_in_person(v_cap) then 'in_person' else 'online' end, v_init, p_platform, v_intent,
          p_external_reference, p_public_reference, p_amount, p_currency, ctry,
          v_pricing_amount, v_pricing_currency, p_fx_quote_id,
          v_status, jsonb_strip_nulls(ins), coalesce(p_metadata, '{}'::jsonb), p_expires_at)
  returning * into r;
  -- the quote is consumed by exactly this request; a mismatch, an expired or a foreign quote is refused inside
  if p_fx_quote_id is not null then
    perform beau_ph.fx_quote_consume(p_fx_quote_id, m.id, r.id, p_amount, p_currency, v_pricing_amount, v_pricing_currency);
  end if;
  insert into beau_ph.payment_events (request_id, from_status, to_status, amount, currency, actor, evidence)
  values (r.id, null, r.status, r.amount, r.currency, 'system',
          jsonb_build_object('created', true, 'kind', pv.kind, 'capability', v_cap, 'channel', r.channel, 'intent', v_intent,
                             'pricing_amount', v_pricing_amount, 'pricing_currency', v_pricing_currency, 'fx_quote_id', p_fx_quote_id));
  return beau_ph.request_json(r);
end $$;

-- ---------- 9. operator screens: catalogue + merchant state, data-driven ----------
-- Finance > Payment methods: only what the merchant added (listed rows).
create or replace function beau_ph.merchant_methods_summary(p_merchant_key text)
returns jsonb language sql stable security definer set search_path = '' as $$
  select coalesce(jsonb_agg(jsonb_build_object(
      'provider', mm.provider_key, 'display_name', p.display_name, 'channel_label', p.channel_label, 'kind', p.kind, 'readiness', p.readiness,
      'enabled', mm.enabled, 'countries', to_jsonb(mm.countries), 'currencies', to_jsonb(mm.currencies), 'intents', to_jsonb(mm.intents),
      'health', case when mm.countries is null or mm.currencies is null then 'needs_configuration' else 'configured' end,
      'hint', (select string_agg('•••• ' || right(mm.instructions ->> (s ->> 'key'), 4), ' ')
                 from jsonb_array_elements(p.config_schema) s where (s ->> 'mask')::boolean and coalesce(mm.instructions ->> (s ->> 'key'), '') <> ''),
      'history', (select count(*) from beau_ph.payment_requests r where r.merchant_id = mm.merchant_id and r.provider_key = mm.provider_key),
      'updated_at', mm.updated_at, 'updated_by', mm.updated_by) order by p.sort, p.key), '[]'::jsonb)
    from beau_ph.merchant_methods mm join beau_ph.merchants m on m.id = mm.merchant_id join beau_ph.providers p on p.key = mm.provider_key
   where m.key = p_merchant_key and mm.listed
$$;

-- One method's full configuration for the editor (never a secret value; secrets are names + presence reported by the Edge runtime).
create or replace function beau_ph.merchant_method_get(p_merchant_key text, p_provider text)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare m beau_ph.merchants%rowtype; pv beau_ph.providers%rowtype; mm beau_ph.merchant_methods%rowtype;
begin
  select * into m from beau_ph.merchants where key = p_merchant_key;
  if not found then raise exception 'unknown merchant' using errcode = 'P0002'; end if;
  select * into pv from beau_ph.providers where key = p_provider;
  if not found then raise exception 'unknown provider' using errcode = 'P0002'; end if;
  select * into mm from beau_ph.merchant_methods where merchant_id = m.id and provider_key = p_provider;
  return jsonb_build_object(
    'provider', jsonb_build_object('key', pv.key, 'display_name', pv.display_name, 'kind', pv.kind, 'channel_label', pv.channel_label, 'readiness', pv.readiness,
                                   'confirmation', pv.confirmation, 'countries', to_jsonb(pv.countries), 'currencies', to_jsonb(pv.currencies), 'intents', to_jsonb(pv.intents),
                                   'secrets', to_jsonb(pv.secrets), 'config_schema', pv.config_schema, 'onboarding', pv.onboarding, 'notes', pv.notes,
                                   'capabilities', beau_ph.capabilities_json(pv.key)),
    'method', case when mm.id is null then null else beau_ph.merchant_method_json(mm) end,
    'destinations', beau_ph.settlement_destinations_list(p_merchant_key),
    'intents', jsonb_build_array('service','package','support','other'));
end $$;

-- BEAU PH > Rails: every provider BEAU PH knows, with the merchant's real state and activity.
create or replace function beau_ph.rails_overview(p_merchant_key text)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare m beau_ph.merchants%rowtype;
begin
  select * into m from beau_ph.merchants where key = p_merchant_key;
  if not found then raise exception 'unknown merchant' using errcode = 'P0002'; end if;
  return jsonb_build_object(
    'merchant', jsonb_build_object('key', m.key, 'name', m.name, 'country', m.country, 'default_currency', m.default_currency, 'mode', m.mode),
    'rails', (select coalesce(jsonb_agg(jsonb_build_object(
      'provider', p.key, 'display_name', p.display_name, 'kind', p.kind, 'channel_label', p.channel_label, 'confirmation', p.confirmation, 'readiness', p.readiness,
      'provider_countries', to_jsonb(p.countries), 'provider_currencies', to_jsonb(p.currencies), 'provider_intents', to_jsonb(p.intents),
      'secrets', to_jsonb(p.secrets), 'onboarding', p.onboarding, 'notes', p.notes, 'capabilities', beau_ph.capabilities_json(p.key),
      'merchant', case when mm.id is null then null else jsonb_build_object(
          'enabled', mm.enabled, 'listed', mm.listed, 'countries', to_jsonb(mm.countries), 'currencies', to_jsonb(mm.currencies), 'intents', to_jsonb(mm.intents),
          'settlement_currency', mm.currency, 'limits', mm.limits, 'updated_at', mm.updated_at, 'updated_by', mm.updated_by,
          'health', case when mm.countries is null or mm.currencies is null then 'needs_configuration' else 'configured' end) end,
      'activity', jsonb_build_object(
          'requests', (select count(*) from beau_ph.payment_requests r where r.merchant_id = m.id and r.provider_key = p.key),
          'paid',     (select count(*) from beau_ph.payment_requests r where r.merchant_id = m.id and r.provider_key = p.key and r.status in ('paid','refunded')),
          'last_paid_at', (select max(r.paid_at) from beau_ph.payment_requests r where r.merchant_id = m.id and r.provider_key = p.key),
          'last_event_at', (select max(e.received_at) from beau_ph.provider_events e where e.provider_key = p.key),
          'last_event_outcome', (select e.outcome from beau_ph.provider_events e where e.provider_key = p.key order by e.received_at desc limit 1)))
      order by p.sort, p.key), '[]'::jsonb) from beau_ph.providers p left join beau_ph.merchant_methods mm on mm.provider_key = p.key and mm.merchant_id = m.id));
end $$;

-- Provider events for one rail (evidence log, lazily loaded). Payloads are not returned — ids, types, outcomes only.
create or replace function beau_ph.rail_events(p_merchant_key text, p_provider text, p_limit int default 30)
returns jsonb language sql stable security definer set search_path = '' as $$
  select coalesce(jsonb_agg(jsonb_build_object('id', e.provider_event_id, 'type', e.event_type, 'outcome', e.outcome, 'received_at', e.received_at,
                                               'processed_at', e.processed_at, 'public_reference', r.public_reference) order by e.received_at desc), '[]'::jsonb)
    from (select * from beau_ph.provider_events pe
           where pe.provider_key = p_provider
             and (pe.request_id is null or exists (select 1 from beau_ph.payment_requests r join beau_ph.merchants m on m.id = r.merchant_id where r.id = pe.request_id and m.key = p_merchant_key))
           order by pe.received_at desc limit greatest(1, least(coalesce(p_limit, 30), 200))) e
    left join beau_ph.payment_requests r on r.id = e.request_id
$$;

create or replace function beau_ph.config_audit_list(p_merchant_key text, p_limit int default 100)
returns jsonb language sql stable security definer set search_path = '' as $$
  select coalesce(jsonb_agg(jsonb_build_object('area', a.area, 'entity', a.entity, 'actor', a.actor, 'changed_at', a.changed_at, 'field', a.field,
                                               'old_value', a.old_value, 'new_value', a.new_value) order by a.changed_at desc), '[]'::jsonb)
    from (select ca.* from beau_ph.config_audit ca join beau_ph.merchants m on m.id = ca.merchant_id where m.key = p_merchant_key
           order by ca.changed_at desc limit greatest(1, least(coalesce(p_limit, 100), 500))) a
$$;

-- ---------- 10. Coach Gari backfill: explicit configuration, no silent "any" ----------
do $$
declare mid uuid;
begin
  select id into mid from beau_ph.merchants where key = 'coach_gari';
  if mid is null then return; end if;
  -- Stripe: the audience Coach Gari already maps in cg_country_code(), the currencies seen on packs / services / orders
  update beau_ph.merchant_methods set
    countries  = coalesce(countries,  '{AE,AU,CA,CH,DE,EG,ES,FR,GB,GH,IN,IT,KE,MA,NG,QA,SA,US,ZA,ZW}'::text[]),
    currencies = coalesce(currencies, '{AED,USD}'::text[])
   where merchant_id = mid and provider_key = 'stripe';
  -- Aani: UAE / AED — the provider's own coverage, now the merchant's explicit configuration
  update beau_ph.merchant_methods set countries = coalesce(countries, '{AE}'::text[]), currencies = coalesce(currencies, '{AED}'::text[])
   where merchant_id = mid and provider_key = 'aani';
  -- any other existing row: settlement currency becomes the single enabled currency; countries from the provider when it has an explicit list
  update beau_ph.merchant_methods mm set
    countries  = coalesce(mm.countries, p.countries),
    currencies = coalesce(mm.currencies, case when mm.currency is not null then array[mm.currency] else p.currencies end)
    from beau_ph.providers p where p.key = mm.provider_key and mm.merchant_id = mid;
  insert into beau_ph.config_audit (merchant_id, area, entity, actor, field, old_value, new_value)
  select mid, 'merchant_method', mm.provider_key, 'migration:20260926', 'backfill', 'null'::jsonb,
         jsonb_build_object('countries', to_jsonb(mm.countries), 'currencies', to_jsonb(mm.currencies))
    from beau_ph.merchant_methods mm where mm.merchant_id = mid;
end $$;

-- ---------- 11. grants: definer functions, owner / service_role only ----------
revoke all on function beau_ph.audit_diff(uuid, text, text, text, jsonb, jsonb), beau_ph.merchant_method_configure(text, text, jsonb, text),
  beau_ph.merchant_method_remove(text, text, text), beau_ph.settlement_destination_set(text, jsonb, text), beau_ph.settlement_destination_remove(text, text, text),
  beau_ph.settlement_destinations_list(text), beau_ph.merchant_methods_summary(text), beau_ph.merchant_method_get(text, text), beau_ph.rails_overview(text),
  beau_ph.rail_events(text, text, int), beau_ph.config_audit_list(text, int), beau_ph.eligible_currencies(text, text, jsonb, text, text, text),
  beau_ph.method_matrix(text, text, text, jsonb, text, text, text), beau_ph.eligible_methods(text, text, text, jsonb, text, text, text),
  beau_ph.eligible_capabilities(text, text, text, jsonb, text, text, text),
  beau_ph.create_request(text, text, text, text, int, text, text, timestamptz, jsonb, jsonb, text, text, text, text, int, text, uuid),
  beau_ph.fx_quote_consume(uuid, uuid, uuid, int, text, int, text)
  from public, anon, authenticated;
grant execute on function beau_ph.audit_diff(uuid, text, text, text, jsonb, jsonb), beau_ph.merchant_method_configure(text, text, jsonb, text),
  beau_ph.merchant_method_remove(text, text, text), beau_ph.settlement_destination_set(text, jsonb, text), beau_ph.settlement_destination_remove(text, text, text),
  beau_ph.settlement_destinations_list(text), beau_ph.merchant_methods_summary(text), beau_ph.merchant_method_get(text, text), beau_ph.rails_overview(text),
  beau_ph.rail_events(text, text, int), beau_ph.config_audit_list(text, int), beau_ph.eligible_currencies(text, text, jsonb, text, text, text),
  beau_ph.method_matrix(text, text, text, jsonb, text, text, text), beau_ph.eligible_methods(text, text, text, jsonb, text, text, text),
  beau_ph.eligible_capabilities(text, text, text, jsonb, text, text, text),
  beau_ph.create_request(text, text, text, text, int, text, text, timestamptz, jsonb, jsonb, text, text, text, text, int, text, uuid),
  beau_ph.fx_quote_consume(uuid, uuid, uuid, int, text, int, text)
  to service_role;

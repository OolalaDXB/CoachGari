-- =====================================================================
-- BEAU PH — a newly added rail with open provider coverage starts in the
-- merchant's home market
--
-- A provider without a country restriction (Stripe, bank transfer) used to
-- leave a brand-new merchant row with countries = null, which now reads as
-- "needs configuration" and is not eligible anywhere — correct, but it
-- turned the legacy one-call set-up (Finance "Enable bank transfer") into a
-- silent no-show. The rail now starts with ONE explicit, persisted country:
-- the merchant's own. Still never "any"; the operator widens it in the
-- editor, and the audit trail shows the default as a real value.
-- Applies to the legacy 8-argument merchant_method_set() and to the host
-- payment_method_set() (new rows only; configured rows are untouched).
-- Forward migration only.
-- =====================================================================
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
  elsif cur.id is null then cfg := cfg || jsonb_build_object('countries', to_jsonb(coalesce(pv.countries, array[m.country]))); end if;
  if cur.id is null then
    if pv.currencies is not null then cfg := cfg || jsonb_build_object('currencies', to_jsonb(pv.currencies));
    elsif nullif(upper(p_currency), '') is not null then cfg := cfg || jsonb_build_object('currencies', to_jsonb(array[upper(p_currency)])); end if;
  end if;
  return beau_ph.merchant_method_configure(p_merchant_key, p_provider, cfg, p_updated_by) - 'settlement';
end $$;

create or replace function public.payment_method_set(p jsonb)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare e text := public.current_email(); m text := coalesce(p ->> 'method', 'aani'); pv beau_ph.providers%rowtype; row jsonb; ins jsonb := '{}'::jsonb; cfg jsonb := '{}'::jsonb;
  f jsonb; s jsonb; k text; v text; conf jsonb := '{}'::jsonb; prev jsonb; home text;
begin
  if not public.has_permission('finance:manage') then raise exception 'forbidden' using errcode = '42501'; end if;
  select * into pv from beau_ph.providers where key = m;
  if not found then raise exception 'unknown method' using errcode = '22023'; end if;
  f := coalesce(p -> 'fields', '{}'::jsonb);
  for s in select * from jsonb_array_elements(pv.config_schema) loop
    k := s ->> 'key';
    v := coalesce(f ->> k, case when p ? k then p ->> k end);
    v := nullif(btrim(coalesce(v, '')), '');
    if v is not null then
      if s ->> 'type' = 'select' and not (s -> 'options') ? v then raise exception 'invalid %', k using errcode = '22023'; end if;
      if s ->> 'type' = 'url' and v !~ '^[a-z][a-z0-9+.-]*:' then raise exception '% must be an app link or URL', k using errcode = '22023'; end if;
      if s ->> 'store' = 'settings' then cfg := cfg || jsonb_build_object(k, v); else ins := ins || jsonb_build_object(k, v); end if;
    end if;
  end loop;
  for k in select jsonb_object_keys(f) loop
    if not exists (select 1 from jsonb_array_elements(pv.config_schema) x where x ->> 'key' = k) then raise exception 'unknown field %', k using errcode = '22023'; end if;
  end loop;
  conf := jsonb_build_object('enabled', coalesce((p ->> 'enabled')::boolean, false), 'instructions', ins, 'settings', cfg);
  if p ? 'currency' or pv.kind = 'manual' or pv.kind = 'online' then
    conf := conf || jsonb_build_object('currency', case when m = 'stripe' then null else coalesce(nullif(p ->> 'currency', ''), 'AED') end);
  end if;
  if p ? 'countries'  then conf := conf || jsonb_build_object('countries',  p -> 'countries');  end if;
  if p ? 'currencies' then conf := conf || jsonb_build_object('currencies', p -> 'currencies'); end if;
  if p ? 'intents'    then conf := conf || jsonb_build_object('intents',    p -> 'intents');    end if;
  if p ? 'limits'     then conf := conf || jsonb_build_object('limits',     p -> 'limits');     end if;
  if p ? 'settlement' then conf := conf || jsonb_build_object('settlement', p -> 'settlement'); end if;
  if p ? 'capabilities' then conf := conf || jsonb_build_object('capabilities', p -> 'capabilities'); end if;
  -- a brand-new row starts with an explicit market: the provider's own coverage, or the merchant's home country
  if not exists (select 1 from beau_ph.merchant_methods mm join beau_ph.merchants mc on mc.id = mm.merchant_id where mc.key = 'coach_gari' and mm.provider_key = m) then
    select country into home from beau_ph.merchants where key = 'coach_gari';
    if not (conf ? 'countries') then conf := conf || jsonb_build_object('countries', to_jsonb(coalesce(pv.countries, array[home]))); end if;
    if not (conf ? 'currencies') then
      if pv.currencies is not null then conf := conf || jsonb_build_object('currencies', to_jsonb(pv.currencies));
      elsif conf ->> 'currency' is not null then conf := conf || jsonb_build_object('currencies', jsonb_build_array(conf ->> 'currency')); end if;
    end if;
  end if;
  prev := (select beau_ph.merchant_method_json(mm) from beau_ph.merchant_methods mm join beau_ph.merchants mc on mc.id = mm.merchant_id where mc.key = 'coach_gari' and mm.provider_key = m);
  row := beau_ph.merchant_method_configure('coach_gari', m, conf, e);
  insert into public.admin_audit (area, entity_id, action, changed_by, summary)
  values ('payment_method', m, 'set', e, jsonb_build_object('enabled', (row ->> 'enabled')::boolean, 'countries', row -> 'countries', 'currencies', row -> 'currencies',
                                                            'changed', (select coalesce(jsonb_agg(k2), '[]'::jsonb) from jsonb_object_keys(row - 'updated_at' - 'updated_by' - 'created_at' - 'id') k2
                                                                        where (prev -> k2) is distinct from (row -> k2))));
  return row;
end $$;

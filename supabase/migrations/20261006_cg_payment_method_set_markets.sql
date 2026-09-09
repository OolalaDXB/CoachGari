-- =====================================================================
-- Coach Gari host — enabling a rail that still has no market gives it one
--
-- "+ Add payment method" creates the merchant row disabled and without
-- markets (countries / currencies null = needs configuration). A save that
-- ENABLES such a row without naming its markets (the legacy flat call, or
-- an editor save that left them untouched) used to leave the rail enabled
-- but eligible nowhere — a silent no-show that also made a receipt on that
-- rail fail. The same rule as a brand-new row now applies to that save: the
-- provider's own coverage, or the merchant's home country; the provider's
-- currencies, or the settlement currency. Explicit values always win; a
-- disabled row is left as it is. Forward migration only.
-- =====================================================================
create or replace function public.payment_method_set(p jsonb)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare e text := public.current_email(); m text := coalesce(p ->> 'method', 'aani'); pv beau_ph.providers%rowtype; row jsonb; ins jsonb := '{}'::jsonb; cfg jsonb := '{}'::jsonb;
  f jsonb; s jsonb; k text; v text; conf jsonb := '{}'::jsonb; prev jsonb; home text; cur beau_ph.merchant_methods%rowtype;
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
  select mm.* into cur from beau_ph.merchant_methods mm join beau_ph.merchants mc on mc.id = mm.merchant_id where mc.key = 'coach_gari' and mm.provider_key = m;
  -- a rail without a market gets one explicit market when it is created or enabled: never "any", never a silent no-show
  if cur.id is null or ((conf ->> 'enabled')::boolean and (cur.countries is null or cur.currencies is null)) then
    select country into home from beau_ph.merchants where key = 'coach_gari';
    if not (conf ? 'countries') and (cur.id is null or cur.countries is null) then conf := conf || jsonb_build_object('countries', to_jsonb(coalesce(pv.countries, array[home]))); end if;
    if not (conf ? 'currencies') and (cur.id is null or cur.currencies is null) then
      if pv.currencies is not null then conf := conf || jsonb_build_object('currencies', to_jsonb(pv.currencies));
      elsif coalesce(conf ->> 'currency', cur.currency) is not null then conf := conf || jsonb_build_object('currencies', jsonb_build_array(coalesce(conf ->> 'currency', cur.currency))); end if;
    end if;
  end if;
  prev := case when cur.id is null then null else beau_ph.merchant_method_json(cur) end;
  row := beau_ph.merchant_method_configure('coach_gari', m, conf, e);
  insert into public.admin_audit (area, entity_id, action, changed_by, summary)
  values ('payment_method', m, 'set', e, jsonb_build_object('enabled', (row ->> 'enabled')::boolean, 'countries', row -> 'countries', 'currencies', row -> 'currencies',
                                                            'changed', (select coalesce(jsonb_agg(k2), '[]'::jsonb) from jsonb_object_keys(row - 'updated_at' - 'updated_by' - 'created_at' - 'id') k2
                                                                        where (prev -> k2) is distinct from (row -> k2))));
  return row;
end $$;

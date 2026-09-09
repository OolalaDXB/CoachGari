-- =====================================================================
-- BEAU PH core — a rail that cannot act reports why, before merchant state
--
-- method_matrix() named a placeholder / not-onboarded rail after the
-- merchant's configuration gap ("needs_configuration") when the merchant had
-- enabled it without markets. The structural reason comes first: a rail
-- whose every capability is "coming soon" is `coming_soon`; one whose
-- capabilities are not onboarded is `not_configured`; only a rail that could
-- act is described by the merchant's configuration or context.
-- Forward migration only.
-- =====================================================================
create or replace function beau_ph.method_matrix(p_merchant_key text, p_country text default null, p_currency text default null, p_runtime jsonb default '{}'::jsonb,
                                                 p_platform text default null, p_initiated_by text default 'customer', p_intent text default null)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare m beau_ph.merchants%rowtype; ctry text; cur text; res jsonb := '[]'::jsonb; r record; c record;
  caps jsonb; cap_why text; any_ok boolean; first_conf text; first_cap text; prov_why text; health text; struct_why text; n_caps int; n_placeholder int; n_dead int;
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
    prov_why := case when r.mm_id is null or not r.m_enabled or not r.m_listed                  then 'disabled'
                     when health = 'needs_configuration'                                         then 'needs_configuration'
                     when r.countries  is not null and not (ctry = any(r.countries))             then 'country'
                     when not (ctry = any(r.m_countries))                                        then 'country'
                     when r.currencies is not null and not (cur = any(r.currencies))             then 'currency'
                     when not (cur = any(r.m_currencies))                                        then 'currency'
                     when p_intent is not null and r.intents   is not null and not (p_intent = any(r.intents))   then 'intent'
                     when p_intent is not null and r.m_intents is not null and not (p_intent = any(r.m_intents)) then 'intent'
                     else null end;
    -- structural reasons: the rail could not act for anyone, whatever the merchant configured
    select count(*), count(*) filter (where pc.readiness = 'placeholder'), count(*) filter (where pc.readiness <> 'available')
      into n_caps, n_placeholder, n_dead from beau_ph.provider_capabilities pc where pc.provider_key = r.key;
    struct_why := case when n_caps > 0 and n_placeholder = n_caps then 'coming_soon'
                       when n_caps > 0 and n_dead = n_caps then 'not_configured' else null end;
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
      'reason', case when any_ok then null else coalesce(struct_why, prov_why, (select e ->> 'reason' from jsonb_array_elements(caps) e limit 1), 'no_capability') end,
      'countries', to_jsonb(r.m_countries), 'currencies', to_jsonb(r.m_currencies), 'intents', to_jsonb(r.m_intents),
      'provider_countries', to_jsonb(r.countries), 'provider_currencies', to_jsonb(r.currencies), 'provider_intents', to_jsonb(r.intents),
      'settlement_currency', r.m_currency, 'limits', case when any_ok then coalesce(r.m_limits -> cur, '{}'::jsonb) else null end,
      'instructions', case when any_ok then coalesce(r.m_instructions, '{}'::jsonb) else null end,
      'settings',     case when any_ok then coalesce(r.m_settings, '{}'::jsonb) else null end,
      'capabilities', caps);
  end loop;
  return res;
end $$;

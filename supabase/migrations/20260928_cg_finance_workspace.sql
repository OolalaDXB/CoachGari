-- =====================================================================
-- Coach Gari host — Finance (Transactions · Payment methods) and the
-- embedded BEAU PH workspace (Rails · FX), server side
--
-- Access: both launch users use these surfaces. Everything is gated on the
-- existing finance permissions — finance:view to read, finance:manage to
-- change — never on platform:admin. Authorisation is enforced here, in
-- SECURITY DEFINER functions, not in the page.
--
-- Extraction boundary: every function in this file is a thin host wrapper
-- around beau_ph.* with the merchant key fixed to 'coach_gari' and the
-- Coach Gari permission check in front. When BEAU PH becomes a service,
-- these wrappers point at its API and the beau_ph schema leaves with it.
--
-- Also here:
--   * finance_transactions(): one unified list across every rail, from the
--     host order joined to its BEAU PH request(s) — normalised status, type
--     (service / package / support), method, amount in the currency actually
--     collected. finance_transaction_detail(): everything about one order,
--     lazily. No CRM notes, no health data, no enquiry bodies.
--   * payment currency: cg_ph_request_for_order / _for_pack take an optional
--     payment currency; another currency than the order's needs a BEAU FX
--     quote (server-side, immutable, expiring) and the request carries both
--     the pricing origin and the quoted amount. report_view() returns the
--     payment options the payer may choose from.
--   * recompute_earning(): the earning is stamped with the currency actually
--     collected (the payment's), not the order's pricing currency.
--   * Gari's back-office access is provisioned (app_users + the launch set).
-- Forward migration only.
-- =====================================================================

-- ---------- 0. audit areas + Gari's access ----------
alter table public.admin_audit drop constraint if exists admin_audit_area_check;
alter table public.admin_audit add constraint admin_audit_area_check
  check (area in ('crm_contact','crm_note','body_measurement','permission','consent','merge','coaching_session','session_pack','block','report','payment','payment_method',
                  'beau_ph_rail','beau_ph_fx','settlement_destination'));

-- Launch access for the coach (CG-006 / CG-007 / CG-009 / CG-010 sets): identical business access, expressed as the granular permissions.
insert into public.app_users (email, display_name, party, active) values ('grej28roux@gmail.com', 'Gari', 'gari', true)
on conflict (email) do update set active = true;
insert into public.app_permissions (email, permission)
select 'grej28roux@gmail.com', p from unnest(array['coach:operations','client_profile:view','client_profile:manage','health_metrics:view','health_metrics:manage',
                                                   'coaching_sensitive:view','coaching_sensitive:manage','finance:view','finance:manage','analytics:view',
                                                   'catalog:view','catalog:manage']) p
on conflict do nothing;
insert into public.admin_audit (area, entity_id, action, changed_by, summary)
values ('permission', 'grej28roux@gmail.com', 'provision', 'migration:20260928', '{"launch_set":true}'::jsonb);

-- ---------- 1. the ledger is in the collected currency ----------
create or replace function public.recompute_earning(p_order_id uuid)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare
  o public.orders%rowtype; p public.payments%rowtype;
  v_refunds int; v_chargebacks int; v_tax int := 0; v_net int; v_comm int; v_pay int; v_rate numeric(6,4) := 0.1000;
  e public.partner_earnings%rowtype;
begin
  select * into o from public.orders where id = p_order_id;
  if not found then raise exception 'order not found' using errcode = 'P0002'; end if;
  select * into p from public.payments where order_id = o.id and status = 'succeeded' order by paid_at desc nulls last limit 1;
  if not found then return null; end if;
  select coalesce(sum(amount), 0) into v_refunds from public.refunds where order_id = o.id and status = 'succeeded';
  select coalesce(sum(amount), 0) into v_chargebacks from public.chargebacks where order_id = o.id and status = 'lost';
  select coalesce((select commission_rate from public.partner_earnings where order_id = o.id), 0.1000) into v_rate;
  v_net  := p.amount - p.fee_amount - v_refunds - v_chargebacks - v_tax;
  v_comm := greatest(0, round(v_net * v_rate))::int;
  v_pay  := v_net - v_comm;
  insert into public.partner_earnings (order_id, payment_id, currency, gross_amount, stripe_fee, refund_amount, chargeback_amount,
                                       tax_amount, net_collected, commission_rate, oolala_commission, gari_payable)
  values (o.id, p.id, coalesce(p.currency, o.currency), p.amount, p.fee_amount, v_refunds, v_chargebacks, v_tax, v_net, v_rate, v_comm, v_pay)
  on conflict (order_id) do update
    set payment_id = excluded.payment_id, currency = excluded.currency, gross_amount = excluded.gross_amount, stripe_fee = excluded.stripe_fee,
        refund_amount = excluded.refund_amount, chargeback_amount = excluded.chargeback_amount, tax_amount = excluded.tax_amount,
        net_collected = excluded.net_collected, oolala_commission = excluded.oolala_commission, gari_payable = excluded.gari_payable,
        adjusted_at = case when public.partner_earnings.status = 'settled'
                            and (public.partner_earnings.net_collected <> excluded.net_collected) then now()
                           else public.partner_earnings.adjusted_at end
  returning * into e;
  return to_jsonb(e);
end $$;

-- finance_orders(): + ledger_currency (the earning's currency) so the ledger table never labels a collected amount with the pricing currency
drop function if exists public.finance_orders();
create function public.finance_orders()
returns table(
  id uuid, reference text, status text, currency text, gross_amount integer,
  paid_at timestamptz, created_at timestamptz, stripe_checkout_session_id text,
  booking_reference text, session_start_at timestamptz, session_timezone text,
  booking_status text, delivery_mode text, service_slug text, service_title text,
  customer_hint text, stripe_fee integer, refund_amount integer, chargeback_amount integer,
  net_collected integer, oolala_commission integer, gari_payable integer,
  earning_status text, settlement_id uuid, adjusted_at timestamptz,
  order_reason text, pack_reference text, crm_contact_id uuid, fee_known boolean, ledger_currency text)
language plpgsql stable security definer set search_path to '' as $function$
begin
  if not public.has_permission('finance:view') then raise exception 'forbidden' using errcode = '42501'; end if;
  return query
    select o.id, o.reference, o.status, o.currency, o.gross_amount, o.paid_at, o.created_at, o.stripe_checkout_session_id,
           b.reference, b.start_at, b.session_timezone, b.status, b.delivery_mode,
           coalesce(b.service_slug, s.slug),
           coalesce(o.service_title, b.service_title, s.title, p.title),
           public.mask_contact(coalesce(b.customer_contact, c.email, o.customer_contact)),
           pe.stripe_fee, pe.refund_amount, pe.chargeback_amount, pe.net_collected, pe.oolala_commission, pe.gari_payable,
           pe.status, pe.settlement_id, pe.adjusted_at,
           coalesce(o.order_reason, case when o.booking_id is not null then 'booking' else 'session_pack' end),
           p.public_ref,
           coalesce(b.crm_contact_id, p.crm_contact_id),
           pm.fee_known, coalesce(pe.currency, o.currency)
    from public.orders o
    left join public.bookings b on b.id = o.booking_id
    left join public.services s on s.id = b.service_id
    left join public.session_packs p on p.id = o.session_pack_id
    left join public.crm_contacts c on c.id = p.crm_contact_id
    left join public.partner_earnings pe on pe.order_id = o.id
    left join public.payments pm on pm.id = pe.payment_id
    order by o.created_at desc;
end $function$;
revoke all on function public.finance_orders() from public;
revoke all on function public.finance_orders() from anon;
grant execute on function public.finance_orders() to authenticated, service_role;

-- ---------- 2. Finance > Transactions ----------
create or replace function public.finance_transactions(p_limit int default 200)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
begin
  if not public.has_permission('finance:view') then raise exception 'forbidden' using errcode = '42501'; end if;
  return coalesce((select jsonb_agg(row_to_json(t)::jsonb order by t.created_at desc) from (
    select o.reference, o.created_at, o.paid_at,
           coalesce(b.reference, sp.public_ref, o.reference) as public_reference,
           case coalesce(o.order_reason, case when o.booking_id is not null then 'booking' else 'session_pack' end)
                when 'booking' then 'service' when 'session_pack' then 'package' when 'support' then 'support' else 'other' end as type,
           public.mask_contact(coalesce(b.customer_contact, c.email, o.customer_contact)) as customer_hint,
           coalesce(b.crm_contact_id, sp.crm_contact_id) as crm_contact_id,
           coalesce(o.service_title, b.service_title, sp.title) as item,
           coalesce(r.provider_key, pm.provider) as method,
           coalesce(pv.display_name, pm.provider) as method_label,
           coalesce(pv.kind, case when pm.provider is not null then 'manual' end) as method_kind,
           coalesce(r.amount, pm.amount, o.gross_amount) as amount,
           coalesce(r.currency, pm.currency, o.currency) as currency,
           o.gross_amount as pricing_amount, o.currency as pricing_currency,
           (r.pricing_currency is not null and r.pricing_currency <> r.currency) as fx,
           coalesce(r.status, case o.status when 'pending_payment' then 'created' when 'paid' then 'paid' when 'refunded' then 'refunded'
                                            when 'partially_refunded' then 'paid' when 'cancelled' then 'cancelled' when 'expired' then 'expired' else o.status end) as status,
           o.status as order_status,
           pe.refund_amount, pe.chargeback_amount, pe.status as earning_status, pm.fee_known,
           case when r.status in ('pending','requires_action') and pv.kind = 'manual' then 'confirm_receipt'
                when pe.status = 'open' and pm.fee_known = false then 'fee_pending'
                when o.status = 'partially_refunded' then 'partial_refund' else null end as action,
           r.public_reference as ph_reference, r.id as ph_request_id, r.payment_reference as provider_reference,
           (select count(*) from beau_ph.reconciliations rc where rc.request_id = r.id) > 0 as reconciled,
           nullif(r.metadata ->> 'message', '') as support_message
      from public.orders o
      left join public.bookings b on b.id = o.booking_id
      left join public.session_packs sp on sp.id = o.session_pack_id
      left join public.crm_contacts c on c.id = sp.crm_contact_id
      left join lateral (select pr.* from beau_ph.payment_requests pr join beau_ph.merchants m on m.id = pr.merchant_id
                          where m.key = 'coach_gari' and pr.external_reference = o.reference
                          order by case pr.status when 'paid' then 0 when 'refunded' then 0 when 'pending' then 1 when 'requires_action' then 1 when 'created' then 2 else 3 end, pr.created_at desc
                          limit 1) r on true
      left join beau_ph.providers pv on pv.key = r.provider_key
      left join lateral (select * from public.payments p where p.order_id = o.id and p.status = 'succeeded' order by p.paid_at desc nulls last limit 1) pm on true
      left join public.partner_earnings pe on pe.order_id = o.id
     order by o.created_at desc limit greatest(1, least(coalesce(p_limit, 200), 1000))) t), '[]'::jsonb);
end $$;
revoke execute on function public.finance_transactions(int) from public, anon;
grant  execute on function public.finance_transactions(int) to authenticated, service_role;

create or replace function public.finance_transaction_detail(p_reference text)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare o public.orders%rowtype; b public.bookings%rowtype; sp public.session_packs%rowtype; reqs jsonb; pay jsonb; earn jsonb; refunds jsonb; cbs jsonb;
begin
  if not public.has_permission('finance:view') then raise exception 'forbidden' using errcode = '42501'; end if;
  select * into o from public.orders where reference = p_reference;
  if not found then raise exception 'order not found' using errcode = 'P0002'; end if;
  if o.booking_id is not null then select * into b from public.bookings where id = o.booking_id; end if;
  if o.session_pack_id is not null then select * into sp from public.session_packs where id = o.session_pack_id; end if;
  reqs := (select coalesce(jsonb_agg((rq - 'metadata' - 'instructions')
              || jsonb_build_object('events', beau_ph.request_events((rq ->> 'id')::uuid, 'coach_gari'),
                                    'reconciled', exists (select 1 from beau_ph.reconciliations rc where rc.request_id = (rq ->> 'id')::uuid),
                                    'fx_quote', (select beau_ph.fx_quote_json(q) from beau_ph.fx_quotes q where q.id = (rq ->> 'fx_quote_id')::uuid),
                                    'support_message', nullif(rq -> 'metadata' ->> 'message', ''))), '[]'::jsonb)
             from jsonb_array_elements(beau_ph.requests_for('coach_gari', o.reference)) rq);
  pay := (select coalesce(jsonb_agg(jsonb_build_object('id', p.id, 'provider', p.provider, 'amount', p.amount, 'currency', p.currency, 'fee_amount', p.fee_amount, 'fee_known', p.fee_known,
                                                       'status', p.status, 'paid_at', p.paid_at, 'capability', p.capability, 'note', p.note,
                                                       'provider_refs', jsonb_strip_nulls(jsonb_build_object('payment_intent', p.provider_payment_intent_id, 'charge', p.provider_charge_id,
                                                                                                             'balance_transaction', p.provider_balance_transaction_id, 'event', p.provider_event_id)))
                                     order by p.created_at), '[]'::jsonb) from public.payments p where p.order_id = o.id);
  earn := (select jsonb_build_object('currency', pe.currency, 'gross_amount', pe.gross_amount, 'stripe_fee', pe.stripe_fee, 'refund_amount', pe.refund_amount, 'chargeback_amount', pe.chargeback_amount,
                                     'net_collected', pe.net_collected, 'commission_rate', pe.commission_rate, 'oolala_commission', pe.oolala_commission, 'gari_payable', pe.gari_payable,
                                     'status', pe.status, 'settlement_id', pe.settlement_id, 'adjusted_at', pe.adjusted_at)
             from public.partner_earnings pe where pe.order_id = o.id);
  refunds := (select coalesce(jsonb_agg(jsonb_build_object('amount', r.amount, 'currency', r.currency, 'status', r.status, 'reason', r.reason, 'provider_refund_id', r.provider_refund_id, 'created_at', r.created_at) order by r.created_at), '[]'::jsonb) from public.refunds r where r.order_id = o.id);
  cbs := (select coalesce(jsonb_agg(jsonb_build_object('amount', cb.amount, 'currency', cb.currency, 'status', cb.status, 'reason', cb.reason, 'provider_dispute_id', cb.provider_dispute_id, 'created_at', cb.created_at) order by cb.created_at), '[]'::jsonb) from public.chargebacks cb where cb.order_id = o.id);
  return jsonb_build_object(
    'order', jsonb_build_object('reference', o.reference, 'status', o.status, 'currency', o.currency, 'gross_amount', o.gross_amount, 'created_at', o.created_at, 'paid_at', o.paid_at,
                                'reason', o.order_reason, 'service_title', o.service_title, 'checkout_session', o.stripe_checkout_session_id, 'checkout_attempts', o.checkout_attempts,
                                'customer_hint', public.mask_contact(o.customer_contact)),
    'booking', case when b.id is null then null else jsonb_build_object('reference', b.reference, 'status', b.status, 'start_at', b.start_at, 'session_timezone', b.session_timezone,
                                                                        'service_title', b.service_title, 'delivery_mode', b.delivery_mode, 'crm_contact_id', b.crm_contact_id) end,
    'pack', case when sp.id is null then null else jsonb_build_object('reference', sp.public_ref, 'title', sp.title, 'payment_status', sp.payment_status, 'total_sessions', sp.total_sessions,
                                                                      'crm_contact_id', sp.crm_contact_id) end,
    'requests', reqs, 'payments', pay, 'earning', earn, 'refunds', refunds, 'chargebacks', cbs);
end $$;
revoke execute on function public.finance_transaction_detail(text) from public, anon;
grant  execute on function public.finance_transaction_detail(text) to authenticated, service_role;

-- ---------- 3. Finance > Payment methods (the merchant's own list; lazy detail; schema-driven save) ----------
create or replace function public.payment_methods_summary()
returns jsonb language plpgsql stable security definer set search_path = '' as $$
begin
  if not public.has_permission('finance:view') then raise exception 'forbidden' using errcode = '42501'; end if;
  return beau_ph.merchant_methods_summary('coach_gari');
end $$;
create or replace function public.payment_method_get(p_method text)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
begin
  if not public.has_permission('finance:view') then raise exception 'forbidden' using errcode = '42501'; end if;
  return beau_ph.merchant_method_get('coach_gari', p_method);
end $$;

-- p: {method, enabled, currency, countries[], currencies[], intents[], limits{}, settlement{}, fields{key: value}}.
-- Backward compatible with the flat shape {method, enabled, proxy_type, iban, …}: any top-level key that is a schema key is a field.
create or replace function public.payment_method_set(p jsonb)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare e text := public.current_email(); m text := coalesce(p ->> 'method', 'aani'); pv beau_ph.providers%rowtype; row jsonb; ins jsonb := '{}'::jsonb; cfg jsonb := '{}'::jsonb;
  f jsonb; s jsonb; k text; v text; conf jsonb := '{}'::jsonb; prev jsonb;
begin
  if not public.has_permission('finance:manage') then raise exception 'forbidden' using errcode = '42501'; end if;
  select * into pv from beau_ph.providers where key = m;
  if not found then raise exception 'unknown method' using errcode = '22023'; end if;
  f := coalesce(p -> 'fields', '{}'::jsonb);
  -- every schema field, from `fields` or from the flat legacy shape; unknown field keys are refused
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
  -- a brand-new manual row inherits the provider's explicit coverage (visible configuration, as the legacy path did)
  if not exists (select 1 from beau_ph.merchant_methods mm join beau_ph.merchants mc on mc.id = mm.merchant_id where mc.key = 'coach_gari' and mm.provider_key = m) then
    if not (conf ? 'countries')  and pv.countries  is not null then conf := conf || jsonb_build_object('countries',  to_jsonb(pv.countries));  end if;
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

-- "+ Add payment method": creates the merchant row (disabled, needs configuration) and returns the editor payload
create or replace function public.payment_method_add(p_provider text)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare e text := public.current_email();
begin
  if not public.has_permission('finance:manage') then raise exception 'forbidden' using errcode = '42501'; end if;
  if not exists (select 1 from beau_ph.providers where key = p_provider) then raise exception 'unknown method' using errcode = '22023'; end if;
  if exists (select 1 from beau_ph.merchant_methods mm join beau_ph.merchants m on m.id = mm.merchant_id where m.key = 'coach_gari' and mm.provider_key = p_provider) then
    perform beau_ph.merchant_method_configure('coach_gari', p_provider, '{"listed":true}'::jsonb, e);
  else
    perform beau_ph.merchant_method_configure('coach_gari', p_provider, '{"enabled":false,"listed":true}'::jsonb, e);
  end if;
  insert into public.admin_audit (area, entity_id, action, changed_by, summary) values ('payment_method', p_provider, 'add', e, '{}'::jsonb);
  return beau_ph.merchant_method_get('coach_gari', p_provider);
end $$;

-- "Remove": deactivate + unlist when history exists; delete only an unused configuration
create or replace function public.payment_method_remove(p_method text)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare e text := public.current_email(); r jsonb;
begin
  if not public.has_permission('finance:manage') then raise exception 'forbidden' using errcode = '42501'; end if;
  r := beau_ph.merchant_method_remove('coach_gari', p_method, e);
  insert into public.admin_audit (area, entity_id, action, changed_by, summary) values ('payment_method', p_method, 'remove', e, jsonb_build_object('removed', r ->> 'removed', 'history', r -> 'history'));
  return r;
end $$;

-- ---------- 4. BEAU PH > Rails ----------
create or replace function public.beau_ph_rails()
returns jsonb language plpgsql stable security definer set search_path = '' as $$
begin
  if not public.has_permission('finance:view') then raise exception 'forbidden' using errcode = '42501'; end if;
  return beau_ph.rails_overview('coach_gari');
end $$;
create or replace function public.beau_ph_rail_events(p_provider text, p_limit int default 30)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
begin
  if not public.has_permission('finance:view') then raise exception 'forbidden' using errcode = '42501'; end if;
  return beau_ph.rail_events('coach_gari', p_provider, p_limit);
end $$;
create or replace function public.beau_ph_config_audit(p_limit int default 100)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
begin
  if not public.has_permission('finance:view') then raise exception 'forbidden' using errcode = '42501'; end if;
  return beau_ph.config_audit_list('coach_gari', p_limit);
end $$;
create or replace function public.beau_ph_settlement_destinations()
returns jsonb language plpgsql stable security definer set search_path = '' as $$
begin
  if not public.has_permission('finance:view') then raise exception 'forbidden' using errcode = '42501'; end if;
  return beau_ph.settlement_destinations_list('coach_gari');
end $$;
create or replace function public.beau_ph_settlement_destination_set(p jsonb)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare e text := public.current_email(); r jsonb;
begin
  if not public.has_permission('finance:manage') then raise exception 'forbidden' using errcode = '42501'; end if;
  r := beau_ph.settlement_destination_set('coach_gari', p, e);
  insert into public.admin_audit (area, entity_id, action, changed_by, summary) values ('settlement_destination', r ->> 'key', 'set', e, jsonb_build_object('currency', r ->> 'currency', 'active', r -> 'active'));
  return r;
end $$;
create or replace function public.beau_ph_settlement_destination_remove(p_key text)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare e text := public.current_email(); r jsonb;
begin
  if not public.has_permission('finance:manage') then raise exception 'forbidden' using errcode = '42501'; end if;
  r := beau_ph.settlement_destination_remove('coach_gari', p_key, e);
  insert into public.admin_audit (area, entity_id, action, changed_by, summary) values ('settlement_destination', p_key, 'remove', e, jsonb_build_object('removed', r ->> 'removed'));
  return r;
end $$;

-- ---------- 5. BEAU PH > FX ----------
create or replace function public.beau_ph_fx()
returns jsonb language plpgsql stable security definer set search_path = '' as $$
begin
  if not public.has_permission('finance:view') then raise exception 'forbidden' using errcode = '42501'; end if;
  return beau_ph.fx_overview('coach_gari');
end $$;
create or replace function public.beau_ph_fx_refresh()
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare e text := public.current_email(); rid uuid;
begin
  if not public.has_permission('finance:manage') then raise exception 'forbidden' using errcode = '42501'; end if;
  rid := beau_ph.fx_refresh_start(e);
  insert into public.admin_audit (area, entity_id, action, changed_by, summary) values ('beau_ph_fx', 'refresh', 'start', e, jsonb_build_object('run', rid));
  return jsonb_build_object('run', rid);
end $$;
-- the minute job collects; the workspace may poll this to close a run sooner (idempotent)
create or replace function public.beau_ph_fx_collect()
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
begin
  if not public.has_permission('finance:view') then raise exception 'forbidden' using errcode = '42501'; end if;
  return beau_ph.fx_refresh_collect();
end $$;
create or replace function public.beau_ph_fx_set(p jsonb)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare e text := public.current_email(); r jsonb;
begin
  if not public.has_permission('finance:manage') then raise exception 'forbidden' using errcode = '42501'; end if;
  r := beau_ph.merchant_fx_set('coach_gari', p, e);
  insert into public.admin_audit (area, entity_id, action, changed_by, summary) values ('beau_ph_fx', 'settings', 'set', e, r - 'updated_at' - 'updated_by');
  return r;
end $$;
create or replace function public.beau_ph_fx_currency_set(p_currency text, p jsonb)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare e text := public.current_email(); r jsonb;
begin
  if not public.has_permission('finance:manage') then raise exception 'forbidden' using errcode = '42501'; end if;
  r := beau_ph.fx_currency_set(p_currency, p, e);
  insert into public.admin_audit (area, entity_id, action, changed_by, summary) values ('beau_ph_fx', upper(p_currency), 'currency_set', e, jsonb_build_object('enabled', r -> 'enabled', 'source_key', r -> 'source_key'));
  return r;
end $$;
-- workspace calculator: an indicative conversion, never a stored quote
create or replace function public.beau_ph_fx_preview(p_amount int, p_from text, p_to text)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
begin
  if not public.has_permission('finance:view') then raise exception 'forbidden' using errcode = '42501'; end if;
  return beau_ph.fx_quote('coach_gari', p_amount, p_from, p_to, true);
end $$;

-- ---------- 6. payment currency on the payer path ----------
drop function if exists public.cg_ph_request_for_order(public.orders, text, jsonb, boolean, text, text);
create or replace function public.cg_ph_request_for_order(o public.orders, p_provider text, p_runtime jsonb default '{}'::jsonb, p_use_contact_country boolean default true,
                                                          p_capability text default null, p_platform text default null, p_currency text default null)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare pub text; ctry text; meta jsonb; v_intent text; pay_ccy text := nullif(upper(p_currency), ''); live beau_ph.payment_requests%rowtype; q jsonb; mid uuid;
begin
  if o.booking_id is not null then
    select b.reference into pub from public.bookings b where b.id = o.booking_id;
    meta := jsonb_build_object('order_id', o.id, 'booking_id', o.booking_id, 'reason', coalesce(o.order_reason, 'booking'));
  else
    select sp.public_ref, case when p_use_contact_country then public.cg_country_code(c.country) else null end into pub, ctry
      from public.session_packs sp left join public.crm_contacts c on c.id = sp.crm_contact_id where sp.id = o.session_pack_id;
    meta := jsonb_build_object('order_id', o.id, 'session_pack_id', o.session_pack_id, 'reason', coalesce(o.order_reason, 'session_pack'));
  end if;
  v_intent := case coalesce(o.order_reason, case when o.booking_id is not null then 'booking' else 'session_pack' end)
                when 'booking' then 'service' when 'session_pack' then 'package' when 'support' then 'support' else 'other' end;
  if pay_ccy is null or pay_ccy = o.currency then
    return beau_ph.create_request('coach_gari', p_provider, o.reference, coalesce(pub, o.reference), o.gross_amount, o.currency, ctry,
                                  o.checkout_expires_at, meta, p_runtime, p_capability, p_platform, null, v_intent, o.gross_amount, o.currency, null);
  end if;
  -- another payment currency: a live request in that currency keeps its locked amount; one in another currency is superseded
  select id into mid from beau_ph.merchants where key = 'coach_gari';
  select * into live from beau_ph.payment_requests
   where merchant_id = mid and provider_key = p_provider and external_reference = o.reference and status in ('created','pending','requires_action');
  if found then
    if live.currency = pay_ccy then return beau_ph.request_json(live); end if;
    perform beau_ph.cancel_request(live.id, 'system', null, 'payment currency changed to ' || pay_ccy, 'coach_gari');
  end if;
  q := beau_ph.fx_quote('coach_gari', o.gross_amount, o.currency, pay_ccy, false);
  return beau_ph.create_request('coach_gari', p_provider, o.reference, coalesce(pub, o.reference), (q ->> 'payment_amount')::int, pay_ccy, ctry,
                                o.checkout_expires_at, meta || jsonb_build_object('fx_quote_id', q ->> 'id'), p_runtime, p_capability, p_platform, null,
                                v_intent, o.gross_amount, o.currency, (q ->> 'id')::uuid);
end $$;
revoke execute on function public.cg_ph_request_for_order(public.orders, text, jsonb, boolean, text, text, text) from public, anon, authenticated;
grant  execute on function public.cg_ph_request_for_order(public.orders, text, jsonb, boolean, text, text, text) to service_role;

drop function if exists public.cg_ph_request_for_pack(uuid, text, jsonb);
create or replace function public.cg_ph_request_for_pack(p_pack_id uuid, p_provider text, p_runtime jsonb default '{}'::jsonb, p_currency text default null)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare oj jsonb; o public.orders%rowtype; req jsonb;
begin
  oj := public.create_order_for_pack(p_pack_id);
  select * into o from public.orders where reference = oj ->> 'reference';
  req := public.cg_ph_request_for_order(o, p_provider, p_runtime, true, null, null, p_currency);
  return jsonb_build_object('request', req, 'order', oj);
end $$;
revoke execute on function public.cg_ph_request_for_pack(uuid, text, jsonb, text) from public, anon, authenticated;
grant  execute on function public.cg_ph_request_for_pack(uuid, text, jsonb, text) to service_role;

-- report_view(): + payment block — pricing origin, the currency selected, the amount in it, FX disclosure, and the options the payer may choose
drop function if exists public.report_view(text, jsonb);
create or replace function public.report_view(p_token text, p_runtime jsonb default '{}'::jsonb, p_currency text default null)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare t public.report_tokens%rowtype; recap jsonb; ref text; cur text; ctry text; methods jsonb; mth jsonb; due int; sel text; opts jsonb; opt jsonb; fxj jsonb; c jsonb; pay_amt int;
  aani_json jsonb := jsonb_build_object('enabled', false); bank_json jsonb := jsonb_build_object('enabled', false); fx_on boolean;
begin
  if p_token is null or p_token !~ '^[0-9a-f]{64}$' then raise exception 'invalid token' using errcode = 'P0002'; end if;
  select * into t from public.report_tokens where token_hash = encode(extensions.digest(p_token,'sha256'),'hex');
  if not found then raise exception 'invalid token' using errcode = 'P0002'; end if;
  if t.revoked_at is not null then raise exception 'this link has been revoked' using errcode = 'P0003'; end if;
  if t.expires_at is not null and t.expires_at < now() then raise exception 'this link has expired' using errcode = 'P0003'; end if;
  recap := public.pack_recap_data(t.session_pack_id, true);
  select sp.public_ref, sp.currency, public.cg_country_code(c2.country) into ref, cur, ctry
    from public.session_packs sp left join public.crm_contacts c2 on c2.id = sp.crm_contact_id where sp.id = t.session_pack_id;
  ref := coalesce(ref, 'CG-' || upper(substr(t.session_pack_id::text, 1, 6)));
  due := (recap ->> 'amount_due')::int;
  -- payment options: the pricing currency, then every eligible currency BEAU FX can quote right now (indicative; the quote is locked when paying)
  opts := jsonb_build_array(jsonb_build_object('currency', cur, 'amount', due, 'pricing', true));
  select f.enabled into fx_on from beau_ph.merchant_fx f join beau_ph.merchants m on m.id = f.merchant_id where m.key = 'coach_gari';
  if coalesce(fx_on, false) and due > 0 then
    for c in select * from jsonb_array_elements(beau_ph.eligible_currencies('coach_gari', ctry, p_runtime, null, 'customer', 'package')) loop
      if c ->> 'currency' = cur then continue; end if;
      begin
        fxj := beau_ph.fx_quote('coach_gari', due, cur, c ->> 'currency', true);
        opts := opts || jsonb_build_object('currency', c ->> 'currency', 'amount', (fxj ->> 'payment_amount')::int, 'pricing', false,
                                           'rate', fxj -> 'customer_rate', 'freshness', fxj ->> 'freshness', 'quote_ttl_minutes', fxj -> 'quote_ttl_minutes');
      exception when others then null;   -- stale / missing rate: that currency is simply not offered
      end;
    end loop;
  end if;
  sel := coalesce(nullif(upper(p_currency), ''), cur);
  select o into opt from jsonb_array_elements(opts) o where o ->> 'currency' = sel;
  if opt is null then sel := cur; select o into opt from jsonb_array_elements(opts) o where o ->> 'currency' = sel; end if;
  pay_amt := (opt ->> 'amount')::int;
  methods := (select coalesce(jsonb_agg(e || jsonb_build_object('reference', ref)), '[]'::jsonb)
                from jsonb_array_elements(beau_ph.eligible_methods('coach_gari', ctry, sel, p_runtime, null, 'customer', 'package')) e);
  for mth in select * from jsonb_array_elements(methods) loop
    if mth ->> 'provider' = 'aani' then
      aani_json := jsonb_build_object('enabled', true, 'reference', ref, 'currency', mth ->> 'settlement_currency') || coalesce(mth -> 'instructions', '{}'::jsonb);
    elsif mth ->> 'provider' = 'bank_transfer' then
      bank_json := jsonb_build_object('enabled', true, 'reference', ref, 'currency', mth ->> 'settlement_currency') || coalesce(mth -> 'instructions', '{}'::jsonb);
    end if;
  end loop;
  return jsonb_build_object('ok', true, 'recap', recap, 'pay_ref', ref, 'currency', sel, 'customer_country', ctry,
                            'methods', methods, 'aani', aani_json, 'bank', bank_json,
                            'payment', jsonb_build_object('pricing_amount', due, 'pricing_currency', cur, 'currency', sel, 'amount', pay_amt,
                                                          'fx', case when sel = cur then null else opt - 'pricing' end, 'options', opts));
end $$;
revoke execute on function public.report_view(text, jsonb, text) from public, anon, authenticated;
grant  execute on function public.report_view(text, jsonb, text) to service_role;

-- ---------- 7. grants ----------
revoke execute on function public.payment_methods_summary(), public.payment_method_get(text), public.payment_method_set(jsonb), public.payment_method_add(text), public.payment_method_remove(text),
  public.beau_ph_rails(), public.beau_ph_rail_events(text, int), public.beau_ph_config_audit(int), public.beau_ph_settlement_destinations(),
  public.beau_ph_settlement_destination_set(jsonb), public.beau_ph_settlement_destination_remove(text), public.beau_ph_fx(), public.beau_ph_fx_refresh(), public.beau_ph_fx_collect(),
  public.beau_ph_fx_set(jsonb), public.beau_ph_fx_currency_set(text, jsonb), public.beau_ph_fx_preview(int, text, text)
  from public, anon;
grant execute on function public.payment_methods_summary(), public.payment_method_get(text), public.payment_method_set(jsonb), public.payment_method_add(text), public.payment_method_remove(text),
  public.beau_ph_rails(), public.beau_ph_rail_events(text, int), public.beau_ph_config_audit(int), public.beau_ph_settlement_destinations(),
  public.beau_ph_settlement_destination_set(jsonb), public.beau_ph_settlement_destination_remove(text), public.beau_ph_fx(), public.beau_ph_fx_refresh(), public.beau_ph_fx_collect(),
  public.beau_ph_fx_set(jsonb), public.beau_ph_fx_currency_set(text, jsonb), public.beau_ph_fx_preview(int, text, text)
  to authenticated, service_role;

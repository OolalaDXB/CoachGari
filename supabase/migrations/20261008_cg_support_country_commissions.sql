-- =====================================================================
-- Coach Gari — Support offered by the payer's country; Oolala commission report
--
-- 1. cg_ph_request_for_order() takes an explicit payer country (a support
--    payment has no contact to derive it from). Same body as 20260930 plus
--    the parameter; the 7-argument signature is dropped (positional callers
--    are unchanged).
-- 2. support_options(country): what BEAU PH can offer a payer in that
--    country for the `support` intent — currencies, and the eligible
--    methods per currency. Nothing is guessed from the merchant's home.
-- 3. support_create() requires the country and validates the currency and
--    the rail against it; the request records the customer country.
-- 4. finance_commissions(): the Oolala commission, month × currency × type
--    (service / package / support), settled vs open — finance:view.
-- Forward migration only.
-- =====================================================================

drop function if exists public.cg_ph_request_for_order(public.orders, text, jsonb, boolean, text, text, text);
create or replace function public.cg_ph_request_for_order(o public.orders, p_provider text, p_runtime jsonb default '{}'::jsonb, p_use_contact_country boolean default true,
                                                          p_capability text default null, p_platform text default null, p_currency text default null, p_country text default null)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare pub text; ctry text; meta jsonb; v_intent text; pay_ccy text := coalesce(nullif(upper(p_currency), ''), o.currency); live beau_ph.payment_requests%rowtype; q jsonb; mid uuid;
begin
  if o.booking_id is not null then
    select b.reference into pub from public.bookings b where b.id = o.booking_id;
    meta := jsonb_build_object('order_id', o.id, 'booking_id', o.booking_id, 'reason', coalesce(o.order_reason, 'booking'));
  else
    select sp.public_ref, case when p_use_contact_country then public.cg_country_code(c.country) else null end into pub, ctry
      from public.session_packs sp left join public.crm_contacts c on c.id = sp.crm_contact_id where sp.id = o.session_pack_id;
    meta := jsonb_build_object('order_id', o.id, 'session_pack_id', o.session_pack_id, 'reason', coalesce(o.order_reason, 'session_pack'));
  end if;
  ctry := coalesce(nullif(upper(p_country), ''), ctry);   -- an explicit payer country wins (support payments carry no contact)
  v_intent := case coalesce(o.order_reason, case when o.booking_id is not null then 'booking' else 'session_pack' end)
                when 'booking' then 'service' when 'session_pack' then 'package' when 'support' then 'support' else 'other' end;
  select id into mid from beau_ph.merchants where key = 'coach_gari';
  select * into live from beau_ph.payment_requests
   where merchant_id = mid and provider_key = p_provider and external_reference = o.reference and status in ('created','pending','requires_action');
  if found then
    if live.currency = pay_ccy then return beau_ph.request_json(live); end if;
    perform beau_ph.cancel_request(live.id, 'system', null, 'payment currency changed to ' || pay_ccy, 'coach_gari');
  end if;
  if pay_ccy = o.currency then
    return beau_ph.create_request('coach_gari', p_provider, o.reference, coalesce(pub, o.reference), o.gross_amount, o.currency, ctry,
                                  o.checkout_expires_at, meta, p_runtime, p_capability, p_platform, null, v_intent, o.gross_amount, o.currency, null);
  end if;
  q := beau_ph.fx_quote('coach_gari', o.gross_amount, o.currency, pay_ccy, false);
  return beau_ph.create_request('coach_gari', p_provider, o.reference, coalesce(pub, o.reference), (q ->> 'payment_amount')::int, pay_ccy, ctry,
                                o.checkout_expires_at, meta || jsonb_build_object('fx_quote_id', q ->> 'id'), p_runtime, p_capability, p_platform, null,
                                v_intent, o.gross_amount, o.currency, (q ->> 'id')::uuid);
end $$;
revoke execute on function public.cg_ph_request_for_order(public.orders, text, jsonb, boolean, text, text, text, text) from public, anon, authenticated;
grant  execute on function public.cg_ph_request_for_order(public.orders, text, jsonb, boolean, text, text, text, text) to service_role;

-- what a payer in a given country can use to support Coach Gari right now
create or replace function public.support_options(p_country text, p_runtime jsonb default '{}'::jsonb)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare ctry text := upper(coalesce(p_country, '')); ccys jsonb; res jsonb := '[]'::jsonb; c jsonb; m jsonb;
begin
  if ctry !~ '^[A-Z]{2}$' then raise exception 'country required (ISO 3166-1 alpha-2)' using errcode = '22023'; end if;
  ccys := beau_ph.eligible_currencies('coach_gari', ctry, p_runtime, null, 'customer', 'support');
  for c in select * from jsonb_array_elements(ccys) loop
    m := (select coalesce(jsonb_agg(jsonb_build_object('provider', e ->> 'provider', 'display_name', e ->> 'display_name', 'kind', e ->> 'kind', 'capability', e ->> 'capability',
                                                       'instructions', e -> 'instructions')), '[]'::jsonb)
            from jsonb_array_elements(beau_ph.eligible_methods('coach_gari', ctry, c ->> 'currency', p_runtime, null, 'customer', 'support')) e);
    if jsonb_array_length(m) > 0 then res := res || jsonb_build_object('currency', c ->> 'currency', 'methods', m); end if;
  end loop;
  return jsonb_build_object('country', ctry, 'currencies', res,
                            'default_currency', case when exists (select 1 from jsonb_array_elements(res) x where x ->> 'currency' = 'AED') then 'AED' else (res -> 0 ->> 'currency') end);
end $$;
revoke execute on function public.support_options(text, jsonb) from public, anon, authenticated;
grant  execute on function public.support_options(text, jsonb) to service_role;

drop function if exists public.support_create(int, text, text, jsonb);
create or replace function public.support_create(p_amount int, p_currency text, p_message text default null, p_runtime jsonb default '{}'::jsonb, p_country text default null)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare cur text := upper(coalesce(p_currency, '')); ctry text := upper(coalesce(p_country, '')); msg text; o public.orders%rowtype; req jsonb; tok text; v_ref text; pub text;
  floor_minor int; ceil_minor int; offered jsonb;
begin
  if ctry !~ '^[A-Z]{2}$' then raise exception 'country required (ISO 3166-1 alpha-2)' using errcode = '22023'; end if;
  if cur !~ '^[A-Z]{3}$' then raise exception 'currency required (ISO 4217)' using errcode = '22023'; end if;
  if p_amount is null or p_amount <= 0 then raise exception 'amount required' using errcode = '22023'; end if;
  -- what BEAU PH can offer a payer in THAT country for a support payment: the rails that list the intent, their markets
  offered := beau_ph.eligible_currencies('coach_gari', ctry, p_runtime, null, 'customer', 'support');
  if not exists (select 1 from jsonb_array_elements(offered) c where c ->> 'currency' = cur) then
    raise exception 'no payment method is available for % in %', cur, ctry using errcode = '22023';
  end if;
  floor_minor := 1000; ceil_minor := 500000;   -- 10 – 5,000 in the payment currency's major unit
  if p_amount < floor_minor then raise exception 'amount below the minimum (% %)', cur, floor_minor / 100 using errcode = '22023'; end if;
  if p_amount > ceil_minor then raise exception 'amount above the maximum (% %)', cur, ceil_minor / 100 using errcode = '22023'; end if;
  msg := nullif(left(regexp_replace(btrim(coalesce(p_message, '')), '\s+', ' ', 'g'), 500), '');
  loop v_ref := 'OR-' || upper(substr(encode(extensions.gen_random_bytes(4), 'hex'), 1, 6)); exit when not exists (select 1 from public.orders where reference = v_ref); end loop;
  loop pub := 'SUP-' || upper(substr(encode(extensions.gen_random_bytes(4), 'hex'), 1, 6));
       exit when not exists (select 1 from beau_ph.payment_requests where public_reference = pub); end loop;
  tok := encode(extensions.gen_random_bytes(32), 'hex');
  insert into public.orders (reference, booking_id, session_pack_id, order_reason, customer_name, customer_contact, currency, gross_amount, status, service_title, access_token_hash)
  values (v_ref, null, null, 'support', 'Supporter', 'n/a', cur, p_amount, 'pending_payment', 'Support Coach Gari', encode(extensions.digest(tok, 'sha256'), 'hex'))
  returning * into o;
  req := public.cg_ph_request_for_order(o, 'stripe', p_runtime, false, null, null, null, ctry);
  if req is null or (req ->> 'id') is null then raise exception 'support payment unavailable' using errcode = 'P0003'; end if;
  update beau_ph.payment_requests
     set public_reference = pub, metadata = metadata || jsonb_strip_nulls(jsonb_build_object('message', msg))
   where id = (req ->> 'id')::uuid;
  req := beau_ph.request_json((select r from beau_ph.payment_requests r where r.id = (req ->> 'id')::uuid));
  return jsonb_build_object('request', req, 'token', tok,
                            'order', jsonb_build_object('reference', o.reference, 'status', o.status, 'gross_amount', o.gross_amount, 'currency', o.currency,
                                                        'customer_contact', o.customer_contact, 'public_reference', pub));
end $$;
revoke execute on function public.support_create(int, text, text, jsonb, text) from public, anon, authenticated;
grant  execute on function public.support_create(int, text, text, jsonb, text) to service_role;

-- Finance › Commissions: the Oolala commission on money Oolala collected, per month × currency × type; settled vs open
create or replace function public.finance_commissions()
returns jsonb language plpgsql stable security definer set search_path = '' as $$
begin
  if not public.has_permission('finance:view') then raise exception 'forbidden' using errcode = '42501'; end if;
  return jsonb_build_object(
    'rows', coalesce((select jsonb_agg(row_to_json(r)::jsonb order by r.month desc, r.currency, r.type) from (
      select to_char(date_trunc('month', coalesce(o.paid_at, pe.created_at)), 'YYYY-MM') as month, pe.currency,
             case o.order_reason when 'booking' then 'service' when 'session_pack' then 'package' when 'support' then 'support' else 'other' end as type,
             count(*)::int as payments,
             sum(pe.gross_amount)::int as gross, sum(pe.stripe_fee)::int as fees, sum(pe.refund_amount)::int as refunds, sum(pe.chargeback_amount)::int as chargebacks,
             sum(pe.net_collected)::int as net, sum(pe.oolala_commission)::int as commission, sum(pe.gari_payable)::int as gari_payable,
             sum(case when pe.status = 'settled' then pe.oolala_commission else 0 end)::int as commission_settled,
             sum(case when pe.status <> 'settled' then pe.oolala_commission else 0 end)::int as commission_open,
             count(*) filter (where pe.adjusted_at is not null)::int as adjusted
        from public.partner_earnings pe join public.orders o on o.id = pe.order_id
       group by 1, 2, 3) r), '[]'::jsonb),
    'totals', coalesce((select jsonb_agg(row_to_json(t)::jsonb order by t.currency) from (
      select pe.currency, sum(pe.oolala_commission)::int as commission,
             sum(case when pe.status = 'settled' then pe.oolala_commission else 0 end)::int as commission_settled,
             sum(case when pe.status <> 'settled' then pe.oolala_commission else 0 end)::int as commission_open,
             sum(pe.gross_amount)::int as gross, sum(pe.net_collected)::int as net, count(*)::int as payments
        from public.partner_earnings pe group by pe.currency) t), '[]'::jsonb),
    'rate', (select coalesce(max(commission_rate), 0.1000) from public.partner_earnings));
end $$;
revoke execute on function public.finance_commissions() from public, anon;
grant  execute on function public.finance_commissions() to authenticated, service_role;

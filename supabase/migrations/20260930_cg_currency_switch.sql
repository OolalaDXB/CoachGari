-- =====================================================================
-- Coach Gari host — switching the payment currency back to the pricing
-- currency supersedes a live request in another currency
--
-- cg_ph_request_for_order() cancelled a live request only when the payer
-- moved TO another currency; moving BACK to the pricing currency hit the
-- BEAU PH "live request with a different amount/currency" guard. The rule is
-- now symmetric: exactly one live request per rail and order, in the currency
-- the payer last chose; the previous one is cancelled with the reason recorded.
-- Forward migration only.
-- =====================================================================
create or replace function public.cg_ph_request_for_order(o public.orders, p_provider text, p_runtime jsonb default '{}'::jsonb, p_use_contact_country boolean default true,
                                                          p_capability text default null, p_platform text default null, p_currency text default null)
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
  v_intent := case coalesce(o.order_reason, case when o.booking_id is not null then 'booking' else 'session_pack' end)
                when 'booking' then 'service' when 'session_pack' then 'package' when 'support' then 'support' else 'other' end;
  -- one live request per rail and order, in the currency the payer last chose: another currency supersedes it (its locked amount is kept while it lives)
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

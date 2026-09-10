-- =====================================================================
-- Coach Gari — Finance: a distinct "Collaboration" transaction type
--
-- Collaboration payments are target-less orders (order_reason 'collaboration')
-- and were folding into the finance "type" derivation's `else 'other'` bucket.
-- This re-creates the two read functions that derive the displayed type so a
-- collaboration shows as its own type. Nothing else changes: the BEAU PH intent
-- mapping stays 'other' (the rail lists it), and commission is untouched — a
-- collaboration payment still accrues the flat 10% via recompute_earning.
-- Forward-only; both functions are re-created verbatim except the added branch.
-- =====================================================================

create or replace function public.finance_transactions(p_limit int default 200)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
begin
  if not public.has_permission('finance:view') then raise exception 'forbidden' using errcode = '42501'; end if;
  return coalesce((select jsonb_agg(row_to_json(t)::jsonb order by t.created_at desc) from (
    select o.reference, o.created_at, o.paid_at,
           coalesce(b.reference, sp.public_ref, o.reference) as public_reference,
           case coalesce(o.order_reason, case when o.booking_id is not null then 'booking' else 'session_pack' end)
                when 'booking' then 'service' when 'session_pack' then 'package' when 'support' then 'support'
                when 'collaboration' then 'collaboration' else 'other' end as type,
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

create or replace function public.finance_commissions()
returns jsonb language plpgsql stable security definer set search_path = '' as $$
begin
  if not public.has_permission('finance:view') then raise exception 'forbidden' using errcode = '42501'; end if;
  return jsonb_build_object(
    'rows', coalesce((select jsonb_agg(row_to_json(r)::jsonb order by r.month desc, r.currency, r.type) from (
      select to_char(date_trunc('month', coalesce(o.paid_at, pe.created_at)), 'YYYY-MM') as month, pe.currency,
             case o.order_reason when 'booking' then 'service' when 'session_pack' then 'package' when 'support' then 'support'
                  when 'collaboration' then 'collaboration' else 'other' end as type,
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

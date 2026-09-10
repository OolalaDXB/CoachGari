/* =============================================================
   CG — recompute_earning and the Finance view on the origin model
   The rate is resolved from the ORIGIN of the money (who collected it), never
   from the technical rail; the rail is only a declared mapping to an origin.
   The explicit per-order override keeps winning, exactly as before.
   Finance reports the two accounting directions separately: what Oolala owes
   Gari and what Gari owes Studio are different balances and never blend.
   ============================================================= */

-- ---------- recompute_earning: rate from the ORIGIN, direction from the origin ----------
create or replace function public.recompute_earning(p_order_id uuid)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare
  o public.orders%rowtype; p public.payments%rowtype;
  v_refunds int; v_chargebacks int; v_tax int := 0; v_net int; v_comm int; v_pay int; v_recv int;
  v_origin text; v_rate numeric(6,4);
  e public.partner_earnings%rowtype;
begin
  select * into o from public.orders where id = p_order_id;
  if not found then raise exception 'order not found' using errcode = 'P0002'; end if;
  select * into p from public.payments where order_id = o.id and status = 'succeeded' order by paid_at desc nulls last limit 1;
  if not found then return null; end if;

  -- ORIGIN first: who actually collected the money. The rail only maps to an origin; the rate is
  -- never read off the rail. An unmapped rail counts as collected by Coach Gari, the conservative
  -- side, because it never claims Studio is holding funds it does not hold.
  select cr.origin into v_origin from public.collection_rails cr where cr.rail = p.provider;
  v_origin := coalesce(v_origin, 'direct');
  select co.rate into v_rate from public.commission_origins co where co.origin = v_origin;
  -- an explicit per-order override still wins, exactly as before: the rate already on the row sticks
  select coalesce((select commission_rate from public.partner_earnings where order_id = o.id), v_rate) into v_rate;

  select coalesce(sum(amount), 0) into v_refunds from public.refunds where order_id = o.id and status = 'succeeded';
  select coalesce(sum(amount), 0) into v_chargebacks from public.chargebacks where order_id = o.id and status = 'lost';
  v_net  := p.amount - p.fee_amount - v_refunds - v_chargebacks - v_tax;
  v_comm := greatest(0, round(v_net * v_rate))::int;
  if v_origin = 'platform' then
    v_pay := v_net - v_comm; v_recv := 0;      -- Oolala holds the cash and owes Gari the net
  else
    v_pay := 0; v_recv := v_comm;              -- Gari holds the cash and owes Studio the commission
  end if;

  insert into public.partner_earnings (order_id, payment_id, currency, gross_amount, stripe_fee, refund_amount, chargeback_amount,
                                       tax_amount, net_collected, commission_rate, oolala_commission, gari_payable,
                                       collection_origin, studio_receivable)
  values (o.id, p.id, coalesce(p.currency, o.currency), p.amount, p.fee_amount, v_refunds, v_chargebacks, v_tax, v_net, v_rate, v_comm, v_pay,
          v_origin, v_recv)
  on conflict (order_id) do update
    set payment_id = excluded.payment_id, currency = excluded.currency, gross_amount = excluded.gross_amount, stripe_fee = excluded.stripe_fee,
        refund_amount = excluded.refund_amount, chargeback_amount = excluded.chargeback_amount, tax_amount = excluded.tax_amount,
        net_collected = excluded.net_collected, oolala_commission = excluded.oolala_commission, gari_payable = excluded.gari_payable,
        collection_origin = excluded.collection_origin, studio_receivable = excluded.studio_receivable,
        adjusted_at = case when public.partner_earnings.status = 'settled'
                            and (public.partner_earnings.net_collected <> excluded.net_collected) then now()
                           else public.partner_earnings.adjusted_at end
  returning * into e;
  return to_jsonb(e);
end $$;

-- ---------- Finance: the two directions never blend ----------
create or replace function public.finance_commissions()
returns jsonb language plpgsql stable security definer set search_path = '' as $$
begin
  if not public.has_permission('finance:view') then raise exception 'forbidden' using errcode = '42501'; end if;
  return jsonb_build_object(
    'rows', coalesce((select jsonb_agg(row_to_json(r)::jsonb order by r.month desc, r.currency, r.direction, r.type) from (
      select to_char(date_trunc('month', coalesce(o.paid_at, pe.created_at)), 'YYYY-MM') as month, pe.currency,
             pe.collection_origin as origin, pe.direction,
             case o.order_reason when 'booking' then 'service' when 'session_pack' then 'package' when 'support' then 'support'
                  when 'collaboration' then 'collaboration' else 'other' end as type,
             count(*)::int as payments,
             sum(pe.gross_amount)::int as gross, sum(pe.stripe_fee)::int as fees, sum(pe.refund_amount)::int as refunds, sum(pe.chargeback_amount)::int as chargebacks,
             sum(pe.net_collected)::int as net, sum(pe.oolala_commission)::int as commission,
             sum(pe.gari_payable)::int as gari_payable, sum(pe.studio_receivable)::int as studio_receivable,
             sum(case when pe.status = 'settled' then pe.oolala_commission else 0 end)::int as commission_settled,
             sum(case when pe.status <> 'settled' then pe.oolala_commission else 0 end)::int as commission_open,
             count(*) filter (where pe.adjusted_at is not null)::int as adjusted
        from public.partner_earnings pe join public.orders o on o.id = pe.order_id
       group by 1, 2, 3, 4, 5) r), '[]'::jsonb),
    -- per currency AND per direction: money Oolala holds and owes Gari is not money Gari holds
    -- and owes Studio. Summing them together would invent a balance that exists nowhere.
    'totals', coalesce((select jsonb_agg(row_to_json(t)::jsonb order by t.currency, t.direction) from (
      select pe.currency, pe.direction, pe.collection_origin as origin,
             sum(pe.oolala_commission)::int as commission,
             sum(case when pe.status = 'settled' then pe.oolala_commission else 0 end)::int as commission_settled,
             sum(case when pe.status <> 'settled' then pe.oolala_commission else 0 end)::int as commission_open,
             sum(pe.gross_amount)::int as gross, sum(pe.net_collected)::int as net,
             sum(pe.gari_payable)::int as gari_payable, sum(pe.studio_receivable)::int as studio_receivable,
             count(*)::int as payments
        from public.partner_earnings pe group by pe.currency, pe.direction, pe.collection_origin) t), '[]'::jsonb),
    'rates', coalesce((select jsonb_agg(jsonb_build_object('origin', co.origin, 'rate', co.rate, 'direction', co.direction, 'description', co.description) order by co.origin)
                         from public.commission_origins co), '[]'::jsonb));
end $$;
revoke execute on function public.finance_commissions() from public, anon;
grant  execute on function public.finance_commissions() to authenticated, service_role;

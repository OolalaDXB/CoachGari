/* =============================================================
   CG — recompute_earning: the rate an order is actually priced at
   In order of authority:
     1. a fully signed exemption on the line, then on the client — the governed decision;
     2. an explicit per-order rate already on the earning row — the legacy manual override;
     3. the standard rate for the origin.
   The origin still decides the accounting DIRECTION in every case.

   The legacy sticky override is read only when the row was NOT priced by an
   exemption: otherwise a revoked exemption would leave its rate behind for good
   and the commission would never come back.
   ============================================================= */
create or replace function public.recompute_earning(p_order_id uuid)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare
  o public.orders%rowtype; p public.payments%rowtype;
  v_refunds int; v_chargebacks int; v_tax int := 0; v_net int; v_comm int; v_pay int; v_recv int;
  v_origin text; v_rate numeric(6,4); v_exempt_rate numeric; v_exempt_id uuid;
  v_prev_rate numeric(6,4); v_prev_exempt uuid; v_had_row boolean;
  e public.partner_earnings%rowtype;
begin
  select * into o from public.orders where id = p_order_id;
  if not found then raise exception 'order not found' using errcode = 'P0002'; end if;
  select * into p from public.payments where order_id = o.id and status = 'succeeded' order by paid_at desc nulls last limit 1;
  if not found then return null; end if;

  -- ORIGIN first: who actually collected the money. The rail only maps to an origin. An
  -- unmapped rail counts as collected by Coach Gari, the conservative side, because it never
  -- claims Studio is holding funds it does not hold.
  select cr.origin into v_origin from public.collection_rails cr where cr.rail = p.provider;
  v_origin := coalesce(v_origin, 'direct');
  select co.rate into v_rate from public.commission_origins co where co.origin = v_origin;

  select commission_rate, exemption_id into v_prev_rate, v_prev_exempt
    from public.partner_earnings where order_id = o.id;
  v_had_row := found;
  -- an explicit per-order override still wins over the standard rate, exactly as before —
  -- but only a hand-set one, never a rate an exemption put there
  if v_had_row and v_prev_exempt is null then v_rate := v_prev_rate; end if;
  -- ... and a doubly signed exemption wins over both: it is the decision Gari and Studio took together
  select rate, exemption_id into v_exempt_rate, v_exempt_id from public.commission_exempt_rate(o.id);
  if v_exempt_id is not null then v_rate := v_exempt_rate; end if;

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
                                       collection_origin, studio_receivable, exemption_id)
  values (o.id, p.id, coalesce(p.currency, o.currency), p.amount, p.fee_amount, v_refunds, v_chargebacks, v_tax, v_net, v_rate, v_comm, v_pay,
          v_origin, v_recv, v_exempt_id)
  on conflict (order_id) do update
    set payment_id = excluded.payment_id, currency = excluded.currency, gross_amount = excluded.gross_amount, stripe_fee = excluded.stripe_fee,
        refund_amount = excluded.refund_amount, chargeback_amount = excluded.chargeback_amount, tax_amount = excluded.tax_amount,
        net_collected = excluded.net_collected, oolala_commission = excluded.oolala_commission, gari_payable = excluded.gari_payable,
        collection_origin = excluded.collection_origin, studio_receivable = excluded.studio_receivable,
        -- an exemption is the one thing allowed to move a rate that was already set
        commission_rate = excluded.commission_rate, exemption_id = excluded.exemption_id,
        adjusted_at = case when public.partner_earnings.status = 'settled'
                            and (public.partner_earnings.net_collected <> excluded.net_collected
                                 or public.partner_earnings.oolala_commission <> excluded.oolala_commission) then now()
                           else public.partner_earnings.adjusted_at end
  returning * into e;
  return to_jsonb(e);
end $$;

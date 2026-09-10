/* =============================================================
   CG — a settlement is a payout, so it sweeps payable earnings only
   Now that off-platform receipts book an earning, create_settlement would have
   swept those receivable rows into a payout document: it would mark them
   'settled' while adding 0 to amount_payable, quietly burying money Gari owes
   Studio inside a transfer Studio makes to Gari. A settlement is money Oolala
   holds and pays out; a receivable is collected, not paid.
   ============================================================= */
create or replace function public.create_settlement(p_partner text, p_period_start date, p_period_end date, p_currency text default 'USD')
returns jsonb language plpgsql security definer set search_path = '' as $$
declare s public.partner_settlements%rowtype; v_ref text; n int;
begin
  loop
    v_ref := 'ST-' || upper(substr(encode(extensions.gen_random_bytes(4), 'hex'), 1, 6));
    exit when not exists (select 1 from public.partner_settlements where reference = v_ref);
  end loop;
  insert into public.partner_settlements (reference, partner, period_start, period_end, currency, status)
  values (v_ref, p_partner, p_period_start, p_period_end, p_currency, 'open') returning * into s;

  insert into public.partner_settlement_items (settlement_id, earning_id, order_id, gross_amount, stripe_fee, refund_amount, chargeback_amount, net_collected, oolala_commission, gari_payable)
  select s.id, e.id, e.order_id, e.gross_amount, e.stripe_fee, e.refund_amount, e.chargeback_amount, e.net_collected, e.oolala_commission, e.gari_payable
  from public.partner_earnings e
  join public.orders o on o.id = e.order_id
  where e.partner = p_partner and e.status = 'open' and e.currency = p_currency
    and e.collection_origin = 'platform'          -- payable only; receivables are not paid out
    and o.paid_at >= p_period_start and o.paid_at < (p_period_end + 1);
  get diagnostics n = row_count;

  update public.partner_earnings e set status = 'settled', settlement_id = s.id
   where e.id in (select earning_id from public.partner_settlement_items where settlement_id = s.id);

  update public.partner_settlements set
    gross_amount = coalesce((select sum(gross_amount) from public.partner_settlement_items where settlement_id = s.id), 0),
    refund_amount = coalesce((select sum(refund_amount) from public.partner_settlement_items where settlement_id = s.id), 0),
    chargeback_amount = coalesce((select sum(chargeback_amount) from public.partner_settlement_items where settlement_id = s.id), 0),
    fee_amount = coalesce((select sum(stripe_fee) from public.partner_settlement_items where settlement_id = s.id), 0),
    net_collected = coalesce((select sum(net_collected) from public.partner_settlement_items where settlement_id = s.id), 0),
    oolala_commission = coalesce((select sum(oolala_commission) from public.partner_settlement_items where settlement_id = s.id), 0),
    amount_payable = coalesce((select sum(gari_payable) from public.partner_settlement_items where settlement_id = s.id), 0),
    status = case when n > 0 then 'ready' else 'open' end
  where id = s.id returning * into s;
  return to_jsonb(s) || jsonb_build_object('items', n);
end $$;

revoke all on function public.create_settlement(text, date, date, text) from public, anon, authenticated;

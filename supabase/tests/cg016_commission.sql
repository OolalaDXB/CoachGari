-- =====================================================================
-- CG-016 — Commission by ORIGIN (10 % platform / 6 % off-platform)
-- One rolled-back transaction. Proves that the rate follows who collected
-- the money and never the technical rail, that every origin books an earning
-- (manual rails included), that the two accounting directions are structurally
-- separate — Oolala owes Gari the net, Gari owes Studio the commission — and
-- that an explicit per-order override still wins.
-- Run by scripts/db-tests.sh; nothing persists (final RAISE).
-- =====================================================================
do $$
declare
  ok int := 0; fail int := 0; log text := '';
  j jsonb; e public.partner_earnings%rowtype;
  oid uuid; oref text; pid uuid; cid uuid; packid uuid; mref text; moid uuid; st jsonb;
begin
  update beau_ph.merchants set mode = 'test' where key = 'coach_gari';
  perform set_config('request.jwt.claims', '{"email":"grej28roux@gmail.com","role":"authenticated"}', true);

  -- 0. the rates live in data, keyed by origin, with the direction attached
  if (select rate from public.commission_origins where origin = 'platform') = 0.1000
     and (select direction from public.commission_origins where origin = 'platform') = 'payable'
    then ok := ok + 1; else fail := fail + 1; log := log || ' [platform-rate]'; end if;
  if (select rate from public.commission_origins where origin = 'direct') = 0.0600
     and (select direction from public.commission_origins where origin = 'direct') = 'receivable'
    then ok := ok + 1; else fail := fail + 1; log := log || ' [direct-rate]'; end if;
  if (select origin from public.collection_rails where rail = 'stripe') = 'platform'
     and (select count(*) from public.collection_rails where rail in ('cash','aani','bank_transfer') and origin = 'direct') = 3
    then ok := ok + 1; else fail := fail + 1; log := log || ' [rail-mapping]'; end if;

  -- 1. Stripe, 500 EUR: Oolala collected → 10 %, payable, net owed to Gari
  --    (order_reason 'support' is target-less, so no booking or pack fixture is needed)
  oref := 'OR-T' || upper(substr(encode(extensions.gen_random_bytes(3),'hex'),1,5));
  insert into public.orders (reference, order_reason, customer_name, customer_contact, currency, gross_amount, status, paid_at)
  values (oref, 'support', 'Test Payer', 'payer@example.com', 'EUR', 50000, 'paid', now()) returning id into oid;
  insert into public.payments (order_id, provider, amount, currency, status, paid_at)
  values (oid, 'stripe', 50000, 'EUR', 'succeeded', now()) returning id into pid;

  j := public.recompute_earning(oid);
  select * into e from public.partner_earnings where order_id = oid;
  if e.collection_origin = 'platform' and e.direction = 'payable' then ok := ok + 1; else fail := fail + 1; log := log || ' [stripe-origin]'; end if;
  if e.commission_rate = 0.1000 and e.oolala_commission = 5000 then ok := ok + 1; else fail := fail + 1; log := log || ' [stripe-rate ' || e.commission_rate || '/' || e.oolala_commission || ']'; end if;
  if e.gari_payable = 45000 and e.studio_receivable = 0 then ok := ok + 1; else fail := fail + 1; log := log || ' [stripe-direction]'; end if;

  -- 2. cash, 500 AED, through the real manual rail: Gari collected → 6 %, receivable by Studio
  insert into public.crm_contacts (display_name, email)
  values ('Commission Test Client', 'commission-test@example.com') returning id into cid;
  insert into public.session_packs (crm_contact_id, title, total_sessions, price_amount, currency, created_by)
  values (cid, 'Cash pack', 5, 50000, 'AED', 'grej28roux@gmail.com') returning id into packid;

  j := public.payment_record_manual(packid, 50000, 'AED', 'cash', 'receipt-CG016');
  mref := j ->> 'order';
  select id into moid from public.orders where reference = mref;

  -- 3. a manually paid pack now HAS an earning row at all (it never did before)
  select * into e from public.partner_earnings where order_id = moid;
  if found then ok := ok + 1; else fail := fail + 1; log := log || ' [manual-no-earning]'; end if;
  if e.collection_origin = 'direct' and e.direction = 'receivable' then ok := ok + 1; else fail := fail + 1; log := log || ' [cash-origin]'; end if;
  if e.commission_rate = 0.0600 and e.oolala_commission = 3000 then ok := ok + 1; else fail := fail + 1; log := log || ' [cash-rate ' || e.commission_rate || '/' || e.oolala_commission || ']'; end if;
  -- the direction that matters: Studio is owed 3000, and holds nothing to pay Gari
  if e.studio_receivable = 3000 and e.gari_payable = 0 then ok := ok + 1; else fail := fail + 1; log := log || ' [cash-direction]'; end if;
  -- and the RPC says so out loud, for the operator and the audit trail
  if (j -> 'earning' ->> 'origin') = 'direct' and (j -> 'earning' ->> 'direction') = 'receivable' then ok := ok + 1; else fail := fail + 1; log := log || ' [manual-rpc-report]'; end if;

  -- 4. an explicit per-order override still wins over the origin rate
  update public.partner_earnings set commission_rate = 0.0250 where order_id = oid;
  perform public.recompute_earning(oid);
  select * into e from public.partner_earnings where order_id = oid;
  if e.commission_rate = 0.0250 and e.oolala_commission = 1250 and e.gari_payable = 48750 then ok := ok + 1; else fail := fail + 1; log := log || ' [override ' || e.commission_rate || '/' || e.oolala_commission || ']'; end if;

  -- 5. a receivable can never be written as if Studio held funds to pay out
  begin
    update public.partner_earnings set gari_payable = 999 where order_id = moid;
    fail := fail + 1; log := log || ' [receivable-payable-accepted]';
  exception when check_violation then ok := ok + 1; end;

  -- 6. a settlement is a payout: it sweeps payable earnings only, never receivables
  st := public.create_settlement('gari', (current_date - 1), (current_date + 1), 'AED');
  if (select status from public.partner_earnings where order_id = moid) = 'open'
    then ok := ok + 1; else fail := fail + 1; log := log || ' [receivable-settled]'; end if;

  -- 7. Finance reports the two directions separately, and publishes the rates
  j := public.finance_commissions();
  if (select count(*) from jsonb_array_elements(j -> 'totals') t
       where (t ->> 'direction') = 'payable' and (t ->> 'currency') = 'EUR') = 1
    then ok := ok + 1; else fail := fail + 1; log := log || ' [totals-payable]'; end if;
  if (select count(*) from jsonb_array_elements(j -> 'totals') t
       where (t ->> 'direction') = 'receivable' and (t ->> 'currency') = 'AED'
         and (t ->> 'studio_receivable')::int >= 3000) = 1
    then ok := ok + 1; else fail := fail + 1; log := log || ' [totals-receivable]'; end if;
  if (select count(*) from jsonb_array_elements(j -> 'rates') r where (r ->> 'origin') = 'direct' and (r ->> 'rate')::numeric = 0.0600) = 1
    then ok := ok + 1; else fail := fail + 1; log := log || ' [rates-published]'; end if;

  raise exception 'CG016_TESTS ok=% fail=% %', ok, fail, log;
end $$;

-- =====================================================================
-- CG-016 — Commission: one rate, two accounting directions, dual-signed exemptions
-- One rolled-back transaction. Proves that the commission is 10 % whatever the
-- origin, that the ORIGIN still decides the direction (Oolala owes Gari the net;
-- Gari owes Studio the commission), that every origin books an earning (manual
-- rails included), and that holding a client or a single line out of commission
-- takes BOTH signatures — Coach Gari's and Studio MT's — and nothing less.
-- Run by scripts/db-tests.sh; nothing persists (final RAISE).
-- =====================================================================
do $$
declare
  ok int := 0; fail int := 0; log text := '';
  GARI   constant text := '{"email":"grej28roux@gmail.com","role":"authenticated"}';
  STUDIO constant text := '{"email":"mickael@thestudio.mt","role":"authenticated"}';
  j jsonb; e public.partner_earnings%rowtype;
  oid uuid; oref text; cid uuid; packid uuid; mref text; moid uuid; st jsonb; xid uuid;
begin
  update beau_ph.merchants set mode = 'test' where key = 'coach_gari';
  perform set_config('request.jwt.claims', GARI, true);

  -- 1. one rate everywhere; the origin carries the direction, not the rate
  if (select count(*) from public.commission_origins where rate = 0.1000) = 2
    then ok := ok + 1; else fail := fail + 1; log := log || ' [rate-not-flat]'; end if;
  if (select direction from public.commission_origins where origin = 'platform') = 'payable'
     and (select direction from public.commission_origins where origin = 'direct') = 'receivable'
    then ok := ok + 1; else fail := fail + 1; log := log || ' [direction-lost]'; end if;
  if (select origin from public.collection_rails where rail = 'stripe') = 'platform'
     and (select count(*) from public.collection_rails where rail in ('cash','aani','bank_transfer') and origin = 'direct') = 3
    then ok := ok + 1; else fail := fail + 1; log := log || ' [rail-mapping]'; end if;

  -- 2. Stripe, 500 EUR: Oolala collected → 10 %, payable, net owed to Gari
  --    (order_reason 'support' is target-less, so no booking or pack fixture is needed)
  oref := 'OR-T' || upper(substr(encode(extensions.gen_random_bytes(3),'hex'),1,5));
  insert into public.orders (reference, order_reason, customer_name, customer_contact, currency, gross_amount, status, paid_at)
  values (oref, 'support', 'Test Payer', 'payer@example.com', 'EUR', 50000, 'paid', now()) returning id into oid;
  insert into public.payments (order_id, provider, amount, currency, status, paid_at)
  values (oid, 'stripe', 50000, 'EUR', 'succeeded', now());

  perform public.recompute_earning(oid);
  select * into e from public.partner_earnings where order_id = oid;
  if e.collection_origin = 'platform' and e.direction = 'payable' then ok := ok + 1; else fail := fail + 1; log := log || ' [stripe-origin]'; end if;
  if e.commission_rate = 0.1000 and e.oolala_commission = 5000 then ok := ok + 1; else fail := fail + 1; log := log || ' [stripe-rate ' || e.commission_rate || '/' || e.oolala_commission || ']'; end if;
  if e.gari_payable = 45000 and e.studio_receivable = 0 then ok := ok + 1; else fail := fail + 1; log := log || ' [stripe-direction]'; end if;

  -- 3. cash, 500 AED, through the real manual rail: Gari collected → same 10 %, but receivable
  insert into public.crm_contacts (display_name, email)
  values ('Commission Test Client', 'commission-test@example.com') returning id into cid;
  insert into public.session_packs (crm_contact_id, title, total_sessions, price_amount, currency, created_by)
  values (cid, 'Cash pack', 5, 50000, 'AED', 'grej28roux@gmail.com') returning id into packid;

  j := public.payment_record_manual(packid, 50000, 'AED', 'cash', 'receipt-CG016');
  mref := j ->> 'order';
  select id into moid from public.orders where reference = mref;

  --    a manually paid pack now HAS an earning row at all (it never did before)
  select * into e from public.partner_earnings where order_id = moid;
  if found then ok := ok + 1; else fail := fail + 1; log := log || ' [manual-no-earning]'; end if;
  if e.collection_origin = 'direct' and e.direction = 'receivable' then ok := ok + 1; else fail := fail + 1; log := log || ' [cash-origin]'; end if;
  if e.commission_rate = 0.1000 and e.oolala_commission = 5000 then ok := ok + 1; else fail := fail + 1; log := log || ' [cash-rate ' || e.commission_rate || '/' || e.oolala_commission || ']'; end if;
  --    the direction that matters: Studio is owed 5000, and holds nothing to pay Gari
  if e.studio_receivable = 5000 and e.gari_payable = 0 then ok := ok + 1; else fail := fail + 1; log := log || ' [cash-direction]'; end if;
  if (j -> 'earning' ->> 'origin') = 'direct' and (j -> 'earning' ->> 'direction') = 'receivable' then ok := ok + 1; else fail := fail + 1; log := log || ' [manual-rpc-report]'; end if;

  -- 4. an exemption on one line: requested by Studio, it changes NOTHING on its own
  j := public.commission_exemption_request(jsonb_build_object('scope','order','order_id',oid::text,'reason','Launch partner, agreed gesture'));
  xid := (j ->> 'id')::uuid;
  if (j ->> 'status') = 'pending' and (j ->> 'rate')::numeric = 0 then ok := ok + 1; else fail := fail + 1; log := log || ' [request-not-pending]'; end if;
  perform public.recompute_earning(oid);
  if (select oolala_commission from public.partner_earnings where order_id = oid) = 5000
    then ok := ok + 1; else fail := fail + 1; log := log || ' [pending-already-bites]'; end if;

  -- 5. one signature is not enough, and a side cannot sign twice to fake the second
  j := public.commission_exemption_approve(xid);                     -- Gari signs
  if (j ->> 'status') = 'pending' and (j ->> 'gari_by') is not null and (j ->> 'studio_by') is null
    then ok := ok + 1; else fail := fail + 1; log := log || ' [one-sig-activates]'; end if;
  begin perform public.commission_exemption_approve(xid); fail := fail + 1; log := log || ' [double-sign-accepted]';
  exception when sqlstate 'P0003' then ok := ok + 1; end;
  perform public.recompute_earning(oid);
  if (select oolala_commission from public.partner_earnings where order_id = oid) = 5000
    then ok := ok + 1; else fail := fail + 1; log := log || ' [one-sig-bites]'; end if;

  -- 6. the second signature, from the OTHER side, is what makes it real — and it reprices at once
  perform set_config('request.jwt.claims', STUDIO, true);
  j := public.commission_exemption_approve(xid);
  if (j ->> 'status') = 'active' and (j ->> 'studio_by') is not null then ok := ok + 1; else fail := fail + 1; log := log || ' [two-sigs-not-active]'; end if;
  select * into e from public.partner_earnings where order_id = oid;
  if e.oolala_commission = 0 and e.commission_rate = 0 and e.exemption_id = xid
    then ok := ok + 1; else fail := fail + 1; log := log || ' [exempt-not-applied ' || e.oolala_commission || ']'; end if;
  --    the direction still holds: Oolala collected, so the whole net is payable to Gari
  if e.gari_payable = 50000 and e.studio_receivable = 0 then ok := ok + 1; else fail := fail + 1; log := log || ' [exempt-breaks-direction]'; end if;

  -- 7. 'active' is not a label an operator can write by hand
  begin
    insert into public.commission_exemptions (scope, order_id, reason, status, requested_by)
    values ('order', moid, 'no signatures at all', 'active', 'someone@example.com');
    fail := fail + 1; log := log || ' [unsigned-active-accepted]';
  exception when check_violation then ok := ok + 1; end;

  -- 8. only Gari and Studio MT have a signature to give
  perform set_config('request.jwt.claims', '{"email":"nobody@example.com","role":"authenticated"}', true);
  if public.commission_party() is null then ok := ok + 1; else fail := fail + 1; log := log || ' [stranger-has-a-side]'; end if;
  perform set_config('request.jwt.claims', STUDIO, true);

  -- 9. a client-scope exemption covers that client's orders, and revoking it brings the commission back
  j := public.commission_exemption_request(jsonb_build_object('scope','client','crm_contact_id',cid::text,'reason','Ambassador, no commission while the deal runs'));
  xid := (j ->> 'id')::uuid;
  perform public.commission_exemption_approve(xid);                   -- Studio signs
  perform set_config('request.jwt.claims', GARI, true);
  perform public.commission_exemption_approve(xid);                   -- Gari countersigns → active
  select * into e from public.partner_earnings where order_id = moid;
  if e.oolala_commission = 0 and e.studio_receivable = 0 and e.exemption_id = xid
    then ok := ok + 1; else fail := fail + 1; log := log || ' [client-exempt-not-applied]'; end if;

  j := public.commission_exemption_close(xid, 'deal ended');
  if (j ->> 'status') = 'revoked' then ok := ok + 1; else fail := fail + 1; log := log || ' [revoke-status]'; end if;
  --    the exemption rate must not survive the exemption
  select * into e from public.partner_earnings where order_id = moid;
  if e.commission_rate = 0.1000 and e.oolala_commission = 5000 and e.studio_receivable = 5000 and e.exemption_id is null
    then ok := ok + 1; else fail := fail + 1; log := log || ' [revoked-rate-stuck ' || e.commission_rate || ']'; end if;

  -- 10. a hand-set per-order override still holds through a recompute, as it always did
  update public.partner_earnings set commission_rate = 0.0250 where order_id = moid;
  perform public.recompute_earning(moid);
  select * into e from public.partner_earnings where order_id = moid;
  if e.commission_rate = 0.0250 and e.oolala_commission = 1250 then ok := ok + 1; else fail := fail + 1; log := log || ' [override ' || e.commission_rate || ']'; end if;

  -- 11. a receivable can never be written as if Studio held funds to pay out
  begin
    update public.partner_earnings set gari_payable = 999 where order_id = moid;
    fail := fail + 1; log := log || ' [receivable-payable-accepted]';
  exception when check_violation then ok := ok + 1; end;

  -- 12. a settlement is a payout: it sweeps payable earnings only, never receivables
  st := public.create_settlement('gari', (current_date - 1), (current_date + 1), 'AED');
  if (select status from public.partner_earnings where order_id = moid) = 'open'
    then ok := ok + 1; else fail := fail + 1; log := log || ' [receivable-settled]'; end if;

  -- 13. Finance reports the two directions separately, and the exemptions are visible with their signatures
  j := public.finance_commissions();
  if (select count(*) from jsonb_array_elements(j -> 'totals') t
       where (t ->> 'direction') = 'payable' and (t ->> 'currency') = 'EUR') = 1
    then ok := ok + 1; else fail := fail + 1; log := log || ' [totals-payable]'; end if;
  if (select count(*) from jsonb_array_elements(j -> 'totals') t
       where (t ->> 'direction') = 'receivable' and (t ->> 'currency') = 'AED') = 1
    then ok := ok + 1; else fail := fail + 1; log := log || ' [totals-receivable]'; end if;
  j := public.commission_exemptions_list();
  if (j ->> 'side') = 'gari'
     and (select count(*) from jsonb_array_elements(j -> 'rows') r where (r ->> 'status') = 'active' and (r ->> 'gari_by') is not null and (r ->> 'studio_by') is not null) >= 1
    then ok := ok + 1; else fail := fail + 1; log := log || ' [exemptions-list]'; end if;
  if (select count(*) from public.admin_audit where area = 'commission' and action like 'exemption_%') >= 4
    then ok := ok + 1; else fail := fail + 1; log := log || ' [exemption-audit]'; end if;

  raise exception 'CG016_TESTS ok=% fail=% %', ok, fail, log;
end $$;

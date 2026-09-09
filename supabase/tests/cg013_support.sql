-- CG-013 Support Coach Gari — database suite. One transaction, always rolls
-- back (RAISE EXCEPTION 'CG013_TESTS ok=… fail=…').
-- Proves: Support is not a service (nothing bookable); the amount, currency,
-- floor / ceiling and rail are validated SERVER-side; the record is a generic
-- support order + a BEAU PH request with intent `support` and the optional
-- message in its metadata; a rail that does not list the intent is refused;
-- the payer's token reads state only; browser completion is never proof — a
-- forged webhook amount is ignored and only the verified event marks paid;
-- paying creates no booking, pack, session or credit; Finance shows it as
-- Type: Support with the message; a second webhook does not double-pay.
do $$
declare
  ok int := 0; fail int := 0; log text := '';
  rt jsonb := '{"stripe":{"configured":true,"mode":"test","embedded":true}}'::jsonb;
  j jsonb; e1 jsonb; oref text; tok text; rid uuid; n int; b0 int; p0 int; s0 int; e0 int;
begin
  update beau_ph.merchants set mode = 'test' where key = 'coach_gari';   -- suites run the host in TEST mode regardless of the production setting (rolled back)
  insert into public.app_users (email, display_name, party) values ('fin@test.local', 'Fin', 'gari');
  insert into public.app_permissions (email, permission) values ('fin@test.local', 'finance:view'), ('fin@test.local', 'finance:manage');
  select count(*) into b0 from public.bookings; select count(*) into p0 from public.session_packs; select count(*) into s0 from public.coaching_sessions;
  select count(*) into e0 from public.session_packs where payment_status = 'paid';

  /* ---- 1. not a service: nothing bookable, nothing in the catalogue ---- */
  if not exists (select 1 from public.services where slug ilike '%support%' or title ilike '%support%') then ok := ok + 1; else fail := fail + 1; log := log || ' [support in catalogue]'; end if;

  /* ---- 2. server-side validation: floor, ceiling, currency ---- */
  begin perform public.support_create(500, 'AED', null, rt); fail := fail + 1; log := log || ' [below floor accepted]'; exception when sqlstate '22023' then ok := ok + 1; end;
  begin perform public.support_create(600000, 'AED', null, rt); fail := fail + 1; log := log || ' [above ceiling accepted]'; exception when sqlstate '22023' then ok := ok + 1; end;
  begin perform public.support_create(5000, 'ZAR', null, rt); fail := fail + 1; log := log || ' [unsupported currency accepted]'; exception when sqlstate '22023' then ok := ok + 1; end;
  begin perform public.support_create(5000, 'AED', null, '{}'::jsonb); fail := fail + 1; log := log || ' [no configured rail accepted]'; exception when sqlstate '22023' or sqlstate 'P0003' then ok := ok + 1; end;
  -- only rails that list the support intent are offered: card, not Aani / cash
  j := beau_ph.eligible_methods('coach_gari', 'AE', 'AED', rt, null, 'customer', 'support');
  if (select array_agg(e ->> 'provider' order by e ->> 'provider') from jsonb_array_elements(j) e) = array['stripe'] then ok := ok + 1; else fail := fail + 1; log := log || ' [support rails ' || j::text || ']'; end if;

  /* ---- 3. create: generic support order + BEAU PH request, intent support, message persisted safely ---- */
  j := public.support_create(5000, 'AED', '  Keep going,   Coach Gari!  ', rt);
  oref := j -> 'order' ->> 'reference'; tok := j ->> 'token'; rid := (j -> 'request' ->> 'id')::uuid;
  if (select order_reason from public.orders where reference = oref) = 'support'
     and (select booking_id is null and session_pack_id is null from public.orders where reference = oref)
     and (select gross_amount from public.orders where reference = oref) = 5000 and (select currency from public.orders where reference = oref) = 'AED'
     and (select status from public.orders where reference = oref) = 'pending_payment' then ok := ok + 1; else fail := fail + 1; log := log || ' [support order]'; end if;
  if (select intent from beau_ph.payment_requests where id = rid) = 'support'
     and (select amount from beau_ph.payment_requests where id = rid) = 5000 and (select currency from beau_ph.payment_requests where id = rid) = 'AED'
     and (select provider_key from beau_ph.payment_requests where id = rid) = 'stripe'
     and (select public_reference from beau_ph.payment_requests where id = rid) like 'SUP-%'
     and (select metadata ->> 'message' from beau_ph.payment_requests where id = rid) = 'Keep going, Coach Gari!' then ok := ok + 1; else fail := fail + 1; log := log || ' [support request ' || j::text || ']'; end if;
  if tok ~ '^[0-9a-f]{64}$' and (select access_token_hash from public.orders where reference = oref) = encode(extensions.digest(tok, 'sha256'), 'hex') then ok := ok + 1; else fail := fail + 1; log := log || ' [support token]'; end if;
  -- an over-long message is capped, never refused; no message is fine
  j := public.support_create(2500, 'AED', repeat('x', 900), rt);
  if length((select metadata ->> 'message' from beau_ph.payment_requests where id = (j -> 'request' ->> 'id')::uuid)) = 500 then ok := ok + 1; else fail := fail + 1; log := log || ' [message cap]'; end if;
  j := public.support_create(2500, 'AED', null, rt);
  if not ((select metadata from beau_ph.payment_requests where id = (j -> 'request' ->> 'id')::uuid) ? 'message') then ok := ok + 1; else fail := fail + 1; log := log || ' [empty message stored]'; end if;

  /* ---- 4. a rail that does not list the intent is refused for this order ---- */
  begin perform public.cg_ph_request_for_order((select o from public.orders o where reference = oref), 'aani', '{}'::jsonb, false, null, null, null); fail := fail + 1; log := log || ' [aani accepted support]'; exception when sqlstate 'P0003' then ok := ok + 1; end;
  begin perform public.cg_ph_request_for_order((select o from public.orders o where reference = oref), 'cash', '{}'::jsonb, false, null, null, null); fail := fail + 1; log := log || ' [cash accepted support]'; exception when sqlstate 'P0003' then ok := ok + 1; end;

  /* ---- 5. the payer's token reads state only; a wrong token finds nothing ---- */
  begin perform public.support_state(oref, repeat('a', 64)); fail := fail + 1; log := log || ' [wrong token reads]'; exception when sqlstate 'P0002' then ok := ok + 1; end;
  if (public.support_state(oref, tok) ->> 'status') = 'pending_payment' then ok := ok + 1; else fail := fail + 1; log := log || ' [state pending]'; end if;

  /* ---- 6. browser completion is never proof: a forged amount is ignored; only the verified event pays ---- */
  perform public.attach_checkout(oref, 'cs_sup_1', null, now() + interval '30 minutes');
  e1 := public.process_stripe_event(jsonb_build_object('id', 'evt_sup_bad', 'type', 'checkout.session.completed', 'livemode', false,
          'data', jsonb_build_object('object', jsonb_build_object('id', 'cs_sup_1', 'payment_status', 'paid', 'amount_total', 4000, 'currency', 'aed', 'payment_intent', 'pi_sup_bad', 'client_reference_id', oref))));
  if (e1 ->> 'status') = 'ignored' and (select status from public.orders where reference = oref) = 'pending_payment' and (public.support_state(oref, tok) ->> 'status') = 'pending_payment' then ok := ok + 1; else fail := fail + 1; log := log || ' [forged amount ' || e1::text || ']'; end if;
  e1 := public.process_stripe_event(jsonb_build_object('id', 'evt_sup_ok', 'type', 'checkout.session.completed', 'livemode', false,
          'data', jsonb_build_object('object', jsonb_build_object('id', 'cs_sup_1', 'payment_status', 'paid', 'amount_total', 5000, 'currency', 'aed', 'payment_intent', 'pi_sup_ok', 'client_reference_id', oref)),
          '_enrich', jsonb_build_object('charge_id', 'ch_sup', 'balance_transaction_id', 'txn_sup', 'fee_amount', 200)));
  if (e1 ->> 'status') = 'processed' and (select status from public.orders where reference = oref) = 'paid'
     and (select status from beau_ph.payment_requests where id = rid) = 'paid'
     and exists (select 1 from public.payments p join public.orders o on o.id = p.order_id where o.reference = oref and p.provider_payment_intent_id = 'pi_sup_ok' and p.amount = 5000 and p.currency = 'AED')
     and exists (select 1 from beau_ph.reconciliations rc join beau_ph.payment_events pe on pe.id = rc.payment_event_id where pe.request_id = rid)
     and (public.support_state(oref, tok) ->> 'status') = 'paid' then ok := ok + 1; else fail := fail + 1; log := log || ' [webhook pays ' || e1::text || ']'; end if;
  -- a re-delivery does not double-pay
  e1 := public.process_stripe_event(jsonb_build_object('id', 'evt_sup_ok2', 'type', 'checkout.session.completed', 'livemode', false,
          'data', jsonb_build_object('object', jsonb_build_object('id', 'cs_sup_1', 'payment_status', 'paid', 'amount_total', 5000, 'currency', 'aed', 'payment_intent', 'pi_sup_ok', 'client_reference_id', oref))));
  if (select count(*) from public.payments p join public.orders o on o.id = p.order_id where o.reference = oref) = 1 then ok := ok + 1; else fail := fail + 1; log := log || ' [double pay]'; end if;

  /* ---- 7. nothing else moved: no booking, pack, session or credit ---- */
  if (select count(*) from public.bookings) = b0 and (select count(*) from public.session_packs) = p0 and (select count(*) from public.coaching_sessions) = s0
     and (select count(*) from public.session_packs where payment_status = 'paid') = e0 then ok := ok + 1; else fail := fail + 1; log := log || ' [side effects]'; end if;

  /* ---- 8. Finance: Type Support, amount, currency, method, status, message; the payer identity is a masked hint ---- */
  perform set_config('request.jwt.claims', '{"role":"authenticated","email":"fin@test.local"}', true);
  execute 'set local role authenticated';
  j := public.finance_transactions(50);
  if exists (select 1 from jsonb_array_elements(j) t where t ->> 'reference' = oref and t ->> 'type' = 'support' and (t ->> 'amount')::int = 5000 and t ->> 'currency' = 'AED'
                and t ->> 'method' = 'stripe' and t ->> 'status' = 'paid' and t ->> 'support_message' = 'Keep going, Coach Gari!' and t ->> 'item' = 'Support Coach Gari')
     then ok := ok + 1; else fail := fail + 1; log := log || ' [finance row]'; end if;
  j := public.finance_transaction_detail(oref);
  if j -> 'order' ->> 'reason' = 'support' and (j -> 'booking') = 'null'::jsonb and (j -> 'pack') = 'null'::jsonb and j -> 'requests' -> 0 ->> 'intent' = 'support'
     and j -> 'requests' -> 0 ->> 'support_message' = 'Keep going, Coach Gari!' then ok := ok + 1; else fail := fail + 1; log := log || ' [finance detail]'; end if;
  execute 'reset role';

  /* ---- 9. the RPCs are service-role only (the Edge Function is the only caller) ---- */
  perform set_config('request.jwt.claims', '{"role":"anon"}', true);
  execute 'set local role anon';
  begin perform public.support_create(5000, 'AED', null, rt); fail := fail + 1; log := log || ' [anon creates]'; exception when insufficient_privilege then ok := ok + 1; end;
  begin perform public.support_state(oref, tok); fail := fail + 1; log := log || ' [anon reads state]'; exception when insufficient_privilege then ok := ok + 1; end;
  execute 'reset role';

  raise exception 'CG013_TESTS ok=% fail=% %', ok, fail, log;
end $$;

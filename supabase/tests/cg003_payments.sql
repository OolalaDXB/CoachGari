-- CG-003 payments & ledger — database-level suite. One transaction, always
-- rolls back (ends with RAISE EXCEPTION 'CG003_TESTS ok=… fail=…').
-- Proves: order from a hold (trusted amount), checkout attach extends the hold,
-- synthetic checkout.session.completed → exactly one payment, order paid,
-- booking confirmed, ledger (gross 4500, fee 161 → net 4339, commission 434,
-- payable 3905), retry of the same event = duplicate with no second payment /
-- earning, amount mismatch never confirms, expired checkout releases capacity,
-- partial and full refunds adjust economics (commission floors at 0),
-- lost dispute adjusts economics, settlement aggregates and transitions.
do $$
declare
  ok int := 0; fail int := 0; log text := '';
  svc uuid; d date; base timestamptz; j jsonb; o jsonb; ev jsonb; res jsonb; n int; e record; s jsonb;
  ref text; tok text; oref text; sess text := 'cs_test_' || replace(gen_random_uuid()::text, '-', ''); pi text := 'pi_test_' || replace(gen_random_uuid()::text, '-', '');
begin
  d := current_date + 3; while extract(isodow from d) <> 1 loop d := d + 1; end loop;
  update public.availability_rules set active = false;
  insert into public.services (slug, title, category, duration_minutes, price_amount, currency, delivery_mode, default_capacity, active, listed)
  values ('t-pay', 'Test paid session', 'mentoring', 60, 4500, 'USD', 'online', 1, true, false) returning id into svc;
  insert into public.availability_rules (weekday, start_time, end_time, timezone) values (1, '09:00', '12:00', 'Asia/Dubai');
  select start_at into base from public.available_slots('t-pay', d, d, 'Asia/Dubai') order by start_at limit 1;

  /* 1. hold → order with trusted amount */
  j := public.create_hold('t-pay', base, 1, 'a1111111-1111-4111-8111-111111111111', 'Pay One', 'payone@coachgari.com');
  ref := j ->> 'reference'; tok := j ->> 'manage_token';
  o := public.create_order_for_booking(ref, tok); oref := o ->> 'reference';
  if (o ->> 'gross_amount')::int = 4500 and o ->> 'currency' = 'USD' and o ->> 'status' = 'pending_payment' and oref like 'OR-%' then ok := ok + 1;
  else fail := fail + 1; log := log || ' [order create ' || o::text || ']'; end if;
  -- idempotent: a second call returns the same order
  if (public.create_order_for_booking(ref, tok) ->> 'reference') = oref and (select count(*) from public.orders) = 1 then ok := ok + 1;
  else fail := fail + 1; log := log || ' [order idempotence]'; end if;

  /* 2. attach checkout: booking pending_payment, hold aligned to checkout expiry (30 min) */
  o := public.attach_checkout(oref, sess, 'https://checkout.stripe.com/c/pay/' || sess, now() + interval '30 minutes');
  if (select status from public.bookings where reference = ref) = 'pending_payment'
     and (select hold_expires_at from public.bookings where reference = ref) > now() + interval '25 minutes'
     and (o ->> 'checkout_attempts')::int = 1 then ok := ok + 1;
  else fail := fail + 1; log := log || ' [attach checkout]'; end if;
  -- still consumes capacity
  select count(*) into n from public.available_slots('t-pay', d, d, 'Asia/Dubai') where start_at = base;
  if n = 0 then ok := ok + 1; else fail := fail + 1; log := log || ' [pending slot listed]'; end if;

  /* 3. webhook: checkout.session.completed with fee enrichment */
  ev := jsonb_build_object('id', 'evt_test_1', 'type', 'checkout.session.completed', 'livemode', false,
          'data', jsonb_build_object('object', jsonb_build_object('id', sess, 'payment_status', 'paid', 'amount_total', 4500, 'currency', 'usd', 'payment_intent', pi,
                                                                   'metadata', jsonb_build_object('order_reference', oref))),
          '_enrich', jsonb_build_object('charge_id', 'ch_test_1', 'balance_transaction_id', 'txn_test_1', 'fee_amount', 161));
  res := public.process_stripe_event(ev);
  if res ->> 'status' = 'processed' and (select status from public.orders where reference = oref) = 'paid'
     and (select status from public.bookings where reference = ref) = 'confirmed'
     and (select count(*) from public.payments) = 1 then ok := ok + 1;
  else fail := fail + 1; log := log || ' [completed ' || res::text || ']'; end if;
  select * into e from public.partner_earnings pe join public.orders oo on oo.id = pe.order_id where oo.reference = oref;
  if e.gross_amount = 4500 and e.stripe_fee = 161 and e.net_collected = 4339 and e.oolala_commission = 434 and e.gari_payable = 3905 and e.status = 'open' then ok := ok + 1;
  else fail := fail + 1; log := log || format(' [ledger g=%s f=%s n=%s c=%s p=%s]', e.gross_amount, e.stripe_fee, e.net_collected, e.oolala_commission, e.gari_payable); end if;
  if (select count(*) from public.email_events where kind in ('booking_confirmed','payment_received') and status = 'pending') = 2 then ok := ok + 1;
  else fail := fail + 1; log := log || ' [email events queued]'; end if;

  /* 4. retry of the same event: duplicate, nothing doubled */
  res := public.process_stripe_event(ev);
  if (res ->> 'duplicate')::boolean and (select count(*) from public.payments) = 1 and (select count(*) from public.partner_earnings) = 1
     and (select count(*) from public.webhook_events) = 1 then ok := ok + 1;
  else fail := fail + 1; log := log || ' [retry duplicate ' || res::text || ']'; end if;
  -- a different event id for the same session/payment_intent (Stripe re-delivery with new id) still yields one payment
  res := public.process_stripe_event(ev || jsonb_build_object('id', 'evt_test_1b'));
  if (select count(*) from public.payments) = 1 and (select count(*) from public.partner_earnings) = 1 then ok := ok + 1;
  else fail := fail + 1; log := log || ' [re-delivery duplicated payment]'; end if;

  /* 5. amount mismatch never confirms */
  j := public.create_hold('t-pay', base + interval '1 hour', 1, 'a2222222-2222-4222-8222-222222222222', 'Pay Two', 'paytwo@coachgari.com');
  o := public.create_order_for_booking(j ->> 'reference', j ->> 'manage_token');
  perform public.attach_checkout(o ->> 'reference', sess || '_2', 'https://checkout.stripe.com/x', now() + interval '30 minutes');
  res := public.process_stripe_event(jsonb_build_object('id', 'evt_test_2', 'type', 'checkout.session.completed', 'livemode', false,
          'data', jsonb_build_object('object', jsonb_build_object('id', sess || '_2', 'payment_status', 'paid', 'amount_total', 100, 'currency', 'usd', 'payment_intent', pi || '_2'))));
  if res ->> 'status' = 'ignored' and (select status from public.orders where reference = o ->> 'reference') = 'pending_payment'
     and (select status from public.bookings where reference = j ->> 'reference') = 'pending_payment' then ok := ok + 1;
  else fail := fail + 1; log := log || ' [mismatch ' || res::text || ']'; end if;

  /* 6. expired checkout releases capacity, order cancelled */
  res := public.process_stripe_event(jsonb_build_object('id', 'evt_test_3', 'type', 'checkout.session.expired', 'livemode', false,
          'data', jsonb_build_object('object', jsonb_build_object('id', sess || '_2'))));
  select count(*) into n from public.available_slots('t-pay', d, d, 'Asia/Dubai') where start_at = base + interval '1 hour';
  if (select status from public.bookings where reference = j ->> 'reference') = 'expired'
     and (select status from public.orders where reference = o ->> 'reference') = 'cancelled' and n = 1 then ok := ok + 1;
  else fail := fail + 1; log := log || ' [expired checkout]'; end if;
  -- time-based expiry path: pending_payment past its hold → expire_holds closes booking and order
  j := public.create_hold('t-pay', base + interval '2 hours', 1, 'a3333333-3333-4333-8333-333333333333', 'Pay Three', 'paythree@coachgari.com');
  o := public.create_order_for_booking(j ->> 'reference', j ->> 'manage_token');
  perform public.attach_checkout(o ->> 'reference', sess || '_3', 'https://checkout.stripe.com/y', now() - interval '1 minute');
  n := public.expire_holds();
  if (select status from public.bookings where reference = j ->> 'reference') = 'expired'
     and (select status from public.orders where reference = o ->> 'reference') = 'cancelled' then ok := ok + 1;
  else fail := fail + 1; log := log || ' [expire_holds pending_payment]'; end if;

  /* 7. partial refund 2000 → net 2339, commission 234, payable 2105 */
  res := public.process_stripe_event(jsonb_build_object('id', 'evt_test_4', 'type', 'refund.created', 'livemode', false,
          'data', jsonb_build_object('object', jsonb_build_object('id', 're_test_1', 'amount', 2000, 'currency', 'usd', 'status', 'succeeded', 'payment_intent', pi, 'reason', 'requested_by_customer'))));
  select * into e from public.partner_earnings pe join public.orders oo on oo.id = pe.order_id where oo.reference = oref;
  if (select status from public.orders where reference = oref) = 'partially_refunded' and e.refund_amount = 2000 and e.net_collected = 2339 and e.oolala_commission = 234 and e.gari_payable = 2105 then ok := ok + 1;
  else fail := fail + 1; log := log || format(' [partial refund n=%s c=%s p=%s]', e.net_collected, e.oolala_commission, e.gari_payable); end if;
  -- refund.updated for the same refund does not double count
  res := public.process_stripe_event(jsonb_build_object('id', 'evt_test_5', 'type', 'refund.updated', 'livemode', false,
          'data', jsonb_build_object('object', jsonb_build_object('id', 're_test_1', 'amount', 2000, 'currency', 'usd', 'status', 'succeeded', 'payment_intent', pi))));
  if (select count(*) from public.refunds) = 1 and (select refund_amount from public.partner_earnings pe join public.orders oo on oo.id = pe.order_id where oo.reference = oref) = 2000 then ok := ok + 1;
  else fail := fail + 1; log := log || ' [refund.updated double count]'; end if;

  /* 8. full refund of the rest → net −161 (Stripe keeps the fee), commission floors at 0, payable −161 */
  res := public.process_stripe_event(jsonb_build_object('id', 'evt_test_6', 'type', 'refund.created', 'livemode', false,
          'data', jsonb_build_object('object', jsonb_build_object('id', 're_test_2', 'amount', 2500, 'currency', 'usd', 'status', 'succeeded', 'payment_intent', pi))));
  select * into e from public.partner_earnings pe join public.orders oo on oo.id = pe.order_id where oo.reference = oref;
  if (select status from public.orders where reference = oref) = 'refunded' and e.net_collected = -161 and e.oolala_commission = 0 and e.gari_payable = -161 then ok := ok + 1;
  else fail := fail + 1; log := log || format(' [full refund n=%s c=%s p=%s status=%s]', e.net_collected, e.oolala_commission, e.gari_payable, (select status from public.orders where reference = oref)); end if;

  /* 9. dispute on a fresh paid order: only 'lost' hits the ledger */
  j := public.create_hold('t-pay', base + interval '1 hour', 1, 'a4444444-4444-4444-8444-444444444444', 'Pay Four', 'payfour@coachgari.com');
  o := public.create_order_for_booking(j ->> 'reference', j ->> 'manage_token');
  perform public.attach_checkout(o ->> 'reference', sess || '_4', 'https://checkout.stripe.com/z', now() + interval '30 minutes');
  perform public.process_stripe_event(jsonb_build_object('id', 'evt_test_7', 'type', 'checkout.session.completed', 'livemode', false,
          'data', jsonb_build_object('object', jsonb_build_object('id', sess || '_4', 'payment_status', 'paid', 'amount_total', 4500, 'currency', 'usd', 'payment_intent', pi || '_4')),
          '_enrich', jsonb_build_object('charge_id', 'ch_test_4', 'balance_transaction_id', 'txn_test_4', 'fee_amount', 161)));
  perform public.process_stripe_event(jsonb_build_object('id', 'evt_test_8', 'type', 'charge.dispute.created', 'livemode', false,
          'data', jsonb_build_object('object', jsonb_build_object('id', 'dp_test_1', 'amount', 4500, 'currency', 'usd', 'status', 'needs_response', 'payment_intent', pi || '_4', 'reason', 'fraudulent'))));
  select * into e from public.partner_earnings pe join public.orders oo on oo.id = pe.order_id where oo.reference = o ->> 'reference';
  if e.chargeback_amount = 0 and e.net_collected = 4339 then ok := ok + 1; else fail := fail + 1; log := log || ' [dispute open should not hit ledger]'; end if;
  perform public.process_stripe_event(jsonb_build_object('id', 'evt_test_9', 'type', 'charge.dispute.closed', 'livemode', false,
          'data', jsonb_build_object('object', jsonb_build_object('id', 'dp_test_1', 'amount', 4500, 'currency', 'usd', 'status', 'lost', 'payment_intent', pi || '_4'))));
  select * into e from public.partner_earnings pe join public.orders oo on oo.id = pe.order_id where oo.reference = o ->> 'reference';
  if e.chargeback_amount = 4500 and e.net_collected = -161 and e.oolala_commission = 0 and e.gari_payable = -161 and (select count(*) from public.chargebacks) = 1 then ok := ok + 1;
  else fail := fail + 1; log := log || format(' [dispute lost cb=%s n=%s]', e.chargeback_amount, e.net_collected); end if;

  /* 10. settlement over the period: both earnings, sums, transitions */
  s := public.create_settlement('gari', current_date - 1, current_date + 1, 'USD');
  if (s ->> 'items')::int = 2 and (s ->> 'status') = 'ready'
     and (s ->> 'amount_payable')::int = -322 and (s ->> 'gross_amount')::int = 9000 and (s ->> 'fee_amount')::int = 322
     and (select count(*) from public.partner_earnings where status = 'settled') = 2 then ok := ok + 1;
  else fail := fail + 1; log := log || ' [settlement ' || s::text || ']'; end if;
  s := public.mark_settlement_paid(s ->> 'reference', 'WISE-TEST-001');
  if s ->> 'status' = 'paid' and s ->> 'bank_transfer_reference' = 'WISE-TEST-001' then ok := ok + 1; else fail := fail + 1; log := log || ' [settlement paid]'; end if;
  s := public.mark_settlement_reconciled(s ->> 'reference');
  if s ->> 'status' = 'reconciled' then ok := ok + 1; else fail := fail + 1; log := log || ' [settlement reconciled]'; end if;
  -- a settled earning that changes afterwards is flagged
  perform public.process_stripe_event(jsonb_build_object('id', 'evt_test_10', 'type', 'refund.created', 'livemode', false,
          'data', jsonb_build_object('object', jsonb_build_object('id', 're_test_3', 'amount', 100, 'currency', 'usd', 'status', 'succeeded', 'payment_intent', pi || '_4'))));
  if (select adjusted_at is not null from public.partner_earnings pe join public.orders oo on oo.id = pe.order_id where oo.reference = o ->> 'reference') then ok := ok + 1;
  else fail := fail + 1; log := log || ' [post-settlement adjustment flag]'; end if;

  /* 11. unknown order / unhandled type are ignored, not errors */
  res := public.process_stripe_event(jsonb_build_object('id', 'evt_test_11', 'type', 'checkout.session.completed', 'livemode', false,
          'data', jsonb_build_object('object', jsonb_build_object('id', 'cs_unknown', 'payment_status', 'paid', 'amount_total', 1, 'currency', 'usd'))));
  if res ->> 'status' = 'ignored' then ok := ok + 1; else fail := fail + 1; log := log || ' [unknown order]'; end if;
  res := public.process_stripe_event(jsonb_build_object('id', 'evt_test_12', 'type', 'customer.created', 'livemode', false, 'data', jsonb_build_object('object', '{}'::jsonb)));
  if res ->> 'status' = 'ignored' then ok := ok + 1; else fail := fail + 1; log := log || ' [unhandled type]'; end if;

  /* 12. booking_to_json exposes the order for polling */
  j := public.get_booking(ref, tok);
  if j -> 'order' ->> 'reference' = oref and j -> 'order' ->> 'status' = 'refunded' and j ->> 'status' = 'confirmed' then ok := ok + 1;
  else fail := fail + 1; log := log || ' [booking_to_json order]'; end if;

  raise exception 'CG003_TESTS ok=% fail=% %', ok, fail, log;
end $$;

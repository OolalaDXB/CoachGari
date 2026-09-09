-- CG-014 transactional email outbox — database-level suite. One transaction, always
-- rolls back (ends with RAISE EXCEPTION 'CG014_TESTS ok=… fail=…').
-- Proves: a reconciled booking payment queues exactly one customer confirmation and
-- one owner notice (replayed / re-delivered webhooks add nothing); claim leases rows
-- and a failed send leaves booking + order untouched (retry, then failed after the
-- maximum, operator retry); a confirmed booking cancelled by the customer or the
-- coach queues one cancellation (a cancelled hold queues nothing); moving the
-- coaching session of a confirmed booking moves the booking and queues one
-- reschedule per actual change; a manual pack receipt queues the client receipt +
-- owner notice; a support payment queues the thank-you to the Stripe-captured email
-- and creates no booking / pack / session / credit; an enquiry queues the owner lead
-- + the customer acknowledgement (phone contact → skipped); addresses stay out of
-- the operator view; sender RPCs are service_role only; the cron drain is scheduled.
do $$
declare
  ok int := 0; fail int := 0; log text := '';
  svc uuid; d date; base timestamptz; j jsonb; o jsonb; ev jsonb; res jsonb; n int; r record;
  ref text; tok text; oref text; oid uuid; bid uuid; ref2 text; tok2 text; oref2 text; ref3 text; tok3 text; ref4 text; tok4 text; oref4 text; bid4 uuid; sid uuid;
  cA uuid; cB uuid; p1 uuid; p2 uuid; e_id uuid; e2_id uuid; cid uuid; cid2 uuid; sref text; stok text;
  rt jsonb := '{"stripe":{"configured":true,"mode":"test","embedded":true}}'::jsonb;
  b_book int; b_pack int; b_sess int; b_paidpacks int;
begin
  update beau_ph.merchants set mode = 'test' where key = 'coach_gari';
  insert into public.app_users (email, display_name, party) values ('fin@test.local','Fin','gari');
  insert into public.app_permissions (email, permission) values ('fin@test.local','coach:operations'), ('fin@test.local','finance:view'), ('fin@test.local','finance:manage');
  d := current_date + 3; while extract(isodow from d) <> 1 loop d := d + 1; end loop;
  update public.availability_rules set active = false;
  insert into public.services (slug, title, category, duration_minutes, price_amount, currency, delivery_mode, default_capacity, active, listed)
  values ('t-mail', 'Test mail session', 'mentoring', 60, 4500, 'USD', 'online', 4, true, false) returning id into svc;
  insert into public.availability_rules (weekday, start_time, end_time, timezone) values (1, '09:00', '12:00', 'Asia/Dubai');
  select start_at into base from public.available_slots('t-mail', d, d, 'Asia/Dubai') order by start_at limit 1;

  /* ---- 1. paid booking → exactly one confirmation + one owner notice ---- */
  j := public.create_hold('t-mail', base, 1, gen_random_uuid(), 'Mail One', 'Mail.One@coachgari.com');
  ref := j ->> 'reference'; tok := j ->> 'manage_token'; select id into bid from public.bookings where reference = ref;
  o := public.create_order_for_booking(ref, tok); oref := o ->> 'reference'; select id into oid from public.orders where reference = oref;
  perform public.attach_checkout(oref, 'cs_mail_1', null, now() + interval '30 minutes');
  ev := jsonb_build_object('id', 'evt_mail_1', 'type', 'checkout.session.completed', 'livemode', false,
          'data', jsonb_build_object('object', jsonb_build_object('id', 'cs_mail_1', 'payment_status', 'paid', 'amount_total', 4500, 'currency', 'usd', 'payment_intent', 'pi_mail_1',
                                                                   'customer_details', jsonb_build_object('email', 'stripe.side@example.com'))),
          '_enrich', jsonb_build_object('charge_id', 'ch_mail_1', 'balance_transaction_id', 'txn_mail_1', 'fee_amount', 161));
  res := public.process_stripe_event(ev);
  if res ->> 'status' = 'processed' and (select status from public.bookings where id = bid) = 'confirmed' then ok := ok + 1; else fail := fail + 1; log := log || ' [paid ' || res::text || ']'; end if;
  if (select count(*) from public.email_events where order_id = oid) = 2
     and (select count(*) from public.email_events where order_id = oid and kind = 'booking_confirmed' and status = 'pending' and to_address = 'mail.one@coachgari.com') = 1
     and (select count(*) from public.email_events where order_id = oid and kind = 'payment_received' and status = 'pending' and to_address = 'letsgo@coachgari28.com') = 1
  then ok := ok + 1; else fail := fail + 1; log := log || ' [queued rows]'; end if;
  select * into r from public.email_events where order_id = oid and kind = 'booking_confirmed';
  if r.dedupe_key = 'order:' || oid || ':booking_confirmed' and r.booking_id = bid
     and r.payload ->> 'service_title' = 'Test mail session' and r.payload ->> 'reference' = ref and r.payload ->> 'timezone' = 'Asia/Dubai'
     and (r.payload ->> 'start_at')::timestamptz = base and (r.payload ->> 'duration_minutes')::int = 60 and r.payload ->> 'where' = 'Online'
     and (r.payload ->> 'amount')::int = 4500 and r.payload ->> 'currency' = 'USD' and r.payload ->> 'name' = 'Mail One'
     and not (r.payload ? 'notes') and not (r.payload ? 'manage_token') and not (r.payload ? 'ip_hash')
  then ok := ok + 1; else fail := fail + 1; log := log || ' [payload ' || r.payload::text || ']'; end if;
  -- the booking's own contact is the recipient, never the Stripe-side email
  if (select to_address from public.email_events where order_id = oid and kind = 'booking_confirmed') <> 'stripe.side@example.com' then ok := ok + 1; else fail := fail + 1; log := log || ' [stripe email used for booking]'; end if;

  /* ---- 2. replay + re-delivery: nothing added ---- */
  res := public.process_stripe_event(ev);
  res := public.process_stripe_event(ev || jsonb_build_object('id', 'evt_mail_1b'));
  if (select count(*) from public.email_events where order_id = oid) = 2 then ok := ok + 1; else fail := fail + 1; log := log || ' [replay queued more]'; end if;
  perform public.email_on_order_paid(oid);
  if (select count(*) from public.email_events where order_id = oid) = 2 then ok := ok + 1; else fail := fail + 1; log := log || ' [producer re-run queued more]'; end if;

  /* ---- 3. claim / result: a failed send never touches booking or order ---- */
  select count(*) into n from public.email_outbox_claim(20, oid, null, null);
  if n = 2 and (select count(*) from public.email_events where order_id = oid and attempts = 1 and last_attempt_at is not null and next_attempt_at > now()) = 2
  then ok := ok + 1; else fail := fail + 1; log := log || ' [claim ' || n || ']'; end if;
  select count(*) into n from public.email_outbox_claim(20, oid, null, null);
  if n = 0 then ok := ok + 1; else fail := fail + 1; log := log || ' [leased rows re-claimed]'; end if;
  select id into e_id from public.email_events where order_id = oid and kind = 'booking_confirmed';
  res := public.email_outbox_result(e_id, false, null, 'resend 500');
  if res ->> 'status' = 'pending' and (select error from public.email_events where id = e_id) = 'resend 500'
     and (select status from public.orders where id = oid) = 'paid' and (select status from public.bookings where id = bid) = 'confirmed'
     and (select count(*) from public.payments where order_id = oid) = 1
  then ok := ok + 1; else fail := fail + 1; log := log || ' [failed send side effects ' || res::text || ']'; end if;
  res := public.email_outbox_result(e_id, true, 'msg_abc', null);
  if res ->> 'status' = 'sent' and (select status from public.email_events where id = e_id) = 'sent'
     and (select provider_message_id from public.email_events where id = e_id) = 'msg_abc' and (select sent_at is not null and error is null from public.email_events where id = e_id)
  then ok := ok + 1; else fail := fail + 1; log := log || ' [sent state]'; end if;
  res := public.email_outbox_result(e_id, false, null, 'late failure');
  if (res ->> 'already')::boolean and (select status from public.email_events where id = e_id) = 'sent' then ok := ok + 1; else fail := fail + 1; log := log || ' [sent row regressed]'; end if;
  select count(*) into n from public.email_outbox_claim(20, oid, null, null);
  if n = 0 then ok := ok + 1; else fail := fail + 1; log := log || ' [sent row claimable]'; end if;
  -- the owner notice: exhaust the attempts → failed, then an operator retry brings it back
  select id into e2_id from public.email_events where order_id = oid and kind = 'payment_received';
  update public.email_events set attempts = 6 where id = e2_id;
  res := public.email_outbox_result(e2_id, false, null, 'resend 500');
  if res ->> 'status' = 'failed' and (select status from public.email_events where id = e2_id) = 'failed' then ok := ok + 1; else fail := fail + 1; log := log || ' [max attempts]'; end if;
  perform set_config('request.jwt.claims', '{"role":"authenticated","email":"fin@test.local"}', true);
  execute 'set role authenticated';
  res := public.email_outbox_retry(e2_id);
  if res ->> 'status' = 'pending' then ok := ok + 1; else fail := fail + 1; log := log || ' [operator retry]'; end if;
  begin perform public.email_outbox_retry(e_id); fail := fail + 1; log := log || ' [retry of a sent row]'; exception when sqlstate 'P0003' then ok := ok + 1; end;
  -- sender RPCs and the table are out of reach for an authenticated user
  begin perform public.email_outbox_claim(1, null, null, null); fail := fail + 1; log := log || ' [auth claims]'; exception when insufficient_privilege then ok := ok + 1; end;
  begin perform public.email_outbox_result(e2_id, true, 'x', null); fail := fail + 1; log := log || ' [auth results]'; exception when insufficient_privilege then ok := ok + 1; end;
  begin perform public.email_on_order_paid(oid); fail := fail + 1; log := log || ' [auth queues]'; exception when insufficient_privilege then ok := ok + 1; end;
  begin perform public.email_outbox_authorize('x'); fail := fail + 1; log := log || ' [auth authorizes]'; exception when insufficient_privilege then ok := ok + 1; end;
  begin select count(*) into n from public.outbox_keys; fail := fail + 1; log := log || ' [auth reads keys]'; exception when insufficient_privilege then ok := ok + 1; end;
  -- operator view: masked address, counts, no payload
  res := public.email_outbox_status(10);
  if (res -> 'counts' ->> 'sent')::int >= 1 and res -> 'recent' -> 0 ? 'kind'
     and not exists (select 1 from jsonb_array_elements(res -> 'recent') x where x ->> 'to' like '%mail.one@%' or x ? 'payload')
     and exists (select 1 from jsonb_array_elements(res -> 'recent') x where x ->> 'to' = 'm***@coachgari.com')
  then ok := ok + 1; else fail := fail + 1; log := log || ' [status view ' || left(res::text, 200) || ']'; end if;
  execute 'reset role';
  perform set_config('request.jwt.claims', '', true);
  if (select attempts from public.email_events where id = e2_id) = 0 and (select status from public.email_events where id = e2_id) = 'pending' then ok := ok + 1; else fail := fail + 1; log := log || ' [retry reset]'; end if;

  /* ---- 4. cancellation: confirmed bookings only, once ---- */
  j := public.cancel_booking(ref, tok, 'cannot make it');
  if j ->> 'status' = 'cancelled'
     and (select count(*) from public.email_events where booking_id = bid and kind = 'booking_cancelled' and status = 'pending' and to_address = 'mail.one@coachgari.com') = 1
     and (select payload ->> 'cancelled_by' from public.email_events where booking_id = bid and kind = 'booking_cancelled') = 'customer'
  then ok := ok + 1; else fail := fail + 1; log := log || ' [customer cancel]'; end if;
  begin perform public.cancel_booking(ref, tok); fail := fail + 1; log := log || ' [cancel twice accepted]'; exception when sqlstate 'P0003' then ok := ok + 1; end;
  perform public.email_on_booking_cancelled(bid);
  if (select count(*) from public.email_events where booking_id = bid and kind = 'booking_cancelled') = 1 then ok := ok + 1; else fail := fail + 1; log := log || ' [cancel queued twice]'; end if;
  -- coach cancels a confirmed booking
  j := public.create_hold('t-mail', base, 1, gen_random_uuid(), 'Mail Two', 'mail.two@coachgari.com');
  ref2 := j ->> 'reference'; tok2 := j ->> 'manage_token';
  o := public.create_order_for_booking(ref2, tok2); oref2 := o ->> 'reference';
  perform public.attach_checkout(oref2, 'cs_mail_2', null, now() + interval '30 minutes');
  perform public.process_stripe_event(jsonb_build_object('id', 'evt_mail_2', 'type', 'checkout.session.completed', 'livemode', false,
          'data', jsonb_build_object('object', jsonb_build_object('id', 'cs_mail_2', 'payment_status', 'paid', 'amount_total', 4500, 'currency', 'usd', 'payment_intent', 'pi_mail_2'))));
  perform set_config('request.jwt.claims', '{"role":"authenticated","email":"fin@test.local"}', true);
  execute 'set role authenticated';
  j := public.ops_set_booking_status(ref2, 'cancelled', 'coach travelling');
  execute 'reset role';
  perform set_config('request.jwt.claims', '', true);
  if j ->> 'status' = 'cancelled'
     and (select count(*) from public.email_events e join public.bookings b on b.id = e.booking_id where b.reference = ref2 and e.kind = 'booking_cancelled' and e.status = 'pending') = 1
     and (select e.payload ->> 'cancelled_by' from public.email_events e join public.bookings b on b.id = e.booking_id where b.reference = ref2 and e.kind = 'booking_cancelled') = 'coach'
  then ok := ok + 1; else fail := fail + 1; log := log || ' [coach cancel]'; end if;
  -- a cancelled hold (never confirmed) queues nothing
  j := public.create_hold('t-mail', base, 1, gen_random_uuid(), 'Mail Three', 'mail.three@coachgari.com');
  ref3 := j ->> 'reference'; tok3 := j ->> 'manage_token';
  perform public.cancel_booking(ref3, tok3);
  if (select count(*) from public.email_events e join public.bookings b on b.id = e.booking_id where b.reference = ref3) = 0 then ok := ok + 1; else fail := fail + 1; log := log || ' [hold cancel queued]'; end if;
  -- a phone contact: the row is skipped, nothing is sent, nothing breaks
  j := public.create_hold('t-mail', base, 1, gen_random_uuid(), 'Mail Phone', '+971500000001');
  o := public.create_order_for_booking(j ->> 'reference', j ->> 'manage_token');
  perform public.attach_checkout(o ->> 'reference', 'cs_mail_p', null, now() + interval '30 minutes');
  perform public.process_stripe_event(jsonb_build_object('id', 'evt_mail_p', 'type', 'checkout.session.completed', 'livemode', false,
          'data', jsonb_build_object('object', jsonb_build_object('id', 'cs_mail_p', 'payment_status', 'paid', 'amount_total', 4500, 'currency', 'usd', 'payment_intent', 'pi_mail_p'))));
  if (select count(*) from public.email_events e join public.orders oo on oo.id = e.order_id where oo.reference = o ->> 'reference' and e.kind = 'booking_confirmed' and e.status = 'skipped' and e.to_address is null) = 1
     and (select count(*) from public.email_events e join public.orders oo on oo.id = e.order_id where oo.reference = o ->> 'reference' and e.kind = 'payment_received' and e.status = 'pending') = 1
     and (select status from public.bookings where reference = j ->> 'reference') = 'confirmed'
  then ok := ok + 1; else fail := fail + 1; log := log || ' [phone contact]'; end if;

  /* ---- 5. reschedule: the coaching session moves the confirmed booking, one email per actual change ---- */
  j := public.create_hold('t-mail', base, 1, gen_random_uuid(), 'Mail Four', 'mail.four@coachgari.com');
  ref4 := j ->> 'reference'; tok4 := j ->> 'manage_token'; select id into bid4 from public.bookings where reference = ref4;
  o := public.create_order_for_booking(ref4, tok4); oref4 := o ->> 'reference';
  perform public.attach_checkout(oref4, 'cs_mail_4', null, now() + interval '30 minutes');
  perform public.process_stripe_event(jsonb_build_object('id', 'evt_mail_4', 'type', 'checkout.session.completed', 'livemode', false,
          'data', jsonb_build_object('object', jsonb_build_object('id', 'cs_mail_4', 'payment_status', 'paid', 'amount_total', 4500, 'currency', 'usd', 'payment_intent', 'pi_mail_4'))));
  select id into sid from public.coaching_sessions where booking_id = bid4;
  if sid is not null then ok := ok + 1; else fail := fail + 1; log := log || ' [no session for the booking]'; end if;
  update public.coaching_sessions set start_at = start_at + interval '1 day', end_at = end_at + interval '1 day' where id = sid;
  if (select start_at from public.bookings where id = bid4) = base + interval '1 day'
     and (select count(*) from public.email_events where booking_id = bid4 and kind = 'reschedule' and status = 'pending' and to_address = 'mail.four@coachgari.com') = 1
     and (select (payload ->> 'previous_start_at')::timestamptz from public.email_events where booking_id = bid4 and kind = 'reschedule') = base
     and (select (payload ->> 'start_at')::timestamptz from public.email_events where booking_id = bid4 and kind = 'reschedule') = base + interval '1 day'
  then ok := ok + 1; else fail := fail + 1; log := log || ' [reschedule]'; end if;
  update public.coaching_sessions set note = 'no time change' where id = sid;
  update public.coaching_sessions set start_at = start_at where id = sid;
  if (select count(*) from public.email_events where booking_id = bid4 and kind = 'reschedule') = 1 then ok := ok + 1; else fail := fail + 1; log := log || ' [no-op edit queued]'; end if;
  update public.coaching_sessions set start_at = start_at + interval '2 hours', end_at = end_at + interval '2 hours' where id = sid;
  if (select count(*) from public.email_events where booking_id = bid4 and kind = 'reschedule') = 2
     and (select start_at from public.bookings where id = bid4) = base + interval '1 day 2 hours' then ok := ok + 1; else fail := fail + 1; log := log || ' [second change]'; end if;
  -- the booking-side sync (status change) does not fire a reschedule
  update public.bookings set status = 'confirmed' where id = bid4;
  if (select count(*) from public.email_events where booking_id = bid4 and kind = 'reschedule') = 2 then ok := ok + 1; else fail := fail + 1; log := log || ' [status sync queued]'; end if;
  -- a session moved after the booking was cancelled: nothing
  perform public.cancel_booking(ref4, tok4);
  update public.coaching_sessions set start_at = start_at + interval '1 day', end_at = end_at + interval '1 day' where id = sid;
  if (select count(*) from public.email_events where booking_id = bid4 and kind = 'reschedule') = 2 and (select status from public.bookings where id = bid4) = 'cancelled'
  then ok := ok + 1; else fail := fail + 1; log := log || ' [cancelled booking rescheduled]'; end if;

  /* ---- 6. manual pack receipt → client receipt + owner notice ---- */
  insert into public.crm_contacts (display_name, email, email_norm) values ('Sarah Mail', 'Sarah@ex.com', 'sarah@ex.com') returning id into cA;
  insert into public.crm_contacts (display_name, phone) values ('Phone Only', '+971500000002') returning id into cB;
  insert into public.session_packs (crm_contact_id, title, total_sessions, price_amount, currency, payment_status, created_by) values (cA, '10-session pack', 10, 312000, 'AED', 'unpaid', 'seed') returning id into p1;
  insert into public.session_packs (crm_contact_id, title, total_sessions, price_amount, currency, payment_status, created_by) values (cB, '5-session pack', 5, 150000, 'AED', 'unpaid', 'seed') returning id into p2;
  perform set_config('request.jwt.claims', '{"role":"authenticated","email":"fin@test.local"}', true);
  execute 'set role authenticated';
  j := public.payment_record_manual(p1, 312000, 'AED', 'aani', 'aani-ref-1');
  res := public.payment_record_manual(p2, 150000, 'AED', 'cash', null);
  execute 'reset role';
  perform set_config('request.jwt.claims', '', true);
  select id into oid from public.orders where reference = j ->> 'order';
  if (select count(*) from public.email_events where order_id = oid) = 2
     and (select count(*) from public.email_events where order_id = oid and kind = 'payment_confirmed' and status = 'pending' and to_address = 'sarah@ex.com') = 1
     and (select payload ->> 'pack_title' from public.email_events where order_id = oid and kind = 'payment_confirmed') = '10-session pack'
     and (select (payload ->> 'amount')::int from public.email_events where order_id = oid and kind = 'payment_confirmed') = 312000
     and (select payload ->> 'method' from public.email_events where order_id = oid and kind = 'payment_confirmed') = 'aani'
     and (select count(*) from public.email_events where order_id = oid and kind = 'payment_received' and to_address = 'letsgo@coachgari28.com' and payload ->> 'type' = 'package') = 1
  then ok := ok + 1; else fail := fail + 1; log := log || ' [pack receipt]'; end if;
  select id into oid from public.orders where reference = res ->> 'order';
  if (select count(*) from public.email_events where order_id = oid and kind = 'payment_confirmed' and status = 'skipped') = 1
     and (select count(*) from public.email_events where order_id = oid and kind = 'payment_received' and status = 'pending') = 1
  then ok := ok + 1; else fail := fail + 1; log := log || ' [pack without email]'; end if;

  /* ---- 7. support: thank-you to the Stripe-captured payer email; no entitlement ---- */
  select count(*) into b_book from public.bookings; select count(*) into b_pack from public.session_packs; select count(*) into b_sess from public.coaching_sessions;
  select count(*) into b_paidpacks from public.session_packs where payment_status = 'paid';
  j := public.support_create(5000, 'AED', 'Keep going', rt, 'AE');
  sref := j -> 'order' ->> 'reference'; stok := j ->> 'token';
  perform public.attach_checkout(sref, 'cs_mail_sup', null, now() + interval '30 minutes');
  res := public.process_stripe_event(jsonb_build_object('id', 'evt_mail_sup', 'type', 'checkout.session.completed', 'livemode', false,
          'data', jsonb_build_object('object', jsonb_build_object('id', 'cs_mail_sup', 'payment_status', 'paid', 'amount_total', 5000, 'currency', 'aed', 'payment_intent', 'pi_mail_sup', 'client_reference_id', sref,
                                                                   'customer_details', jsonb_build_object('email', 'Fan@Example.com', 'name', 'A Fan')))));
  select id into oid from public.orders where reference = sref;
  if res ->> 'status' = 'processed' and (select status from public.orders where id = oid) = 'paid'
     and (select count(*) from public.email_events where order_id = oid) = 2
     and (select count(*) from public.email_events where order_id = oid and kind = 'support_thanks' and status = 'pending' and to_address = 'fan@example.com') = 1
     and (select payload ->> 'public_ref' from public.email_events where order_id = oid and kind = 'support_thanks') like 'SUP-%'
     and (select (payload ->> 'amount')::int from public.email_events where order_id = oid and kind = 'support_thanks') = 5000
     and not exists (select 1 from public.email_events where order_id = oid and (payload ? 'message' or payload ? 'name'))
     and (select count(*) from public.email_events where order_id = oid and kind = 'payment_received' and payload ->> 'type' = 'support') = 1
  then ok := ok + 1; else fail := fail + 1; log := log || ' [support thanks ' || res::text || ']'; end if;
  perform public.process_stripe_event(jsonb_build_object('id', 'evt_mail_sup2', 'type', 'checkout.session.completed', 'livemode', false,
          'data', jsonb_build_object('object', jsonb_build_object('id', 'cs_mail_sup', 'payment_status', 'paid', 'amount_total', 5000, 'currency', 'aed', 'payment_intent', 'pi_mail_sup', 'client_reference_id', sref,
                                                                   'customer_details', jsonb_build_object('email', 'fan@example.com')))));
  if (select count(*) from public.email_events where order_id = oid) = 2 then ok := ok + 1; else fail := fail + 1; log := log || ' [support replay queued more]'; end if;
  if (select count(*) from public.bookings) = b_book and (select count(*) from public.session_packs) = b_pack and (select count(*) from public.coaching_sessions) = b_sess
     and (select count(*) from public.session_packs where payment_status = 'paid') = b_paidpacks
     and (select booking_id is null and session_pack_id is null from public.orders where id = oid)
  then ok := ok + 1; else fail := fail + 1; log := log || ' [support entitlement]'; end if;
  -- no payer email captured → skipped row, still no failure
  j := public.support_create(2500, 'AED', null, rt, 'AE');
  perform public.attach_checkout(j -> 'order' ->> 'reference', 'cs_mail_sup3', null, now() + interval '30 minutes');
  res := public.process_stripe_event(jsonb_build_object('id', 'evt_mail_sup3', 'type', 'checkout.session.completed', 'livemode', false,
          'data', jsonb_build_object('object', jsonb_build_object('id', 'cs_mail_sup3', 'payment_status', 'paid', 'amount_total', 2500, 'currency', 'aed', 'payment_intent', 'pi_mail_sup3', 'client_reference_id', j -> 'order' ->> 'reference'))));
  if res ->> 'status' = 'processed'
     and (select count(*) from public.email_events e join public.orders oo on oo.id = e.order_id where oo.reference = j -> 'order' ->> 'reference' and e.kind = 'support_thanks' and e.status = 'skipped') = 1
  then ok := ok + 1; else fail := fail + 1; log := log || ' [support no email]'; end if;

  /* ---- 8. enquiry → owner lead + customer acknowledgement ---- */
  insert into public.contacts (submission_id, name, contact, city, country, interest, message, source, page, utm_source)
  values (gen_random_uuid(), 'Lead Mail', 'Lead.Mail@example.com', 'Dubai', 'AE', 'Padel coaching', 'Hello there', 'web', '/', 'instagram') returning id into cid;
  perform public.email_on_enquiry(cid);
  if (select count(*) from public.email_events where contact_id = cid) = 2
     and (select count(*) from public.email_events where contact_id = cid and kind = 'lead_notification' and status = 'pending' and to_address = 'letsgo@coachgari28.com') = 1
     and (select payload ->> 'message' from public.email_events where contact_id = cid and kind = 'lead_notification') = 'Hello there'
     and (select payload ->> 'attribution' from public.email_events where contact_id = cid and kind = 'lead_notification') = 'source: instagram'
     and (select count(*) from public.email_events where contact_id = cid and kind = 'enquiry_received' and status = 'pending' and to_address = 'lead.mail@example.com') = 1
     and not exists (select 1 from public.email_events where contact_id = cid and kind = 'enquiry_received' and payload ? 'message')
  then ok := ok + 1; else fail := fail + 1; log := log || ' [enquiry]'; end if;
  perform public.email_on_enquiry(cid);
  if (select count(*) from public.email_events where contact_id = cid) = 2 then ok := ok + 1; else fail := fail + 1; log := log || ' [enquiry re-run queued more]'; end if;
  insert into public.contacts (submission_id, name, contact, source) values (gen_random_uuid(), 'Phone Lead', '+971500000003', 'web') returning id into cid2;
  perform public.email_on_enquiry(cid2);
  if (select count(*) from public.email_events where contact_id = cid2 and kind = 'lead_notification' and status = 'pending') = 1
     and (select count(*) from public.email_events where contact_id = cid2 and kind = 'enquiry_received' and status = 'skipped') = 1
  then ok := ok + 1; else fail := fail + 1; log := log || ' [phone enquiry]'; end if;
  select count(*) into n from public.email_outbox_claim(20, null, null, cid);
  if n = 2 then ok := ok + 1; else fail := fail + 1; log := log || ' [claim by contact]'; end if;

  /* ---- 9. scheduled drain wiring ---- */
  if exists (select 1 from cron.job where jobname = 'cg-email-outbox' and schedule = '*/2 * * * *') then ok := ok + 1; else fail := fail + 1; log := log || ' [cron]'; end if;
  if (select count(*) from public.outbox_keys where name = 'email' and length(key) = 64) = 1 and not public.email_outbox_authorize('not-a-key')
     and public.email_outbox_authorize((select key from public.outbox_keys where name = 'email'))
  then ok := ok + 1; else fail := fail + 1; log := log || ' [outbox key]'; end if;
  if (select prosecdef from pg_proc where proname = 'email_outbox_kick' and pronamespace = 'public'::regnamespace) then ok := ok + 1; else fail := fail + 1; log := log || ' [kick definer]'; end if;

  raise exception 'CG014_TESTS ok=% fail=% %', ok, fail, log;
end $$;

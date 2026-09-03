-- CG-002.5 permissions & RLS — database-level suite. One transaction, always
-- rolls back (ends with RAISE EXCEPTION 'CG0025_TESTS ok=… fail=…').
-- Runs as postgres (member of anon/authenticated) and switches role + JWT
-- claims per persona to prove, negatively, what each party cannot reach:
--   anon              → nothing at all (permission denied)
--   signed-in, no row → nothing (0 rows), every RPC forbidden
--   inactive user     → same as no row
--   coach             → leads/bookings/calendar; no orders/payments/ledger; no manage_token
--   finance           → orders/ledger without customer identity; no leads/bookings
--   analytics         → aggregates only
do $$
declare
  ok int := 0; fail int := 0; log text := '';
  svc uuid; bid uuid; oref text; n int; j jsonb; s jsonb; q text;
  sess text := 'cs_test_' || replace(gen_random_uuid()::text, '-', ''); pi text := 'pi_test_' || replace(gen_random_uuid()::text, '-', '');
begin
  /* ---- seed as postgres ---- */
  insert into public.app_users (email, display_name, party) values
    ('coach@test.local', 'Coach', 'gari'), ('finance@test.local', 'Finance', 'oolala'),
    ('analytics@test.local', 'Analytics', 'studio'), ('inactive@test.local', 'Gone', 'gari');
  update public.app_users set active = false where email = 'inactive@test.local';
  insert into public.app_permissions (email, permission) values
    ('coach@test.local', 'coach:operations'), ('finance@test.local', 'finance:view'), ('finance@test.local', 'finance:manage'),
    ('analytics@test.local', 'analytics:view'), ('inactive@test.local', 'coach:operations');
  insert into public.contacts (submission_id, name, contact, interest, message, country) values (gen_random_uuid(), 'Lead Person', 'lead@example.com', 'coaching', 'private message body', 'Zimbabwe');
  insert into public.services (slug, title, category, duration_minutes, price_amount, currency, delivery_mode, default_capacity, active, listed)
    values ('t-perm', 'Perm test session', 'mentoring', 60, 4500, 'USD', 'online', 1, true, false) returning id into svc;
  insert into public.services (slug, title, category, duration_minutes, price_amount, currency, delivery_mode, default_capacity, active, listed)
    values ('t-perm-free', 'Perm unpriced', 'mentoring', 60, null, 'USD', 'online', 1, true, false);
  -- a paid booking in the past (for complete / no-show) through the real payment pipeline
  insert into public.bookings (reference, service_id, customer_name, customer_contact, start_at, end_at, session_timezone, delivery_mode, status, hold_expires_at, idempotency_key, manage_token, price_amount, currency)
    values ('CG-TEST01', svc, 'Paying Person', 'payer@example.com', now() - interval '2 days', now() - interval '2 days' + interval '60 minutes', 'Asia/Dubai', 'online', 'hold', now() + interval '10 minutes', gen_random_uuid(), 'secret-token', 4500, 'USD')
    returning id into bid;
  j := public.create_order_for_booking('CG-TEST01', 'secret-token'); oref := j ->> 'reference';
  perform public.attach_checkout(oref, sess, 'https://checkout.stripe.com/x', now() + interval '30 minutes');
  perform public.process_stripe_event(jsonb_build_object('id', 'evt_perm_1', 'type', 'checkout.session.completed', 'livemode', false,
    'data', jsonb_build_object('object', jsonb_build_object('id', sess, 'payment_status', 'paid', 'amount_total', 4500, 'currency', 'usd', 'payment_intent', pi)),
    '_enrich', jsonb_build_object('charge_id', 'ch_perm', 'balance_transaction_id', 'txn_perm', 'fee_amount', 161)));
  -- an unpriced hold (manual confirmation path) and a future confirmed one
  insert into public.bookings (reference, service_id, customer_name, customer_contact, start_at, end_at, session_timezone, delivery_mode, status, hold_expires_at, idempotency_key, manage_token, currency)
    values ('CG-TEST02', (select id from public.services where slug = 't-perm-free'), 'Free Person', '+27000000', now() + interval '3 days', now() + interval '3 days 1 hour', 'Asia/Dubai', 'online', 'hold', now() + interval '10 minutes', gen_random_uuid(), 'secret-2', 'USD');
  insert into public.bookings (reference, service_id, customer_name, customer_contact, start_at, end_at, session_timezone, delivery_mode, status, idempotency_key, manage_token, price_amount, currency)
    values ('CG-TEST03', svc, 'Future Person', 'future@example.com', now() + interval '5 days', now() + interval '5 days 1 hour', 'Asia/Dubai', 'online', 'confirmed', gen_random_uuid(), 'secret-3', 4500, 'USD');
  if (select status from public.bookings where reference = 'CG-TEST01') = 'confirmed' then ok := ok + 1; else fail := fail + 1; log := log || ' [seed paid booking]'; end if;

  /* ---- 1. anon: permission denied everywhere ---- */
  perform set_config('request.jwt.claims', '{"role":"anon"}', true);
  execute 'set local role anon';
  foreach q in array array['select count(*) from public.contacts', 'select count(*) from public.bookings', 'select count(*) from public.orders',
                           'select count(*) from public.partner_earnings', 'select count(*) from public.finance_orders', 'select count(*) from public.availability_rules',
                           'select count(*) from public.app_permissions', 'select public.my_permissions()', 'select public.analytics_summary()',
                           'select public.ops_set_booking_status(''CG-TEST03'', ''cancelled'')'] loop
    begin execute q; fail := fail + 1; log := log || ' [anon allowed: ' || q || ']';
    exception when insufficient_privilege then ok := ok + 1; end;
  end loop;
  execute 'reset role';

  /* ---- 2. signed in without an app_users row, and an inactive user: nothing ---- */
  foreach q in array array['stranger@test.local', 'inactive@test.local'] loop
    perform set_config('request.jwt.claims', format('{"role":"authenticated","sub":"00000000-0000-4000-8000-000000000001","email":"%s"}', q), true);
    execute 'set local role authenticated';
    select count(*) into n from public.contacts;           if n = 0 then ok := ok + 1; else fail := fail + 1; log := log || format(' [%s contacts]', q); end if;
    select count(*) into n from public.bookings;           if n = 0 then ok := ok + 1; else fail := fail + 1; log := log || format(' [%s bookings]', q); end if;
    select count(*) into n from public.orders;             if n = 0 then ok := ok + 1; else fail := fail + 1; log := log || format(' [%s orders]', q); end if;
    select count(*) into n from public.finance_orders;     if n = 0 then ok := ok + 1; else fail := fail + 1; log := log || format(' [%s finance_orders]', q); end if;
    select count(*) into n from public.availability_rules; if n = 0 then ok := ok + 1; else fail := fail + 1; log := log || format(' [%s rules]', q); end if;
    if (public.my_permissions() -> 'permissions') = '[]'::jsonb then ok := ok + 1; else fail := fail + 1; log := log || format(' [%s my_permissions]', q); end if;
    begin perform public.ops_set_booking_status('CG-TEST03', 'cancelled'); fail := fail + 1; log := log || format(' [%s ops rpc]', q); exception when insufficient_privilege then ok := ok + 1; end;
    begin perform public.finance_create_settlement(current_date - 1, current_date + 1); fail := fail + 1; log := log || format(' [%s finance rpc]', q); exception when insufficient_privilege then ok := ok + 1; end;
    begin perform public.analytics_summary(); fail := fail + 1; log := log || format(' [%s analytics rpc]', q); exception when insufficient_privilege then ok := ok + 1; end;
    begin
      insert into public.availability_exceptions (kind, start_at, end_at, timezone, reason) values ('closed', now(), now() + interval '1 hour', 'Asia/Dubai', 'x');
      fail := fail + 1; log := log || format(' [%s insert exception]', q);
    exception when insufficient_privilege then ok := ok + 1; end;
    update public.contacts set status = 'contacted'; get diagnostics n = row_count;
    if n = 0 then ok := ok + 1; else fail := fail + 1; log := log || format(' [%s update contacts]', q); end if;
    execute 'reset role';
  end loop;

  /* ---- 3. coach: people yes, money no ---- */
  perform set_config('request.jwt.claims', '{"role":"authenticated","sub":"00000000-0000-4000-8000-000000000002","email":"coach@test.local"}', true);
  execute 'set local role authenticated';
  if (public.my_permissions() -> 'permissions') = '["coach:operations"]'::jsonb then ok := ok + 1; else fail := fail + 1; log := log || ' [coach my_permissions]'; end if;
  select count(*) into n from public.contacts where message = 'private message body'; if n = 1 then ok := ok + 1; else fail := fail + 1; log := log || ' [coach reads leads]'; end if;
  select count(*) into n from public.bookings where customer_contact = 'payer@example.com'; if n = 1 then ok := ok + 1; else fail := fail + 1; log := log || ' [coach reads bookings]'; end if;
  begin select count(*) into n from public.bookings where manage_token = 'secret-token'; fail := fail + 1; log := log || ' [coach manage_token readable]';
  exception when insufficient_privilege then ok := ok + 1; end;
  begin select count(*) into n from public.contacts where ip_hash is null; fail := fail + 1; log := log || ' [coach ip_hash readable]';
  exception when insufficient_privilege then ok := ok + 1; end;
  select count(*) into n from public.orders;           if n = 0 then ok := ok + 1; else fail := fail + 1; log := log || ' [coach sees orders]'; end if;
  select count(*) into n from public.payments;         if n = 0 then ok := ok + 1; else fail := fail + 1; log := log || ' [coach sees payments]'; end if;
  select count(*) into n from public.partner_earnings; if n = 0 then ok := ok + 1; else fail := fail + 1; log := log || ' [coach sees earnings]'; end if;
  select count(*) into n from public.finance_orders;   if n = 0 then ok := ok + 1; else fail := fail + 1; log := log || ' [coach sees finance_orders]'; end if;
  begin perform public.finance_create_settlement(current_date - 1, current_date + 1); fail := fail + 1; log := log || ' [coach finance rpc]'; exception when insufficient_privilege then ok := ok + 1; end;
  begin perform public.analytics_summary(); fail := fail + 1; log := log || ' [coach analytics rpc]'; exception when insufficient_privilege then ok := ok + 1; end;
  select count(*) into n from public.app_users; if n = 1 then ok := ok + 1; else fail := fail + 1; log := log || ' [coach app_users self only]'; end if;
  -- lead status: allowed; lead name: column not granted
  update public.contacts set status = 'contacted' where contact = 'lead@example.com'; get diagnostics n = row_count;
  if n = 1 then ok := ok + 1; else fail := fail + 1; log := log || ' [coach update lead status]'; end if;
  begin update public.contacts set name = 'x'; fail := fail + 1; log := log || ' [coach update lead name]'; exception when insufficient_privilege then ok := ok + 1; end;
  -- calendar edits
  insert into public.availability_exceptions (kind, start_at, end_at, timezone, reason) values ('closed', now() + interval '1 day', now() + interval '1 day 2 hours', 'Asia/Dubai', 'dentist');
  insert into public.tour_stops (slug, city, country, timezone, start_at, end_at, status) values ('t-harare', 'Harare', 'Zimbabwe', 'Africa/Harare', now() + interval '20 days', now() + interval '25 days', 'draft');
  update public.availability_rules set active = false; get diagnostics n = row_count;
  if n > 0 and (select count(*) from public.tour_stops where slug = 't-harare') = 1 then ok := ok + 1; else fail := fail + 1; log := log || ' [coach calendar edits]'; end if;
  -- booking state machine
  j := public.ops_set_booking_status('CG-TEST01', 'completed');
  if j ->> 'status' = 'completed' then ok := ok + 1; else fail := fail + 1; log := log || ' [coach complete]'; end if;
  begin perform public.ops_set_booking_status('CG-TEST03', 'completed'); fail := fail + 1; log := log || ' [complete future]'; exception when sqlstate 'P0003' then ok := ok + 1; end;
  begin perform public.ops_set_booking_status('CG-TEST02', 'completed'); fail := fail + 1; log := log || ' [complete a hold]'; exception when sqlstate 'P0003' then ok := ok + 1; end;
  j := public.ops_set_booking_status('CG-TEST02', 'confirmed');
  if j ->> 'status' = 'confirmed' then ok := ok + 1; else fail := fail + 1; log := log || ' [confirm unpriced hold]'; end if;
  j := public.ops_set_booking_status('CG-TEST03', 'cancelled', 'coach travelling');
  if j ->> 'status' = 'cancelled' and j ->> 'cancelled_by' = 'coach'
     and (select count(*) from public.contacts) = 1 then ok := ok + 1; else fail := fail + 1; log := log || ' [coach cancel]'; end if;
  begin perform public.ops_set_booking_status('CG-NOPE00', 'cancelled'); fail := fail + 1; log := log || ' [unknown ref]'; exception when no_data_found then ok := ok + 1; end;
  execute 'reset role';
  -- the cancel queued a customer email (prepared, not sent) and did not touch the paid order
  if (select count(*) from public.email_events where kind = 'booking_cancelled' and status = 'pending') = 1
     and (select status from public.orders where reference = oref) = 'paid' then ok := ok + 1; else fail := fail + 1; log := log || ' [cancel side effects]'; end if;

  /* ---- 4. finance: money yes, people no ---- */
  perform set_config('request.jwt.claims', '{"role":"authenticated","sub":"00000000-0000-4000-8000-000000000003","email":"finance@test.local"}', true);
  execute 'set local role authenticated';
  select count(*) into n from public.orders where reference = oref; if n = 1 then ok := ok + 1; else fail := fail + 1; log := log || ' [finance reads orders]'; end if;
  begin select count(*) into n from public.orders where customer_name = 'Paying Person'; fail := fail + 1; log := log || ' [finance customer_name readable]';
  exception when insufficient_privilege then ok := ok + 1; end;
  select count(*) into n from public.contacts;  if n = 0 then ok := ok + 1; else fail := fail + 1; log := log || ' [finance sees leads]'; end if;
  select count(*) into n from public.bookings;  if n = 0 then ok := ok + 1; else fail := fail + 1; log := log || ' [finance sees bookings]'; end if;
  select count(*) into n from public.finance_orders where reference = oref and service_title = 'Perm test session' and gari_payable = 3905;
  if n = 1 then ok := ok + 1; else fail := fail + 1; log := log || ' [finance_orders row]'; end if;
  select count(*) into n from information_schema.columns where table_schema = 'public' and table_name = 'finance_orders' and column_name in ('customer_name','customer_contact');
  if n = 0 then ok := ok + 1; else fail := fail + 1; log := log || ' [finance_orders exposes identity]'; end if;
  select count(*) into n from public.finance_webhook_log where event_id = 'evt_perm_1'; if n = 1 then ok := ok + 1; else fail := fail + 1; log := log || ' [finance webhook log]'; end if;
  begin select count(*) into n from public.webhook_events; fail := fail + 1; log := log || ' [finance raw webhook payloads]'; exception when insufficient_privilege then ok := ok + 1; end;
  begin perform public.ops_set_booking_status('CG-TEST02', 'cancelled'); fail := fail + 1; log := log || ' [finance ops rpc]'; exception when insufficient_privilege then ok := ok + 1; end;
  update public.availability_rules set active = true; get diagnostics n = row_count;
  if n = 0 then ok := ok + 1; else fail := fail + 1; log := log || ' [finance edits calendar]'; end if;
  begin perform public.analytics_summary(); fail := fail + 1; log := log || ' [finance analytics rpc]'; exception when insufficient_privilege then ok := ok + 1; end;
  s := public.finance_create_settlement(current_date - 1, current_date + 1, 'USD');
  if (s ->> 'items')::int = 1 and (s ->> 'amount_payable')::int = 3905 then ok := ok + 1; else fail := fail + 1; log := log || ' [finance settlement ' || s::text || ']'; end if;
  s := public.finance_mark_settlement_paid(s ->> 'reference', 'BANK-REF-1');
  s := public.finance_mark_settlement_reconciled(s ->> 'reference');
  if s ->> 'status' = 'reconciled' and (select count(*) from public.partner_settlements where status = 'reconciled') = 1 then ok := ok + 1; else fail := fail + 1; log := log || ' [finance settlement flow]'; end if;
  execute 'reset role';

  /* ---- 5. analytics: aggregates only ---- */
  perform set_config('request.jwt.claims', '{"role":"authenticated","sub":"00000000-0000-4000-8000-000000000004","email":"analytics@test.local"}', true);
  execute 'set local role authenticated';
  j := public.analytics_summary();
  if (j -> 'leads' ->> 'total')::int >= 1 and (j -> 'revenue' -> 'totals' ->> 'gross')::int >= 4500 and (j -> 'bookings' -> 'by_status' ->> 'completed')::int >= 1 then ok := ok + 1;
  else fail := fail + 1; log := log || ' [analytics summary ' || j::text || ']'; end if;
  if j::text not like '%private message body%' and j::text not like '%lead@example.com%' and j::text not like '%Paying Person%' then ok := ok + 1; else fail := fail + 1; log := log || ' [analytics leaks PII]'; end if;
  select count(*) into n from public.contacts; if n = 0 then ok := ok + 1; else fail := fail + 1; log := log || ' [analytics sees leads]'; end if;
  select count(*) into n from public.orders;   if n = 0 then ok := ok + 1; else fail := fail + 1; log := log || ' [analytics sees orders]'; end if;
  select count(*) into n from public.bookings; if n = 0 then ok := ok + 1; else fail := fail + 1; log := log || ' [analytics sees bookings]'; end if;
  execute 'reset role';

  raise exception 'CG0025_TESTS ok=% fail=% %', ok, fail, log;
end $$;

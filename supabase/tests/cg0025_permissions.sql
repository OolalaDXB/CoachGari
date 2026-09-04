-- CG-002.5 permissions & RLS — database-level suite. One transaction, always
-- rolls back (ends with RAISE EXCEPTION 'CG0025_TESTS ok=… fail=…').
-- Runs as postgres (member of anon/authenticated) and switches role + JWT
-- claims per persona to prove, negatively, what each party cannot reach:
--   anon              → nothing at all (permission denied)
--   signed-in, no row → nothing (0 rows), every RPC forbidden
--   inactive user     → same as no row
--   coach             → leads/bookings/calendar; no orders/payments/ledger; no manage_token
--   finance           → orders/ledger (finance_orders() function) without customer identity; no leads/bookings
--   analytics         → aggregates only
--   attachments       → server-issued upload token (256-bit, 30 min, one enquiry); limits (3 files, 50 MB, strict MIME allowlist); only the coach reads rows and objects
--   launch user       → composite coach+finance+analytics persona reaches every business area (CG-006)
--   platform:admin    → access administration only; never a bypass of RLS on business data (CG-006)
do $$
declare
  ok int := 0; fail int := 0; log text := '';
  svc uuid; bid uuid; cid uuid; tok text; oref text; n int; j jsonb; s jsonb; q text; b boolean;
  sess text := 'cs_test_' || replace(gen_random_uuid()::text, '-', ''); pi text := 'pi_test_' || replace(gen_random_uuid()::text, '-', '');
begin
  /* ---- seed as postgres ---- */
  insert into public.app_users (email, display_name, party) values
    ('coach@test.local', 'Coach', 'gari'), ('finance@test.local', 'Finance', 'oolala'),
    ('analytics@test.local', 'Analytics', 'studio'), ('inactive@test.local', 'Gone', 'gari'),
    ('launch@test.local', 'Launch user', 'gari'), ('padmin@test.local', 'Access admin', 'studio');
  update public.app_users set active = false where email = 'inactive@test.local';
  insert into public.app_permissions (email, permission) values
    ('coach@test.local', 'coach:operations'), ('finance@test.local', 'finance:view'), ('finance@test.local', 'finance:manage'),
    ('analytics@test.local', 'analytics:view'), ('inactive@test.local', 'coach:operations'),
    ('launch@test.local', 'coach:operations'), ('launch@test.local', 'finance:view'), ('launch@test.local', 'finance:manage'), ('launch@test.local', 'analytics:view'),
    ('padmin@test.local', 'platform:admin');
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
  if public.mask_contact('+27000000') = '•••••••00' and public.mask_contact('payer@example.com') = 'p***@example.com' and public.mask_contact(null) is null then ok := ok + 1; else fail := fail + 1; log := log || ' [mask_contact]'; end if;

  /* ---- 0a. enquiry attachments: server-issued upload token, limits, allowlist (as postgres, service-role path) ---- */
  select id into cid from public.contacts where contact = 'lead@example.com';
  tok := public.issue_upload_token(cid);
  if tok ~ '^[0-9a-f]{64}$' and (select upload_token_hash from public.contacts where id = cid) = encode(extensions.digest(tok, 'sha256'), 'hex')
     and (select upload_token_expires_at from public.contacts where id = cid) between now() + interval '29 minutes' and now() + interval '31 minutes'
  then ok := ok + 1; else fail := fail + 1; log := log || ' [issue_upload_token]'; end if;
  begin perform public.issue_upload_token('00000000-0000-4000-8000-00000000dead'); fail := fail + 1; log := log || ' [token for unknown enquiry]'; exception when no_data_found then ok := ok + 1; end;
  -- the browser-known submission_id is worthless as a credential
  begin perform public.reserve_contact_media((select submission_id::text from public.contacts where id = cid), 'x.png', 'image/png', 1000); fail := fail + 1; log := log || ' [submission_id accepted as token]'; exception when no_data_found then ok := ok + 1; end;
  begin perform public.reserve_contact_media(cid::text, 'x.png', 'image/png', 1000); fail := fail + 1; log := log || ' [contact id accepted as token]'; exception when no_data_found then ok := ok + 1; end;
  begin perform public.reserve_contact_media(repeat('b', 64), 'x.png', 'image/png', 1000); fail := fail + 1; log := log || ' [wrong token accepted]'; exception when no_data_found then ok := ok + 1; end;
  begin perform public.reserve_contact_media(null, 'x.png', 'image/png', 1000); fail := fail + 1; log := log || ' [null token accepted]'; exception when no_data_found then ok := ok + 1; end;
  j := public.reserve_contact_media(tok, 'swing.mp4', 'video/mp4', 30000000);
  if j ->> 'path' like 'contacts/' || cid::text || '/%.mp4' then ok := ok + 1; else fail := fail + 1; log := log || ' [reserve media]'; end if;
  perform public.reserve_contact_media(tok, 'front.jpg', 'image/jpeg', 10000000);
  begin perform public.reserve_contact_media(tok, 'big.mov', 'video/quicktime', 15000000); fail := fail + 1; log := log || ' [media total > 50MB]'; exception when sqlstate 'P0003' then ok := ok + 1; end;
  foreach q in array array['application/pdf', 'image/svg+xml', 'application/x-msdownload', 'text/html', 'application/octet-stream', 'video/x-matroska'] loop
    begin perform public.reserve_contact_media(tok, 'file.bin', q, 1000); fail := fail + 1; log := log || ' [media accepted ' || q || ']'; exception when sqlstate '22023' then ok := ok + 1; end;
  end loop;
  if not public.media_type_allowed('image/svg+xml') and public.media_type_allowed('image/heic') and public.media_type_allowed('video/quicktime') then ok := ok + 1; else fail := fail + 1; log := log || ' [media_type_allowed]'; end if;
  begin insert into public.contact_media (contact_id, storage_path, original_name, content_type, size_bytes) values (cid, 'contacts/x/y.svg', 'y.svg', 'image/svg+xml', 10); fail := fail + 1; log := log || ' [svg row accepted by table]'; exception when check_violation then ok := ok + 1; end;
  if (select allowed_mime_types from storage.buckets where id = 'enquiry-media') @> array['image/jpeg', 'video/mp4'] and not ((select allowed_mime_types from storage.buckets where id = 'enquiry-media') @> array['image/svg+xml'])
     and (select public from storage.buckets where id = 'enquiry-media') = false then ok := ok + 1; else fail := fail + 1; log := log || ' [bucket allowlist / private]'; end if;
  begin perform public.reserve_contact_media(tok, 'huge.mp4', 'video/mp4', 52428801); fail := fail + 1; log := log || ' [media > 50MB file]'; exception when sqlstate '22023' then ok := ok + 1; end;
  perform public.reserve_contact_media(tok, 'side.png', 'image/png', 1000);
  begin perform public.reserve_contact_media(tok, 'fourth.png', 'image/png', 1000); fail := fail + 1; log := log || ' [media 4th file]'; exception when sqlstate 'P0003' then ok := ok + 1; end;
  begin perform public.confirm_contact_media(repeat('b', 64), j ->> 'path', true); fail := fail + 1; log := log || ' [confirm with wrong token]'; exception when no_data_found then ok := ok + 1; end;
  s := public.confirm_contact_media(tok, j ->> 'path', true);
  if s ->> 'status' = 'uploaded' and (select status from public.contact_media where storage_path = j ->> 'path') = 'uploaded' then ok := ok + 1; else fail := fail + 1; log := log || ' [confirm media]'; end if;
  update public.contacts set upload_token_expires_at = now() - interval '1 minute' where id = cid;
  begin perform public.reserve_contact_media(tok, 'late.png', 'image/png', 10); fail := fail + 1; log := log || ' [media window closed]'; exception when sqlstate 'P0003' then ok := ok + 1; end;
  -- re-issuing rotates the credential: the old token dies
  q := public.issue_upload_token(cid);
  begin perform public.reserve_contact_media(tok, 'old.png', 'image/png', 10); fail := fail + 1; log := log || ' [old token survives rotation]'; exception when no_data_found then ok := ok + 1; end;
  insert into storage.objects (bucket_id, name, metadata) values ('enquiry-media', j ->> 'path', '{"size": 30000000}'::jsonb);

  /* ---- 0. booking correctness is independent of pg_cron: an expired hold stops consuming capacity
          the moment it expires, without expire_holds() having run ---- */
  update public.availability_rules set active = false;
  insert into public.availability_rules (weekday, start_time, end_time, timezone) values (extract(isodow from (now() + interval '3 days'))::int, '10:00', '14:00', 'UTC');
  j := public.create_hold('t-perm', ((now() + interval '3 days')::date + time '12:00') at time zone 'UTC', 1, 'a5555555-5555-4555-8555-555555555555', 'Hold Person', 'hold@example.com');
  select count(*) into n from public.available_slots('t-perm', (now() + interval '3 days')::date, (now() + interval '3 days')::date, 'UTC') where start_at = ((now() + interval '3 days')::date + time '12:00') at time zone 'UTC';
  if n = 0 then ok := ok + 1; else fail := fail + 1; log := log || ' [live hold not consuming]'; end if;
  update public.bookings set hold_expires_at = now() - interval '1 second' where reference = j ->> 'reference';   -- expired, status still 'hold', no cron
  select count(*) into n from public.available_slots('t-perm', (now() + interval '3 days')::date, (now() + interval '3 days')::date, 'UTC') where start_at = ((now() + interval '3 days')::date + time '12:00') at time zone 'UTC';
  if n = 1 then ok := ok + 1; else fail := fail + 1; log := log || ' [expired hold still consuming without cron]'; end if;
  j := public.create_hold('t-perm', ((now() + interval '3 days')::date + time '12:00') at time zone 'UTC', 1, 'a6666666-6666-4666-8666-666666666666', 'Next Person', 'next@example.com');
  if j ->> 'status' = 'hold' then ok := ok + 1; else fail := fail + 1; log := log || ' [rebook over expired hold]'; end if;

  /* ---- 0b. CG-005 price chain on the real catalogue: 100 USD is the only amount that can be paid ---- */
  if (select price_amount from public.services where slug = 'conversation') = 10000 then ok := ok + 1; else fail := fail + 1; log := log || ' [conversation price]'; end if;
  j := public.create_hold('conversation', ((now() + interval '3 days')::date + time '13:00') at time zone 'UTC', 1, 'a7777777-7777-4777-8777-777777777777', 'Price Person', 'price@example.com');
  if (j ->> 'price_amount')::int = 10000 and j ->> 'currency' = 'USD' then ok := ok + 1; else fail := fail + 1; log := log || ' [hold snapshot ' || coalesce(j ->> 'price_amount', 'null') || ']'; end if;
  s := public.create_order_for_booking(j ->> 'reference', j ->> 'manage_token');
  if (s ->> 'gross_amount')::int = 10000 then ok := ok + 1; else fail := fail + 1; log := log || ' [order amount]'; end if;
  perform public.attach_checkout(s ->> 'reference', 'cs_price_' || replace(gen_random_uuid()::text, '-', ''), 'https://checkout.stripe.com/p', now() + interval '30 minutes');
  -- the old 45 USD amount arriving from Stripe is ignored and never confirms
  b := (public.process_stripe_event(jsonb_build_object('id', 'evt_price_45', 'type', 'checkout.session.completed', 'livemode', false,
         'data', jsonb_build_object('object', jsonb_build_object('id', (select stripe_checkout_session_id from public.orders where reference = s ->> 'reference'), 'payment_status', 'paid', 'amount_total', 4500, 'currency', 'usd', 'payment_intent', 'pi_price_45')))) ->> 'status') = 'ignored';
  if b and (select status from public.orders where reference = s ->> 'reference') = 'pending_payment' then ok := ok + 1; else fail := fail + 1; log := log || ' [45 USD not refused]'; end if;
  -- the correct amount confirms and the ledger applies the unchanged 10 % rule
  perform public.process_stripe_event(jsonb_build_object('id', 'evt_price_100', 'type', 'checkout.session.completed', 'livemode', false,
         'data', jsonb_build_object('object', jsonb_build_object('id', (select stripe_checkout_session_id from public.orders where reference = s ->> 'reference'), 'payment_status', 'paid', 'amount_total', 10000, 'currency', 'usd', 'payment_intent', 'pi_price_100')),
         '_enrich', jsonb_build_object('charge_id', 'ch_price', 'balance_transaction_id', 'txn_price', 'fee_amount', 320)));
  if (select pe.gross_amount || '/' || pe.stripe_fee || '/' || pe.net_collected || '/' || pe.oolala_commission || '/' || pe.gari_payable
        from public.partner_earnings pe join public.orders o on o.id = pe.order_id where o.reference = s ->> 'reference') = '10000/320/9680/968/8712'
     and (select status from public.bookings where reference = j ->> 'reference') = 'confirmed' then ok := ok + 1;
  else fail := fail + 1; log := log || ' [ledger 100 USD]'; end if;

  /* ---- 1. anon: permission denied everywhere ---- */
  perform set_config('request.jwt.claims', '{"role":"anon"}', true);
  execute 'set local role anon';
  foreach q in array array['select count(*) from public.contacts', 'select count(*) from public.bookings', 'select count(*) from public.orders',
                           'select count(*) from public.partner_earnings', 'select count(*) from public.finance_orders()', 'select count(*) from public.availability_rules',
                           'select count(*) from public.app_permissions', 'select count(*) from public.contact_media', 'select public.my_permissions()', 'select public.analytics_summary()',
                           'select public.ops_set_booking_status(''CG-TEST03'', ''cancelled'')', 'select public.admin_list_access()', 'select public.admin_grant(''x@test.local'', ''platform:admin'')',
                           'select public.issue_upload_token(gen_random_uuid())', 'select public.reserve_contact_media(repeat(''a'', 64), ''x.png'', ''image/png'', 1)',
                           'select public.set_app_access(''x@test.local'', ''x'', ''gari'', array[''platform:admin''])', 'select public.auth_identity_exists(''x@test.local'')'] loop
    begin execute q; fail := fail + 1; log := log || ' [anon allowed: ' || q || ']';
    exception when insufficient_privilege then ok := ok + 1; end;
  end loop;
  select count(*) into n from storage.objects where bucket_id = 'enquiry-media'; if n = 0 then ok := ok + 1; else fail := fail + 1; log := log || ' [anon reads media objects]'; end if;
  execute 'reset role';

  /* ---- 2. signed in without an app_users row, and an inactive user: nothing ---- */
  foreach q in array array['stranger@test.local', 'inactive@test.local'] loop
    perform set_config('request.jwt.claims', format('{"role":"authenticated","sub":"00000000-0000-4000-8000-000000000001","email":"%s"}', q), true);
    execute 'set local role authenticated';
    select count(*) into n from public.contacts;           if n = 0 then ok := ok + 1; else fail := fail + 1; log := log || format(' [%s contacts]', q); end if;
    select count(*) into n from public.bookings;           if n = 0 then ok := ok + 1; else fail := fail + 1; log := log || format(' [%s bookings]', q); end if;
    select count(*) into n from public.orders;             if n = 0 then ok := ok + 1; else fail := fail + 1; log := log || format(' [%s orders]', q); end if;
    begin perform public.finance_orders(); fail := fail + 1; log := log || format(' [%s finance_orders]', q); exception when insufficient_privilege then ok := ok + 1; end;
    select count(*) into n from public.availability_rules; if n = 0 then ok := ok + 1; else fail := fail + 1; log := log || format(' [%s rules]', q); end if;
    select count(*) into n from public.contact_media;      if n = 0 then ok := ok + 1; else fail := fail + 1; log := log || format(' [%s media]', q); end if;
    select count(*) into n from storage.objects where bucket_id = 'enquiry-media'; if n = 0 then ok := ok + 1; else fail := fail + 1; log := log || format(' [%s media objects]', q); end if;
    if (public.my_permissions() -> 'permissions') = '[]'::jsonb then ok := ok + 1; else fail := fail + 1; log := log || format(' [%s my_permissions]', q); end if;
    begin perform public.ops_set_booking_status('CG-TEST03', 'cancelled'); fail := fail + 1; log := log || format(' [%s ops rpc]', q); exception when insufficient_privilege then ok := ok + 1; end;
    begin perform public.finance_create_settlement(current_date - 1, current_date + 1); fail := fail + 1; log := log || format(' [%s finance rpc]', q); exception when insufficient_privilege then ok := ok + 1; end;
    begin perform public.analytics_summary(); fail := fail + 1; log := log || format(' [%s analytics rpc]', q); exception when insufficient_privilege then ok := ok + 1; end;
    begin perform public.admin_list_access(); fail := fail + 1; log := log || format(' [%s admin rpc]', q); exception when insufficient_privilege then ok := ok + 1; end;
    -- an inactive user still sees its own (inactive) row and nothing else; a stranger sees nothing
    select count(*) into n from public.app_users where email <> q; if n = 0 then ok := ok + 1; else fail := fail + 1; log := log || format(' [%s app_users of others]', q); end if;
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
  -- (the 'contacts' message column: a coach's intended read; finance and analytics are refused it below)
  select count(*) into n from public.contacts where message = 'private message body'; if n = 1 then ok := ok + 1; else fail := fail + 1; log := log || ' [coach reads leads]'; end if;
  select count(*) into n from public.bookings where customer_contact = 'payer@example.com'; if n = 1 then ok := ok + 1; else fail := fail + 1; log := log || ' [coach reads bookings]'; end if;
  select count(*) into n from public.contact_media where status = 'uploaded'; if n = 1 then ok := ok + 1; else fail := fail + 1; log := log || ' [coach reads media rows]'; end if;
  select count(*) into n from storage.objects where bucket_id = 'enquiry-media'; if n = 1 then ok := ok + 1; else fail := fail + 1; log := log || ' [coach reads media objects]'; end if;
  begin perform public.reserve_contact_media(repeat('a', 64), 'x.png', 'image/png', 1); fail := fail + 1; log := log || ' [coach calls reserve]'; exception when insufficient_privilege then ok := ok + 1; end;
  begin perform public.issue_upload_token(cid); fail := fail + 1; log := log || ' [coach issues upload token]'; exception when insufficient_privilege then ok := ok + 1; end;
  begin select count(*) into n from public.contacts where upload_token_hash is not null; fail := fail + 1; log := log || ' [coach reads upload_token_hash]'; exception when insufficient_privilege then ok := ok + 1; end;
  begin perform public.admin_list_access(); fail := fail + 1; log := log || ' [coach lists access]'; exception when insufficient_privilege then ok := ok + 1; end;
  begin perform public.admin_grant('coach@test.local', 'finance:manage'); fail := fail + 1; log := log || ' [coach self-grants via rpc]'; exception when insufficient_privilege then ok := ok + 1; end;
  begin perform public.set_app_access('coach@test.local', 'Coach', 'gari', array['platform:admin']); fail := fail + 1; log := log || ' [coach calls set_app_access]'; exception when insufficient_privilege then ok := ok + 1; end;
  begin select count(*) into n from public.bookings where manage_token = 'secret-token'; fail := fail + 1; log := log || ' [coach manage_token readable]';
  exception when insufficient_privilege then ok := ok + 1; end;
  begin select count(*) into n from public.contacts where ip_hash is null; fail := fail + 1; log := log || ' [coach ip_hash readable]';
  exception when insufficient_privilege then ok := ok + 1; end;
  select count(*) into n from public.orders;           if n = 0 then ok := ok + 1; else fail := fail + 1; log := log || ' [coach sees orders]'; end if;
  select count(*) into n from public.payments;         if n = 0 then ok := ok + 1; else fail := fail + 1; log := log || ' [coach sees payments]'; end if;
  select count(*) into n from public.partner_earnings; if n = 0 then ok := ok + 1; else fail := fail + 1; log := log || ' [coach sees earnings]'; end if;
  begin perform public.finance_orders(); fail := fail + 1; log := log || ' [coach sees finance_orders]'; exception when insufficient_privilege then ok := ok + 1; end;
  select count(*) into n from public.partner_settlements;      if n = 0 then ok := ok + 1; else fail := fail + 1; log := log || ' [coach sees settlements]'; end if;
  select count(*) into n from public.partner_settlement_items; if n = 0 then ok := ok + 1; else fail := fail + 1; log := log || ' [coach sees settlement items]'; end if;
  select count(*) into n from public.refunds;                  if n = 0 then ok := ok + 1; else fail := fail + 1; log := log || ' [coach sees refunds]'; end if;
  select count(*) into n from public.chargebacks;              if n = 0 then ok := ok + 1; else fail := fail + 1; log := log || ' [coach sees chargebacks]'; end if;
  begin perform public.finance_webhook_log(); fail := fail + 1; log := log || ' [coach webhook log]'; exception when insufficient_privilege then ok := ok + 1; end;
  begin perform public.finance_mark_settlement_paid('ST-000000', 'x'); fail := fail + 1; log := log || ' [coach mark paid]'; exception when insufficient_privilege then ok := ok + 1; end;
  begin select count(*) into n from public.webhook_events; fail := fail + 1; log := log || ' [coach raw webhook events]'; exception when insufficient_privilege then ok := ok + 1; end;
  begin insert into public.app_permissions (email, permission) values ('coach@test.local', 'finance:manage'); fail := fail + 1; log := log || ' [coach grants self finance]'; exception when insufficient_privilege then ok := ok + 1; end;
  begin update public.app_users set active = true; fail := fail + 1; log := log || ' [coach edits app_users]'; exception when insufficient_privilege then ok := ok + 1; end;
  begin delete from public.app_permissions; fail := fail + 1; log := log || ' [coach deletes permissions]'; exception when insufficient_privilege then ok := ok + 1; end;
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
     and (select count(*) from public.contacts where contact = 'lead@example.com') = 1 then ok := ok + 1; else fail := fail + 1; log := log || ' [coach cancel]'; end if;
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
  select count(*) into n from public.contact_media; if n = 0 then ok := ok + 1; else fail := fail + 1; log := log || ' [finance sees media rows]'; end if;
  select count(*) into n from storage.objects where bucket_id = 'enquiry-media'; if n = 0 then ok := ok + 1; else fail := fail + 1; log := log || ' [finance sees media objects]'; end if;
  select count(*) into n from public.finance_orders() f where f.reference = oref and f.service_title = 'Perm test session' and f.gari_payable = 3905;
  if n = 1 then ok := ok + 1; else fail := fail + 1; log := log || ' [finance_orders row]'; end if;
  select (to_jsonb(f) ? 'customer_name') or (to_jsonb(f) ? 'customer_contact') or to_jsonb(f)::text like '%Paying Person%' or to_jsonb(f)::text like '%payer@example.com%' into b
    from public.finance_orders() f where f.reference = oref;
  if not b then ok := ok + 1; else fail := fail + 1; log := log || ' [finance_orders exposes identity]'; end if;
  select f.customer_hint into q from public.finance_orders() f where f.reference = oref;
  if q = 'p***@example.com' then ok := ok + 1; else fail := fail + 1; log := log || ' [customer_hint ' || coalesce(q, 'null') || ']'; end if;
  begin perform public.mask_contact('+27000000'); fail := fail + 1; log := log || ' [finance calls mask_contact]'; exception when insufficient_privilege then ok := ok + 1; end;
  select count(*) into n from public.contacts where message is not null;  -- column is granted to the shared role; RLS returns no row to finance
  if n = 0 then ok := ok + 1; else fail := fail + 1; log := log || ' [finance reads message bodies]'; end if;
  begin select count(*) into n from public.email_events; fail := fail + 1; log := log || ' [finance reads email_events]'; exception when insufficient_privilege then ok := ok + 1; end;
  begin insert into public.app_permissions (email, permission) values ('finance@test.local', 'coach:operations'); fail := fail + 1; log := log || ' [finance grants self coach]'; exception when insufficient_privilege then ok := ok + 1; end;
  select count(*) into n from public.finance_webhook_log() w where w.event_id = 'evt_perm_1'; if n = 1 then ok := ok + 1; else fail := fail + 1; log := log || ' [finance webhook log]'; end if;
  begin select count(*) into n from public.webhook_events; fail := fail + 1; log := log || ' [finance raw webhook payloads]'; exception when insufficient_privilege then ok := ok + 1; end;
  begin perform public.ops_set_booking_status('CG-TEST02', 'cancelled'); fail := fail + 1; log := log || ' [finance ops rpc]'; exception when insufficient_privilege then ok := ok + 1; end;
  update public.availability_rules set active = true; get diagnostics n = row_count;
  if n = 0 then ok := ok + 1; else fail := fail + 1; log := log || ' [finance edits calendar]'; end if;
  begin perform public.analytics_summary(); fail := fail + 1; log := log || ' [finance analytics rpc]'; exception when insufficient_privilege then ok := ok + 1; end;
  s := public.finance_create_settlement(current_date - 1, current_date + 1, 'USD');
  if (s ->> 'items')::int = 2 and (s ->> 'amount_payable')::int = 3905 + 8712 then ok := ok + 1; else fail := fail + 1; log := log || ' [finance settlement ' || s::text || ']'; end if;
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
  if j::text !~ '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}' and j::text !~ '\+?[0-9][0-9 ]{6,}[0-9]' and j::text !~ 'CG-[0-9A-Z]{6}' then ok := ok + 1; else fail := fail + 1; log := log || ' [analytics contains email/phone/reference pattern]'; end if;
  select count(*) into n from public.contacts; if n = 0 then ok := ok + 1; else fail := fail + 1; log := log || ' [analytics sees leads]'; end if;
  select count(*) into n from public.orders;   if n = 0 then ok := ok + 1; else fail := fail + 1; log := log || ' [analytics sees orders]'; end if;
  select count(*) into n from public.bookings; if n = 0 then ok := ok + 1; else fail := fail + 1; log := log || ' [analytics sees bookings]'; end if;
  select count(*) into n from storage.objects where bucket_id = 'enquiry-media'; if n = 0 then ok := ok + 1; else fail := fail + 1; log := log || ' [analytics sees media objects]'; end if;
  execute 'reset role';


  /* ---- 6. launch user: coach + finance + analytics in one identity reaches every business area (no owner role needed) ---- */
  perform set_config('request.jwt.claims', '{"role":"authenticated","sub":"00000000-0000-4000-8000-000000000006","email":"launch@test.local"}', true);
  execute 'set local role authenticated';
  if (public.my_permissions() -> 'permissions') = '["analytics:view","coach:operations","finance:manage","finance:view"]'::jsonb then ok := ok + 1; else fail := fail + 1; log := log || ' [launch my_permissions ' || (public.my_permissions() -> 'permissions')::text || ']'; end if;
  select count(*) into n from public.contacts where message = 'private message body'; if n = 1 then ok := ok + 1; else fail := fail + 1; log := log || ' [launch reads leads]'; end if;
  select count(*) into n from public.bookings where reference like 'CG-TEST%'; if n = 3 then ok := ok + 1; else fail := fail + 1; log := log || ' [launch reads bookings]'; end if;
  select count(*) into n from public.availability_rules; if n >= 1 then ok := ok + 1; else fail := fail + 1; log := log || ' [launch reads calendar]'; end if;
  select count(*) into n from public.contact_media where status = 'uploaded'; if n = 1 then ok := ok + 1; else fail := fail + 1; log := log || ' [launch reads media rows]'; end if;
  select count(*) into n from storage.objects where bucket_id = 'enquiry-media'; if n = 1 then ok := ok + 1; else fail := fail + 1; log := log || ' [launch reads media objects]'; end if;
  select count(*) into n from public.orders where reference = oref; if n = 1 then ok := ok + 1; else fail := fail + 1; log := log || ' [launch reads orders]'; end if;
  select count(*) into n from public.payments; if n >= 1 then ok := ok + 1; else fail := fail + 1; log := log || ' [launch reads payments]'; end if;
  select count(*) into n from public.partner_earnings; if n >= 1 then ok := ok + 1; else fail := fail + 1; log := log || ' [launch reads earnings]'; end if;
  select count(*) into n from public.partner_settlements where status = 'reconciled'; if n = 1 then ok := ok + 1; else fail := fail + 1; log := log || ' [launch reads settlements]'; end if;
  select count(*) into n from public.finance_orders() f where f.reference = oref; if n = 1 then ok := ok + 1; else fail := fail + 1; log := log || ' [launch finance_orders]'; end if;
  select count(*) into n from public.finance_webhook_log() w where w.event_id = 'evt_perm_1'; if n = 1 then ok := ok + 1; else fail := fail + 1; log := log || ' [launch webhook log]'; end if;
  j := public.analytics_summary(); if (j -> 'leads' ->> 'total')::int >= 1 then ok := ok + 1; else fail := fail + 1; log := log || ' [launch analytics]'; end if;
  update public.contacts set status = 'contacted' where contact = 'lead@example.com'; get diagnostics n = row_count;
  if n = 1 then ok := ok + 1; else fail := fail + 1; log := log || ' [launch updates lead]'; end if;
  -- still no secrets, no raw payloads, no access administration, no self-grant
  begin select count(*) into n from public.bookings where manage_token = 'secret-token'; fail := fail + 1; log := log || ' [launch manage_token readable]'; exception when insufficient_privilege then ok := ok + 1; end;
  begin select count(*) into n from public.orders where customer_name = 'Paying Person'; fail := fail + 1; log := log || ' [launch order identity readable]'; exception when insufficient_privilege then ok := ok + 1; end;
  begin select count(*) into n from public.webhook_events; fail := fail + 1; log := log || ' [launch raw webhook events]'; exception when insufficient_privilege then ok := ok + 1; end;
  begin perform public.admin_list_access(); fail := fail + 1; log := log || ' [launch lists access]'; exception when insufficient_privilege then ok := ok + 1; end;
  begin perform public.admin_grant('launch@test.local', 'platform:admin'); fail := fail + 1; log := log || ' [launch self-grants admin]'; exception when insufficient_privilege then ok := ok + 1; end;
  begin insert into public.app_permissions (email, permission) values ('launch@test.local', 'platform:admin'); fail := fail + 1; log := log || ' [launch inserts permission]'; exception when insufficient_privilege then ok := ok + 1; end;
  select count(*) into n from public.app_users; if n = 1 then ok := ok + 1; else fail := fail + 1; log := log || ' [launch app_users self only]'; end if;
  execute 'reset role';

  /* ---- 7. platform:admin: access administration only, never a bypass ---- */
  perform set_config('request.jwt.claims', '{"role":"authenticated","sub":"00000000-0000-4000-8000-000000000007","email":"padmin@test.local"}', true);
  execute 'set local role authenticated';
  if (public.my_permissions() -> 'permissions') = '["platform:admin"]'::jsonb then ok := ok + 1; else fail := fail + 1; log := log || ' [padmin my_permissions]'; end if;
  select count(*) into n from public.contacts;                if n = 0 then ok := ok + 1; else fail := fail + 1; log := log || ' [padmin sees leads]'; end if;
  select count(*) into n from public.bookings;                if n = 0 then ok := ok + 1; else fail := fail + 1; log := log || ' [padmin sees bookings]'; end if;
  select count(*) into n from public.orders;                  if n = 0 then ok := ok + 1; else fail := fail + 1; log := log || ' [padmin sees orders]'; end if;
  select count(*) into n from public.payments;                if n = 0 then ok := ok + 1; else fail := fail + 1; log := log || ' [padmin sees payments]'; end if;
  select count(*) into n from public.partner_earnings;        if n = 0 then ok := ok + 1; else fail := fail + 1; log := log || ' [padmin sees earnings]'; end if;
  select count(*) into n from public.partner_settlements;     if n = 0 then ok := ok + 1; else fail := fail + 1; log := log || ' [padmin sees settlements]'; end if;
  select count(*) into n from public.availability_rules;      if n = 0 then ok := ok + 1; else fail := fail + 1; log := log || ' [padmin sees calendar]'; end if;
  select count(*) into n from public.contact_media;           if n = 0 then ok := ok + 1; else fail := fail + 1; log := log || ' [padmin sees media rows]'; end if;
  select count(*) into n from storage.objects where bucket_id = 'enquiry-media'; if n = 0 then ok := ok + 1; else fail := fail + 1; log := log || ' [padmin sees media objects]'; end if;
  begin perform public.finance_orders(); fail := fail + 1; log := log || ' [padmin finance_orders]'; exception when insufficient_privilege then ok := ok + 1; end;
  begin perform public.finance_webhook_log(); fail := fail + 1; log := log || ' [padmin webhook log]'; exception when insufficient_privilege then ok := ok + 1; end;
  begin perform public.analytics_summary(); fail := fail + 1; log := log || ' [padmin analytics]'; exception when insufficient_privilege then ok := ok + 1; end;
  begin perform public.ops_set_booking_status('CG-TEST03', 'cancelled'); fail := fail + 1; log := log || ' [padmin ops rpc]'; exception when insufficient_privilege then ok := ok + 1; end;
  begin perform public.finance_create_settlement(current_date - 1, current_date + 1); fail := fail + 1; log := log || ' [padmin finance rpc]'; exception when insufficient_privilege then ok := ok + 1; end;
  begin select count(*) into n from public.webhook_events; fail := fail + 1; log := log || ' [padmin raw webhook events]'; exception when insufficient_privilege then ok := ok + 1; end;
  begin perform public.set_app_access('padmin@test.local', 'x', 'studio', array['coach:operations']); fail := fail + 1; log := log || ' [padmin calls set_app_access]'; exception when insufficient_privilege then ok := ok + 1; end;
  begin perform public.auth_identity_exists('padmin@test.local'); fail := fail + 1; log := log || ' [padmin reads auth directly]'; exception when insufficient_privilege then ok := ok + 1; end;
  update public.contacts set status = 'contacted'; get diagnostics n = row_count;
  if n = 0 then ok := ok + 1; else fail := fail + 1; log := log || ' [padmin updates leads]'; end if;
  -- no direct writes on the access tables either: everything goes through the audited RPCs
  begin insert into public.app_permissions (email, permission) values ('padmin@test.local', 'coach:operations'); fail := fail + 1; log := log || ' [padmin inserts permission directly]'; exception when insufficient_privilege then ok := ok + 1; end;
  begin update public.app_users set active = false where email = 'coach@test.local'; fail := fail + 1; log := log || ' [padmin updates app_users directly]'; exception when insufficient_privilege then ok := ok + 1; end;
  -- what platform:admin can do
  select count(*) into n from public.app_users; if n >= 6 then ok := ok + 1; else fail := fail + 1; log := log || ' [padmin lists app_users]'; end if;
  j := public.admin_list_access();
  if jsonb_array_length(j) >= 6 and exists (select 1 from jsonb_array_elements(j) e where e ->> 'email' = 'coach@test.local' and e -> 'permissions' = '["coach:operations"]'::jsonb and (e ->> 'auth_exists')::boolean = false)
  then ok := ok + 1; else fail := fail + 1; log := log || ' [admin_list_access]'; end if;
  if j::text not like '%private message body%' and j::text not like '%lead@example.com%' then ok := ok + 1; else fail := fail + 1; log := log || ' [admin_list_access leaks business data]'; end if;
  j := public.admin_grant('coach@test.local', 'finance:view');
  if (j ->> 'granted')::boolean and exists (select 1 from public.app_permissions where email = 'coach@test.local' and permission = 'finance:view') then ok := ok + 1; else fail := fail + 1; log := log || ' [admin_grant]'; end if;
  j := public.admin_grant('coach@test.local', 'finance:view');  -- idempotent
  if (j ->> 'granted')::boolean then ok := ok + 1; else fail := fail + 1; log := log || ' [admin_grant idempotent]'; end if;
  j := public.admin_revoke('coach@test.local', 'finance:view');
  if not exists (select 1 from public.app_permissions where email = 'coach@test.local' and permission = 'finance:view') then ok := ok + 1; else fail := fail + 1; log := log || ' [admin_revoke]'; end if;
  begin perform public.admin_grant('coach@test.local', 'superadmin'); fail := fail + 1; log := log || ' [unknown permission granted]'; exception when check_violation then ok := ok + 1; end;
  begin perform public.admin_grant('nobody@test.local', 'coach:operations'); fail := fail + 1; log := log || ' [grant to unknown user]'; exception when no_data_found then ok := ok + 1; end;
  begin perform public.admin_revoke('padmin@test.local', 'platform:admin'); fail := fail + 1; log := log || ' [padmin revoked own admin]'; exception when sqlstate 'P0003' then ok := ok + 1; end;
  -- no fake app records: a user without an auth identity cannot be created (auth.users is empty in the harness)
  begin perform public.admin_set_user('ghost@test.local', 'Ghost', 'gari', true); fail := fail + 1; log := log || ' [user created without auth identity]'; exception when no_data_found then ok := ok + 1; end;
  select count(*) into n from public.app_users where email = 'ghost@test.local'; if n = 0 then ok := ok + 1; else fail := fail + 1; log := log || ' [ghost row persisted]'; end if;
  -- granting itself a business permission through the RPC is by design (platform:admin administers access);
  -- but even then business data is only visible because of that explicit permission, never because of platform:admin
  perform public.admin_grant('padmin@test.local', 'analytics:view');
  j := public.analytics_summary(); if (j -> 'leads' ->> 'total')::int >= 1 then ok := ok + 1; else fail := fail + 1; log := log || ' [padmin analytics after explicit grant]'; end if;
  select count(*) into n from public.contacts; if n = 0 then ok := ok + 1; else fail := fail + 1; log := log || ' [padmin sees leads after analytics grant]'; end if;
  perform public.admin_revoke('padmin@test.local', 'analytics:view');
  begin perform public.analytics_summary(); fail := fail + 1; log := log || ' [padmin analytics after revoke]'; exception when insufficient_privilege then ok := ok + 1; end;
  execute 'reset role';

  /* ---- 8. set_app_access (service role / SQL editor path): idempotent, refuses an email with no auth identity ---- */
  begin perform public.set_app_access('ghost@test.local', 'Ghost', 'gari', array['coach:operations']); fail := fail + 1; log := log || ' [set_app_access without auth identity]'; exception when no_data_found then ok := ok + 1; end;
  select count(*) into n from public.app_users where email = 'ghost@test.local'; if n = 0 then ok := ok + 1; else fail := fail + 1; log := log || ' [set_app_access ghost row]'; end if;

  raise exception 'CG0025_TESTS ok=% fail=% %', ok, fail, log;
end $$;

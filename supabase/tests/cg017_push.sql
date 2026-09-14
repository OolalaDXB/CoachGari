-- CG-017 push notifications — access boundaries and queue behaviour.
-- Rolls back: the whole block ends in RAISE EXCEPTION, so nothing is persisted.
-- Run: psql "$DATABASE_URL" -f supabase/tests/cg017_push.sql
do $$
declare
  ok int := 0; fail int := 0;
  v_txt text; v_int int; v_id uuid; v_big bigint; v_eid text; n int;
  ep1 text := 'https://fcm.googleapis.com/fcm/send/aaa-' || gen_random_uuid();
  ep2 text := 'https://fcm.googleapis.com/fcm/send/bbb-' || gen_random_uuid();
  k1 text := repeat('A', 87);      -- a plausible p256dh length
  a1 text := repeat('B', 22);      -- a plausible auth length
begin

  -- two people who work here, one who does not
  insert into public.app_users (email, display_name, party, active)
  values ('push-a@example.com', 'A', 'gari', true),
         ('push-b@example.com', 'B', 'gari', true)
  on conflict (email) do nothing;

  -- ---------- 1. the tables are closed to anon and to the browser role ----------
  perform set_config('role', 'anon', true);
  begin
    perform 1 from public.push_subscriptions limit 1;
    fail := fail + 1; raise notice 'FAIL  anon can read push_subscriptions';
  exception when insufficient_privilege or undefined_table then ok := ok + 1;
  end;
  begin
    perform 1 from public.push_events limit 1;
    fail := fail + 1; raise notice 'FAIL  anon can read push_events';
  exception when insufficient_privilege or undefined_table then ok := ok + 1;
  end;
  begin
    perform 1 from public.push_config limit 1;
    fail := fail + 1; raise notice 'FAIL  anon can read push_config';
  exception when insufficient_privilege or undefined_table then ok := ok + 1;
  end;
  begin
    perform public.push_vapid_public();
    fail := fail + 1; raise notice 'FAIL  anon can read the VAPID public key';
  exception when insufficient_privilege then ok := ok + 1;
  end;
  reset role;

  -- ---------- 2. the private key is never reachable from a browser session ----------
  perform set_config('role', 'authenticated', true);
  begin
    perform public.push_sender_config();
    fail := fail + 1; raise notice 'FAIL  an authenticated user can read the VAPID private key';
  exception when insufficient_privilege then ok := ok + 1;
  end;
  begin
    perform public.push_queue('booking_confirmed', 'x');
    fail := fail + 1; raise notice 'FAIL  an authenticated user can queue a push';
  exception when insufficient_privilege then ok := ok + 1;
  end;
  begin
    perform public.push_outbox_authorize('x');
    fail := fail + 1; raise notice 'FAIL  an authenticated user can call the drain authoriser';
  exception when insufficient_privilege then ok := ok + 1;
  end;
  reset role;

  -- ---------- 3. push_config holds no private key column at all ----------
  select count(*) into n from information_schema.columns
   where table_schema = 'public' and table_name = 'push_config' and column_name = 'vapid_private';
  if n = 0 then ok := ok + 1; else fail := fail + 1; raise notice 'FAIL  push_config still has a vapid_private column'; end if;

  select count(*) into n from information_schema.columns
   where table_schema = 'public' and table_name = 'push_events' and column_name in ('payload','to_address','contact_id','customer_name');
  if n = 0 then ok := ok + 1; else fail := fail + 1; raise notice 'FAIL  push_events carries a column that could hold personal data'; end if;

  -- the drain key is stored hashed, like the email one
  select count(*) into n from information_schema.columns
   where table_schema = 'public' and table_name = 'outbox_keys' and column_name = 'key';
  if n = 0 then ok := ok + 1; else fail := fail + 1; raise notice 'FAIL  outbox_keys still has a clear key column'; end if;
  select count(*) into n from public.outbox_keys where name = 'push' and key_sha256 is not null;
  if n = 1 then ok := ok + 1; else fail := fail + 1; raise notice 'FAIL  no hashed push drain key'; end if;

  -- ---------- 4. a subscription is pinned to whoever is signed in ----------
  perform set_config('request.jwt.claims', json_build_object('email','push-a@example.com')::text, true);
  perform set_config('role', 'authenticated', true);
  v_id := public.push_subscribe(ep1, k1, a1, 'ua/1');
  reset role;
  select email into v_txt from public.push_subscriptions where id = v_id;
  if v_txt = 'push-a@example.com' then ok := ok + 1; else fail := fail + 1; raise notice 'FAIL  subscribe did not pin the caller (got %)', v_txt; end if;

  -- B subscribes their own device
  perform set_config('request.jwt.claims', json_build_object('email','push-b@example.com')::text, true);
  perform set_config('role', 'authenticated', true);
  perform public.push_subscribe(ep2, k1, a1, 'ua/2');

  -- ---------- 5. B sees only their own ----------
  select count(*) into n from public.push_subscriptions;
  if n = 1 then ok := ok + 1; else fail := fail + 1; raise notice 'FAIL  B sees % subscriptions, expected only their own', n; end if;
  select count(*) into n from public.push_subscriptions where endpoint = ep1;
  if n = 0 then ok := ok + 1; else fail := fail + 1; raise notice 'FAIL  B can see A''s subscription'; end if;

  -- B cannot delete A's
  delete from public.push_subscriptions where endpoint = ep1;
  get diagnostics n = row_count;
  if n = 0 then ok := ok + 1; else fail := fail + 1; raise notice 'FAIL  B deleted A''s subscription'; end if;

  -- B can delete their own, through the RPC
  v_int := public.push_unsubscribe(ep2);
  if v_int = 1 then ok := ok + 1; else fail := fail + 1; raise notice 'FAIL  B could not remove their own subscription'; end if;

  -- and cannot remove A's through it either
  v_int := public.push_unsubscribe(ep1);
  if v_int = 0 then ok := ok + 1; else fail := fail + 1; raise notice 'FAIL  push_unsubscribe removed another person''s row'; end if;
  reset role;

  -- ---------- 6. no direct insert, even signed in ----------
  perform set_config('request.jwt.claims', json_build_object('email','push-b@example.com')::text, true);
  perform set_config('role', 'authenticated', true);
  begin
    insert into public.push_subscriptions (email, endpoint, p256dh, auth)
    values ('push-a@example.com', 'https://x/' || gen_random_uuid(), k1, a1);
    fail := fail + 1; raise notice 'FAIL  a signed-in user inserted a subscription directly';
  exception when insufficient_privilege or others then ok := ok + 1;
  end;
  reset role;

  -- ---------- 7. rubbish subscriptions are refused ----------
  perform set_config('request.jwt.claims', json_build_object('email','push-a@example.com')::text, true);
  perform set_config('role', 'authenticated', true);
  begin
    perform public.push_subscribe('http://not-https/x', k1, a1, null);
    fail := fail + 1; raise notice 'FAIL  a non-https endpoint was accepted';
  exception when others then ok := ok + 1;
  end;
  begin
    perform public.push_subscribe('https://ok/' || gen_random_uuid(), 'short', a1, null);
    fail := fail + 1; raise notice 'FAIL  a short p256dh was accepted';
  exception when others then ok := ok + 1;
  end;
  reset role;

  -- someone with no app_users row cannot subscribe at all
  perform set_config('request.jwt.claims', json_build_object('email','stranger@example.com')::text, true);
  perform set_config('role', 'authenticated', true);
  begin
    perform public.push_subscribe('https://ok/' || gen_random_uuid(), k1, a1, null);
    fail := fail + 1; raise notice 'FAIL  someone with no back-office access subscribed';
  exception when others then ok := ok + 1;
  end;
  reset role;
  perform set_config('request.jwt.claims', null, true);

  -- ---------- 8. the queue: owner mail buzzes, customer mail does not ----------
  delete from public.push_events where dedupe_key like 'email:%';
  insert into public.email_events (kind, to_address, dedupe_key, payload, status)
  values ('payment_received', public.email_owner_address(), 'test:' || gen_random_uuid(), '{}'::jsonb, 'pending');
  select count(*) into n from public.push_events where kind = 'payment_received';
  if n = 1 then ok := ok + 1; else fail := fail + 1; raise notice 'FAIL  an owner email queued % pushes, expected 1', n; end if;

  insert into public.email_events (kind, to_address, dedupe_key, payload, status)
  values ('booking_confirmed', 'customer@example.com', 'test:' || gen_random_uuid(), '{}'::jsonb, 'pending');
  select count(*) into n from public.push_events where kind = 'booking_confirmed';
  if n = 0 then ok := ok + 1; else fail := fail + 1; raise notice 'FAIL  a customer email queued a push to the owner''s phone'; end if;

  -- the same email row never queues twice
  select id::text into v_eid from public.email_events where to_address = public.email_owner_address() order by created_at desc limit 1;
  v_big := public.push_queue('payment_received', 'email:' || v_eid);
  if v_big is null then ok := ok + 1; else fail := fail + 1; raise notice 'FAIL  the same event queued a second push'; end if;

  -- ---------- 9. nothing is queued when nobody is listening ----------
  delete from public.push_subscriptions;
  delete from public.push_events where dedupe_key like 'email:%';
  insert into public.email_events (kind, to_address, dedupe_key, payload, status)
  values ('lead_notification', public.email_owner_address(), 'test:' || gen_random_uuid(), '{}'::jsonb, 'pending');
  select count(*) into n from public.push_events where kind = 'lead_notification';
  if n = 0 then ok := ok + 1; else fail := fail + 1; raise notice 'FAIL  a push was queued with no subscriptions to send it to'; end if;

  raise exception 'CG017_TESTS ok=% fail=%', ok, fail;
end $$;

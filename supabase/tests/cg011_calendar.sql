-- CG-011 calendar / sessions / packs / blocks — database suite. One
-- transaction, always rolls back (RAISE EXCEPTION 'CG011_TESTS ok=… fail=…').
-- Proves: a session appears in calendar_range at its real time and links the
-- right CRM contact; "Block time" is one authoritative closed exception that
-- the PUBLIC available_slots engine already excludes, and its private note
-- never reaches that engine; package X/total is counted from LINKED sessions
-- (completed consumes, scheduled/cancelled don't, no_show only if chargeable),
-- a wrong-client session cannot consume a pack, renewal is a NEW pack and the
-- old one is immutable; financial fields need finance:*, session/block
-- mutations need coach:operations, platform:admin alone grants neither; a
-- website booking materialises exactly one session (no duplicate); anon is
-- refused everything.
do $$
declare
  ok int := 0; fail int := 0; log text := '';
  cA uuid; cB uuid; svc uuid; packA uuid; packRenew uuid; sess uuid; blk uuid; j jsonb; n int;
  d date := (current_date + 10); dow int; sc0 int; sc1 int;
begin
  /* ---- personas ---- */
  insert into public.app_users (email, display_name, party) values
    ('coachonly@test.local','CoachOnly','gari'),('coachfin@test.local','CoachFin','gari'),
    ('padmin@test.local','PA','studio');
  insert into public.app_permissions (email, permission) values
    ('coachonly@test.local','coach:operations'),
    ('coachfin@test.local','coach:operations'),('coachfin@test.local','finance:view'),('coachfin@test.local','finance:manage'),
    ('padmin@test.local','platform:admin');

  insert into public.crm_contacts (display_name, email, email_norm) values ('Client A','ca@ex.com','ca@ex.com') returning id into cA;
  insert into public.crm_contacts (display_name, email, email_norm) values ('Client B','cb@ex.com','cb@ex.com') returning id into cB;
  insert into public.services (slug, title, category, duration_minutes, price_amount, currency, delivery_mode, default_capacity, active, listed)
    values ('t-cal','Calendar test','coaching',60,5000,'USD','online',1,true,false) returning id into svc;

  /* ========== 1. session create + calendar_range ========== */
  perform set_config('request.jwt.claims','{"role":"authenticated","sub":"00000000-0000-4000-8000-0000000c0001","email":"coachonly@test.local"}',true);
  execute 'set local role authenticated';
  j := public.session_write(jsonb_build_object('crm_contact_id', cA::text, 'title','Private coaching',
        'start_at', (d::text||' 10:00')::timestamp at time zone 'Asia/Dubai',
        'end_at',   (d::text||' 11:00')::timestamp at time zone 'Asia/Dubai',
        'delivery_mode','in_person','location_name','Dubai Padel Academy','location_address','Al Quoz, Dubai',
        'location_lat','25.14','location_lng','55.23'));
  sess := (j->>'id')::uuid;
  if (j->>'crm_contact_id')::uuid = cA and (j->>'location_name')='Dubai Padel Academy'
     and (j->>'location_lat')::numeric = 25.14 then ok:=ok+1; else fail:=fail+1; log:=log||' [session create/location]'; end if;

  j := public.calendar_range((d::text||' 00:00')::timestamp at time zone 'Asia/Dubai', (d::text||' 23:59')::timestamp at time zone 'Asia/Dubai');
  if jsonb_array_length(j->'sessions') = 1 and (j->'sessions'->0->>'client_name')='Client A'
     and (j->'sessions'->0->>'id')::uuid = sess then ok:=ok+1; else fail:=fail+1; log:=log||' [calendar_range in-window]'; end if;
  -- a window that does not contain it returns none
  j := public.calendar_range((d::text||' 00:00')::timestamp at time zone 'Asia/Dubai' + interval '2 days', (d::text||' 23:59')::timestamp at time zone 'Asia/Dubai' + interval '2 days');
  if jsonb_array_length(j->'sessions') = 0 then ok:=ok+1; else fail:=fail+1; log:=log||' [calendar_range out-window]'; end if;
  execute 'reset role';

  /* ========== 2. blocks drive the PUBLIC availability engine ========== */
  -- an 08:00-12:00 rule guarantees a 09:00 slot for t-cal. Other production
  -- rules may exist, so assert the DELTA the block makes, not an absolute count.
  dow := extract(isodow from d);
  insert into public.availability_rules (weekday, start_time, end_time, timezone, service_ids, active)
    values (dow, '08:00', '12:00', 'Asia/Dubai', array[svc], true);
  select count(*) into sc0 from public.available_slots('t-cal', d, d, 'Asia/Dubai');
  if sc0 >= 4 then ok:=ok+1; else fail:=fail+1; log:=log||' [baseline slots '||sc0||' < 4]'; end if;

  perform set_config('request.jwt.claims','{"role":"authenticated","sub":"00000000-0000-4000-8000-0000000c0001","email":"coachonly@test.local"}',true);
  execute 'set local role authenticated';
  j := public.block_create(jsonb_build_object(
        'start_at', (d::text||' 09:00')::timestamp at time zone 'Asia/Dubai',
        'end_at',   (d::text||' 10:00')::timestamp at time zone 'Asia/Dubai',
        'timezone','Asia/Dubai','label','Lunch','private_note','SECRET-NOTE-DO-NOT-LEAK'));
  blk := (j->>'id')::uuid;
  if (j->>'source')='calendar_block' and (j->>'kind')='closed' then ok:=ok+1; else fail:=fail+1; log:=log||' [block created closed]'; end if;
  execute 'reset role';

  -- the 09:00 slot is now suppressed for the public engine (exactly one fewer)
  select count(*) into sc1 from public.available_slots('t-cal', d, d, 'Asia/Dubai');
  if sc1 = sc0 - 1 then ok:=ok+1; else fail:=fail+1; log:=log||' [block delta '||sc0||'->'||sc1||']'; end if;
  if (select coalesce(string_agg(local_start,','),'') from public.available_slots('t-cal', d, d, 'Asia/Dubai')) not like '%SECRET-NOTE%' then ok:=ok+1; else fail:=fail+1; log:=log||' [private note leaked to slots]'; end if;
  -- and the private note is not exposed by any public column of available_slots
  if not exists (select 1 from public.available_slots('t-cal', d, d, 'Asia/Dubai') s where s::text like '%SECRET-NOTE%') then ok:=ok+1; else fail:=fail+1; log:=log||' [private note in slot row]'; end if;

  -- moving the block off this day restores the slot
  perform set_config('request.jwt.claims','{"role":"authenticated","sub":"00000000-0000-4000-8000-0000000c0001","email":"coachonly@test.local"}',true);
  execute 'set local role authenticated';
  perform public.block_update(blk, jsonb_build_object(
     'start_at', (d::text||' 09:00')::timestamp at time zone 'Asia/Dubai' + interval '1 day',
     'end_at',   (d::text||' 10:00')::timestamp at time zone 'Asia/Dubai' + interval '1 day'));
  execute 'reset role';
  select count(*) into sc1 from public.available_slots('t-cal', d, d, 'Asia/Dubai');
  if sc1 = sc0 then ok:=ok+1; else fail:=fail+1; log:=log||' [block edit did not restore '||sc0||'->'||sc1||']'; end if;

  -- removing the block leaves availability intact
  perform set_config('request.jwt.claims','{"role":"authenticated","sub":"00000000-0000-4000-8000-0000000c0001","email":"coachonly@test.local"}',true);
  execute 'set local role authenticated';
  perform public.block_remove(blk);
  execute 'reset role';
  select count(*) into sc1 from public.available_slots('t-cal', d, d, 'Asia/Dubai');
  if sc1 = sc0 then ok:=ok+1; else fail:=fail+1; log:=log||' [block remove '||sc0||'->'||sc1||']'; end if;

  /* ========== 3. packages: X/total from linked sessions ========== */
  perform set_config('request.jwt.claims','{"role":"authenticated","sub":"00000000-0000-4000-8000-0000000c0002","email":"coachfin@test.local"}',true);
  execute 'set local role authenticated';
  j := public.pack_create(jsonb_build_object('crm_contact_id', cA::text, 'title','10-session pack',
        'total_sessions','10','price_amount','85000','currency','USD','payment_status','paid','payment_source','bank_transfer',
        'paid_at', now()::text, 'agreement_date', current_date::text));
  packA := (j->>'id')::uuid;
  if (j->>'total_sessions')::int = 10 and (j->>'used')::int = 0 and (j->>'remaining')::int = 10
     and (j->>'price_amount')::int = 85000 then ok:=ok+1; else fail:=fail+1; log:=log||' [pack create '||j::text||']'; end if;

  -- three linked sessions: one completed (consumes), one scheduled (no), one cancelled (no)
  j := public.session_write(jsonb_build_object('crm_contact_id', cA::text, 'session_pack_id', packA::text,
        'start_at', (d::text||' 08:00')::timestamp at time zone 'Asia/Dubai', 'end_at', (d::text||' 09:00')::timestamp at time zone 'Asia/Dubai'));
  perform public.session_set_status((j->>'id')::uuid, 'completed');
  j := public.session_write(jsonb_build_object('crm_contact_id', cA::text, 'session_pack_id', packA::text,
        'start_at', (d::text||' 15:00')::timestamp at time zone 'Asia/Dubai', 'end_at', (d::text||' 16:00')::timestamp at time zone 'Asia/Dubai'));
  -- leave scheduled
  j := public.session_write(jsonb_build_object('crm_contact_id', cA::text, 'session_pack_id', packA::text,
        'start_at', (d::text||' 16:00')::timestamp at time zone 'Asia/Dubai', 'end_at', (d::text||' 17:00')::timestamp at time zone 'Asia/Dubai'));
  perform public.session_set_status((j->>'id')::uuid, 'cancelled', false, 'client asked');
  if public.pack_used(packA) = 1 then ok:=ok+1; else fail:=fail+1; log:=log||' [used != 1 after completed/scheduled/cancelled ('||public.pack_used(packA)||')]'; end if;

  -- a no_show consumes only when explicitly chargeable
  j := public.session_write(jsonb_build_object('crm_contact_id', cA::text, 'session_pack_id', packA::text,
        'start_at', (d::text||' 17:00')::timestamp at time zone 'Asia/Dubai', 'end_at', (d::text||' 18:00')::timestamp at time zone 'Asia/Dubai'));
  perform public.session_set_status((j->>'id')::uuid, 'no_show', false);
  if public.pack_used(packA) = 1 then ok:=ok+1; else fail:=fail+1; log:=log||' [no_show non-chargeable consumed]'; end if;
  perform public.session_set_status((j->>'id')::uuid, 'no_show', true);
  if public.pack_used(packA) = 2 then ok:=ok+1; else fail:=fail+1; log:=log||' [no_show chargeable not consumed]'; end if;

  -- a wrong-client session cannot be linked to A's pack
  begin
    perform public.session_write(jsonb_build_object('crm_contact_id', cB::text, 'session_pack_id', packA::text,
      'start_at', (d::text||' 19:00')::timestamp at time zone 'Asia/Dubai', 'end_at', (d::text||' 20:00')::timestamp at time zone 'Asia/Dubai'));
    fail:=fail+1; log:=log||' [wrong-client linked to pack]';
  exception when sqlstate '22023' then ok:=ok+1; end;

  /* ========== 4. renewal creates a NEW pack; old is immutable ========== */
  j := public.pack_create(jsonb_build_object('crm_contact_id', cA::text, 'title','10-session pack #2',
        'total_sessions','10','renewed_from_pack_id', packA::text, 'price_amount','85000','payment_status','unpaid'));
  packRenew := (j->>'id')::uuid;
  if packRenew <> packA and (j->>'renewed_from_pack_id')::uuid = packA and (j->>'used')::int = 0
     and (select total_sessions from public.session_packs where id = packA) = 10
     and public.pack_used(packA) = 2 then ok:=ok+1; else fail:=fail+1; log:=log||' [renewal not new/old changed]'; end if;
  execute 'reset role';

  /* ========== 5. permissions ========== */
  -- coach-only cannot set financial fields on create, nor change payment
  perform set_config('request.jwt.claims','{"role":"authenticated","sub":"00000000-0000-4000-8000-0000000c0001","email":"coachonly@test.local"}',true);
  execute 'set local role authenticated';
  begin perform public.pack_create(jsonb_build_object('crm_contact_id', cA::text, 'total_sessions','5','price_amount','1000')); fail:=fail+1; log:=log||' [coach set price]'; exception when insufficient_privilege then ok:=ok+1; end;
  begin perform public.pack_set_payment(packA, 999); fail:=fail+1; log:=log||' [coach set_payment]'; exception when insufficient_privilege then ok:=ok+1; end;
  -- coach-only sees pack WITHOUT financial fields
  j := public.packs_for_contact(cA);
  if not (j->0 ? 'price_amount') and (j->0 ? 'used') then ok:=ok+1; else fail:=fail+1; log:=log||' [coach saw finance fields]'; end if;
  -- coach CAN create an operational (no-price) pack and a session
  j := public.pack_create(jsonb_build_object('crm_contact_id', cA::text, 'title','ops pack','total_sessions','8'));
  if (j->>'total_sessions')::int = 8 then ok:=ok+1; else fail:=fail+1; log:=log||' [coach ops pack]'; end if;
  execute 'reset role';

  -- coach WITH finance sees financial fields
  perform set_config('request.jwt.claims','{"role":"authenticated","sub":"00000000-0000-4000-8000-0000000c0002","email":"coachfin@test.local"}',true);
  execute 'set local role authenticated';
  j := public.packs_for_contact(cA);
  if exists (select 1 from jsonb_array_elements(j) e where e ? 'price_amount') then ok:=ok+1; else fail:=fail+1; log:=log||' [finance missing price]'; end if;
  execute 'reset role';

  -- platform:admin ALONE grants neither calendar operations nor financial
  perform set_config('request.jwt.claims','{"role":"authenticated","sub":"00000000-0000-4000-8000-0000000c0003","email":"padmin@test.local"}',true);
  execute 'set local role authenticated';
  begin perform public.calendar_range(now(), now()+interval '1 day'); fail:=fail+1; log:=log||' [padmin calendar]'; exception when insufficient_privilege then ok:=ok+1; end;
  begin perform public.session_write(jsonb_build_object('crm_contact_id', cA::text, 'start_at', now()::text, 'end_at',(now()+interval '1 hour')::text)); fail:=fail+1; log:=log||' [padmin session]'; exception when insufficient_privilege then ok:=ok+1; end;
  begin perform public.block_create(jsonb_build_object('start_at', now()::text, 'end_at',(now()+interval '1 hour')::text)); fail:=fail+1; log:=log||' [padmin block]'; exception when insufficient_privilege then ok:=ok+1; end;
  begin perform public.pack_set_payment(packA, 1); fail:=fail+1; log:=log||' [padmin finance]'; exception when insufficient_privilege then ok:=ok+1; end;
  select count(*) into n from public.coaching_sessions; if n = 0 then ok:=ok+1; else fail:=fail+1; log:=log||' [padmin reads sessions]'; end if;
  execute 'reset role';

  /* ========== 6. website booking materialises exactly one session ========== */
  insert into public.bookings (reference, service_id, customer_name, customer_contact, start_at, end_at, session_timezone, delivery_mode, status, idempotency_key, manage_token, price_amount, currency, crm_contact_id)
    values ('CG-CAL01', svc, 'Client A', 'ca@ex.com', (d::text||' 07:00')::timestamp at time zone 'Asia/Dubai', (d::text||' 08:00')::timestamp at time zone 'Asia/Dubai', 'Asia/Dubai', 'online', 'confirmed', gen_random_uuid(), 'tok', 5000, 'USD', cA);
  select count(*) into n from public.coaching_sessions where booking_id = (select id from public.bookings where reference='CG-CAL01');
  if n = 1 then ok:=ok+1; else fail:=fail+1; log:=log||' [booking materialise '||n||']'; end if;
  -- marking the booking completed does not create a second session
  update public.bookings set status='completed' where reference='CG-CAL01';
  select count(*) into n from public.coaching_sessions where booking_id = (select id from public.bookings where reference='CG-CAL01');
  if n = 1 and (select status from public.coaching_sessions where booking_id=(select id from public.bookings where reference='CG-CAL01'))='completed'
    then ok:=ok+1; else fail:=fail+1; log:=log||' [booking dup/complete '||n||']'; end if;

  /* ========== 7. anon refused ========== */
  perform set_config('request.jwt.claims','{"role":"anon"}',true);
  execute 'set local role anon';
  begin perform public.calendar_range(now(), now()+interval '1 day'); fail:=fail+1; log:=log||' [anon calendar]'; exception when insufficient_privilege then ok:=ok+1; end;
  begin perform public.session_write(jsonb_build_object('crm_contact_id', cA::text,'start_at',now()::text,'end_at',(now()+interval '1 hour')::text)); fail:=fail+1; log:=log||' [anon session]'; exception when insufficient_privilege then ok:=ok+1; end;
  begin perform public.pack_create(jsonb_build_object('crm_contact_id', cA::text,'total_sessions','1')); fail:=fail+1; log:=log||' [anon pack]'; exception when insufficient_privilege then ok:=ok+1; end;
  execute 'reset role';

  raise exception 'CG011_TESTS ok=% fail=% %', ok, fail, log;
end $$;

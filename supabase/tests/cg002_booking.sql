-- CG-002 booking engine — database-level test suite.
-- Runs inside ONE transaction and always ends with RAISE EXCEPTION so nothing
-- is persisted (run it through `supabase db query`, psql, or the MCP
-- apply_migration tool: a failing statement is rolled back and not recorded).
-- The exception message carries the result summary: CG002_TESTS ok=<n> fail=<n>.
--
-- What it proves: recurring rules, closed exceptions, exceptional openings,
-- tour-stop windows (eligibility + open/closed status), coexistence of tour and
-- normal calendar, timezone conversion, hold creation, idempotence, capacity 1
-- (second hold refused), capacity 3 (technical case), hold expiry releasing
-- capacity, cancellation releasing capacity, and that the caller cannot forge
-- duration / price / capacity. True concurrency (two sessions racing) is
-- exercised by scripts/test-booking.mjs against the live API.
do $$
declare
  ok int := 0; fail int := 0; log text := '';
  svc uuid; svc_cap3 uuid; stop_id uuid;
  d date; base timestamptz; n int; j jsonb; j2 jsonb; ref text; tok text;
  r record;
  procedure_note text;
begin
  -- Pick the next Monday at least 3 days out so rules (Mon–Fri) apply and the 2 h notice never bites.
  d := (current_date + 3);
  while extract(isodow from d) <> 1 loop d := d + 1; end loop;

  -- Isolate: use a dedicated test service + rules so the seed does not interfere.
  update public.availability_rules set active = false;                     -- rolled back at the end
  insert into public.services (slug, title, category, duration_minutes, price_amount, currency, delivery_mode, default_capacity, active, listed)
  values ('t-conv', 'Test conversation', 'mentoring', 60, 4500, 'USD', 'online', 1, true, false) returning id into svc;
  insert into public.services (slug, title, category, duration_minutes, price_amount, currency, delivery_mode, default_capacity, active, listed)
  values ('t-cap3', 'Test capacity 3', 'coaching', 60, 1000, 'USD', 'online', 3, true, false) returning id into svc_cap3;
  -- Monday 09:00–12:00 Asia/Dubai for every service
  insert into public.availability_rules (weekday, start_time, end_time, timezone, service_ids) values (1, '09:00', '12:00', 'Asia/Dubai', null);

  /* 1. recurring rule → 3 slots (09,10,11 Dubai) */
  select count(*) into n from public.available_slots('t-conv', d, d, 'Asia/Dubai');
  if n = 3 then ok := ok + 1; else fail := fail + 1; log := log || ' [rule slots=' || n || ' expected 3]'; end if;

  /* 2. timezone conversion: 09:00 Asia/Dubai == 05:00 UTC */
  select start_at into base from public.available_slots('t-conv', d, d, 'Asia/Dubai') order by start_at limit 1;
  if base = ((d::text || ' 09:00')::timestamp at time zone 'Asia/Dubai')
     and to_char(base at time zone 'UTC', 'HH24:MI') = '05:00' then ok := ok + 1;
  else fail := fail + 1; log := log || ' [tz conversion]'; end if;
  -- local_start reported in the requested zone
  select local_start into procedure_note from public.available_slots('t-conv', d, d, 'Africa/Johannesburg') order by start_at limit 1;
  if procedure_note = d::text || 'T07:00' then ok := ok + 1; else fail := fail + 1; log := log || ' [local_start=' || procedure_note || ']'; end if;

  /* 3. closed exception removes the 10:00 slot */
  insert into public.availability_exceptions (kind, start_at, end_at, timezone, reason)
  values ('closed', base + interval '1 hour', base + interval '2 hours', 'Asia/Dubai', 'test block');
  select count(*) into n from public.available_slots('t-conv', d, d, 'Asia/Dubai');
  if n = 2 then ok := ok + 1; else fail := fail + 1; log := log || ' [closed exception slots=' || n || ']'; end if;

  /* 4. exceptional opening adds slots outside the rules (Sunday 14:00–16:00) */
  insert into public.availability_exceptions (kind, start_at, end_at, timezone, reason)
  values ('open', ((d + 6)::text || ' 14:00')::timestamp at time zone 'Asia/Dubai', ((d + 6)::text || ' 16:00')::timestamp at time zone 'Asia/Dubai', 'Asia/Dubai', 'test opening');
  select count(*) into n from public.available_slots('t-conv', d + 6, d + 6, 'Asia/Dubai');
  if n = 2 then ok := ok + 1; else fail := fail + 1; log := log || ' [open exception slots=' || n || ']'; end if;

  /* 5. tour stop: window only for eligible service, only while open */
  insert into public.tour_stops (slug, city, country, timezone, start_at, end_at, status, venue)
  values ('t-jnb', 'Johannesburg', 'South Africa', 'Africa/Johannesburg',
          ((d + 8)::text || ' 00:00')::timestamp at time zone 'Africa/Johannesburg',
          ((d + 10)::text || ' 23:59')::timestamp at time zone 'Africa/Johannesburg', 'draft', 'Test venue')
  returning id into stop_id;
  insert into public.availability_exceptions (kind, start_at, end_at, timezone, tour_stop_id, reason)
  values ('open', ((d + 8)::text || ' 10:00')::timestamp at time zone 'Africa/Johannesburg',
                  ((d + 8)::text || ' 13:00')::timestamp at time zone 'Africa/Johannesburg', 'Africa/Johannesburg', stop_id, 'tour window');
  insert into public.tour_stop_services (tour_stop_id, service_id) values (stop_id, svc);
  -- draft → nothing
  select count(*) into n from public.available_slots('t-conv', d + 8, d + 8, 'Africa/Johannesburg');
  if n = 0 then ok := ok + 1; else fail := fail + 1; log := log || ' [tour draft slots=' || n || ']'; end if;
  update public.tour_stops set status = 'open' where id = stop_id;
  select count(*) into n from public.available_slots('t-conv', d + 8, d + 8, 'Africa/Johannesburg');
  if n = 3 then ok := ok + 1; else fail := fail + 1; log := log || ' [tour open slots=' || n || ']'; end if;
  -- non-eligible service sees nothing
  select count(*) into n from public.available_slots('t-cap3', d + 8, d + 8, 'Africa/Johannesburg');
  if n = 0 then ok := ok + 1; else fail := fail + 1; log := log || ' [tour eligibility slots=' || n || ']'; end if;
  -- session timezone reported is the destination zone
  select session_timezone into procedure_note from public.available_slots('t-conv', d + 8, d + 8, 'Africa/Johannesburg') limit 1;
  if procedure_note = 'Africa/Johannesburg' then ok := ok + 1; else fail := fail + 1; log := log || ' [tour tz]'; end if;

  /* 6. coexistence: the tour day is a Monday → rule slots (online) AND tour slots both exist */
  -- d+8 is Tuesday; use d+7 (Monday): add a tour window on d+7 too
  insert into public.availability_exceptions (kind, start_at, end_at, timezone, tour_stop_id, reason)
  values ('open', ((d + 7)::text || ' 15:00')::timestamp at time zone 'Africa/Johannesburg',
                  ((d + 7)::text || ' 17:00')::timestamp at time zone 'Africa/Johannesburg', 'Africa/Johannesburg', stop_id, 'tour window 2');
  update public.tour_stops set start_at = ((d + 7)::text || ' 00:00')::timestamp at time zone 'Africa/Johannesburg' where id = stop_id;
  select count(*) filter (where tour_stop_id is null) as online, count(*) filter (where tour_stop_id is not null) as tour
    into r from public.available_slots('t-conv', d + 7, d + 7, 'Asia/Dubai');
  if r.online = 3 and r.tour = 2 then ok := ok + 1; else fail := fail + 1; log := log || ' [coexistence online=' || r.online || ' tour=' || r.tour || ']'; end if;

  /* 7. hold creation (capacity 1) */
  j := public.create_hold('t-conv', base, 1, '11111111-1111-4111-8111-111111111111', 'Test One', 'one@coachgari.com');
  ref := j ->> 'reference'; tok := j ->> 'manage_token';
  if j ->> 'status' = 'hold' and ref like 'CG-%' and (j ->> 'price_amount')::int = 4500 then ok := ok + 1;
  else fail := fail + 1; log := log || ' [hold create ' || coalesce(j::text, 'null') || ']'; end if;
  -- end_at derives from the service duration, not from the caller
  if (j ->> 'end_at')::timestamptz = base + interval '60 minutes' then ok := ok + 1; else fail := fail + 1; log := log || ' [duration forged?]'; end if;

  /* 8. idempotence: same key → same reference, still one row */
  j2 := public.create_hold('t-conv', base, 1, '11111111-1111-4111-8111-111111111111', 'Test One', 'one@coachgari.com');
  select count(*) into n from public.bookings where service_id = svc;
  if j2 ->> 'reference' = ref and n = 1 then ok := ok + 1; else fail := fail + 1; log := log || ' [idempotence rows=' || n || ']'; end if;

  /* 9. capacity 1: second hold on the same slot is refused, slot no longer listed */
  begin
    perform public.create_hold('t-conv', base, 1, '22222222-2222-4222-8222-222222222222', 'Test Two', 'two@coachgari.com');
    fail := fail + 1; log := log || ' [capacity1 second hold accepted]';
  exception when others then
    if sqlstate = 'P0003' then ok := ok + 1; else fail := fail + 1; log := log || ' [capacity1 wrong error ' || sqlstate || ']'; end if;
  end;
  select count(*) into n from public.available_slots('t-conv', d, d, 'Asia/Dubai') where start_at = base;
  if n = 0 then ok := ok + 1; else fail := fail + 1; log := log || ' [held slot still listed]'; end if;

  /* 10. capacity 3 (technical case): remaining decreases, 4th participant refused */
  j := public.create_hold('t-cap3', base, 2, '33333333-3333-4333-8333-333333333333', 'Test Group', 'grp@coachgari.com');
  select remaining into n from public.available_slots('t-cap3', d, d, 'Asia/Dubai') where start_at = base;
  if n = 1 then ok := ok + 1; else fail := fail + 1; log := log || ' [cap3 remaining=' || coalesce(n::text, 'none') || ']'; end if;
  begin
    perform public.create_hold('t-cap3', base, 2, '44444444-4444-4444-8444-444444444444', 'Test Over', 'over@coachgari.com');
    fail := fail + 1; log := log || ' [cap3 overbooked]';
  exception when others then
    if sqlstate = 'P0003' then ok := ok + 1; else fail := fail + 1; log := log || ' [cap3 wrong error ' || sqlstate || ']'; end if;
  end;
  j := public.create_hold('t-cap3', base, 1, '55555555-5555-4555-8555-555555555555', 'Test Last', 'last@coachgari.com');
  select count(*) into n from public.available_slots('t-cap3', d, d, 'Asia/Dubai') where start_at = base;
  if n = 0 then ok := ok + 1; else fail := fail + 1; log := log || ' [cap3 full slot still listed]'; end if;

  /* 11. hold expiry releases capacity; expire_holds() marks it */
  update public.bookings set hold_expires_at = now() - interval '1 minute' where reference = ref;
  select count(*) into n from public.available_slots('t-conv', d, d, 'Asia/Dubai') where start_at = base;
  if n = 1 then ok := ok + 1; else fail := fail + 1; log := log || ' [expired hold not released]'; end if;
  n := public.expire_holds();
  if n >= 1 and (select status from public.bookings where reference = ref) = 'expired' then ok := ok + 1;
  else fail := fail + 1; log := log || ' [expire_holds]'; end if;
  -- get_booking on an expired hold reports expired
  j := public.get_booking(ref, tok);
  if j ->> 'status' = 'expired' then ok := ok + 1; else fail := fail + 1; log := log || ' [get_booking expired]'; end if;

  /* 12. cancellation releases capacity */
  j := public.create_hold('t-conv', base, 1, '66666666-6666-4666-8666-666666666666', 'Test Three', 'three@coachgari.com');
  ref := j ->> 'reference'; tok := j ->> 'manage_token';
  select count(*) into n from public.available_slots('t-conv', d, d, 'Asia/Dubai') where start_at = base;
  if n = 0 then ok := ok + 1; else fail := fail + 1; log := log || ' [pre-cancel slot listed]'; end if;
  j := public.cancel_booking(ref, tok, 'changed my mind');
  select count(*) into n from public.available_slots('t-conv', d, d, 'Asia/Dubai') where start_at = base;
  if j ->> 'status' = 'cancelled' and n = 1 then ok := ok + 1; else fail := fail + 1; log := log || ' [cancel release]'; end if;
  -- wrong token cannot read or cancel
  begin
    perform public.get_booking(ref, 'wrong-token');
    fail := fail + 1; log := log || ' [wrong token read]';
  exception when others then
    if sqlstate = 'P0002' then ok := ok + 1; else fail := fail + 1; log := log || ' [wrong token error ' || sqlstate || ']'; end if;
  end;

  /* 13. forged price / capacity: service values win. Change the service, hold again. */
  update public.services set price_amount = 9900 where id = svc;
  j := public.create_hold('t-conv', base, 1, '77777777-7777-4777-8777-777777777777', 'Test Four', 'four@coachgari.com');
  if (j ->> 'price_amount')::int = 9900 then ok := ok + 1; else fail := fail + 1; log := log || ' [price snapshot]'; end if;
  begin
    perform public.create_hold('t-conv', base, 2, '88888888-8888-4888-8888-888888888888', 'Test Five', 'five@coachgari.com');
    fail := fail + 1; log := log || ' [participants > capacity accepted]';
  exception when others then
    if sqlstate = 'P0003' then ok := ok + 1; else fail := fail + 1; log := log || ' [capacity error ' || sqlstate || ']'; end if;
  end;

  /* 14. unknown slot / inactive service / invalid timezone rejected */
  begin
    perform public.create_hold('t-conv', base + interval '7 hours', 1, '99999999-9999-4999-8999-999999999999', 'Test Six', 'six@coachgari.com');
    fail := fail + 1; log := log || ' [off-hours hold accepted]';
  exception when others then
    if sqlstate = 'P0003' then ok := ok + 1; else fail := fail + 1; log := log || ' [off-hours error ' || sqlstate || ']'; end if;
  end;
  begin
    insert into public.availability_rules (weekday, start_time, end_time, timezone) values (2, '09:00', '10:00', 'Mars/Olympus');
    fail := fail + 1; log := log || ' [invalid tz accepted]';
  exception when others then
    if sqlstate = '22023' then ok := ok + 1; else fail := fail + 1; log := log || ' [invalid tz error ' || sqlstate || ']'; end if;
  end;

  raise exception 'CG002_TESTS ok=% fail=% %', ok, fail, log;
end $$;

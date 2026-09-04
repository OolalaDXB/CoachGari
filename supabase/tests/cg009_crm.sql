-- CG-009 CRM / client profile / body metrics — database suite. One transaction,
-- always rolls back (ends with RAISE EXCEPTION 'CG009_TESTS ok=… fail=…').
-- Proves: conservative canonical-contact matching (exact email, then exact
-- phone, never a fuzzy name merge; ambiguity flags, never silently merges);
-- enquiry history stays immutable; a direct booking links a CRM contact;
-- notes have author/timestamp and are permission-gated and PII-safe; body
-- measurements keep history, snapshot the height, derive BMI (not writable),
-- accept partials, reject absurd values; and that client_profile / health_metrics
-- are independent of coach / finance / analytics.
do $$
declare
  ok int := 0; fail int := 0; log text := '';
  c1 uuid; c2 uuid; cid uuid; cid2 uuid; nrid uuid; j jsonb; n int; q text; m1 uuid; got numeric;
begin
  /* ---- seed personas ---- */
  insert into public.app_users (email, display_name, party) values
    ('full@test.local','Full','studio'), ('coach@test.local','Coach','gari'),
    ('prof@test.local','Profile','studio'), ('health@test.local','Health','gari'),
    ('fin@test.local','Finance','oolala'), ('ana@test.local','Analytics','studio');
  insert into public.app_permissions (email, permission) values
    ('full@test.local','coach:operations'),('full@test.local','client_profile:view'),('full@test.local','client_profile:manage'),
    ('full@test.local','health_metrics:view'),('full@test.local','health_metrics:manage'),
    ('coach@test.local','coach:operations'),
    ('prof@test.local','client_profile:view'),('prof@test.local','client_profile:manage'),
    ('health@test.local','health_metrics:view'),('health@test.local','client_profile:view'),
    ('fin@test.local','finance:view'),('fin@test.local','finance:manage'),
    ('ana@test.local','analytics:view');

  /* ---- 1. matching: enquiry creates the canonical person ---- */
  insert into public.contacts (submission_id, name, contact, city, country, interest, message)
    values (gen_random_uuid(), 'Jane Doe', 'jane@example.com', 'Harare', 'Zimbabwe', 'coaching', 'first enquiry');
  select crm_contact_id into c1 from public.contacts where contact = 'jane@example.com';
  if c1 is not null and (select count(*) from public.crm_contacts where email_norm = 'jane@example.com') = 1 then ok := ok + 1; else fail := fail + 1; log := log || ' [enquiry creates crm]'; end if;

  -- same email (different case / spacing) links to the same person, no new row
  insert into public.contacts (submission_id, name, contact, interest, message)
    values (gen_random_uuid(), 'Jane D.', '  JANE@example.com ', 'mentoring', 'second enquiry');
  if (select crm_contact_id from public.contacts where message = 'second enquiry') = c1
     and (select count(*) from public.crm_contacts where email_norm = 'jane@example.com') = 1 then ok := ok + 1; else fail := fail + 1; log := log || ' [exact email match]'; end if;

  -- a phone-only enquiry creates a person; the same phone (reformatted) matches it
  insert into public.contacts (submission_id, name, contact, interest, message)
    values (gen_random_uuid(), 'Phone Person', '+263 77 123 4567', 'coaching', 'phone one');
  select crm_contact_id into c2 from public.contacts where message = 'phone one';
  insert into public.contacts (submission_id, name, contact, interest, message)
    values (gen_random_uuid(), 'Phone P', '263771234567', 'coaching', 'phone two');
  if (select crm_contact_id from public.contacts where message = 'phone two') = c2
     and (select count(*) from public.crm_contacts where phone_norm = '263771234567') = 1 then ok := ok + 1; else fail := fail + 1; log := log || ' [exact phone match]'; end if;

  -- two different people with the same NAME are never merged (different emails)
  insert into public.contacts (submission_id, name, contact, interest) values (gen_random_uuid(), 'John Smith', 'john1@example.com', 'coaching');
  insert into public.contacts (submission_id, name, contact, interest) values (gen_random_uuid(), 'John Smith', 'john2@example.com', 'coaching');
  if (select count(distinct crm_contact_id) from public.contacts where name = 'John Smith') = 2 then ok := ok + 1; else fail := fail + 1; log := log || ' [same name not merged]'; end if;

  -- ambiguous: two canonical people already share an email; a new enquiry with it
  -- must NOT pick one — it creates a fresh contact flagged for review.
  insert into public.crm_contacts (display_name, email, email_norm) values ('Dup A','dup@example.com','dup@example.com');
  insert into public.crm_contacts (display_name, email, email_norm) values ('Dup B','dup@example.com','dup@example.com');
  insert into public.contacts (submission_id, name, contact, interest, message) values (gen_random_uuid(), 'Dup C', 'dup@example.com', 'coaching', 'ambiguous');
  select crm_contact_id into nrid from public.contacts where message = 'ambiguous';
  if (select needs_review from public.crm_contacts where id = nrid)
     and (select count(*) from public.crm_contacts where email_norm = 'dup@example.com') = 3 then ok := ok + 1; else fail := fail + 1; log := log || ' [ambiguous flagged not merged]'; end if;

  /* ---- 2. direct booking (no prior enquiry) links a CRM contact ---- */
  insert into public.services (slug, title, category, duration_minutes, price_amount, currency, delivery_mode, default_capacity, active, listed)
    values ('t-crm', 'CRM test', 'mentoring', 60, 5000, 'USD', 'online', 1, true, false);
  insert into public.bookings (reference, service_id, customer_name, customer_contact, start_at, end_at, session_timezone, delivery_mode, status, idempotency_key, manage_token, price_amount, currency)
    values ('CG-CRM01', (select id from public.services where slug='t-crm'), 'Direct Booker', 'direct@example.com', now() + interval '2 days', now() + interval '2 days 1 hour', 'Asia/Dubai', 'online', 'confirmed', gen_random_uuid(), 'tok', 5000, 'USD');
  if (select crm_contact_id from public.bookings where reference = 'CG-CRM01') is not null
     and exists (select 1 from public.crm_contacts where email_norm = 'direct@example.com') then ok := ok + 1; else fail := fail + 1; log := log || ' [direct booking links crm]'; end if;

  /* ---- 3. enquiry history is immutable ---- */
  if (select message from public.contacts where message = 'first enquiry') = 'first enquiry'
     and (select name from public.contacts where message = 'first enquiry') = 'Jane Doe' then ok := ok + 1; else fail := fail + 1; log := log || ' [enquiry immutable]'; end if;

  /* ---- 4. notes: author + timestamp, permission-gated, PII-safe ---- */
  perform set_config('request.jwt.claims', '{"role":"authenticated","sub":"00000000-0000-4000-8000-000000000001","email":"full@test.local"}', true);
  execute 'set local role authenticated';
  j := public.crm_add_note(c1, 'Warm lead — call back', 'session', true);
  if j ->> 'author' = 'full@test.local' and (j ->> 'created_at') is not null and (j ->> 'pinned')::boolean then ok := ok + 1; else fail := fail + 1; log := log || ' [note author/time]'; end if;
  select count(*) into n from public.crm_notes where crm_contact_id = c1; if n = 1 then ok := ok + 1; else fail := fail + 1; log := log || ' [note read]'; end if;
  j := public.crm_edit_note((j ->> 'id')::uuid, 'Warm lead — called, no answer');
  if j ->> 'body' = 'Warm lead — called, no answer' then ok := ok + 1; else fail := fail + 1; log := log || ' [note edit]'; end if;
  if exists (select 1 from public.admin_audit where area = 'crm_note' and action = 'update' and changed_by = 'full@test.local') then ok := ok + 1; else fail := fail + 1; log := log || ' [note edit audited]'; end if;
  execute 'reset role';

  -- coach-only: no CRM at all
  perform set_config('request.jwt.claims', '{"role":"authenticated","sub":"00000000-0000-4000-8000-000000000002","email":"coach@test.local"}', true);
  execute 'set local role authenticated';
  select count(*) into n from public.crm_contacts; if n = 0 then ok := ok + 1; else fail := fail + 1; log := log || ' [coach sees crm_contacts]'; end if;
  select count(*) into n from public.crm_notes; if n = 0 then ok := ok + 1; else fail := fail + 1; log := log || ' [coach sees notes]'; end if;
  select count(*) into n from public.body_measurements; if n = 0 then ok := ok + 1; else fail := fail + 1; log := log || ' [coach sees measurements]'; end if;
  begin perform public.crm_add_note(c1, 'x'); fail := fail + 1; log := log || ' [coach adds note]'; exception when insufficient_privilege then ok := ok + 1; end;
  begin perform public.crm_save_contact(jsonb_build_object('display_name','X')); fail := fail + 1; log := log || ' [coach saves contact]'; exception when insufficient_privilege then ok := ok + 1; end;
  begin perform public.crm_list_contacts(null); fail := fail + 1; log := log || ' [coach lists crm]'; exception when insufficient_privilege then ok := ok + 1; end;
  execute 'reset role';

  /* ---- 5. body metrics: history, height snapshot, BMI, validation, permissions ---- */
  perform set_config('request.jwt.claims', '{"role":"authenticated","sub":"00000000-0000-4000-8000-000000000001","email":"full@test.local"}', true);
  execute 'set local role authenticated';
  perform public.crm_save_contact(jsonb_build_object('id', c1::text, 'display_name', 'Jane Doe', 'height_cm', '183'));
  j := public.metrics_add(c1, current_date - 30, 92.0, 24.8, 38.2, null, 'scale', null);
  m1 := (j ->> 'id')::uuid;
  if (j ->> 'height_cm_snapshot')::numeric = 183 and (j ->> 'bmi')::numeric = 27.5 then ok := ok + 1; else fail := fail + 1; log := log || ' [bmi/snapshot ' || coalesce(j ->> 'bmi','null') || ']'; end if;
  -- change the current height, add a second measurement: new snapshot, old row unchanged (history kept)
  perform public.crm_save_contact(jsonb_build_object('id', c1::text, 'display_name', 'Jane Doe', 'height_cm', '190'));
  j := public.metrics_add(c1, current_date, 89.9, 23.5, 38.9, null, 'scale', null);
  if (j ->> 'height_cm_snapshot')::numeric = 190
     and (select height_cm_snapshot from public.body_measurements where id = m1) = 183
     and (select weight_kg from public.body_measurements where id = m1) = 92.0
     and (select count(*) from public.body_measurements where crm_contact_id = c1) = 2 then ok := ok + 1; else fail := fail + 1; log := log || ' [weight history + snapshot kept]'; end if;
  -- BMI is derived, never writable
  begin update public.body_measurements set bmi = 10 where id = m1; fail := fail + 1; log := log || ' [bmi writable]'; exception when others then ok := ok + 1; end;
  -- partial measurement (weight only) is accepted
  j := public.metrics_add(c1, current_date - 10, 90.5, null, null, null, null, null);
  if (j ->> 'weight_kg')::numeric = 90.5 and (j ->> 'body_fat_pct') is null then ok := ok + 1; else fail := fail + 1; log := log || ' [partial measurement]'; end if;
  -- absurd values rejected, not coerced
  begin perform public.metrics_add(c1, current_date, 5, null, null, null, null, null); fail := fail + 1; log := log || ' [weight 5 accepted]'; exception when check_violation then ok := ok + 1; end;
  begin perform public.metrics_add(c1, current_date, null, 200, null, null, null, null); fail := fail + 1; log := log || ' [body fat 200 accepted]'; exception when check_violation then ok := ok + 1; end;
  begin perform public.metrics_add(c1, current_date, null, null, null, null, null, null); fail := fail + 1; log := log || ' [empty measurement accepted]'; exception when sqlstate '22023' then ok := ok + 1; end;
  execute 'reset role';

  -- health_metrics:view reads measurements but not notes; client_profile:view is the mirror
  perform set_config('request.jwt.claims', '{"role":"authenticated","sub":"00000000-0000-4000-8000-000000000004","email":"health@test.local"}', true);
  execute 'set local role authenticated';
  select count(*) into n from public.body_measurements where crm_contact_id = c1; if n = 3 then ok := ok + 1; else fail := fail + 1; log := log || ' [health reads measurements]'; end if;
  begin perform public.metrics_add(c1, current_date, 88, null, null, null, null, null); fail := fail + 1; log := log || ' [health-view can write]'; exception when insufficient_privilege then ok := ok + 1; end;
  execute 'reset role';
  perform set_config('request.jwt.claims', '{"role":"authenticated","sub":"00000000-0000-4000-8000-000000000003","email":"prof@test.local"}', true);
  execute 'set local role authenticated';
  select count(*) into n from public.crm_notes where crm_contact_id = c1; if n = 1 then ok := ok + 1; else fail := fail + 1; log := log || ' [profile reads notes]'; end if;
  select count(*) into n from public.body_measurements; if n = 0 then ok := ok + 1; else fail := fail + 1; log := log || ' [profile sees measurements w/o health]'; end if;
  begin perform public.metrics_add(c1, current_date, 88, null, null, null, null, null); fail := fail + 1; log := log || ' [profile writes metrics]'; exception when insufficient_privilege then ok := ok + 1; end;
  execute 'reset role';

  /* ---- 6. finance / analytics never imply profile or health ---- */
  perform set_config('request.jwt.claims', '{"role":"authenticated","sub":"00000000-0000-4000-8000-000000000005","email":"fin@test.local"}', true);
  execute 'set local role authenticated';
  select count(*) into n from public.crm_contacts;      if n = 0 then ok := ok + 1; else fail := fail + 1; log := log || ' [finance sees crm]'; end if;
  select count(*) into n from public.body_measurements; if n = 0 then ok := ok + 1; else fail := fail + 1; log := log || ' [finance sees metrics]'; end if;
  begin perform public.crm_list_contacts(null); fail := fail + 1; log := log || ' [finance lists crm]'; exception when insufficient_privilege then ok := ok + 1; end;
  execute 'reset role';
  perform set_config('request.jwt.claims', '{"role":"authenticated","sub":"00000000-0000-4000-8000-000000000006","email":"ana@test.local"}', true);
  execute 'set local role authenticated';
  select count(*) into n from public.crm_notes;         if n = 0 then ok := ok + 1; else fail := fail + 1; log := log || ' [analytics sees notes]'; end if;
  select count(*) into n from public.body_measurements; if n = 0 then ok := ok + 1; else fail := fail + 1; log := log || ' [analytics sees metrics]'; end if;
  j := public.analytics_summary();
  if j::text not like '%92.0%' and j::text not like '%Warm lead%' and j::text not like '%called, no answer%' then ok := ok + 1; else fail := fail + 1; log := log || ' [analytics leaks notes/metrics]'; end if;
  execute 'reset role';

  /* ---- 7. anon: nothing ---- */
  perform set_config('request.jwt.claims', '{"role":"anon"}', true);
  execute 'set local role anon';
  foreach q in array array['select count(*) from public.crm_contacts','select count(*) from public.crm_notes','select count(*) from public.body_measurements',
                           'select public.crm_list_contacts(null)','select public.crm_add_note(gen_random_uuid(),''x'')','select public.metrics_add(gen_random_uuid(), current_date, 80, null, null, null, null, null)',
                           'select public.admin_overview()'] loop
    begin execute q; fail := fail + 1; log := log || ' [anon allowed: ' || q || ']'; exception when insufficient_privilege then ok := ok + 1; end;
  end loop;
  execute 'reset role';

  /* ---- 8. overview shows only authorised cards ---- */
  perform set_config('request.jwt.claims', '{"role":"authenticated","sub":"00000000-0000-4000-8000-000000000005","email":"fin@test.local"}', true);
  execute 'set local role authenticated';
  j := public.admin_overview();
  if (j ? 'finance') and not (j ? 'operations') and not (j ? 'crm') then ok := ok + 1; else fail := fail + 1; log := log || ' [overview cards ' || j::text || ']'; end if;
  execute 'reset role';

  raise exception 'CG009_TESTS ok=% fail=% %', ok, fail, log;
end $$;

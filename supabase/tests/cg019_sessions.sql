-- =====================================================================
-- CG-019 — the day before, and the two gestures after.
-- One rolled-back transaction. Proves: a session is reminded exactly once on
-- each channel it is entitled to; WhatsApp never goes out without an explicit
-- yes; the one-line note lands in the client's history against its session and
-- needs the permission that writes a history, not the one that moves a diary;
-- the to-close list is the past and only the recent past; the WhatsApp rail
-- belongs to service_role alone and its key is stored hashed.
-- Run by scripts/db-tests.sh; nothing persists (final RAISE).
-- =====================================================================
do $$
declare
  ok int := 0; fail int := 0; log text := '';
  j jsonb; n int; c1 uuid; c2 uuid; c3 uuid; s1 uuid; s2 uuid; s3 uuid; svc uuid; nid uuid;
begin
  insert into public.app_users (email, display_name, party) values
    ('sxcoach@test.local','Coach','gari'), ('sxsched@test.local','Scheduler','studio'), ('sxnone@test.local','Nobody','studio')
  on conflict (email) do nothing;
  insert into public.app_permissions (email, permission) values
    ('sxcoach@test.local','coach:operations'), ('sxcoach@test.local','client_profile:view'), ('sxcoach@test.local','client_profile:manage'),
    ('sxsched@test.local','coach:operations'),                      -- diary only: no client history
    ('sxnone@test.local','finance:view')
  on conflict do nothing;

  select id into svc from public.services order by created_at limit 1;

  insert into public.crm_contacts (display_name, email, phone, phone_norm) values
    ('Reminder Yes','rx1@test.local','+971500000001','971500000001') returning id into c1;
  insert into public.crm_contacts (display_name, email, phone, phone_norm) values
    ('Reminder WhatsApp','rx2@test.local','+971500000002','971500000002') returning id into c2;
  insert into public.crm_contacts (display_name, email, reminders_opt_out) values
    ('Reminder No','rx3@test.local', true) returning id into c3;
  update public.crm_contacts set whatsapp_opt_in = true where id = c2;

  -- one session inside the window for each contact
  insert into public.coaching_sessions (crm_contact_id, service_id, title, start_at, end_at)
    values (c1, svc, 'Padel block', now() + interval '6 hours', now() + interval '7 hours') returning id into s1;
  insert into public.coaching_sessions (crm_contact_id, service_id, title, start_at, end_at)
    values (c2, svc, 'Padel block', now() + interval '8 hours', now() + interval '9 hours') returning id into s2;
  insert into public.coaching_sessions (crm_contact_id, service_id, title, start_at, end_at)
    values (c3, svc, 'Padel block', now() + interval '10 hours', now() + interval '11 hours');

  /* ---- 1. the reminder goes out once, on the channels that are allowed ---- */
  n := public.session_reminders(interval '24 hours');
  select count(*) into n from public.email_events where kind = 'session_reminder' and to_address in ('rx1@test.local','rx2@test.local');
  if n = 2 then ok := ok + 1; else fail := fail + 1; log := log || ' [email-reminders=' || n || ']'; end if;

  select count(*) into n from public.email_events where kind = 'session_reminder' and to_address = 'rx3@test.local';
  if n = 0 then ok := ok + 1; else fail := fail + 1; log := log || ' [opted-out-was-emailed]'; end if;

  -- WhatsApp only for the one who said yes, and never for the one who did not
  select count(*) into n from public.whatsapp_events where to_phone = '971500000002' and status = 'pending';
  if n = 1 then ok := ok + 1; else fail := fail + 1; log := log || ' [whatsapp-optin=' || n || ']'; end if;
  select count(*) into n from public.whatsapp_events where to_phone = '971500000001';
  if n = 0 then ok := ok + 1; else fail := fail + 1; log := log || ' [whatsapp-without-consent]'; end if;

  -- a phone number on file is not consent: the row above proves it, and so does the payload
  if (select template from public.whatsapp_events where to_phone = '971500000002') = 'session_reminder_24h'
     and jsonb_array_length((select params from public.whatsapp_events where to_phone = '971500000002')) = 3
    then ok := ok + 1; else fail := fail + 1; log := log || ' [whatsapp-template]'; end if;

  /* ---- 2. running it again sends nothing: one reminder per session, ever ---- */
  n := public.session_reminders(interval '24 hours');
  if n = 0 then ok := ok + 1; else fail := fail + 1; log := log || ' [second-run-queued=' || n || ']'; end if;
  select count(*) into n from public.email_events where kind = 'session_reminder';
  if n = 2 then ok := ok + 1; else fail := fail + 1; log := log || ' [duplicate-emails=' || n || ']'; end if;
  select count(*) into n from public.whatsapp_events;
  if n = 1 then ok := ok + 1; else fail := fail + 1; log := log || ' [duplicate-whatsapp=' || n || ']'; end if;

  /* ---- 3. a cancelled session is not reminded ---- */
  insert into public.crm_contacts (display_name, email) values ('Cancelled','rx4@test.local') returning id into c3;
  insert into public.coaching_sessions (crm_contact_id, service_id, title, start_at, end_at, status)
    values (c3, svc, 'Gone', now() + interval '5 hours', now() + interval '6 hours', 'cancelled');
  perform public.session_reminders(interval '24 hours');
  select count(*) into n from public.email_events where to_address = 'rx4@test.local';
  if n = 0 then ok := ok + 1; else fail := fail + 1; log := log || ' [cancelled-was-reminded]'; end if;

  /* ---- 4. a session beyond the window waits its turn ---- */
  insert into public.crm_contacts (display_name, email) values ('Far','rx5@test.local') returning id into c3;
  insert into public.coaching_sessions (crm_contact_id, service_id, title, start_at, end_at)
    values (c3, svc, 'Next week', now() + interval '6 days', now() + interval '6 days 1 hour');
  perform public.session_reminders(interval '24 hours');
  select count(*) into n from public.email_events where to_address = 'rx5@test.local';
  if n = 0 then ok := ok + 1; else fail := fail + 1; log := log || ' [far-session-reminded-early]'; end if;

  /* ---- 5. a number that is not a number is stored skipped, with the reason ---- */
  -- the queue call is its own statement: a subselect in the same expression would
  -- read the snapshot taken before the insert and see nothing
  nid := public.whatsapp_queue('session_reminder', 'not a phone', 'session_reminder_24h', '[]'::jsonb, 'test:junk', null);
  if nid is not null
     and (select status from public.whatsapp_events where dedupe_key = 'test:junk') = 'skipped'
     and (select error from public.whatsapp_events where dedupe_key = 'test:junk') = 'no usable phone number'
    then ok := ok + 1; else fail := fail + 1; log := log || ' [junk-phone-not-skipped]'; end if;
  -- and the drain never picks it up
  if not (public.whatsapp_due(50)::text like '%test:junk%') then ok := ok + 1; else fail := fail + 1; log := log || ' [drain-took-a-null-phone]'; end if;

  /* ---- 6. the to-close list is the recent past only ---- */
  insert into public.crm_contacts (display_name, email) values ('Past','rx6@test.local') returning id into c3;
  insert into public.coaching_sessions (crm_contact_id, service_id, title, start_at, end_at)
    values (c3, svc, 'Yesterday', now() - interval '26 hours', now() - interval '25 hours') returning id into s3;
  insert into public.coaching_sessions (crm_contact_id, service_id, title, start_at, end_at)
    values (c3, svc, 'Last month', now() - interval '40 days', now() - interval '40 days' + interval '1 hour');
  insert into public.coaching_sessions (crm_contact_id, service_id, title, start_at, end_at, status)
    values (c3, svc, 'Already closed', now() - interval '3 hours', now() - interval '2 hours', 'completed');

  perform set_config('request.jwt.claims', '{"role":"authenticated","sub":"00000000-0000-4000-8000-0000000000b1","email":"sxcoach@test.local"}', true);
  execute 'set local role authenticated';
  j := public.sessions_to_close(72, 20);
  if j::text like '%' || s3 || '%' then ok := ok + 1; else fail := fail + 1; log := log || ' [to-close-missed-yesterday]'; end if;
  if not (j::text like '%Last month%') then ok := ok + 1; else fail := fail + 1; log := log || ' [to-close-went-too-far-back]'; end if;
  if not (j::text like '%Already closed%') then ok := ok + 1; else fail := fail + 1; log := log || ' [to-close-listed-a-closed-session]'; end if;
  if not (j::text like '%Padel block%') then ok := ok + 1; else fail := fail + 1; log := log || ' [to-close-listed-the-future]'; end if;

  /* ---- 7. one line: the session note and the client history, linked, audited ---- */
  j := public.session_note_quick(s3, 'Worked the backhand and the serve return.');
  nid := (j ->> 'note_id')::uuid;
  if (j ->> 'ok') = 'true'
     and (select note from public.coaching_sessions where id = s3) = 'Worked the backhand and the serve return.'
     and (select session_id from public.crm_notes where id = nid) = s3
     and (select crm_contact_id from public.crm_notes where id = nid) = c3
     and (select category from public.crm_notes where id = nid) = 'session'
     and (select scope from public.crm_notes where id = nid) = 'operational'
    then ok := ok + 1; else fail := fail + 1; log := log || ' [note-not-linked]'; end if;

  begin perform public.session_note_quick(s3, '   '); fail := fail + 1; log := log || ' [empty-note-accepted]'; exception when sqlstate '22023' then ok := ok + 1; end;
  begin perform public.session_note_quick(s3, repeat('x', 501)); fail := fail + 1; log := log || ' [essay-accepted]'; exception when sqlstate '22023' then ok := ok + 1; end;
  begin perform public.session_note_quick(s3, 'ok', 'secret'); fail := fail + 1; log := log || ' [bad-scope-accepted]'; exception when sqlstate '22023' then ok := ok + 1; end;
  begin perform public.session_note_quick(gen_random_uuid(), 'ok'); fail := fail + 1; log := log || ' [note-on-nothing]'; exception when sqlstate 'P0002' then ok := ok + 1; end;
  -- coach_private needs the sensitive permission, which this operator does not hold
  begin perform public.session_note_quick(s3, 'private', 'coach_private'); fail := fail + 1; log := log || ' [private-note-without-permission]'; exception when sqlstate '42501' then ok := ok + 1; end;

  /* ---- 8. moving a diary is not writing a history ---- */
  reset role;
  perform set_config('request.jwt.claims', '{"role":"authenticated","sub":"00000000-0000-4000-8000-0000000000b2","email":"sxsched@test.local"}', true);
  execute 'set local role authenticated';
  begin perform public.session_note_quick(s3, 'I only schedule'); fail := fail + 1; log := log || ' [scheduler-wrote-a-note]'; exception when sqlstate '42501' then ok := ok + 1; end;
  -- but the scheduler can still close the session, which is diary work
  -- session_set_status returns the row it wrote, not an {ok} envelope
  j := public.session_set_status(s3, 'completed');
  if (j ->> 'status') = 'completed' and (j ->> 'completed_at') is not null
    then ok := ok + 1; else fail := fail + 1; log := log || ' [scheduler-cannot-close]'; end if;
  -- and the consent switch is not theirs either
  begin perform public.contact_messaging_set(c1, true, null); fail := fail + 1; log := log || ' [scheduler-set-consent]'; exception when sqlstate '42501' then ok := ok + 1; end;

  /* ---- 9. recording the yes, and taking it back ---- */
  reset role;
  perform set_config('request.jwt.claims', '{"role":"authenticated","sub":"00000000-0000-4000-8000-0000000000b1","email":"sxcoach@test.local"}', true);
  execute 'set local role authenticated';
  perform public.contact_messaging_set(c1, true, null);
  if (select whatsapp_opt_in from public.crm_contacts where id = c1)
     and (select whatsapp_opt_in_at is not null from public.crm_contacts where id = c1)
     and (select whatsapp_opt_in_by from public.crm_contacts where id = c1) = 'sxcoach@test.local'
    then ok := ok + 1; else fail := fail + 1; log := log || ' [opt-in-not-recorded]'; end if;
  perform public.contact_messaging_set(c1, false, null);
  if not (select whatsapp_opt_in from public.crm_contacts where id = c1)
     and (select whatsapp_opt_in_at is null from public.crm_contacts where id = c1)
    then ok := ok + 1; else fail := fail + 1; log := log || ' [opt-out-left-a-trace]'; end if;

  /* ---- 10. the WhatsApp log carries a phone number, so it is client data ---- */
  select count(*) into n from public.whatsapp_events;
  if n >= 1 then ok := ok + 1; else fail := fail + 1; log := log || ' [operator-cannot-read-the-log]'; end if;

  reset role;
  perform set_config('request.jwt.claims', '{"role":"authenticated","sub":"00000000-0000-4000-8000-0000000000b3","email":"sxnone@test.local"}', true);
  execute 'set local role authenticated';
  select count(*) into n from public.whatsapp_events;
  if n = 0 then ok := ok + 1; else fail := fail + 1; log := log || ' [finance-read-client-phones=' || n || ']'; end if;

  -- anon has no grant at all on the table, so it is refused before RLS is even consulted
  reset role;
  execute 'set local role anon';
  begin
    select count(*) into n from public.whatsapp_events;
    fail := fail + 1; log := log || ' [anon-read-the-whatsapp-log]';
  exception when insufficient_privilege then ok := ok + 1;
  end;
  reset role;

  /* ---- 11. the rail belongs to service_role alone ---- */
  foreach j in array array['"whatsapp_queue"','"whatsapp_due"','"whatsapp_mark"','"whatsapp_outbox_kick"','"whatsapp_outbox_authorize"','"session_reminders"']::jsonb[]
  loop
    if not exists (
      select 1 from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
       where ns.nspname = 'public' and p.proname = (j #>> '{}')
         and (has_function_privilege('authenticated', p.oid, 'execute') or has_function_privilege('anon', p.oid, 'execute')))
      then ok := ok + 1; else fail := fail + 1; log := log || ' [' || (j #>> '{}') || '-reachable-by-an-operator]'; end if;
  end loop;

  /* ---- 12. the drain key is a hash at rest, and the clear one is in Vault ---- */
  if (select key_sha256 is not null from public.outbox_keys where name = 'whatsapp')
     and exists (select 1 from vault.decrypted_secrets where name = 'outbox_whatsapp_key')
     and not exists (select 1 from information_schema.columns where table_name = 'outbox_keys' and column_name = 'key')
    then ok := ok + 1; else fail := fail + 1; log := log || ' [whatsapp-key-not-hashed]'; end if;
  -- a wrong key authorises nothing, a right one does
  if public.whatsapp_outbox_authorize(repeat('0', 64)) = false then ok := ok + 1; else fail := fail + 1; log := log || ' [wrong-key-authorised]'; end if;
  if public.whatsapp_outbox_authorize((select decrypted_secret from vault.decrypted_secrets where name = 'outbox_whatsapp_key')) = true
    then ok := ok + 1; else fail := fail + 1; log := log || ' [right-key-refused]'; end if;

  /* ---- 13. the reminder e-mail carries no secret and no room link ---- */
  if not exists (select 1 from public.email_events where kind = 'session_reminder' and payload::text ~* '(sk|rk)_(live|test)_|token')
    then ok := ok + 1; else fail := fail + 1; log := log || ' [reminder-payload-carries-a-secret]'; end if;

  raise exception 'CG019_TESTS ok=% fail=% %', ok, fail, case when log = '' then '' else '—' || log end;
end $$;

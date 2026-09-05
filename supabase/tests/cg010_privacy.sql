-- CG-010 privacy / consent / coaching-sensitive — database suite. One
-- transaction, always rolls back (RAISE EXCEPTION 'CG010_TESTS ok=… fail=…').
-- Proves: coaching_sensitive is an independent boundary; note scope enforced;
-- body measurements require ACTIVE consent (none/withdrawn -> denied); minors
-- blocked; the client-link consent flow; export/deletion are client-scoped and
-- audited; analytics never leaks sensitive values; a manual merge moves every
-- linked row transactionally; platform:admin alone grants none of this.
do $$
declare
  ok int := 0; fail int := 0; log text := '';
  cA uuid; cB uuid; cC uuid; dS uuid; dT uuid; svc uuid;
  j jsonb; n int; tok text; nid uuid;
begin
  /* ---- personas ---- */
  insert into public.app_users (email, display_name, party) values
    ('full@test.local','Full','studio'),('profmgr@test.local','Prof','studio'),('sens@test.local','Sens','gari'),
    ('health@test.local','Health','gari'),('padmin@test.local','PA','studio'),('fin@test.local','Fin','oolala'),('ana@test.local','Ana','studio');
  insert into public.app_permissions (email, permission) values
    ('full@test.local','coach:operations'),('full@test.local','client_profile:view'),('full@test.local','client_profile:manage'),
    ('full@test.local','health_metrics:view'),('full@test.local','health_metrics:manage'),('full@test.local','coaching_sensitive:view'),('full@test.local','coaching_sensitive:manage'),
    ('profmgr@test.local','client_profile:view'),('profmgr@test.local','client_profile:manage'),
    ('sens@test.local','client_profile:view'),('sens@test.local','coaching_sensitive:view'),('sens@test.local','coaching_sensitive:manage'),
    ('health@test.local','client_profile:view'),('health@test.local','health_metrics:view'),('health@test.local','health_metrics:manage'),
    ('padmin@test.local','platform:admin'),('fin@test.local','finance:view'),('ana@test.local','analytics:view');

  insert into public.crm_contacts (display_name, email, email_norm, height_cm) values ('Client A','a@ex.com','a@ex.com',180) returning id into cA;
  insert into public.crm_contacts (display_name, email, email_norm, height_cm) values ('Client B','b@ex.com','b@ex.com',175) returning id into cB;
  insert into public.crm_contacts (display_name, email, email_norm, height_cm) values ('Client C','c@ex.com','c@ex.com',170) returning id into cC;

  /* ========== 1. note scope + coaching_sensitive independence ========== */
  perform set_config('request.jwt.claims','{"role":"authenticated","sub":"00000000-0000-4000-8000-00000000f001","email":"full@test.local"}',true);
  execute 'set local role authenticated';
  perform public.crm_add_note(cA,'prefers whatsapp','general',false,'operational');
  perform public.crm_add_note(cA,'mentioned a knee issue','session',false,'coach_private');
  select count(*) into n from public.crm_notes where crm_contact_id=cA; if n=2 then ok:=ok+1; else fail:=fail+1; log:=log||' [full reads both notes]'; end if;
  execute 'reset role';

  perform set_config('request.jwt.claims','{"role":"authenticated","sub":"00000000-0000-4000-8000-00000000f002","email":"profmgr@test.local"}',true);
  execute 'set local role authenticated';
  select count(*) into n from public.crm_notes where crm_contact_id=cA; if n=1 then ok:=ok+1; else fail:=fail+1; log:=log||' [profmgr sees only operational ('||n||')]'; end if;
  select count(*) into n from public.crm_notes where crm_contact_id=cA and scope='coach_private'; if n=0 then ok:=ok+1; else fail:=fail+1; log:=log||' [profmgr sees coach_private]'; end if;
  begin perform public.crm_add_note(cA,'x',null,false,'coach_private'); fail:=fail+1; log:=log||' [profmgr writes sensitive]'; exception when insufficient_privilege then ok:=ok+1; end;
  perform public.crm_add_note(cA,'reschedule tuesday',null,false,'operational');  -- allowed
  ok:=ok+1;
  execute 'reset role';

  perform set_config('request.jwt.claims','{"role":"authenticated","sub":"00000000-0000-4000-8000-00000000f003","email":"sens@test.local"}',true);
  execute 'set local role authenticated';
  select count(*) into n from public.crm_notes where crm_contact_id=cA and scope='coach_private'; if n=1 then ok:=ok+1; else fail:=fail+1; log:=log||' [sens reads coach_private]'; end if;
  perform public.crm_add_note(cA,'body composition discussion','session',false,'coach_private'); ok:=ok+1;
  execute 'reset role';

  perform set_config('request.jwt.claims','{"role":"authenticated","sub":"00000000-0000-4000-8000-00000000f005","email":"padmin@test.local"}',true);
  execute 'set local role authenticated';
  select count(*) into n from public.crm_notes; if n=0 then ok:=ok+1; else fail:=fail+1; log:=log||' [padmin reads notes]'; end if;
  execute 'reset role';
  perform set_config('request.jwt.claims','{"role":"authenticated","sub":"00000000-0000-4000-8000-00000000f006","email":"ana@test.local"}',true);
  execute 'set local role authenticated';
  select count(*) into n from public.crm_notes; if n=0 then ok:=ok+1; else fail:=fail+1; log:=log||' [analytics reads notes]'; end if;
  execute 'reset role';

  /* ========== 2. consent gate on measurements ========== */
  perform set_config('request.jwt.claims','{"role":"authenticated","sub":"00000000-0000-4000-8000-00000000f004","email":"health@test.local"}',true);
  execute 'set local role authenticated';
  if not (public.consent_status(cA) ->> 'active')::boolean then ok:=ok+1; else fail:=fail+1; log:=log||' [A pre-consent active]'; end if;
  begin perform public.metrics_add(cA, current_date, 90, null, null, null, null, null); fail:=fail+1; log:=log||' [measure without consent]'; exception when sqlstate 'P0004' then ok:=ok+1; end;
  j := public.consent_record_admin(cA);
  if (j->>'source')='admin_recorded' and (j->>'status')='active' and (j->>'notice_version')='fitness-progress-v1-2026-09' then ok:=ok+1; else fail:=fail+1; log:=log||' [record consent '||j::text||']'; end if;
  if (public.consent_status(cA) ->> 'active')::boolean then ok:=ok+1; else fail:=fail+1; log:=log||' [A active after record]'; end if;
  j := public.metrics_add(cA, current_date, 90.0, 22.0, 40.0, null, 'scale', null);
  if (j->>'bmi')::numeric = 27.8 then ok:=ok+1; else fail:=fail+1; log:=log||' [measure w consent bmi '||coalesce(j->>'bmi','null')||']'; end if;
  -- consent for A does not authorise B
  begin perform public.metrics_add(cB, current_date, 80, null, null, null, null, null); fail:=fail+1; log:=log||' [A consent authorises B]'; exception when sqlstate 'P0004' then ok:=ok+1; end;
  -- withdraw -> future denied
  perform public.consent_withdraw(cA);
  if not (public.consent_status(cA) ->> 'active')::boolean then ok:=ok+1; else fail:=fail+1; log:=log||' [still active after withdraw]'; end if;
  begin perform public.metrics_add(cA, current_date, 89, null, null, null, null, null); fail:=fail+1; log:=log||' [measure after withdraw]'; exception when sqlstate 'P0004' then ok:=ok+1; end;
  -- prior measurement is retained (deletion is a separate action)
  select count(*) into n from public.body_measurements where crm_contact_id=cA; if n=1 then ok:=ok+1; else fail:=fail+1; log:=log||' [withdraw deleted history]'; end if;
  execute 'reset role';

  /* ========== 3. minors blocked ========== */
  update public.crm_contacts set is_minor=true where id=cB;
  perform set_config('request.jwt.claims','{"role":"authenticated","sub":"00000000-0000-4000-8000-00000000f004","email":"health@test.local"}',true);
  execute 'set local role authenticated';
  begin perform public.consent_issue_link(cB); fail:=fail+1; log:=log||' [minor issue link]'; exception when sqlstate 'P0005' then ok:=ok+1; end;
  begin perform public.consent_record_admin(cB); fail:=fail+1; log:=log||' [minor record consent]'; exception when sqlstate 'P0005' then ok:=ok+1; end;
  begin perform public.metrics_add(cB, current_date, 60, null, null, null, null, null); fail:=fail+1; log:=log||' [minor measure]'; exception when sqlstate 'P0005' then ok:=ok+1; end;
  -- issue a link for A (non-minor)
  j := public.consent_issue_link(cA); tok := j->>'token';
  if tok ~ '^[0-9a-f]{64}$' then ok:=ok+1; else fail:=fail+1; log:=log||' [issue link token]'; end if;
  execute 'reset role';

  /* ========== 4. client-link flow (service-role path, run as owner) ========== */
  j := public.consent_view(tok);
  if (j->>'first_name')='Client' and (j->'notice'->>'notice_version')='fitness-progress-v1-2026-09' then ok:=ok+1; else fail:=fail+1; log:=log||' [consent_view '||j::text||']'; end if;
  j := public.consent_submit(tok,'accept', jsonb_build_object('ip_hash','x'));
  if (j->>'decision')='accept' and public.has_active_consent(cA,'fitness_progress_tracking') then ok:=ok+1; else fail:=fail+1; log:=log||' [client accept]'; end if;
  begin perform public.consent_submit(tok,'accept'); fail:=fail+1; log:=log||' [token reuse]'; exception when sqlstate 'P0003' then ok:=ok+1; end;
  if (select source from public.client_consents where crm_contact_id=cA and status='active')='client_link' then ok:=ok+1; else fail:=fail+1; log:=log||' [active source not client_link]'; end if;

  /* ========== 5. platform:admin / finance / analytics get nothing sensitive ========== */
  perform set_config('request.jwt.claims','{"role":"authenticated","sub":"00000000-0000-4000-8000-00000000f005","email":"padmin@test.local"}',true);
  execute 'set local role authenticated';
  begin perform public.consent_status(cA); fail:=fail+1; log:=log||' [padmin consent_status]'; exception when insufficient_privilege then ok:=ok+1; end;
  begin perform public.metrics_add(cA, current_date, 90, null, null, null, null, null); fail:=fail+1; log:=log||' [padmin measure]'; exception when insufficient_privilege then ok:=ok+1; end;
  begin perform public.metrics_export(cA); fail:=fail+1; log:=log||' [padmin export]'; exception when insufficient_privilege then ok:=ok+1; end;
  select count(*) into n from public.client_consents; if n=0 then ok:=ok+1; else fail:=fail+1; log:=log||' [padmin reads consents]'; end if;
  select count(*) into n from public.body_measurements; if n=0 then ok:=ok+1; else fail:=fail+1; log:=log||' [padmin reads measurements]'; end if;
  execute 'reset role';
  perform set_config('request.jwt.claims','{"role":"authenticated","sub":"00000000-0000-4000-8000-00000000f006b","email":"fin@test.local"}',true);
  execute 'set local role authenticated';
  begin perform public.consent_status(cA); fail:=fail+1; log:=log||' [fin consent_status]'; exception when insufficient_privilege then ok:=ok+1; end;
  select count(*) into n from public.body_measurements; if n=0 then ok:=ok+1; else fail:=fail+1; log:=log||' [fin reads measurements]'; end if;
  execute 'reset role';

  /* ========== 6. export / deletion are client-scoped and audited ========== */
  -- fixtures: A already has 1 measurement; give C consent + 2 measurements
  perform set_config('request.jwt.claims','{"role":"authenticated","sub":"00000000-0000-4000-8000-00000000f004","email":"health@test.local"}',true);
  execute 'set local role authenticated';
  perform public.consent_record_admin(cC);
  perform public.metrics_add(cC, current_date - 5, 70.0, null, null, null, null, null);
  perform public.metrics_add(cC, current_date, 69.0, null, null, null, null, null);
  j := public.metrics_export(cA);
  if jsonb_array_length(j) = 1 and j::text like '%90.0%' and j::text not like '%70.0%' then ok:=ok+1; else fail:=fail+1; log:=log||' [export A scope]'; end if;
  j := public.metrics_export(cC);
  if jsonb_array_length(j) = 2 then ok:=ok+1; else fail:=fail+1; log:=log||' [export C count]'; end if;
  j := public.metrics_delete_history(cC);
  if (j->>'deleted')::int = 2
     and (select count(*) from public.body_measurements where crm_contact_id=cC)=0
     and (select count(*) from public.body_measurements where crm_contact_id=cA)=1 then ok:=ok+1; else fail:=fail+1; log:=log||' [delete C scope]'; end if;
  if exists (select 1 from public.admin_audit where area='body_measurement' and action='export')
     and exists (select 1 from public.admin_audit where area='body_measurement' and action='delete_history') then ok:=ok+1; else fail:=fail+1; log:=log||' [export/delete audited]'; end if;
  -- BMI is not independently writable
  begin update public.body_measurements set bmi=10 where crm_contact_id=cA; fail:=fail+1; log:=log||' [bmi writable]'; exception when others then ok:=ok+1; end;
  execute 'reset role';

  /* ========== 7. analytics leakage ========== */
  perform set_config('request.jwt.claims','{"role":"authenticated","sub":"00000000-0000-4000-8000-00000000f006","email":"ana@test.local"}',true);
  execute 'set local role authenticated';
  j := public.analytics_summary();
  if j::text not like '%90.0%' and j::text not like '%knee issue%' and j::text not like '%body composition%' then ok:=ok+1; else fail:=fail+1; log:=log||' [analytics leaks sensitive]'; end if;
  execute 'reset role';

  /* ========== 8. manual merge moves every linked row ========== */
  insert into public.crm_contacts (display_name, email, email_norm) values ('Dup Src','dup@ex.com','dup@ex.com') returning id into dS;
  insert into public.crm_contacts (display_name, email, email_norm, needs_review) values ('Dup Tgt','dup@ex.com','dup@ex.com', true) returning id into dT;
  insert into public.services (slug,title,category,duration_minutes,price_amount,currency,delivery_mode,default_capacity,active,listed)
    values ('t-mrg','Merge svc','mentoring',60,4000,'USD','online',1,true,false) returning id into svc;
  insert into public.contacts (submission_id,name,contact,interest,message,crm_contact_id) values (gen_random_uuid(),'S','dup@ex.com','coaching','src enq',dS);
  insert into public.bookings (reference,service_id,customer_name,customer_contact,start_at,end_at,session_timezone,delivery_mode,status,idempotency_key,manage_token,price_amount,currency,crm_contact_id)
    values ('CG-MRG01',svc,'S','dup@ex.com',now()+interval '1 day',now()+interval '1 day 1 hour','Asia/Dubai','online','confirmed',gen_random_uuid(),'tk',4000,'USD',dS);
  insert into public.crm_notes (crm_contact_id,body,author,scope) values (dS,'src note','full@test.local','operational');
  insert into public.client_consents (crm_contact_id,consent_type,notice_version,status,source,consented_at) values (dS,'fitness_progress_tracking','fitness-progress-v1-2026-09','active','admin_recorded',now());
  insert into public.body_measurements (crm_contact_id,measured_at,height_cm_snapshot,weight_kg) values (dS, current_date, 178, 85);

  -- health@ lacks client_profile:manage -> cannot merge
  perform set_config('request.jwt.claims','{"role":"authenticated","sub":"00000000-0000-4000-8000-00000000f004","email":"health@test.local"}',true);
  execute 'set local role authenticated';
  begin perform public.crm_merge_contacts(dS,dT); fail:=fail+1; log:=log||' [health merges]'; exception when insufficient_privilege then ok:=ok+1; end;
  execute 'reset role';

  perform set_config('request.jwt.claims','{"role":"authenticated","sub":"00000000-0000-4000-8000-00000000f001","email":"full@test.local"}',true);
  execute 'set local role authenticated';
  begin perform public.crm_merge_contacts(dS,dS); fail:=fail+1; log:=log||' [merge same]'; exception when sqlstate '22023' then ok:=ok+1; end;
  perform public.crm_merge_contacts(dS,dT);
  execute 'reset role';
  if (select count(*) from public.crm_contacts where id=dS)=0
     and (select crm_contact_id from public.contacts where message='src enq')=dT
     and (select crm_contact_id from public.bookings where reference='CG-MRG01')=dT
     and (select count(*) from public.crm_notes where crm_contact_id=dT)=1
     and (select count(*) from public.body_measurements where crm_contact_id=dT)=1
     and (select count(*) from public.client_consents where crm_contact_id=dT)=1
     and (select needs_review from public.crm_contacts where id=dT)=false then ok:=ok+1; else fail:=fail+1; log:=log||' [merge moved rows]'; end if;
  if exists (select 1 from public.admin_audit where area='merge' and action='merge') then ok:=ok+1; else fail:=fail+1; log:=log||' [merge audited]'; end if;

  /* ========== 9. anon ========== */
  perform set_config('request.jwt.claims','{"role":"anon"}',true);
  execute 'set local role anon';
  foreach tok in array array['select count(*) from public.client_consents','select count(*) from public.consent_tokens',
                             'select public.consent_status('''||cA::text||''')','select public.consent_record_admin('''||cA::text||''')',
                             'select public.metrics_export('''||cA::text||''')'] loop
    begin execute tok; fail:=fail+1; log:=log||' [anon allowed]'; exception when insufficient_privilege then ok:=ok+1; end;
  end loop;
  execute 'reset role';

  raise exception 'CG010_TESTS ok=% fail=% %', ok, fail, log;
end $$;

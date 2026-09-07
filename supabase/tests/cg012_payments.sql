-- CG-012 recap + payments (Stripe + Aani/manual) + renewal — database suite.
-- One transaction, always rolls back (RAISE EXCEPTION 'CG012_TESTS ok=… fail=…').
-- Proves: the recap is authoritative (completed/upcoming dates, X/total, amount
-- due) and NEVER contains body metrics or private notes; a report token gates a
-- client view and revocation stops it; a pack order's amount is server-side (a
-- forged Stripe amount is refused); a Stripe pack payment marks the order+pack
-- paid (source stripe) AND creates an Oolala earning; an Aani/manual payment
-- marks the pack paid (source aani) with NO Oolala earning and no fabricated
-- Stripe id; renewal creates a NEW pack and leaves the old one immutable;
-- permissions hold (finance for money, coach for recap, platform:admin neither).
do $$
declare
  ok int := 0; fail int := 0; log text := '';
  cA uuid; p1 uuid; p2 uuid; p3 uuid; s1 uuid; oref text; tok text; j jsonb; jh jsonb; n int; ordid uuid; pref text;
begin
  insert into public.app_users (email, display_name, party) values
    ('fin@test.local','Fin','gari'),('coachonly@test.local','Coach','gari'),('padmin@test.local','PA','studio');
  insert into public.app_permissions (email, permission) values
    ('fin@test.local','coach:operations'),('fin@test.local','finance:view'),('fin@test.local','finance:manage'),
    ('coachonly@test.local','coach:operations'),
    ('padmin@test.local','platform:admin');
  insert into public.crm_contacts (display_name, email, email_norm) values ('Sarah M','sarah@ex.com','sarah@ex.com') returning id into cA;
  -- two AED packs
  insert into public.session_packs (crm_contact_id, title, total_sessions, price_amount, currency, payment_status, agreement_date, created_by)
    values (cA, '10-session pack', 10, 312000, 'AED', 'unpaid', current_date, 'seed') returning id into p1;
  insert into public.session_packs (crm_contact_id, title, total_sessions, price_amount, currency, payment_status, created_by)
    values (cA, '10-session pack #alt', 10, 100000, 'AED', 'unpaid', 'seed') returning id into p2;
  -- one completed + one scheduled session on p1
  insert into public.coaching_sessions (crm_contact_id, session_pack_id, title, start_at, end_at, status, created_by)
    values (cA, p1, 'Padel', now() - interval '2 days', now() - interval '2 days' + interval '1 hour', 'completed', 'seed') returning id into s1;
  insert into public.coaching_sessions (crm_contact_id, session_pack_id, title, start_at, end_at, status, created_by)
    values (cA, p1, 'Padel', now() + interval '2 days', now() + interval '2 days' + interval '1 hour', 'scheduled', 'seed');
  -- sensitive data that must NEVER surface in a recap
  insert into public.crm_notes (crm_contact_id, body, author, scope) values (cA, 'SECRET-NOTE-XYZ', 'seed', 'coach_private');
  insert into public.body_measurements (crm_contact_id, measured_at, height_cm_snapshot, weight_kg) values (cA, current_date, 170, 77.7);

  /* ---- 1. recap authoritative + no leakage ---- */
  perform set_config('request.jwt.claims','{"role":"authenticated","email":"fin@test.local"}',true);
  execute 'set local role authenticated';
  j := public.pack_recap(p1);
  if (j->>'used')::int = 1 and (j->>'remaining')::int = 9 and (j->>'total_sessions')::int = 10
     and (j->>'price_amount')::int = 312000 and (j->>'currency') = 'AED'
     and jsonb_array_length(j->'completed') = 1 and jsonb_array_length(j->'upcoming') = 1 then ok:=ok+1; else fail:=fail+1; log:=log||' [recap fields '||j::text||']'; end if;
  if j::text not like '%SECRET-NOTE%' and j::text not like '%77.7%' and j::text not like '%height%' and j::text not like '%bmi%' then ok:=ok+1; else fail:=fail+1; log:=log||' [recap leaks sensitive]'; end if;
  -- amount due = price while unpaid
  if (j->>'amount_due')::int = 312000 and (j->>'payment_status') = 'unpaid' then ok:=ok+1; else fail:=fail+1; log:=log||' [amount due]'; end if;
  execute 'reset role';

  -- coach without finance sees no price/amount
  perform set_config('request.jwt.claims','{"role":"authenticated","email":"coachonly@test.local"}',true);
  execute 'set local role authenticated';
  j := public.pack_recap(p1);
  if (j->'price_amount') = 'null'::jsonb and (j->'amount_due') = 'null'::jsonb and (j->>'used')::int = 1 then ok:=ok+1; else fail:=fail+1; log:=log||' [coach sees price]'; end if;
  execute 'reset role';

  /* ---- 2. report token: issue, view, revoke ---- */
  perform set_config('request.jwt.claims','{"role":"authenticated","email":"coachonly@test.local"}',true);
  execute 'set local role authenticated';
  j := public.report_issue_link(p1); tok := j->>'token';
  if tok ~ '^[0-9a-f]{64}$' then ok:=ok+1; else fail:=fail+1; log:=log||' [issue token]'; end if;
  execute 'reset role';
  -- service-role path (owner): view returns recap + Aani, no leakage
  j := public.report_view(tok);
  if (j->'recap'->>'amount_due')::int = 312000 and (j->'recap'->>'first_name') = 'Sarah'
     and (j->'aani'->>'enabled')::boolean = true and (j->'aani'->>'display_value') = '+971 52 136 5065'
     and j::text not like '%SECRET-NOTE%' and j::text not like '%77.7%' then ok:=ok+1; else fail:=fail+1; log:=log||' [report_view '||j::text||']'; end if;
  -- revoke stops it
  perform set_config('request.jwt.claims','{"role":"authenticated","email":"coachonly@test.local"}',true);
  execute 'set local role authenticated';
  perform public.report_revoke(p1);
  execute 'reset role';
  begin perform public.report_view(tok); fail:=fail+1; log:=log||' [revoked still views]'; exception when sqlstate 'P0003' then ok:=ok+1; end;

  /* ---- 3. Stripe pack payment: server-side amount, order+pack paid, Oolala earning ---- */
  j := public.create_order_for_pack(p1); oref := j->>'reference';
  if (j->>'gross_amount')::int = 312000 and (j->>'currency') = 'AED' then ok:=ok+1; else fail:=fail+1; log:=log||' [pack order amount]'; end if;
  -- a forged smaller amount is refused (order + pack stay unpaid)
  perform public.process_stripe_event(jsonb_build_object('id','evt_pk_bad','type','checkout.session.completed','livemode',false,
    'data', jsonb_build_object('object', jsonb_build_object('id','cs_pk_bad','payment_status','paid','amount_total',100,'currency','aed','payment_intent','pi_pk_bad','client_reference_id',oref))));
  if (select payment_status from public.session_packs where id=p1) = 'unpaid' then ok:=ok+1; else fail:=fail+1; log:=log||' [forged amount accepted]'; end if;
  -- the real amount confirms
  perform public.process_stripe_event(jsonb_build_object('id','evt_pk_ok','type','checkout.session.completed','livemode',false,
    'data', jsonb_build_object('object', jsonb_build_object('id','cs_pk_ok','payment_status','paid','amount_total',312000,'currency','aed','payment_intent','pi_pk_ok','client_reference_id',oref)),
    '_enrich', jsonb_build_object('charge_id','ch_pk','balance_transaction_id','txn_pk','fee_amount',5000)));
  if (select payment_status from public.session_packs where id=p1) = 'paid'
     and (select payment_source from public.session_packs where id=p1) = 'stripe'
     and (select status from public.orders where reference=oref) = 'paid'
     and exists (select 1 from public.partner_earnings pe join public.orders oo on oo.id=pe.order_id where oo.reference=oref) then ok:=ok+1; else fail:=fail+1; log:=log||' [stripe pack pay]'; end if;

  /* ---- 4. Aani / manual payment: pack paid, source aani, NO Oolala earning ---- */
  perform set_config('request.jwt.claims','{"role":"authenticated","email":"fin@test.local"}',true);
  execute 'set local role authenticated';
  j := public.payment_record_manual(p2, 100000, 'AED', 'aani', 'client-ref-123');
  if (j->>'ok')::boolean and (j->>'source') = 'aani' then ok:=ok+1; else fail:=fail+1; log:=log||' [manual record]'; end if;
  execute 'reset role';
  if (select payment_status from public.session_packs where id=p2) = 'paid'
     and (select payment_source from public.session_packs where id=p2) = 'aani' then ok:=ok+1; else fail:=fail+1; log:=log||' [aani pack paid]'; end if;
  -- no Oolala earning for the Aani order (money never passed through Oolala)
  select id into ordid from public.orders where session_pack_id=p2 order by created_at desc limit 1;
  if not exists (select 1 from public.partner_earnings where order_id=ordid) then ok:=ok+1; else fail:=fail+1; log:=log||' [aani created earning]'; end if;
  -- the payment row carries the source and no fabricated stripe id
  if exists (select 1 from public.payments where order_id=ordid and provider='aani' and provider_payment_intent_id is null and note='client-ref-123') then ok:=ok+1; else fail:=fail+1; log:=log||' [aani payment row]'; end if;

  /* ---- 5. renewal: new pack, old immutable ---- */
  perform set_config('request.jwt.claims','{"role":"authenticated","email":"fin@test.local"}',true);
  execute 'set local role authenticated';
  j := public.pack_renew(p1);
  jh := public.pack_payment_history(p1);
  execute 'reset role';
  if (j->>'id')::uuid <> p1 and (j->>'renewed_from_pack_id')::uuid = p1 and (j->>'used')::int = 0
     and (j->>'total_sessions')::int = 10
     and (select payment_status from public.session_packs where id=p1) = 'paid'
     and (select total_sessions from public.session_packs where id=p1) = 10 then ok:=ok+1; else fail:=fail+1; log:=log||' [renew]'; end if;
  if jsonb_array_length(jh) >= 1 and (jh->0->>'source') = 'stripe' then ok:=ok+1; else fail:=fail+1; log:=log||' [history]'; end if;

  /* ---- 5b. bank transfer option + human public reference (CG-####) ---- */
  insert into public.session_packs (crm_contact_id, title, total_sessions, price_amount, currency, payment_status, created_by)
    values (cA, '10-session pack #bank', 10, 312000, 'AED', 'unpaid', 'seed') returning id into p3;
  select public_ref into pref from public.session_packs where id = p3;
  if pref ~ '^CG-[0-9]{4,}$' then ok:=ok+1; else fail:=fail+1; log:=log||' [public_ref '||coalesce(pref,'null')||']'; end if;
  perform set_config('request.jwt.claims','{"role":"authenticated","email":"fin@test.local"}',true);
  execute 'set local role authenticated';
  perform public.payment_method_set(jsonb_build_object('method','bank_transfer','enabled',true,'account_holder','Coach Gari FZ-LLC','iban','AE070331234567890123456','bic','EBILAEAD','bank_name','Emirates NBD','currency','AED'));
  j := public.report_issue_link(p3); tok := j->>'token';
  execute 'reset role';
  j := public.report_view(tok);
  if (j->'bank'->>'enabled')::boolean and (j->'bank'->>'iban')='AE070331234567890123456' and (j->'bank'->>'reference')=pref and (j->>'pay_ref')=pref then ok:=ok+1; else fail:=fail+1; log:=log||' [report_view bank]'; end if;
  perform set_config('request.jwt.claims','{"role":"authenticated","email":"fin@test.local"}',true);
  execute 'set local role authenticated';
  perform public.payment_record_manual(p3, 312000, 'AED', 'bank_transfer', pref);
  execute 'reset role';
  if (select payment_status from public.session_packs where id=p3)='paid'
     and (select payment_source from public.session_packs where id=p3)='bank_transfer' then ok:=ok+1; else fail:=fail+1; log:=log||' [bank pack paid]'; end if;
  select id into ordid from public.orders where session_pack_id=p3 order by created_at desc limit 1;
  if not exists (select 1 from public.partner_earnings where order_id=ordid) then ok:=ok+1; else fail:=fail+1; log:=log||' [bank earning]'; end if;

  /* ---- 6. permissions ---- */
  perform set_config('request.jwt.claims','{"role":"authenticated","email":"coachonly@test.local"}',true);
  execute 'set local role authenticated';
  begin perform public.payment_record_manual(p2, 1, 'AED', 'aani'); fail:=fail+1; log:=log||' [coach records payment]'; exception when insufficient_privilege then ok:=ok+1; end;
  begin perform public.payment_method_set(jsonb_build_object('enabled',true)); fail:=fail+1; log:=log||' [coach sets method]'; exception when insufficient_privilege then ok:=ok+1; end;
  execute 'reset role';
  perform set_config('request.jwt.claims','{"role":"authenticated","email":"padmin@test.local"}',true);
  execute 'set local role authenticated';
  begin perform public.pack_recap(p1); fail:=fail+1; log:=log||' [padmin recap]'; exception when insufficient_privilege then ok:=ok+1; end;
  begin perform public.report_issue_link(p1); fail:=fail+1; log:=log||' [padmin issue]'; exception when insufficient_privilege then ok:=ok+1; end;
  execute 'reset role';
  -- anon: report_view / create_order_for_pack are service-role only
  perform set_config('request.jwt.claims','{"role":"anon"}',true);
  execute 'set local role anon';
  begin perform public.report_view(tok); fail:=fail+1; log:=log||' [anon report_view]'; exception when insufficient_privilege then ok:=ok+1; end;
  begin perform public.create_order_for_pack(p1); fail:=fail+1; log:=log||' [anon create order]'; exception when insufficient_privilege then ok:=ok+1; end;
  execute 'reset role';

  raise exception 'CG012_TESTS ok=% fail=% %', ok, fail, log;
end $$;

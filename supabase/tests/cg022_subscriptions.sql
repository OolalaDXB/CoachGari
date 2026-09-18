-- =====================================================================
-- CG-022 — Recurring billing: the spine
-- One rolled-back transaction. It proves the claims the migration makes, and
-- it is written to fail if any of them stops being true:
--
--   * a cycle is a session pack, and the money path is the existing one;
--   * issuing twice for the same period issues ONE invoice;
--   * settlement works from the pack's payment_status, so every rail settles
--     a subscription — including a rail that has never heard of one;
--   * a refund runs it backwards;
--   * an unpaid subscription is NOT invoiced again;
--   * paying October while September is open does not clear past_due;
--   * cancelling at period end keeps the paid month; cancelling immediately
--     kills the open invoice;
--   * a price change never rewrites an invoice already sent;
--   * the pay link is readable for a reminder, and reachable by nobody a
--     browser can be.
-- Run by scripts/db-tests.sh; nothing persists (final RAISE).
-- =====================================================================
do $$
declare
  ok int := 0; fail int := 0; log text := '';
  -- Seeded people, not the real ones: no personal address in the repository
  -- and the suite runs on any database.
  BOSS constant text := '{"email":"boss@test.local","role":"authenticated"}';
  VIEW constant text := '{"email":"viewer@test.local","role":"authenticated"}';
  cid uuid; sid uuid; svc uuid; j jsonb; k jsonb; k2 jsonb;
  pack1 uuid; pack2 uuid; cyc1 uuid; cyc2 uuid; n int; url text; s public.subscriptions%rowtype;
begin
  insert into public.app_users (email, display_name, party, active)
  values ('boss@test.local','Boss','gari',true), ('viewer@test.local','Viewer','gari',true);
  insert into public.app_permissions (email, permission)
  select 'boss@test.local', p from unnest(array['finance:view','finance:manage','coach:operations','client_profile:view']) p;
  insert into public.app_permissions (email, permission) values ('viewer@test.local','finance:view');
  perform set_config('request.jwt.claims', BOSS, true);

  insert into public.crm_contacts (display_name, email, email_norm)
  values ('Amara K','amara@test.local','amara@test.local') returning id into cid;
  select id into svc from public.services where slug = 'online-coaching';

  /* ---- 1. starting a subscription invoices the first month straight away ---- */
  j := public.subscription_start(jsonb_build_object(
        'crm_contact_id', cid, 'service_id', svc, 'sessions_per_cycle', 2,
        'start_date', (current_date - 40)::text));
  sid := (j ->> 'id')::uuid;
  if (j ->> 'status') = 'active' and (j ->> 'price_amount')::int = 7900 and (j ->> 'currency') = 'USD'
     and (j ->> 'title') = (select title from public.services where id = svc)
     and (j ->> 'cycles_issued')::int = 1
    then ok := ok + 1; else fail := fail + 1; log := log || ' [start:' || j::text || ']'; end if;

  -- the cycle exists, and it IS a pack
  select k3.id, k3.session_pack_id into cyc1, pack1 from public.subscription_cycles k3 where k3.subscription_id = sid and k3.seq = 1;
  if pack1 is not null
     and (select total_sessions from public.session_packs where id = pack1) = 2
     and (select price_amount   from public.session_packs where id = pack1) = 7900
     and (select payment_status from public.session_packs where id = pack1) = 'unpaid'
     and (select crm_contact_id from public.session_packs where id = pack1) = cid
    then ok := ok + 1; else fail := fail + 1; log := log || ' [cycle-is-not-a-pack]'; end if;

  -- and the pack therefore has a public reference the client can be quoted
  if (select public_ref from public.session_packs where id = pack1) like 'CG-%'
    then ok := ok + 1; else fail := fail + 1; log := log || ' [no-public-ref]'; end if;

  -- the period is a whole month and the next one starts the day after
  if (select period_end from public.subscription_cycles where id = cyc1) = (current_date - 40) + interval '1 month' - interval '1 day'
     and (select next_billing_date from public.subscriptions where id = sid) = ((current_date - 40) + interval '1 month')::date
    then ok := ok + 1; else fail := fail + 1; log := log || ' [period-arithmetic]'; end if;

  -- the invoice email was queued, and it carries a pack id rather than a link
  if exists (select 1 from public.email_events e
              where e.kind = 'subscription_invoice' and e.dedupe_key = 'subcycle:' || cyc1 || ':invoice'
                and e.payload ? 'pay_pack_id' and not (e.payload ? 'pay_url'))
    then ok := ok + 1; else fail := fail + 1; log := log || ' [invoice-email]'; end if;

  /* ---- 2. issuing twice for the same period issues once ---- */
  -- The scheduler is late (next_billing_date is in the past), so a run issues
  -- month two; a second run must not issue month two again.
  j := public.subscriptions_issue_due();
  select count(*) into n from public.subscription_cycles where subscription_id = sid;
  if (j ->> 'issued')::int >= 1 and n >= 2 then ok := ok + 1; else fail := fail + 1; log := log || ' [nothing-issued]'; end if;
  select count(*) into n from public.subscription_cycles where subscription_id = sid;
  -- re-issuing the CURRENT period explicitly returns the existing cycle, no second invoice
  update public.subscriptions set next_billing_date = (select period_start from public.subscription_cycles where subscription_id = sid and seq = 1)
   where id = sid;
  k := public.subscription_issue_cycle(sid, 'test');
  if (k ->> 'seq')::int = 1 and (select count(*) from public.subscription_cycles where subscription_id = sid) = n
    then ok := ok + 1; else fail := fail + 1; log := log || ' [double-invoice]'; end if;

  /* ---- 3. settlement comes from the pack, so every rail settles ---- */
  -- No order, no payment, no webhook: just the fact a rail always produces.
  update public.session_packs set payment_status = 'paid', paid_at = now() where id = pack1;
  if (select status from public.subscription_cycles where id = cyc1) = 'paid'
     and (select paid_at from public.subscription_cycles where id = cyc1) is not null
    then ok := ok + 1; else fail := fail + 1; log := log || ' [cycle-not-settled]'; end if;

  -- and a refund runs it backwards
  update public.session_packs set payment_status = 'unpaid' where id = pack1;
  if (select status from public.subscription_cycles where id = cyc1) = 'issued'
     and (select paid_at from public.subscription_cycles where id = cyc1) is null
    then ok := ok + 1; else fail := fail + 1; log := log || ' [refund-not-reversed]'; end if;
  update public.session_packs set payment_status = 'paid', paid_at = now() where id = pack1;

  -- a pack that belongs to no subscription is unaffected (the trigger fires on
  -- every pack in the database, so this is not a formality)
  insert into public.session_packs (crm_contact_id, title, total_sessions, price_amount, currency, payment_status)
  values (cid, 'Ordinary pack', 10, 50000, 'USD', 'unpaid') returning id into pack2;
  update public.session_packs set payment_status = 'paid' where id = pack2;
  if (select count(*) from public.subscription_cycles where session_pack_id = pack2) = 0
    then ok := ok + 1; else fail := fail + 1; log := log || ' [stray-pack-adopted]'; end if;

  /* ---- 4. an unpaid subscription is not invoiced again ---- */
  select k3.id into cyc2 from public.subscription_cycles k3 where k3.subscription_id = sid and k3.seq = 2;
  update public.subscription_cycles set due_date = current_date - 30 where id = cyc2;
  j := public.subscriptions_chase();
  select * into s from public.subscriptions where id = sid;
  if s.status = 'past_due' and (j ->> 'overdue')::int = 1
    then ok := ok + 1; else fail := fail + 1; log := log || ' [not-past-due:' || s.status || ']'; end if;

  update public.subscriptions set next_billing_date = current_date where id = sid;     -- due, but past_due
  select count(*) into n from public.subscription_cycles where subscription_id = sid;
  j := public.subscriptions_issue_due();
  if (select count(*) from public.subscription_cycles where subscription_id = sid) = n
    then ok := ok + 1; else fail := fail + 1; log := log || ' [invoiced-while-past-due]'; end if;

  -- chasing twice does not send the same email twice
  select count(*) into n from public.email_events where dedupe_key = 'subcycle:' || cyc2 || ':overdue';
  perform public.subscriptions_chase();
  if n = 1 and (select count(*) from public.email_events where dedupe_key = 'subcycle:' || cyc2 || ':overdue') = 1
    then ok := ok + 1; else fail := fail + 1; log := log || ' [duplicate-chase]'; end if;

  /* ---- 5. paying one month does not clear a debt on another ---- */
  -- Force a third open cycle, then pay only the second.
  update public.subscriptions set status = 'active', next_billing_date = current_date where id = sid;
  perform public.subscription_issue_cycle(sid, 'test');
  update public.subscriptions set status = 'past_due' where id = sid;
  update public.session_packs set payment_status = 'paid', paid_at = now()
   where id = (select session_pack_id from public.subscription_cycles where id = cyc2);
  if (select status from public.subscriptions where id = sid) = 'past_due'
    then ok := ok + 1; else fail := fail + 1; log := log || ' [past-due-cleared-too-early]'; end if;

  -- pay the last open one and it clears
  update public.session_packs set payment_status = 'paid', paid_at = now()
   where id in (select session_pack_id from public.subscription_cycles where subscription_id = sid and status = 'issued');
  if (select status from public.subscriptions where id = sid) = 'active'
     and (select count(*) from public.subscription_cycles where subscription_id = sid and status = 'issued') = 0
    then ok := ok + 1; else fail := fail + 1; log := log || ' [past-due-never-clears]'; end if;

  /* ---- 6. a price change applies forward, never backwards ---- */
  j := public.subscription_set_price(sid, 9900);
  if (select amount from public.subscription_cycles where id = cyc1) = 7900
     and (select price_amount from public.subscriptions where id = sid) = 9900
    then ok := ok + 1; else fail := fail + 1; log := log || ' [invoice-rewritten]'; end if;
  -- a period nothing has used yet, so this is a genuinely new invoice
  update public.subscriptions set next_billing_date = current_date + 100, status = 'active' where id = sid;
  k := public.subscription_issue_cycle(sid, 'test');
  if (k ->> 'amount')::int = 9900 then ok := ok + 1; else fail := fail + 1; log := log || ' [new-price-not-applied:' || (k ->> 'amount') || ']'; end if;
  cyc2 := (k ->> 'id')::uuid;

  /* ---- 7. the two kinds of stop ---- */
  -- at period end: the open invoice survives, nothing new is issued
  j := public.subscription_cancel(sid, true, 'client is travelling');
  if (j ->> 'cancel_at_period_end')::boolean
     and (select status from public.subscription_cycles where id = cyc2) = 'issued'
    then ok := ok + 1; else fail := fail + 1; log := log || ' [period-end-cancel]'; end if;

  update public.subscriptions set next_billing_date = current_date where id = sid;
  j := public.subscriptions_issue_due();
  select * into s from public.subscriptions where id = sid;
  if (j ->> 'ended')::int = 1 and s.status = 'ended' and s.next_billing_date is null
     and exists (select 1 from public.email_events where dedupe_key = 'sub:' || sid || ':ended')
    then ok := ok + 1; else fail := fail + 1; log := log || ' [never-ends:' || s.status || ']'; end if;

  -- immediately: the open invoice is cancelled with it
  update public.subscriptions set status = 'active', ended_at = null, cancelled_at = null,
                                  cancel_at_period_end = false, next_billing_date = current_date + 30 where id = sid;
  j := public.subscription_cancel(sid, false, 'left');
  if (j ->> 'status') = 'cancelled'
     and (select status from public.subscription_cycles where id = cyc2) = 'cancelled'
     and (select next_billing_date from public.subscriptions where id = sid) is null
    then ok := ok + 1; else fail := fail + 1; log := log || ' [immediate-cancel]'; end if;

  /* ---- 8. the pay link ---- */
  url := public.pack_pay_url(pack1);
  if url like 'https://coachgari28.com/r/%' and length(url) = length('https://coachgari28.com/r/') + 64
    then ok := ok + 1; else fail := fail + 1; log := log || ' [pay-url]'; end if;
  -- and it is the token report_view actually resolves
  if (select session_pack_id from public.report_tokens
       where token_hash = encode(extensions.digest(right(url, 64), 'sha256'), 'hex')) = pack1
    then ok := ok + 1; else fail := fail + 1; log := log || ' [url-does-not-resolve]'; end if;
  -- the outbox swaps the pack id for the link at send time, and only then
  if (select (payload ? 'pay_url') from public.email_outbox_claim(50) where kind = 'subscription_invoice' limit 1)
    then ok := ok + 1; else fail := fail + 1; log := log || ' [claim-does-not-build-link]'; end if;

  /* ---- 9. doors ---- */
  -- a viewer can read and cannot touch
  perform set_config('request.jwt.claims', VIEW, true);
  begin j := public.subscriptions_list(); ok := ok + 1;
  exception when others then fail := fail + 1; log := log || ' [viewer-cannot-read]'; end;
  begin
    perform public.subscription_cancel(sid, true, 'nope');
    fail := fail + 1; log := log || ' [viewer-can-cancel]';
  exception when sqlstate '42501' then ok := ok + 1; when others then fail := fail + 1; log := log || ' [cancel-wrong-error]'; end;
  begin
    perform public.subscription_start(jsonb_build_object('crm_contact_id', cid, 'price_amount', 1000, 'currency', 'USD', 'title', 'X'));
    fail := fail + 1; log := log || ' [viewer-can-start]';
  exception when sqlstate '42501' then ok := ok + 1; when others then fail := fail + 1; log := log || ' [start-wrong-error]'; end;
  begin
    perform public.subscription_copy_pay_link(cyc1);
    fail := fail + 1; log := log || ' [viewer-can-copy-link]';
  exception when sqlstate '42501' then ok := ok + 1; when others then fail := fail + 1; log := log || ' [copy-wrong-error]'; end;
  perform set_config('request.jwt.claims', BOSS, true);

  -- the link builder and the encryption key belong to nobody a browser can be
  if not has_function_privilege('authenticated', 'public.pack_pay_url(uuid)', 'execute')
     and not has_function_privilege('anon', 'public.pack_pay_url(uuid)', 'execute')
     and not has_function_privilege('authenticated', 'public.report_link_key()', 'execute')
    then ok := ok + 1; else fail := fail + 1; log := log || ' [link-builder-exposed]'; end if;
  -- the scheduler is service_role's alone
  if not has_function_privilege('authenticated', 'public.subscriptions_issue_due()', 'execute')
     and not has_function_privilege('anon', 'public.subscriptions_chase()', 'execute')
     and has_function_privilege('service_role', 'public.subscriptions_issue_due()', 'execute')
    then ok := ok + 1; else fail := fail + 1; log := log || ' [scheduler-exposed]'; end if;
  -- and the tables themselves are closed to both browser roles
  if not has_table_privilege('authenticated', 'public.subscriptions', 'select')
     and not has_table_privilege('anon', 'public.subscription_cycles', 'select')
    then ok := ok + 1; else fail := fail + 1; log := log || ' [tables-readable]'; end if;

  /* ---- 10. what a subscription refuses to be ---- */
  begin
    perform public.subscription_start(jsonb_build_object('crm_contact_id', cid, 'title', 'Free', 'price_amount', 0, 'currency', 'USD'));
    fail := fail + 1; log := log || ' [zero-price-accepted]';
  exception when sqlstate '22023' then ok := ok + 1; when others then fail := fail + 1; log := log || ' [zero-price-wrong-error]'; end;
  begin
    perform public.subscription_start(jsonb_build_object('crm_contact_id', gen_random_uuid(), 'title', 'X', 'price_amount', 100, 'currency', 'USD'));
    fail := fail + 1; log := log || ' [ghost-client-accepted]';
  exception when sqlstate 'P0002' then ok := ok + 1; when others then fail := fail + 1; log := log || ' [ghost-client-wrong-error]'; end;
  begin
    perform public.subscription_start(jsonb_build_object('crm_contact_id', cid, 'title', 'X', 'price_amount', 100, 'currency', 'dollars'));
    fail := fail + 1; log := log || ' [bad-currency-accepted]';
  exception when sqlstate '22023' then ok := ok + 1; when others then fail := fail + 1; log := log || ' [bad-currency-wrong-error]'; end;

  -- one live subscription per client per product
  perform public.subscription_start(jsonb_build_object('crm_contact_id', cid, 'service_id', svc, 'sessions_per_cycle', 2, 'issue_now', false));
  begin
    perform public.subscription_start(jsonb_build_object('crm_contact_id', cid, 'service_id', svc, 'sessions_per_cycle', 2, 'issue_now', false));
    fail := fail + 1; log := log || ' [double-subscription-accepted]';
  exception when unique_violation then ok := ok + 1; when others then fail := fail + 1; log := log || ' [double-sub-wrong-error:' || sqlstate || ']'; end;

  /* ---- 11. it is all on the audit trail ---- */
  if (select count(distinct action) from public.admin_audit where area = 'subscription') >= 5
     and exists (select 1 from public.admin_audit where area = 'subscription' and action = 'issue_cycle')
     and exists (select 1 from public.admin_audit where area = 'subscription' and action = 'cycle_paid')
     and exists (select 1 from public.admin_audit where area = 'subscription' and action = 'past_due')
    then ok := ok + 1; else fail := fail + 1; log := log || ' [audit-thin]'; end if;

  raise exception 'CG022_TESTS ok=% fail=% %', ok, fail, case when log = '' then '' else '—' || log end;
end $$;

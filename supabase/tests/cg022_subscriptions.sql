-- =====================================================================
-- CG-022 — Recurring billing: the spine, and collecting from a card
-- One rolled-back transaction. It proves the claims both migrations make, and
-- it is written to fail if any of them stops being true.
--
-- The spine (20261056):
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
--
-- Collecting from a card (20261057):
--   * a card is kept exactly once, on the invoice that needs to, and never on
--     an ordinary package;
--   * a period that has not started, and one already paid on another rail,
--     are not charged;
--   * a claim leases, a second runner gets nothing, and a run that died is
--     revived rather than lost;
--   * OUR failures never cost the client their card; a transient one is
--     retried; three real declines drop it and say so, once;
--   * a successful charge settles NOTHING — the webhook does that;
--   * a PaymentIntent from the ordinary Checkout flow is never stolen, a
--     wrong amount is never credited, a replay never doubles;
--   * and nothing that could move money is ever returned to a browser.
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

  /* ---- 12. auto-charge: the mandate ---- */
  -- a subscription on auto without a card is the NORMAL first state, and it is
  -- the only state in which a checkout is told to keep the card
  j := public.subscription_start(jsonb_build_object(
        'crm_contact_id', cid, 'title', 'Auto plan', 'price_amount', 5000, 'currency', 'USD',
        'sessions_per_cycle', 4, 'billing_mode', 'auto'));
  sid := (j ->> 'id')::uuid;
  select k3.id, k3.session_pack_id into cyc1, pack1 from public.subscription_cycles k3 where k3.subscription_id = sid and k3.seq = 1;
  if (j ->> 'billing_mode') = 'auto' and not (j ->> 'has_mandate')::boolean and (j ->> 'awaiting_card')::boolean
     and public.pack_wants_card_on_file(pack1)
    then ok := ok + 1; else fail := fail + 1; log := log || ' [auto-start:' || j::text || ']'; end if;
  -- an ordinary pack is never asked to keep a card
  if not public.pack_wants_card_on_file(pack2) then ok := ok + 1; else fail := fail + 1; log := log || ' [stray-pack-keeps-card]'; end if;

  j := public.subscription_mandate_record(
        (select o.reference from public.orders o where o.session_pack_id = pack1 order by o.created_at desc limit 1),
        jsonb_build_object('customer_id','cus_T1','payment_method_id','pm_T1','brand','visa','last4','4242','exp_month','4','exp_year','2030'));
  -- no order exists for that pack yet, so the mandate cannot attach to anything
  if not (j ->> 'ok')::boolean then ok := ok + 1; else fail := fail + 1; log := log || ' [mandate-without-order]'; end if;

  j := public.create_order_for_pack(pack1);
  j := public.subscription_mandate_record(j ->> 'reference',
        jsonb_build_object('customer_id','cus_T1','payment_method_id','pm_T1','brand','visa','last4','4242','exp_month','4','exp_year','2030'));
  if (j ->> 'ok')::boolean then ok := ok + 1; else fail := fail + 1; log := log || ' [mandate-not-recorded:' || j::text || ']'; end if;

  j := public.subscription_get(sid);
  if (j ->> 'has_mandate')::boolean and (j ->> 'card_last4') = '4242' and (j ->> 'card_expiry') = '04/30'
     and not (j ->> 'awaiting_card')::boolean and not (j ->> 'card_expired')::boolean
    then ok := ok + 1; else fail := fail + 1; log := log || ' [mandate-shape:' || j::text || ']'; end if;
  -- and once there is a card, the next checkout is NOT asked to keep another
  if not public.pack_wants_card_on_file(pack1) then ok := ok + 1; else fail := fail + 1; log := log || ' [asks-for-a-second-card]'; end if;

  /* ---- 13. what may be charged, and what may not ---- */
  j := public.subscription_charges_enqueue();
  if (select count(*) from public.subscription_charges c join public.subscription_cycles k3 on k3.id = c.cycle_id where k3.subscription_id = sid) = 1
    then ok := ok + 1; else fail := fail + 1; log := log || ' [not-queued:' || j::text || ']'; end if;
  -- twice is still once
  perform public.subscription_charges_enqueue();
  if (select count(*) from public.subscription_charges c join public.subscription_cycles k3 on k3.id = c.cycle_id where k3.subscription_id = sid) = 1
    then ok := ok + 1; else fail := fail + 1; log := log || ' [queued-twice]'; end if;

  -- a period that has not started yet is not charged, whatever else is true
  update public.subscriptions set next_billing_date = current_date + 60, status = 'active' where id = sid;
  k := public.subscription_issue_cycle(sid, 'test');
  perform public.subscription_charges_enqueue();
  if not exists (select 1 from public.subscription_charges where cycle_id = (k ->> 'id')::uuid)
    then ok := ok + 1; else fail := fail + 1; log := log || ' [charged-before-the-period]'; end if;

  -- a cycle paid on another rail in the meantime is not charged
  update public.session_packs set payment_status = 'paid', paid_at = now() where id = (k ->> 'session_pack_id')::uuid;
  update public.subscription_cycles set period_start = current_date - 1 where id = (k ->> 'id')::uuid;
  perform public.subscription_charges_enqueue();
  if not exists (select 1 from public.subscription_charges where cycle_id = (k ->> 'id')::uuid)
    then ok := ok + 1; else fail := fail + 1; log := log || ' [charged-what-was-already-paid]'; end if;

  /* ---- 14. claiming, leasing and reviving ---- */
  select c.id into cyc2 from public.subscription_charges c join public.subscription_cycles k3 on k3.id = c.cycle_id where k3.subscription_id = sid limit 1;
  j := public.subscription_charge_claim(5);
  if jsonb_array_length(j) = 1 and (j -> 0 ->> 'customer_id') = 'cus_T1' and (j -> 0 ->> 'payment_method_id') = 'pm_T1'
     and (j -> 0 ->> 'amount')::int = 5000 and (j -> 0 ->> 'attempt')::int = 1
    then ok := ok + 1; else fail := fail + 1; log := log || ' [claim:' || j::text || ']'; end if;
  -- a second runner gets nothing while the lease holds
  if public.subscription_charge_claim(5) = '[]'::jsonb then ok := ok + 1; else fail := fail + 1; log := log || ' [double-claim]'; end if;
  -- a run that died leaves the row 'sent'; the next enqueue brings it back once the lease expires
  update public.subscription_charges set next_attempt_at = now() - interval '1 minute' where id = cyc2;
  j := public.subscription_charges_enqueue();
  if (select status from public.subscription_charges where id = cyc2) = 'pending' and (j ->> 'revived')::int >= 1
    then ok := ok + 1; else fail := fail + 1; log := log || ' [never-revived]'; end if;

  /* ---- 15. what a result does, and does not, do ---- */
  -- a decline is recorded; the invoice stays open and nothing is marked paid
  perform public.subscription_charge_claim(5);
  j := public.subscription_charge_result(cyc2, false, 'pi_T1', 'Your card was declined.', 'card_declined');
  if (select status from public.subscription_charges where id = cyc2) = 'failed'
     and (select charge_failures from public.subscriptions where id = sid) = 1
     and (select status from public.subscription_cycles where id = cyc1) = 'issued'
     and (select payment_status from public.session_packs where id = pack1) = 'unpaid'
    then ok := ok + 1; else fail := fail + 1; log := log || ' [decline-handling]'; end if;

  -- a transient failure goes back in the queue instead of counting as a decline
  update public.subscription_charges set status = 'sent', attempts = 1 where id = cyc2;
  update public.subscriptions set charge_failures = 0 where id = sid;
  j := public.subscription_charge_result(cyc2, false, null, 'network', null, true);
  if (j ->> 'retrying')::boolean and (select status from public.subscription_charges where id = cyc2) = 'pending'
     and (select charge_failures from public.subscriptions where id = sid) = 0
    then ok := ok + 1; else fail := fail + 1; log := log || ' [transient-counted-as-decline]'; end if;

  -- our own failures never cost the client their card
  update public.subscription_charges set status = 'sent' where id = cyc2;
  j := public.subscription_charge_result(cyc2, false, null, 'no card on file', 'no_mandate');
  if (j ->> 'internal')::boolean and (select charge_failures from public.subscriptions where id = sid) = 0
     and (select stripe_payment_method_id from public.subscriptions where id = sid) = 'pm_T1'
    then ok := ok + 1; else fail := fail + 1; log := log || ' [internal-failure-counted]'; end if;

  -- three real declines and the card goes, with the client told once
  update public.subscriptions set charge_failures = 2 where id = sid;
  update public.subscription_charges set status = 'sent' where id = cyc2;
  j := public.subscription_charge_result(cyc2, false, 'pi_T2', 'Your card has expired.', 'expired_card');
  select * into s from public.subscriptions where id = sid;
  if s.billing_mode = 'invoice' and s.stripe_payment_method_id is null and s.stripe_customer_id is null
     and s.card_last4 is null
     and exists (select 1 from public.email_events e where e.kind = 'subscription_card_failed' and e.payload ? 'pay_pack_id')
     and exists (select 1 from public.admin_audit where area = 'subscription' and action = 'mandate_dropped')
    then ok := ok + 1; else fail := fail + 1; log := log || ' [three-strikes:' || s.billing_mode || ']'; end if;

  -- a success clears the counter and still does NOT settle anything: the webhook does that
  update public.subscriptions set stripe_customer_id = 'cus_T1', stripe_payment_method_id = 'pm_T1',
                                  billing_mode = 'auto', charge_failures = 2 where id = sid;
  update public.subscription_charges set status = 'sent' where id = cyc2;
  j := public.subscription_charge_result(cyc2, true, 'pi_T3');
  if (select status from public.subscription_charges where id = cyc2) = 'succeeded'
     and (select charge_failures from public.subscriptions where id = sid) = 0
     and (select status from public.subscription_cycles where id = cyc1) = 'issued'
    then ok := ok + 1; else fail := fail + 1; log := log || ' [success-settled-too-early]'; end if;

  /* ---- 16. the webhook is what settles it ---- */
  -- a PaymentIntent from the ordinary Checkout flow is never touched here
  j := public.process_stripe_charge_event(jsonb_build_object(
        'id','evt_X1','type','payment_intent.succeeded',
        'data', jsonb_build_object('object', jsonb_build_object('id','pi_OTHER','amount_received',5000,'currency','usd','metadata','{}'::jsonb))));
  if (j ->> 'status') = 'ignored' then ok := ok + 1; else fail := fail + 1; log := log || ' [checkout-pi-stolen]'; end if;

  -- and one that names an amount the order does not have is recorded and refused
  select o.reference into url from public.orders o where o.session_pack_id = pack1 order by o.created_at desc limit 1;
  j := public.process_stripe_charge_event(jsonb_build_object(
        'id','evt_X2','type','payment_intent.succeeded',
        'data', jsonb_build_object('object', jsonb_build_object('id','pi_WRONG','amount_received',9999,'currency','usd',
          'metadata', jsonb_build_object('cg_source','subscription_auto','order_reference', url)))));
  if (j ->> 'status') = 'ignored' and (j ->> 'note') = 'amount mismatch'
     and (select payment_status from public.session_packs where id = pack1) = 'unpaid'
    then ok := ok + 1; else fail := fail + 1; log := log || ' [wrong-amount-credited:' || j::text || ']'; end if;

  -- the real one: ledger, pack, cycle, all of it, from one event
  j := public.process_stripe_charge_event(jsonb_build_object(
        'id','evt_X3','type','payment_intent.succeeded',
        '_enrich', jsonb_build_object('fee_amount', 175, 'charge_id','ch_T3','balance_transaction_id','txn_T3'),
        'data', jsonb_build_object('object', jsonb_build_object('id','pi_T3','amount_received',5000,'currency','usd',
          'metadata', jsonb_build_object('cg_source','subscription_auto','order_reference', url)))));
  if (j ->> 'status') = 'processed'
     and (select status from public.orders where reference = url) = 'paid'
     and (select payment_status from public.session_packs where id = pack1) = 'paid'
     and (select status from public.subscription_cycles where id = cyc1) = 'paid'
     and (select fee_amount from public.payments where provider_payment_intent_id = 'pi_T3') = 175
     and (select fee_known from public.payments where provider_payment_intent_id = 'pi_T3')
    then ok := ok + 1; else fail := fail + 1; log := log || ' [auto-charge-not-settled:' || j::text || ']'; end if;

  -- the commission was booked on it like any other payment
  if exists (select 1 from public.partner_earnings e join public.orders o on o.id = e.order_id where o.reference = url)
    then ok := ok + 1; else fail := fail + 1; log := log || ' [no-earning-for-auto-charge]'; end if;

  -- replaying the same event changes nothing
  j := public.process_stripe_charge_event(jsonb_build_object(
        'id','evt_X3','type','payment_intent.succeeded',
        'data', jsonb_build_object('object', jsonb_build_object('id','pi_T3','amount_received',5000,'currency','usd',
          'metadata', jsonb_build_object('cg_source','subscription_auto','order_reference', url)))));
  if (j ->> 'duplicate')::boolean and (select count(*) from public.payments where provider_payment_intent_id = 'pi_T3') = 1
    then ok := ok + 1; else fail := fail + 1; log := log || ' [replay-doubled]'; end if;

  -- a failed charge event is recorded and leaves the invoice exactly as it was
  j := public.process_stripe_charge_event(jsonb_build_object(
        'id','evt_X4','type','payment_intent.payment_failed',
        'data', jsonb_build_object('object', jsonb_build_object('id','pi_T4','currency','usd',
          'metadata', jsonb_build_object('cg_source','subscription_auto','order_reference', url)))));
  if (j ->> 'status') = 'processed' and (j ->> 'outcome') = 'failed'
     and (select count(*) from public.payments where provider_payment_intent_id = 'pi_T4') = 0
    then ok := ok + 1; else fail := fail + 1; log := log || ' [failed-event-mishandled]'; end if;

  /* ---- 17. forgetting the card, and the doors ---- */
  update public.subscriptions set stripe_customer_id = 'cus_T1', stripe_payment_method_id = 'pm_T1', billing_mode = 'auto' where id = sid;
  j := public.subscription_forget_card(sid);
  select * into s from public.subscriptions where id = sid;
  if (j ->> 'detach_payment_method') = 'pm_T1' and s.billing_mode = 'invoice' and s.stripe_payment_method_id is null
    then ok := ok + 1; else fail := fail + 1; log := log || ' [forget-card]'; end if;

  perform set_config('request.jwt.claims', VIEW, true);
  begin
    perform public.subscription_set_billing_mode(sid, 'auto');
    fail := fail + 1; log := log || ' [viewer-can-switch-to-auto]';
  exception when sqlstate '42501' then ok := ok + 1; when others then fail := fail + 1; log := log || ' [mode-wrong-error]'; end;
  begin
    perform public.subscription_forget_card(sid);
    fail := fail + 1; log := log || ' [viewer-can-forget-card]';
  exception when sqlstate '42501' then ok := ok + 1; when others then fail := fail + 1; log := log || ' [forget-wrong-error]'; end;
  perform set_config('request.jwt.claims', BOSS, true);

  -- the charging machinery is service_role's alone, and the queue is closed
  if not has_function_privilege('authenticated', 'public.subscription_charge_claim(int)', 'execute')
     and not has_function_privilege('authenticated', 'public.subscription_charge_result(uuid, boolean, text, text, text, boolean)', 'execute')
     and not has_function_privilege('authenticated', 'public.process_stripe_charge_event(jsonb)', 'execute')
     and not has_function_privilege('anon', 'public.pack_wants_card_on_file(uuid)', 'execute')
     and not has_table_privilege('authenticated', 'public.subscription_charges', 'select')
    then ok := ok + 1; else fail := fail + 1; log := log || ' [charging-exposed]'; end if;
  -- and nothing that could move money is ever returned to a browser
  j := public.subscription_get(sid);
  if not (j ? 'stripe_customer_id') and not (j ? 'stripe_payment_method_id')
    then ok := ok + 1; else fail := fail + 1; log := log || ' [card-ids-leaked]'; end if;

  /* ---- 18. no SECURITY DEFINER helper is reachable by a browser role ----
     20261058: the settlement trigger was executable by anon and the two
     shapes by authenticated, which let a signed-in operator with no finance
     permission read a subscription's figures by passing a hand-made row. The
     permission check belongs in front of the data, not in front of one of
     the two ways to reach it. */
  if not has_function_privilege('anon', 'public.subscription_cycle_on_pack_payment()', 'execute')
     and not has_function_privilege('authenticated', 'public.subscription_cycle_on_pack_payment()', 'execute')
     and not has_function_privilege('authenticated', 'public.subscription_json(public.subscriptions)', 'execute')
     and not has_function_privilege('authenticated', 'public.subscription_cycle_json(public.subscription_cycles)', 'execute')
     and not has_function_privilege('authenticated', 'public.subscription_has_mandate(public.subscriptions)', 'execute')
    then ok := ok + 1; else fail := fail + 1; log := log || ' [definer-helper-exposed]'; end if;
  -- and the permission-checked RPCs still reach them, because they are definers themselves
  if (public.subscription_get(sid) ? 'cycles') and jsonb_array_length(public.subscriptions_list()) >= 1
    then ok := ok + 1; else fail := fail + 1; log := log || ' [lockdown-broke-the-rpcs]'; end if;
  -- every function this pair added pins its search_path, with no exception
  if not exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                  where n.nspname = 'public'
                    and (p.proname like 'subscription%' or p.proname in ('pack_pay_url','report_link_key','pack_wants_card_on_file','process_stripe_charge_event'))
                    and not coalesce(p.proconfig::text, '') like '%search_path=%')
    then ok := ok + 1; else fail := fail + 1; log := log || ' [unpinned-search-path]'; end if;

  raise exception 'CG022_TESTS ok=% fail=% %', ok, fail, case when log = '' then '' else '—' || log end;
end $$;

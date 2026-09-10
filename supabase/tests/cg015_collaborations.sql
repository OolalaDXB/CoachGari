-- =====================================================================
-- CG-015 — Collaborations (deal room, versioned proposals, payment, RLS)
-- One rolled-back transaction. Proves the security and negotiation invariants
-- of §23: intake, token gating, immutable versions, authorised acceptance,
-- idempotency, frozen terms, monetary vs non-cash, BEAU PH payment linkage,
-- and RLS. Run by scripts/db-tests.sh; nothing persists (final RAISE).
-- =====================================================================
do $$
declare
  ok int := 0; fail int := 0; log text := '';
  rt jsonb := '{"stripe":{"configured":true,"mode":"test","embedded":true}}'::jsonb;
  j jsonb; ref text; ref2 text; tok text; tok2 text; did uuid; did2 uuid; cid uuid; v int; ord text; s text; n int;
begin
  update beau_ph.merchants set mode = 'test' where key = 'coach_gari';
  perform set_config('request.jwt.claims', '{"email":"grej28roux@gmail.com","role":"authenticated"}', true);

  -- 1. intake creates exactly one deal, linked to a CRM person, always status 'new'
  j := public.collab_intake(jsonb_build_object('name','ACME Brand','email','brand@example.com','type','event_appearance',
        'title','Padel launch','initial_request','Explore an appearance','status','agreed'));
  ref := j ->> 'public_ref'; tok := j ->> 'token';
  select id, crm_contact_id into did, cid from public.collaboration_deals where public_ref = ref;
  if did is not null then ok := ok + 1; else fail := fail + 1; log := log || ' [intake-no-deal]'; end if;
  if cid is not null then ok := ok + 1; else fail := fail + 1; log := log || ' [intake-no-crm]'; end if;
  if (select status from public.collaboration_deals where id = did) = 'new' then ok := ok + 1; else fail := fail + 1; log := log || ' [intake-status-not-new]'; end if;

  -- 2. the room view hides admin internals (no contact_email / id / crm id)
  j := public.collab_room(tok);
  if (j ->> 'public_ref') = ref and (j ? 'contact_email') = false and (j ? 'id') = false and (j ? 'crm_contact_id') = false then ok := ok + 1; else fail := fail + 1; log := log || ' [room-leaks-internals]'; end if;
  -- admin get DOES expose them
  j := public.collab_admin_get(did);
  if (j ->> 'contact_email') = 'brand@example.com' then ok := ok + 1; else fail := fail + 1; log := log || ' [admin-missing-email]'; end if;

  -- 3. an invalid or malformed token reveals nothing
  begin perform public.collab_room('not-a-token'); fail := fail + 1; log := log || ' [bad-token-accepted]'; exception when sqlstate 'P0002' then ok := ok + 1; end;
  begin perform public.collab_room(repeat('a',64)); fail := fail + 1; log := log || ' [unknown-token-accepted]'; exception when sqlstate 'P0002' then ok := ok + 1; end;

  -- 4. negotiation: coach v1, counterparty v2, coach v3
  perform public.collab_propose(did, jsonb_build_object('intro','P1','monetary_amount',600000,'currency','AED',
     'considerations', jsonb_build_array(jsonb_build_object('type','non_cash','description','Flights'), jsonb_build_object('type','non_cash','description','Hotel')),
     'terms', jsonb_build_object('deliverables','1 appearance')));
  perform public.collab_counter(tok, jsonb_build_object('monetary_amount',500000,'currency','AED'));
  j := public.collab_propose(did, jsonb_build_object('monetary_amount',550000,'currency','AED'));
  v := (j ->> 'version')::int;
  if v = 3 then ok := ok + 1; else fail := fail + 1; log := log || ' [wrong-version]'; end if;

  -- 5. proposal #1 is immutable (still 6000, still its own non-cash)
  if (select monetary_amount from public.collaboration_proposals where collaboration_id = did and version_number = 1) = 600000 then ok := ok + 1; else fail := fail + 1; log := log || ' [v1-mutated]'; end if;
  select count(*) into n from public.collaboration_proposals where collaboration_id = did;
  if n = 3 then ok := ok + 1; else fail := fail + 1; log := log || ' [version-count]'; end if;

  -- 6. only Coach Gari's proposal can be accepted from the room (a counterparty version cannot)
  begin perform public.collab_accept(tok, 2, '{}'::jsonb); fail := fail + 1; log := log || ' [accepted-own-counter]'; exception when sqlstate '22023' then ok := ok + 1; end;

  -- 7. explicit acceptance freezes the correct version → agreed
  perform public.collab_accept(tok, 3, '{}'::jsonb);
  select status into s from public.collaboration_deals where id = did;
  if s = 'agreed' and (select accepted_at is not null from public.collaboration_proposals where collaboration_id = did and version_number = 3) then ok := ok + 1; else fail := fail + 1; log := log || ' [not-frozen]'; end if;
  if (select accepted_proposal_id from public.collaboration_deals where id = did) = (select id from public.collaboration_proposals where collaboration_id = did and version_number = 3) then ok := ok + 1; else fail := fail + 1; log := log || ' [wrong-accepted-id]'; end if;

  -- 8. duplicate acceptance is idempotent (no error, same version)
  j := public.collab_accept(tok, 3, '{}'::jsonb);
  if (j ->> 'already') = 'true' then ok := ok + 1; else fail := fail + 1; log := log || ' [accept-not-idempotent]'; end if;

  -- 9. accepted terms cannot silently change: a new proposal after agreement is refused
  begin perform public.collab_propose(did, jsonb_build_object('monetary_amount',999999,'currency','AED')); fail := fail + 1; log := log || ' [propose-after-agreed]'; exception when sqlstate 'P0003' then ok := ok + 1; end;

  -- 10. monetary agreed deal → BEAU PH payment request + payer checkout, linked back, non-cash never a payment
  perform public.collab_payment_request(did, 550000, 'AED', '100%');
  j := public.collab_pay_start(tok, 'AE', rt);
  ord := j -> 'order' ->> 'reference';
  if (select order_reason from public.orders where reference = ord) = 'collaboration' then ok := ok + 1; else fail := fail + 1; log := log || ' [order-not-collaboration]'; end if;
  if exists (select 1 from beau_ph.payment_requests where external_reference = ord and metadata ->> 'collaboration_ref' = ref) then ok := ok + 1; else fail := fail + 1; log := log || ' [no-finance-linkage]'; end if;
  update public.orders set status = 'paid', paid_at = now() where reference = ord;
  perform public.collab_payment_sync(ord);
  if (select status from public.collaboration_payments where collaboration_id = did) = 'paid' then ok := ok + 1; else fail := fail + 1; log := log || ' [pay-not-synced]'; end if;
  select count(*) into n from public.collaboration_payments where collaboration_id = did;   -- exactly the one monetary request; the two non-cash items never became payments
  if n = 1 then ok := ok + 1; else fail := fail + 1; log := log || ' [noncash-became-payment]'; end if;

  -- 11. a non-cash-only agreed deal needs no payment
  j := public.collab_intake(jsonb_build_object('name','Gear Co','email','gear@example.com','type','product_collaboration'));
  ref2 := j ->> 'public_ref'; tok2 := j ->> 'token';
  select id into did2 from public.collaboration_deals where public_ref = ref2;
  perform public.collab_propose(did2, jsonb_build_object('intro','Products only','considerations', jsonb_build_array(jsonb_build_object('type','non_cash','description','Equipment'))));
  perform public.collab_accept(tok2, 1, '{}'::jsonb);
  if (select status from public.collaboration_deals where id = did2) = 'agreed'
     and (select monetary_amount from public.collaboration_proposals where collaboration_id = did2 and version_number = 1) is null
     and not exists (select 1 from public.collaboration_payments where collaboration_id = did2) then ok := ok + 1; else fail := fail + 1; log := log || ' [noncash-only-broke]'; end if;

  -- 12. revoked token stops all access
  perform public.collab_revoke_token(did2);
  begin perform public.collab_room(tok2); fail := fail + 1; log := log || ' [revoked-token-worked]'; exception when sqlstate 'P0003' then ok := ok + 1; end;

  -- 13. RLS + permission: a signed-in user without collab:view sees no deals and cannot read one
  insert into public.app_users (email, display_name, party, active) values ('nobody@test.dev', 'Nobody', 'studio', true) on conflict (email) do nothing;
  insert into public.app_permissions (email, permission) values ('nobody@test.dev', 'analytics:view') on conflict do nothing;
  set local role authenticated;
  perform set_config('request.jwt.claims', '{"email":"nobody@test.dev","role":"authenticated"}', true);
  select count(*) into n from public.collaboration_deals;
  if n = 0 then ok := ok + 1; else fail := fail + 1; log := log || ' [rls-leaks-deals]'; end if;
  begin perform public.collab_admin_get(did); fail := fail + 1; log := log || ' [no-perm-read]'; exception when sqlstate '42501' then ok := ok + 1; end;
  begin perform public.collab_propose(did, jsonb_build_object('monetary_amount',1)); fail := fail + 1; log := log || ' [no-perm-write]'; exception when sqlstate '42501' then ok := ok + 1; end;
  reset role;
  perform set_config('request.jwt.claims', '{"email":"grej28roux@gmail.com","role":"authenticated"}', true);

  raise exception 'CG015_TESTS ok=% fail=% %', ok, fail, log;
end $$;

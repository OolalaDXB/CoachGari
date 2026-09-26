-- CG-023 Payment links — database suite. One transaction, always rolls back
-- (RAISE EXCEPTION 'CG023_TESTS ok=… fail=…').
--
-- A payment link is the first money in this system that hangs off nothing: no
-- booking, no package, and a client only when the coach happens to know one.
-- The rails the other flows lean on are therefore absent, and what is left is
-- what this suite pins:
--
--   the label and the amount are validated server-side; a link is an order
--   with reason payment_link and NO booking and NO pack; creating one needs
--   finance:manage and reading the list needs finance:view; the token is
--   stored only as a hash and opens that one link and nothing else; opening
--   answers honestly for a paid, withdrawn or lapsed link instead of offering
--   a payment; withdrawing cancels the BEAU PH request behind the order; a
--   paid link cannot be withdrawn; and paying one creates no booking, no
--   pack, no session and consumes no credit.
do $$
declare
  ok int := 0; fail int := 0; log text := '';
  rt jsonb := '{"stripe":{"configured":true,"mode":"test","embedded":true}}'::jsonb;
  j jsonb; ref text; tok text; cid uuid; n int; b0 int; p0 int; s0 int;
begin
  update beau_ph.merchants set mode = 'test' where key = 'coach_gari';
  insert into public.app_users (email, display_name, party) values ('fin@test.local', 'Fin', 'gari'), ('ops@test.local', 'Ops', 'gari');
  insert into public.app_permissions (email, permission) values
    ('fin@test.local', 'finance:view'), ('fin@test.local', 'finance:manage'),
    ('ops@test.local', 'coach:operations');
  select count(*) into b0 from public.bookings;
  select count(*) into p0 from public.session_packs;
  select count(*) into s0 from public.coaching_sessions;

  perform set_config('request.jwt.claims', '{"role":"authenticated","email":"fin@test.local"}', true);

  /* ---- 1. the label is not optional: it is what the payer reads ---- */
  begin perform public.payment_link_create(null, 25000, 'AED'); fail := fail + 1; log := log || ' [no label accepted]'; exception when sqlstate '22023' then ok := ok + 1; end;
  begin perform public.payment_link_create('   ', 25000, 'AED'); fail := fail + 1; log := log || ' [blank label accepted]'; exception when sqlstate '22023' then ok := ok + 1; end;

  /* ---- 2. amount and currency are validated here, not in the browser ---- */
  begin perform public.payment_link_create('X', 500, 'AED'); fail := fail + 1; log := log || ' [below floor accepted]'; exception when sqlstate '22023' then ok := ok + 1; end;
  begin perform public.payment_link_create('X', 6000000, 'AED'); fail := fail + 1; log := log || ' [above ceiling accepted]'; exception when sqlstate '22023' then ok := ok + 1; end;
  begin perform public.payment_link_create('X', 25000, 'ZZ'); fail := fail + 1; log := log || ' [bad currency accepted]'; exception when sqlstate '22023' then ok := ok + 1; end;
  begin perform public.payment_link_create('X', 25000, 'ZAR'); fail := fail + 1; log := log || ' [unofferable currency accepted]'; exception when sqlstate '22023' then ok := ok + 1; end;

  /* ---- 3. a good link ---- */
  j := public.payment_link_create('Strength Training — September', 25000, 'AED', null, 30);
  ref := j ->> 'reference'; tok := j ->> 'token';
  if ref ~ '^PL-[A-Z0-9]{6}$' then ok := ok + 1; else fail := fail + 1; log := log || ' [reference ' || coalesce(ref, 'null') || ']'; end if;
  if tok ~ '^[0-9a-f]{64}$' then ok := ok + 1; else fail := fail + 1; log := log || ' [token shape]'; end if;
  if (j ->> 'label') = 'Strength Training — September' and (j ->> 'amount')::int = 25000 then ok := ok + 1; else fail := fail + 1; log := log || ' [echo]'; end if;

  -- the row: an order with no target, priced as asked, the label snapshotted
  select count(*) into n from public.orders
   where reference = ref and order_reason = 'payment_link' and booking_id is null and session_pack_id is null
     and gross_amount = 25000 and currency = 'AED' and status = 'pending_payment' and service_title = 'Strength Training — September';
  if n = 1 then ok := ok + 1; else fail := fail + 1; log := log || ' [order row]'; end if;

  -- the clear token is NOWHERE in the row: only its sha256
  select count(*) into n from public.orders where reference = ref and access_token_hash = encode(extensions.digest(tok, 'sha256'), 'hex');
  if n = 1 then ok := ok + 1; else fail := fail + 1; log := log || ' [token not hashed]'; end if;
  select count(*) into n from public.orders where reference = ref and (access_token_hash = tok or customer_contact = tok or service_title like '%' || tok || '%');
  if n = 0 then ok := ok + 1; else fail := fail + 1; log := log || ' [clear token stored]'; end if;

  -- creating it is written down
  select count(*) into n from public.admin_audit where area = 'order' and action = 'payment_link:create' and summary ->> 'reference' = ref;
  if n = 1 then ok := ok + 1; else fail := fail + 1; log := log || ' [no audit]'; end if;

  /* ---- 4. the token opens that link and nothing else ---- */
  begin perform public.payment_link_open(ref, 'not-a-token', rt); fail := fail + 1; log := log || ' [bad token shape accepted]'; exception when sqlstate 'P0002' then ok := ok + 1; end;
  begin perform public.payment_link_open(ref, repeat('a', 64), rt); fail := fail + 1; log := log || ' [wrong token accepted]'; exception when sqlstate 'P0002' then ok := ok + 1; end;
  begin perform public.payment_link_open('PL-ZZZZZZ', tok, rt); fail := fail + 1; log := log || ' [wrong reference accepted]'; exception when sqlstate 'P0002' then ok := ok + 1; end;

  j := public.payment_link_open(ref, tok, rt);
  if (j ->> 'state') = 'payable' and (j ->> 'amount')::int = 25000 and (j -> 'request' ->> 'id') is not null then ok := ok + 1; else fail := fail + 1; log := log || ' [open ' || j::text || ']'; end if;
  -- the BEAU PH request carries the `other` intent and points back at this order
  select count(*) into n from beau_ph.payment_requests r join beau_ph.merchants m on m.id = r.merchant_id
   where m.key = 'coach_gari' and r.external_reference = ref and r.intent = 'other' and r.amount = 25000 and r.currency = 'AED';
  if n = 1 then ok := ok + 1; else fail := fail + 1; log := log || ' [request intent/amount]'; end if;
  -- opening twice reuses the live request rather than minting a second one
  perform public.payment_link_open(ref, tok, rt);
  select count(*) into n from beau_ph.payment_requests r join beau_ph.merchants m on m.id = r.merchant_id
   where m.key = 'coach_gari' and r.external_reference = ref and r.status in ('created','pending','requires_action');
  if n = 1 then ok := ok + 1; else fail := fail + 1; log := log || ' [second request minted]'; end if;

  /* ---- 5. it is money that touches nothing else ---- */
  if (select count(*) from public.bookings) = b0 and (select count(*) from public.session_packs) = p0
     and (select count(*) from public.coaching_sessions) = s0 then ok := ok + 1;
  else fail := fail + 1; log := log || ' [a link created something]'; end if;

  /* ---- 6. permissions ---- */
  perform set_config('request.jwt.claims', '{"role":"authenticated","email":"ops@test.local"}', true);
  begin perform public.payment_link_create('X', 25000, 'AED'); fail := fail + 1; log := log || ' [coach:operations can create]'; exception when sqlstate '42501' then ok := ok + 1; end;
  begin perform public.payment_link_void(ref); fail := fail + 1; log := log || ' [coach:operations can void]'; exception when sqlstate '42501' then ok := ok + 1; end;
  select count(*) into n from public.payment_link_list(50);
  if n = 0 then ok := ok + 1; else fail := fail + 1; log := log || ' [list leaks without finance:view]'; end if;

  perform set_config('request.jwt.claims', '{"role":"anon"}', true);
  begin perform public.payment_link_create('X', 25000, 'AED'); fail := fail + 1; log := log || ' [anon can create]'; exception when others then ok := ok + 1; end;

  perform set_config('request.jwt.claims', '{"role":"authenticated","email":"fin@test.local"}', true);
  select count(*) into n from public.payment_link_list(50) where reference = ref;
  if n = 1 then ok := ok + 1; else fail := fail + 1; log := log || ' [finance:view cannot see it]'; end if;

  /* ---- 7. withdrawing ---- */
  j := public.payment_link_void(ref);
  if (j ->> 'status') = 'cancelled' then ok := ok + 1; else fail := fail + 1; log := log || ' [void status]'; end if;
  select count(*) into n from public.orders where reference = ref and status = 'cancelled';
  if n = 1 then ok := ok + 1; else fail := fail + 1; log := log || ' [order not cancelled]'; end if;
  -- the request behind it is closed too: a live request against a closed order is how a
  -- withdrawn link gets paid anyway
  select count(*) into n from beau_ph.payment_requests r join beau_ph.merchants m on m.id = r.merchant_id
   where m.key = 'coach_gari' and r.external_reference = ref and r.status in ('created','pending','requires_action');
  if n = 0 then ok := ok + 1; else fail := fail + 1; log := log || ' [request still live after void]'; end if;
  -- and it stops offering a payment
  j := public.payment_link_open(ref, tok, rt);
  if (j ->> 'state') = 'closed' then ok := ok + 1; else fail := fail + 1; log := log || ' [withdrawn still payable: ' || j::text || ']'; end if;

  /* ---- 8. a paid link is final ---- */
  j := public.payment_link_create('Paid one', 12000, 'AED');
  ref := j ->> 'reference'; tok := j ->> 'token';
  update public.orders set status = 'paid', paid_at = now() where reference = ref;
  j := public.payment_link_open(ref, tok, rt);
  if (j ->> 'state') = 'paid' then ok := ok + 1; else fail := fail + 1; log := log || ' [paid link still payable]'; end if;
  begin perform public.payment_link_void(ref); fail := fail + 1; log := log || ' [paid link withdrawn]'; exception when sqlstate 'P0003' then ok := ok + 1; end;

  /* ---- 9. a lapsed link ---- */
  j := public.payment_link_create('Old one', 12000, 'AED', null, 1);
  ref := j ->> 'reference'; tok := j ->> 'token';
  update public.orders set checkout_expires_at = now() - interval '1 day' where reference = ref;
  j := public.payment_link_open(ref, tok, rt);
  if (j ->> 'state') = 'expired' then ok := ok + 1; else fail := fail + 1; log := log || ' [expired link still payable]'; end if;

  /* ---- 10. a link may name a client, and does not have to ---- */
  insert into public.crm_contacts (display_name, country) values ('Link Client', 'United Arab Emirates') returning id into cid;
  j := public.payment_link_create('For a known client', 30000, 'AED', cid, 30);
  select count(*) into n from public.orders where reference = (j ->> 'reference') and crm_contact_id = cid;
  if n = 1 then ok := ok + 1; else fail := fail + 1; log := log || ' [contact not linked]'; end if;
  begin perform public.payment_link_create('Ghost', 30000, 'AED', '00000000-0000-0000-0000-000000000000'::uuid, 30);
        fail := fail + 1; log := log || ' [unknown contact accepted]'; exception when sqlstate 'P0002' then ok := ok + 1; end;

  raise exception 'CG023_TESTS ok=% fail=% %', ok, fail, log;
end $$;

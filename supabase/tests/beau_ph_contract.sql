-- BEAU PH — contract suite. One transaction, always rolls back
-- (ends with RAISE EXCEPTION 'BEAU_PH_TESTS ok=… fail=…').
--
-- Generic core (schema beau_ph, a throw-away merchant, no Coach Gari knowledge):
--   eligibility by country/currency · disabled provider omitted · not_configured
--   provider cannot act · authoritative amount cannot be overridden · request
--   scoped to one external order · provider event → normalized state · native
--   evidence preserved · manual provider never self-confirms · secrets never in
--   public output · BEAU Wallet placeholder cannot pay · unconfigured Paynow /
--   M-PESA / Ozow / PayShap cannot fake a payment · paid settles sibling rails.
-- Host adapter (Coach Gari): reconciles once, idempotently; a duplicate
--   provider event never duplicates the host payment; manual receipts carry the
--   operator identity; the report page consumes the server-side list.
do $$
declare
  ok int := 0; fail int := 0; log text := '';
  mk text := 'ph_contract'; rt jsonb := '{"stripe":{"configured":true,"mode":"test"}}'::jsonb;
  j jsonb; e1 jsonb; e2 jsonb; r1 uuid; r2 uuid; r3 uuid; txt text;
  cA uuid; p1 uuid; p2 uuid; p3 uuid; oref text; oref2 text; ph_ev uuid; ordid uuid; tok text; ev jsonb;
  p4 uuid; oref4 text; rA uuid; rB uuid; jB jsonb; nB int;
  q1 jsonb; q2 jsonb; qid uuid; mid uuid; nA int; p5 uuid; tok5 text; j5 jsonb; rC uuid;
begin
  update beau_ph.merchants set mode = 'test' where key = 'coach_gari';   -- suites run the host in TEST mode regardless of the production setting (rolled back)
  insert into beau_ph.merchants (key, name, country, default_currency, mode) values (mk, 'Contract Test', 'ZW', 'USD', 'test');
  -- merchant configuration is explicit (countries + currencies persisted); a provider's open coverage is never read as "any"
  perform beau_ph.merchant_method_configure(mk, 'stripe', '{"enabled":true,"countries":["AE","ZW"],"currencies":["AED","USD"]}'::jsonb, 't');
  perform beau_ph.merchant_method_set(mk, 'aani', true, 'AED', '{"display_value":"+971 50 000 0000"}'::jsonb, '{}'::jsonb, null, 't');
  perform beau_ph.merchant_method_configure(mk, 'bank_transfer', '{"enabled":true,"currency":"USD","countries":["AE","ZW"],"currencies":["AED","USD"],"instructions":{"account_holder":"Test Co","iban":"ZW00TEST","bic":"TESTZWHX"}}'::jsonb, 't');
  -- the merchant may "enable" rails that are not onboarded; readiness still wins
  perform beau_ph.merchant_method_set(mk, 'paynow', true, 'USD', '{}'::jsonb, '{}'::jsonb, null, 't');
  perform beau_ph.merchant_method_set(mk, 'mpesa', true, 'KES', '{}'::jsonb, '{}'::jsonb, null, 't');
  perform beau_ph.merchant_method_set(mk, 'ozow', true, 'ZAR', '{}'::jsonb, '{}'::jsonb, null, 't');
  perform beau_ph.merchant_method_set(mk, 'payshap', true, 'ZAR', '{}'::jsonb, '{}'::jsonb, null, 't');
  perform beau_ph.merchant_method_set(mk, 'beau_wallet', true, null, '{}'::jsonb, '{}'::jsonb, null, 't');

  /* ---- 1. eligibility by country / currency ---- */
  j := beau_ph.eligible_methods(mk, 'AE', 'AED', rt);
  if (select array_agg(e ->> 'provider' order by e ->> 'provider') from jsonb_array_elements(j) e) = array['aani','bank_transfer','stripe'] then ok := ok + 1; else fail := fail + 1; log := log || ' [elig AE/AED ' || j::text || ']'; end if;
  j := beau_ph.eligible_methods(mk, 'ZW', 'USD', rt);
  if (select array_agg(e ->> 'provider' order by e ->> 'provider') from jsonb_array_elements(j) e) = array['bank_transfer','stripe'] then ok := ok + 1; else fail := fail + 1; log := log || ' [elig ZW/USD ' || j::text || ']'; end if;
  j := beau_ph.method_matrix(mk, 'ZW', 'USD', rt);
  if (select e ->> 'reason' from jsonb_array_elements(j) e where e ->> 'provider' = 'aani') = 'country'
     and (select e ->> 'reason' from jsonb_array_elements(j) e where e ->> 'provider' = 'paynow') = 'not_configured'
     and (select e ->> 'reason' from jsonb_array_elements(j) e where e ->> 'provider' = 'beau_wallet') = 'coming_soon' then ok := ok + 1; else fail := fail + 1; log := log || ' [matrix reasons ' || j::text || ']'; end if;

  /* ---- 2. disabled provider omitted; undeployed / wrong-mode online rail omitted ---- */
  perform beau_ph.merchant_method_set(mk, 'bank_transfer', false, 'USD', '{"iban":"ZW00TEST"}'::jsonb, '{}'::jsonb, null, 't');
  j := beau_ph.eligible_methods(mk, 'ZW', 'USD', rt);
  if j::text not like '%bank_transfer%' then ok := ok + 1; else fail := fail + 1; log := log || ' [disabled listed]'; end if;
  perform beau_ph.merchant_method_set(mk, 'bank_transfer', true, 'USD', '{"account_holder":"Test Co","iban":"ZW00TEST","bic":"TESTZWHX"}'::jsonb, '{}'::jsonb, null, 't');
  j := beau_ph.eligible_methods(mk, 'ZW', 'USD', '{}'::jsonb);
  if j::text not like '%"stripe"%' then ok := ok + 1; else fail := fail + 1; log := log || ' [stripe without runtime listed]'; end if;
  j := beau_ph.eligible_methods(mk, 'ZW', 'USD', '{"stripe":{"configured":true,"mode":"live"}}'::jsonb);
  if j::text not like '%"stripe"%' then ok := ok + 1; else fail := fail + 1; log := log || ' [live runtime listed for test merchant]'; end if;

  /* ---- 3. not_configured provider cannot act as active ---- */
  begin perform beau_ph.create_request(mk, 'paynow', 'ORD-P', 'REF-2001', 1000, 'USD', 'ZW', null, '{}'::jsonb, rt); fail := fail + 1; log := log || ' [paynow request created]'; exception when sqlstate 'P0003' then ok := ok + 1; end;

  /* ---- 4. authoritative amount cannot be overridden ---- */
  j := beau_ph.create_request(mk, 'stripe', 'ORD-1', 'REF-2002', 5000, 'USD', 'ZW', null, '{"order_id":"x"}'::jsonb, rt); r1 := (j ->> 'id')::uuid;
  perform beau_ph.attach_attempt(r1, 'cs_c1', 'https://checkout.example/c1', now() + interval '30 min');
  e1 := beau_ph.ingest_stripe_event(jsonb_build_object('id', 'evt_c1', 'type', 'checkout.session.completed', 'livemode', false,
          'data', jsonb_build_object('object', jsonb_build_object('id', 'cs_c1', 'payment_status', 'paid', 'amount_total', 4999, 'currency', 'usd', 'payment_intent', 'pi_c1'))));
  if (e1 ->> 'outcome') = 'rejected:amount_mismatch' and (select status from beau_ph.payment_requests where id = r1) = 'requires_action' then ok := ok + 1; else fail := fail + 1; log := log || ' [amount override ' || e1::text || ']'; end if;
  if exists (select 1 from beau_ph.provider_events where provider_key = 'stripe' and provider_event_id = 'evt_c1' and outcome = 'rejected:amount_mismatch'
              and payload -> 'data' -> 'object' ->> 'amount_total' = '4999') then ok := ok + 1; else fail := fail + 1; log := log || ' [refused evidence lost]'; end if;
  begin perform beau_ph.create_request(mk, 'stripe', 'ORD-1', 'REF-2002', 1, 'USD', 'ZW', null, '{}'::jsonb, rt); fail := fail + 1; log := log || ' [amount changed on live request]'; exception when sqlstate 'P0003' then ok := ok + 1; end;
  begin insert into beau_ph.payment_requests (merchant_id, provider_key, external_reference, public_reference, amount, currency)
          values ((select id from beau_ph.merchants where key = mk), 'stripe', 'ORD-U', gen_random_uuid()::text, 100, 'USD');
        fail := fail + 1; log := log || ' [uuid public reference accepted]'; exception when check_violation then ok := ok + 1; end;

  /* ---- 5. request scoped to one external order ---- */
  j := beau_ph.create_request(mk, 'stripe', 'ORD-1', 'REF-2002', 5000, 'USD', 'ZW', null, '{}'::jsonb, rt);
  if (j ->> 'id')::uuid = r1 then ok := ok + 1; else fail := fail + 1; log := log || ' [live request not reused]'; end if;
  e1 := beau_ph.ingest_stripe_event(jsonb_build_object('id', 'evt_c2', 'type', 'checkout.session.completed', 'livemode', false,
          'data', jsonb_build_object('object', jsonb_build_object('id', 'cs_other', 'payment_status', 'paid', 'amount_total', 5000, 'currency', 'usd', 'payment_intent', 'pi_x', 'client_reference_id', 'ORD-NOPE'))));
  if (e1 ->> 'outcome') = 'no_request' and (select status from beau_ph.payment_requests where id = r1) = 'requires_action' then ok := ok + 1; else fail := fail + 1; log := log || ' [cross-order event ' || e1::text || ']'; end if;

  /* ---- 6. provider event → normalized state; 7. native evidence preserved ---- */
  e1 := beau_ph.ingest_stripe_event(jsonb_build_object('id', 'evt_c3', 'type', 'checkout.session.completed', 'livemode', false,
          'data', jsonb_build_object('object', jsonb_build_object('id', 'cs_c1', 'payment_status', 'paid', 'amount_total', 5000, 'currency', 'usd', 'payment_intent', 'pi_c1')),
          '_enrich', jsonb_build_object('charge_id', 'ch_c1', 'balance_transaction_id', 'txn_c1', 'fee_amount', 175)));
  if (e1 ->> 'outcome') = 'normalized' and (e1 ->> 'from') = 'requires_action' and (e1 ->> 'to') = 'paid'
     and (select status from beau_ph.payment_requests where id = r1) = 'paid'
     and (select payment_reference from beau_ph.payment_requests where id = r1) = 'pi_c1' then ok := ok + 1; else fail := fail + 1; log := log || ' [normalize ' || e1::text || ']'; end if;
  if exists (select 1 from beau_ph.payment_events where id = (e1 ->> 'payment_event_id')::uuid and provider_status = 'paid' and provider_reference = 'pi_c1'
              and (evidence ->> 'fee_amount')::int = 175 and evidence ->> 'charge_id' = 'ch_c1' and actor = 'provider')
     and exists (select 1 from beau_ph.provider_events where provider_key = 'stripe' and provider_event_id = 'evt_c3' and payload ->> 'type' = 'checkout.session.completed' and outcome = 'normalized')
     then ok := ok + 1; else fail := fail + 1; log := log || ' [evidence]'; end if;
  e2 := beau_ph.ingest_stripe_event(jsonb_build_object('id', 'evt_c3b', 'type', 'checkout.session.completed', 'livemode', false,
          'data', jsonb_build_object('object', jsonb_build_object('id', 'cs_c1', 'payment_status', 'paid', 'amount_total', 5000, 'currency', 'usd', 'payment_intent', 'pi_c1'))));
  if (e2 ->> 'outcome') = 'ignored:already_paid' and (select count(*) from beau_ph.payment_events where request_id = r1 and to_status = 'paid') = 1 then ok := ok + 1; else fail := fail + 1; log := log || ' [already paid ' || e2::text || ']'; end if;
  e2 := beau_ph.ingest_stripe_event(jsonb_build_object('id', 'evt_c4', 'type', 'checkout.session.expired', 'livemode', false, 'data', jsonb_build_object('object', jsonb_build_object('id', 'cs_c1'))));
  if (e2 ->> 'outcome') like 'rejected:illegal_transition%' and (select status from beau_ph.payment_requests where id = r1) = 'paid' then ok := ok + 1; else fail := fail + 1; log := log || ' [paid→expired ' || e2::text || ']'; end if;
  e2 := beau_ph.ingest_stripe_event(jsonb_build_object('id', 'evt_c5', 'type', 'refund.created', 'livemode', false,
          'data', jsonb_build_object('object', jsonb_build_object('id', 're_c1', 'amount', 1000, 'currency', 'usd', 'status', 'succeeded', 'payment_intent', 'pi_c1'))));
  if (e2 ->> 'outcome') = 'evidence' and (select status from beau_ph.payment_requests where id = r1) = 'paid' then ok := ok + 1; else fail := fail + 1; log := log || ' [partial refund ' || e2::text || ']'; end if;
  e2 := beau_ph.ingest_stripe_event(jsonb_build_object('id', 'evt_c6', 'type', 'refund.created', 'livemode', false,
          'data', jsonb_build_object('object', jsonb_build_object('id', 're_c2', 'amount', 5000, 'currency', 'usd', 'status', 'succeeded', 'payment_intent', 'pi_c1'))));
  if (e2 ->> 'to') = 'refunded' and (select status from beau_ph.payment_requests where id = r1) = 'refunded' then ok := ok + 1; else fail := fail + 1; log := log || ' [full refund ' || e2::text || ']'; end if;
  -- a live-mode event can never touch a test merchant
  e2 := beau_ph.ingest_stripe_event(jsonb_build_object('id', 'evt_c7', 'type', 'checkout.session.completed', 'livemode', true,
          'data', jsonb_build_object('object', jsonb_build_object('id', 'cs_c1', 'payment_status', 'paid', 'amount_total', 5000, 'currency', 'usd', 'payment_intent', 'pi_c1'))));
  if (e2 ->> 'outcome') = 'rejected:mode_mismatch' then ok := ok + 1; else fail := fail + 1; log := log || ' [livemode accepted ' || e2::text || ']'; end if;

  /* ---- 8. manual provider never self-confirms ---- */
  j := beau_ph.create_request(mk, 'bank_transfer', 'ORD-2', 'REF-2003', 7000, 'USD', 'ZW'); r2 := (j ->> 'id')::uuid;
  if (j ->> 'status') = 'pending' and (j -> 'instructions' ->> 'iban') = 'ZW00TEST' and (j -> 'instructions' ->> 'reference') = 'REF-2003' then ok := ok + 1; else fail := fail + 1; log := log || ' [manual request ' || j::text || ']'; end if;
  e1 := beau_ph.ingest_provider_event('bank_transfer', 'fake-bank-1', 'bank.credit', '{"claimed":"paid"}'::jsonb, jsonb_build_object('request_id', r2, 'status', 'paid', 'amount', 7000, 'currency', 'USD'));
  if (e1 ->> 'outcome') = 'rejected:manual_provider_requires_operator' and (select status from beau_ph.payment_requests where id = r2) = 'pending' then ok := ok + 1; else fail := fail + 1; log := log || ' [manual self-confirm ' || e1::text || ']'; end if;
  begin perform beau_ph.confirm_manual(r2, null, 7000, 'USD'); fail := fail + 1; log := log || ' [anonymous confirm]'; exception when insufficient_privilege then ok := ok + 1; end;
  begin perform beau_ph.confirm_manual(r2, 'op@test', 6000, 'USD'); fail := fail + 1; log := log || ' [confirm wrong amount]'; exception when sqlstate 'P0003' then ok := ok + 1; end;
  e1 := beau_ph.confirm_manual(r2, 'op@test', 7000, 'USD', 'bank-ref-77', now() - interval '1 day', 'statement line 12');
  if (e1 ->> 'to') = 'paid' and exists (select 1 from beau_ph.payment_events where id = (e1 ->> 'payment_event_id')::uuid and actor = 'operator' and actor_id = 'op@test'
                                          and provider_reference = 'bank-ref-77' and amount = 7000 and currency = 'USD')
     and exists (select 1 from beau_ph.provider_events where request_id = r2 and event_type = 'operator.confirmed' and payload ->> 'operator' = 'op@test')
     then ok := ok + 1; else fail := fail + 1; log := log || ' [operator confirm ' || e1::text || ']'; end if;
  begin perform beau_ph.confirm_manual(r2, 'op@test', 7000, 'USD'); fail := fail + 1; log := log || ' [confirmed twice]'; exception when sqlstate 'P0003' then ok := ok + 1; end;

  /* ---- 9. provider secrets never appear in public output ---- */
  begin perform beau_ph.merchant_method_set(mk, 'stripe', true, null, '{"webhook_secret":"whsec_abcdefghijklmnop"}'::jsonb, '{}'::jsonb, null, 't'); fail := fail + 1; log := log || ' [secret accepted in instructions]'; exception when check_violation or sqlstate '22023' then ok := ok + 1; end;
  begin perform beau_ph.merchant_method_set(mk, 'stripe', true, null, '{}'::jsonb, '{"api_key":"sk_test_abcdefghijklmnop"}'::jsonb, null, 't'); fail := fail + 1; log := log || ' [secret accepted in settings]'; exception when check_violation or sqlstate '22023' then ok := ok + 1; end;
  txt := beau_ph.eligible_methods(mk, 'AE', 'AED', rt)::text || beau_ph.method_matrix(mk, 'AE', 'AED', rt)::text || beau_ph.get_request(r1)::text || beau_ph.request_events(r1)::text;
  if txt !~ '(sk|rk)_(live|test)_|whsec_' and txt !~* '"(secret|api_?key|private_?key|password)"' then ok := ok + 1; else fail := fail + 1; log := log || ' [secret in output]'; end if;

  /* ---- 10. BEAU Wallet placeholder cannot mark paid ---- */
  begin perform beau_ph.create_request(mk, 'beau_wallet', 'ORD-W', 'REF-2004', 100, 'USD', 'ZW'); fail := fail + 1; log := log || ' [wallet request]'; exception when sqlstate 'P0003' then ok := ok + 1; end;
  e1 := beau_ph.ingest_provider_event('beau_wallet', 'tx-0xabc', 'wallet.transfer', '{"tx":"0xabc"}'::jsonb, jsonb_build_object('external_reference', 'ORD-2', 'merchant', mk, 'status', 'paid', 'amount', 7000, 'currency', 'USD'));
  -- refused either as "cannot confirm" (confirmation = unavailable) or as placeholder — never normalized
  if (e1 ->> 'outcome') in ('rejected:provider_cannot_confirm', 'rejected:provider_placeholder')
     and (select status from beau_ph.payment_requests where id = r2) = 'paid'   -- untouched by the wallet claim
     then ok := ok + 1; else fail := fail + 1; log := log || ' [wallet event ' || e1::text || ']'; end if;

  /* ---- 11–13. unconfigured Paynow / M-PESA / Ozow / PayShap cannot fake a payment ---- */
  j := beau_ph.create_request(mk, 'stripe', 'ORD-3', 'REF-2005', 2500, 'USD', 'ZW', null, '{}'::jsonb, rt); r3 := (j ->> 'id')::uuid;
  e1 := beau_ph.ingest_provider_event('paynow', 'pn-1', 'paynow.paid', '{"status":"Paid"}'::jsonb, jsonb_build_object('external_reference', 'ORD-3', 'merchant', mk, 'status', 'paid', 'amount', 2500, 'currency', 'USD'));
  if (e1 ->> 'outcome') = 'rejected:provider_not_configured' and (select status from beau_ph.payment_requests where id = r3) = 'created' then ok := ok + 1; else fail := fail + 1; log := log || ' [paynow fake ' || e1::text || ']'; end if;
  e1 := beau_ph.ingest_provider_event('mpesa', 'mp-1', 'stkCallback', '{"ResultCode":0}'::jsonb, jsonb_build_object('external_reference', 'ORD-3', 'merchant', mk, 'status', 'paid', 'amount', 2500, 'currency', 'USD'));
  if (e1 ->> 'outcome') = 'rejected:provider_not_configured' then ok := ok + 1; else fail := fail + 1; log := log || ' [mpesa fake ' || e1::text || ']'; end if;
  e1 := beau_ph.ingest_provider_event('ozow', 'oz-1', 'notify', '{"Status":"Complete"}'::jsonb, jsonb_build_object('external_reference', 'ORD-3', 'merchant', mk, 'status', 'paid', 'amount', 2500, 'currency', 'USD'));
  e2 := beau_ph.ingest_provider_event('payshap', 'ps-1', 'rpp.settled', '{}'::jsonb, jsonb_build_object('external_reference', 'ORD-3', 'merchant', mk, 'status', 'paid', 'amount', 2500, 'currency', 'USD'));
  if (e1 ->> 'outcome') = 'rejected:provider_not_configured' and (e2 ->> 'outcome') = 'rejected:provider_not_configured'
     and (select status from beau_ph.payment_requests where id = r3) = 'created' then ok := ok + 1; else fail := fail + 1; log := log || ' [ozow/payshap fake]'; end if;
  if (select count(*) from beau_ph.provider_events where provider_key in ('paynow','mpesa','ozow','payshap','beau_wallet') and outcome like 'rejected:provider_%') = 5 then ok := ok + 1; else fail := fail + 1; log := log || ' [unconfigured evidence]'; end if;

  /* ---- 14–15. HOST ADAPTER (Coach Gari): reconciles once, idempotently ---- */
  insert into public.app_users (email, display_name, party) values ('fin@test.local', 'Fin', 'gari');
  insert into public.app_permissions (email, permission) values ('fin@test.local', 'coach:operations'), ('fin@test.local', 'finance:view'), ('fin@test.local', 'finance:manage');
  insert into public.crm_contacts (display_name, email, email_norm, country) values ('Tino M', 'tino@ex.com', 'tino@ex.com', 'Zimbabwe') returning id into cA;
  insert into public.session_packs (crm_contact_id, title, total_sessions, price_amount, currency, payment_status, created_by)
    values (cA, '5-session pack', 5, 150000, 'AED', 'unpaid', 'seed') returning id into p1;
  perform set_config('request.jwt.claims', '{"role":"authenticated","email":"fin@test.local"}', true);
  execute 'set local role authenticated';
  perform public.payment_method_set(jsonb_build_object('method', 'bank_transfer', 'enabled', true, 'account_holder', 'Coach Gari', 'iban', 'AE00TEST', 'bic', 'TESTAEAD', 'currency', 'AED',
                                                        'countries', jsonb_build_array('AE', 'ZW'), 'currencies', jsonb_build_array('AED')));
  tok := public.report_issue_link(p1) ->> 'token';
  execute 'reset role';
  -- the report page consumes the SERVER-SIDE list: a Zimbabwean client is offered card + bank, not Aani (country) — decided here, not in JS
  j := public.report_view(tok, rt);
  if (select array_agg(e ->> 'provider' order by e ->> 'provider') from jsonb_array_elements(j -> 'methods') e) = array['bank_transfer','stripe']
     and (j -> 'methods' -> 0 ->> 'reference') = (j ->> 'pay_ref') and (j ->> 'customer_country') = 'ZW'
     and j::text !~ '(sk|rk)_(live|test)_|whsec_' then ok := ok + 1; else fail := fail + 1; log := log || ' [report methods ' || (j -> 'methods')::text || ']'; end if;
  -- card path: pack → order → BEAU PH request (public CG-#### reference, amount from the pack) → attempt → verified event → ledger
  j := public.cg_ph_request_for_pack(p1, 'stripe', rt); oref := j -> 'order' ->> 'reference';
  if (j -> 'request' ->> 'external_reference') = oref and (j -> 'request' ->> 'public_reference') ~ '^CG-[0-9]{4,}$'
     and (j -> 'request' ->> 'amount')::int = 150000 and (j -> 'request' ->> 'currency') = 'AED' and (j -> 'request' ->> 'customer_country') = 'ZW'
     then ok := ok + 1; else fail := fail + 1; log := log || ' [host request ' || j::text || ']'; end if;
  perform public.attach_checkout(oref, 'cs_host_1', 'https://checkout.example/h1', now() + interval '30 min');
  ev := jsonb_build_object('id', 'evt_h1', 'type', 'checkout.session.completed', 'livemode', false,
          'data', jsonb_build_object('object', jsonb_build_object('id', 'cs_host_1', 'payment_status', 'paid', 'amount_total', 150000, 'currency', 'aed', 'payment_intent', 'pi_h1', 'client_reference_id', oref)),
          '_enrich', jsonb_build_object('charge_id', 'ch_h1', 'balance_transaction_id', 'txn_h1', 'fee_amount', 4000));
  e1 := public.process_stripe_event(ev);
  ph_ev := (e1 -> 'beau_ph' ->> 'payment_event_id')::uuid;
  select id into ordid from public.orders where reference = oref;
  if (e1 ->> 'status') = 'processed' and ph_ev is not null
     and (select count(*) from public.payments where order_id = ordid) = 1
     and (select ph_event_id from public.payments where order_id = ordid) = ph_ev and beau_ph.is_reconciled(ph_ev)
     and (select payment_status from public.session_packs where id = p1) = 'paid'
     and (select count(*) from public.partner_earnings where order_id = ordid) = 1 then ok := ok + 1; else fail := fail + 1; log := log || ' [host reconcile ' || e1::text || ']'; end if;
  e2 := public.process_stripe_event(ev);                                                    -- same provider event again
  perform public.process_stripe_event(ev || jsonb_build_object('id', 'evt_h1b'));          -- re-delivery under a new event id
  if (e2 ->> 'duplicate')::boolean and (select count(*) from public.payments where order_id = ordid) = 1
     and (select count(*) from public.partner_earnings where order_id = ordid) = 1
     and (select count(*) from beau_ph.reconciliations rc join beau_ph.payment_requests r on r.id = rc.request_id where r.external_reference = oref) = 1
     and (select count(*) from beau_ph.payment_events pe join beau_ph.payment_requests r on r.id = pe.request_id where r.external_reference = oref and pe.to_status = 'paid') = 1
     then ok := ok + 1; else fail := fail + 1; log := log || ' [host duplicate]'; end if;
  j := beau_ph.mark_reconciled(ph_ev, 'should-not-change');
  if (j ->> 'duplicate')::boolean and (j ->> 'host_reference') <> 'should-not-change' then ok := ok + 1; else fail := fail + 1; log := log || ' [reconcile twice]'; end if;

  -- manual path: operator identity recorded, reconciled once, NO Stripe earning, sibling card intent settled
  insert into public.session_packs (crm_contact_id, title, total_sessions, price_amount, currency, payment_status, created_by)
    values (cA, '5-session pack #bank', 5, 90000, 'AED', 'unpaid', 'seed') returning id into p2;
  j := public.cg_ph_request_for_pack(p2, 'stripe', rt); oref2 := j -> 'order' ->> 'reference';   -- a pending card intent for the same order
  perform set_config('request.jwt.claims', '{"role":"authenticated","email":"fin@test.local"}', true);
  execute 'set local role authenticated';
  j := public.payment_record_manual(p2, 90000, 'AED', 'bank_transfer', 'BANK-REF-1');
  execute 'reset role';
  select id into ordid from public.orders where reference = j ->> 'order';
  if (j ->> 'ok')::boolean and (j ->> 'order') = oref2
     and (select count(*) from public.payments where order_id = ordid and provider = 'bank_transfer' and ph_event_id is not null) = 1
     and beau_ph.is_reconciled((select ph_event_id from public.payments where order_id = ordid))
     and exists (select 1 from beau_ph.payment_events pe where pe.id = (select ph_event_id from public.payments where order_id = ordid) and pe.actor = 'operator' and pe.actor_id = 'fin@test.local')
     and (select count(*) from public.partner_earnings where order_id = ordid) = 0
     and (select status from beau_ph.payment_requests where external_reference = oref2 and provider_key = 'stripe') = 'cancelled'
     and (select status from beau_ph.payment_requests where external_reference = oref2 and provider_key = 'bank_transfer') = 'paid'
     then ok := ok + 1; else fail := fail + 1; log := log || ' [host manual ' || j::text || ']'; end if;
  -- a manual receipt of a DIFFERENT amount supersedes the pending intent explicitly (never converted, never guessed)
  insert into public.session_packs (crm_contact_id, title, total_sessions, price_amount, currency, payment_status, created_by)
    values (cA, '5-session pack #alt', 5, 100000, 'AED', 'unpaid', 'seed') returning id into p3;
  j := public.cg_ph_request_for_pack(p3, 'stripe', rt); oref := j -> 'order' ->> 'reference';
  perform set_config('request.jwt.claims', '{"role":"authenticated","email":"fin@test.local"}', true);
  execute 'set local role authenticated';
  j := public.payment_record_manual(p3, 80000, 'AED', 'aani', 'AANI-REF-1');
  execute 'reset role';
  if (j ->> 'superseded_order') = oref and (j ->> 'order') <> oref
     and (select status from public.orders where reference = oref) = 'cancelled'
     and (select status from beau_ph.payment_requests where external_reference = oref and provider_key = 'stripe') = 'cancelled'
     and (select payment_status from public.session_packs where id = p3) = 'paid'
     and (select payment_source from public.session_packs where id = p3) = 'aani'
     and (select gross_amount from public.orders where reference = j ->> 'order') = 80000 then ok := ok + 1; else fail := fail + 1; log := log || ' [supersede ' || j::text || ']'; end if;
  -- a late card webhook for the superseded intent is refused (evidence kept), the ledger is untouched
  e1 := public.process_stripe_event(jsonb_build_object('id', 'evt_h2', 'type', 'checkout.session.completed', 'livemode', false,
          'data', jsonb_build_object('object', jsonb_build_object('id', 'cs_late', 'payment_status', 'paid', 'amount_total', 100000, 'currency', 'aed', 'payment_intent', 'pi_late', 'client_reference_id', oref))));
  if (e1 ->> 'status') = 'ignored' and (e1 ->> 'note') like 'rejected:illegal_transition%'
     and not exists (select 1 from public.payments p join public.orders o on o.id = p.order_id where o.reference = oref) then ok := ok + 1; else fail := fail + 1; log := log || ' [late webhook ' || e1::text || ']'; end if;

  /* ---- 16. in-person / SoftPOS: capability model, platform + initiator eligibility, handoff attestation ---- */
  -- the capability vocabulary and the reserved in-person keys exist on the UAE PSP boundaries
  if (select count(*) from beau_ph.provider_capabilities where capability in ('softpos','card_present','tap_to_pay') and provider_key in ('network_international','magnati','adyen')) = 9
     and beau_ph.is_capability('softpos') and beau_ph.is_capability('tap_to_pay') and beau_ph.is_capability('card_present') and not beau_ph.is_capability('nfc_raw')
     then ok := ok + 1; else fail := fail + 1; log := log || ' [capability vocabulary]'; end if;
  -- an AED merchant enables the Magnati handoff (app name only — never a credential)
  insert into beau_ph.merchants (key, name, country, default_currency, mode) values ('ph_uae', 'UAE Test', 'AE', 'AED', 'test');
  perform beau_ph.merchant_method_set('ph_uae', 'stripe', true, null, '{}'::jsonb, '{}'::jsonb, null, 't');
  perform beau_ph.merchant_method_set('ph_uae', 'magnati', true, 'AED', '{}'::jsonb, '{"handoff_app":"SwipeX","handoff_url":"swipex://"}'::jsonb, null, 't');
  -- a customer-facing page never sees an in-person capability (initiator), even though the merchant enabled it
  j := beau_ph.eligible_methods('ph_uae', 'AE', 'AED', rt);
  if j::text not like '%magnati%' then ok := ok + 1; else fail := fail + 1; log := log || ' [customer sees softpos]'; end if;
  -- merchant-initiated: the handoff is offered (any platform — the tap happens in the PSP app), native tap_to_pay is not (placeholder)
  j := beau_ph.eligible_capabilities('ph_uae', null, 'AED', rt, 'ios_pwa', 'merchant');
  if (select count(*) from jsonb_array_elements(j) e where e ->> 'provider' = 'magnati' and e ->> 'capability' = 'softpos' and (e ->> 'handoff')::boolean and e -> 'settings' ->> 'handoff_app' = 'SwipeX') = 1
     and j::text not like '%tap_to_pay%' and j::text not like '%network_international%' then ok := ok + 1; else fail := fail + 1; log := log || ' [merchant capabilities ' || j::text || ']'; end if;
  j := beau_ph.method_matrix('ph_uae', null, 'AED', rt, 'ios_pwa', 'merchant');
  if (select c ->> 'reason' from jsonb_array_elements(j) e, jsonb_array_elements(e -> 'capabilities') c where e ->> 'provider' = 'magnati' and c ->> 'capability' = 'tap_to_pay') = 'coming_soon'
     and (select c ->> 'reason' from jsonb_array_elements(j) e, jsonb_array_elements(e -> 'capabilities') c where e ->> 'provider' = 'network_international' and c ->> 'capability' = 'softpos') = 'disabled'
     then ok := ok + 1; else fail := fail + 1; log := log || ' [capability reasons]'; end if;
  begin perform beau_ph.create_request('ph_uae', 'magnati', 'ORD-T1', 'REF-3000', 85000, 'AED', 'AE', null, '{}'::jsonb, rt, 'tap_to_pay', 'ios_app', 'merchant');
        fail := fail + 1; log := log || ' [tap_to_pay request created]'; exception when sqlstate 'P0003' then ok := ok + 1; end;
  -- the PLATFORM gate is real: make tap_to_pay hypothetically live (rolled back) — it is offered on ios_app only, never from a browser/PWA
  update beau_ph.provider_capabilities set readiness = 'available' where provider_key = 'magnati' and capability = 'tap_to_pay';
  update beau_ph.providers set readiness = 'available' where key = 'magnati';
  if beau_ph.eligible_capabilities('ph_uae', null, 'AED', '{"magnati":{"configured":true,"mode":"test"}}'::jsonb, 'web', 'merchant')::text not like '%tap_to_pay%'
     and beau_ph.eligible_capabilities('ph_uae', null, 'AED', '{"magnati":{"configured":true,"mode":"test"}}'::jsonb, 'ios_pwa', 'merchant')::text not like '%tap_to_pay%'
     and beau_ph.eligible_capabilities('ph_uae', null, 'AED', '{"magnati":{"configured":true,"mode":"test"}}'::jsonb, 'ios_app', 'merchant')::text like '%tap_to_pay%'
     and beau_ph.eligible_capabilities('ph_uae', null, 'AED', '{}'::jsonb, 'ios_app', 'merchant')::text not like '%tap_to_pay%'   -- and still needs deployed PSP credentials
     then ok := ok + 1; else fail := fail + 1; log := log || ' [platform gate]'; end if;
  update beau_ph.provider_capabilities set readiness = 'placeholder' where provider_key = 'magnati' and capability = 'tap_to_pay';
  update beau_ph.providers set readiness = 'not_configured' where key = 'magnati';
  -- handoff request: in-person, merchant-initiated, instructions carry the app + reference + amount
  j := beau_ph.create_request('ph_uae', 'magnati', 'ORD-T1', 'REF-3000', 85000, 'AED', 'AE', null, '{}'::jsonb, rt, 'softpos', 'ios_pwa', 'merchant'); r3 := (j ->> 'id')::uuid;
  if (j ->> 'status') = 'pending' and (j ->> 'channel') = 'in_person' and (j ->> 'initiated_by') = 'merchant' and (j ->> 'capability') = 'softpos' and (j ->> 'platform') = 'ios_pwa'
     and (j -> 'instructions' ->> 'handoff_app') = 'SwipeX' and (j -> 'instructions' ->> 'reference') = 'REF-3000' and (j -> 'instructions' ->> 'amount') = '85000'
     then ok := ok + 1; else fail := fail + 1; log := log || ' [handoff request ' || j::text || ']'; end if;
  -- no verified API path exists: a "provider event" for the PSP is refused as evidence, the request stays pending
  e1 := beau_ph.ingest_provider_event('magnati', 'swipex-1', 'swipex.approved', '{"claimed":"approved"}'::jsonb, jsonb_build_object('request_id', r3, 'status', 'paid', 'amount', 85000, 'currency', 'AED'));
  if (e1 ->> 'outcome') = 'rejected:provider_not_configured' and (select status from beau_ph.payment_requests where id = r3) = 'pending' then ok := ok + 1; else fail := fail + 1; log := log || ' [psp event ' || e1::text || ']'; end if;
  -- the operator must attest the app's receipt reference; then the evidence says so
  begin perform beau_ph.confirm_manual(r3, 'op@test', 85000, 'AED', null); fail := fail + 1; log := log || ' [handoff confirmed without receipt]'; exception when sqlstate '22023' then ok := ok + 1; end;
  e1 := beau_ph.confirm_manual(r3, 'op@test', 85000, 'AED', 'RRN-123456');
  if (e1 ->> 'to') = 'paid' and (e1 ->> 'capability') = 'softpos'
     and exists (select 1 from beau_ph.payment_events where id = (e1 ->> 'payment_event_id')::uuid and actor = 'operator' and provider_reference = 'RRN-123456'
                   and evidence ->> 'verification' = 'operator_attested_provider_receipt' and evidence ->> 'capability' = 'softpos')
     then ok := ok + 1; else fail := fail + 1; log := log || ' [handoff attested ' || e1::text || ']'; end if;

  /* ---- 17. HOST: Session → Collect payment → Tap to Pay (PSP app) → paid → pack/ledger updated ---- */
  insert into public.session_packs (crm_contact_id, title, total_sessions, price_amount, currency, payment_status, created_by)
    values (cA, '1-session pack', 1, 85000, 'AED', 'unpaid', 'seed') returning id into p3;
  perform set_config('request.jwt.claims', '{"role":"authenticated","email":"fin@test.local"}', true);
  execute 'set local role authenticated';
  j := public.cg_ph_collect_options(p3, 'ios_pwa');
  if jsonb_array_length(j -> 'options') = 0 and (j ->> 'amount')::int = 85000 then ok := ok + 1; else fail := fail + 1; log := log || ' [collect before setup ' || j::text || ']'; end if;
  perform public.payment_method_set(jsonb_build_object('method', 'magnati', 'enabled', true, 'handoff_app', 'SwipeX', 'handoff_url', 'swipex://', 'currency', 'AED'));
  begin perform public.payment_method_set(jsonb_build_object('method', 'magnati', 'enabled', true, 'handoff_app', 'SwipeX', 'handoff_url', 'javascript alert'));
        fail := fail + 1; log := log || ' [bad handoff url accepted]'; exception when sqlstate '22023' then ok := ok + 1; end;
  j := public.cg_ph_collect_options(p3, 'ios_pwa');
  if (select count(*) from jsonb_array_elements(j -> 'options') o where o ->> 'provider' = 'magnati' and o ->> 'capability' = 'softpos' and o -> 'settings' ->> 'handoff_app' = 'SwipeX') = 1
     and (j ->> 'reference') ~ '^CG-[0-9]{4,}$' and j::text not like '%tap_to_pay%' then ok := ok + 1; else fail := fail + 1; log := log || ' [collect options ' || j::text || ']'; end if;
  -- the receipt reference is mandatory
  begin perform public.payment_record_manual(p3, 85000, 'AED', 'magnati', null, null, 'softpos', 'ios_pwa'); fail := fail + 1; log := log || ' [psp without receipt]'; exception when sqlstate '22023' then ok := ok + 1; end;
  j := public.payment_record_manual(p3, 85000, 'AED', 'magnati', 'RRN-777', null, 'softpos', 'ios_pwa');
  execute 'reset role';
  select id into ordid from public.orders where reference = j ->> 'order';
  if (j ->> 'ok')::boolean and (j ->> 'capability') = 'softpos'
     and (select payment_status from public.session_packs where id = p3) = 'paid'
     and (select payment_source from public.session_packs where id = p3) = 'card_present'
     and (select capability from public.payments where order_id = ordid) = 'softpos'
     and (select provider from public.payments where order_id = ordid) = 'magnati'
     and beau_ph.is_reconciled((select ph_event_id from public.payments where order_id = ordid))
     and (select count(*) from public.partner_earnings where order_id = ordid) = 0
     and (select channel from beau_ph.payment_requests where id = (j ->> 'request_id')::uuid) = 'in_person'
     then ok := ok + 1; else fail := fail + 1; log := log || ' [host collect ' || j::text || ']'; end if;
  -- the client's report page still never lists an in-person capability
  perform set_config('request.jwt.claims', '{"role":"authenticated","email":"fin@test.local"}', true);
  execute 'set local role authenticated';
  tok := public.report_issue_link(p1) ->> 'token';
  execute 'reset role';
  j := public.report_view(tok, rt);
  if j::text not like '%softpos%' and j::text not like '%magnati%' then ok := ok + 1; else fail := fail + 1; log := log || ' [report lists in-person]'; end if;

  /* ---- 18. MULTI-RAIL RACE / IDEMPOTENCY: one order, Stripe + Aani ---- */
  -- (a) Aani settles first (same amount): host payment recorded once, the sibling Stripe request cancelled
  insert into public.session_packs (crm_contact_id, title, total_sessions, price_amount, currency, payment_status, created_by)
    values (cA, '5-session pack #race', 5, 120000, 'AED', 'unpaid', 'seed') returning id into p4;
  j := public.cg_ph_request_for_pack(p4, 'stripe', rt); oref4 := j -> 'order' ->> 'reference';
  perform public.attach_checkout(oref4, 'cs_race_1', 'https://checkout.example/race1', now() + interval '30 min');
  perform set_config('request.jwt.claims', '{"role":"authenticated","email":"fin@test.local"}', true);
  execute 'set local role authenticated';
  j := public.payment_record_manual(p4, 120000, 'AED', 'aani', 'AANI-RACE-1');
  execute 'reset role';
  select id into ordid from public.orders where reference = oref4;
  if (j ->> 'order') = oref4 and (j ->> 'superseded_order') is null
     and (select count(*) from public.payments where order_id = ordid) = 1
     and (select status from beau_ph.payment_requests where external_reference = oref4 and provider_key = 'stripe') = 'cancelled'
     and (select status from beau_ph.payment_requests where external_reference = oref4 and provider_key = 'aani') = 'paid'
     and (select payment_status from public.session_packs where id = p4) = 'paid'
     and (select payment_source from public.session_packs where id = p4) = 'aani'
     then ok := ok + 1; else fail := fail + 1; log := log || ' [race: aani first ' || j::text || ']'; end if;
  -- (b) a late Stripe webhook for the cancelled card request (and a re-delivery under another id)
  ev := jsonb_build_object('id', 'evt_race_1', 'type', 'checkout.session.completed', 'livemode', false,
          'data', jsonb_build_object('object', jsonb_build_object('id', 'cs_race_1', 'payment_status', 'paid', 'amount_total', 120000, 'currency', 'aed', 'payment_intent', 'pi_race_1', 'client_reference_id', oref4)));
  e1 := public.process_stripe_event(ev);
  e2 := public.process_stripe_event(ev || jsonb_build_object('id', 'evt_race_1b'));
  if (e1 ->> 'status') = 'ignored' and (e1 ->> 'note') like 'rejected:illegal_transition%' and (e2 ->> 'status') = 'ignored'
     and (select count(*) from public.payments where order_id = ordid) = 1                                                   -- no duplicate host payment
     and (select count(*) from public.partner_earnings where order_id = ordid) = 0                                           -- no partner earning (Aani money never passed through Oolala)
     and (select count(*) from beau_ph.reconciliations rc join beau_ph.payment_requests r on r.id = rc.request_id where r.external_reference = oref4) = 1
     and (select count(*) from beau_ph.payment_events pe join beau_ph.payment_requests r on r.id = pe.request_id where r.external_reference = oref4 and pe.to_status = 'paid') = 1
     and (select status from public.orders where id = ordid) = 'paid'
     and (select payment_status from public.session_packs where id = p4) = 'paid'
     and (select payment_source from public.session_packs where id = p4) = 'aani'
     and (select count(*) from public.orders where session_pack_id = p4) = 1                                                 -- pack paid exactly once
     and (select count(*) from beau_ph.provider_events where provider_key = 'stripe' and provider_event_id in ('evt_race_1','evt_race_1b') and outcome like 'rejected:illegal_transition%') = 2
     then ok := ok + 1; else fail := fail + 1; log := log || ' [race: late webhook ' || e1::text || ']'; end if;
  -- (c) reverse: Stripe settles first; a later manual confirmation must not double-pay the order
  insert into public.session_packs (crm_contact_id, title, total_sessions, price_amount, currency, payment_status, created_by)
    values (cA, '5-session pack #race2', 5, 130000, 'AED', 'unpaid', 'seed') returning id into p3;
  j := public.cg_ph_request_for_pack(p3, 'stripe', rt); oref := j -> 'order' ->> 'reference';
  perform public.attach_checkout(oref, 'cs_race_2', 'https://checkout.example/race2', now() + interval '30 min');
  e1 := public.process_stripe_event(jsonb_build_object('id', 'evt_race_2', 'type', 'checkout.session.completed', 'livemode', false,
          'data', jsonb_build_object('object', jsonb_build_object('id', 'cs_race_2', 'payment_status', 'paid', 'amount_total', 130000, 'currency', 'aed', 'payment_intent', 'pi_race_2', 'client_reference_id', oref))));
  select id into ordid from public.orders where reference = oref;
  perform set_config('request.jwt.claims', '{"role":"authenticated","email":"fin@test.local"}', true);
  execute 'set local role authenticated';
  begin perform public.payment_record_manual(p3, 130000, 'AED', 'aani', 'AANI-LATE'); fail := fail + 1; log := log || ' [race: double pay same amount]'; exception when sqlstate 'P0003' then ok := ok + 1; end;
  begin perform public.payment_record_manual(p3, 90000, 'AED', 'bank_transfer', 'BANK-LATE'); fail := fail + 1; log := log || ' [race: double pay other amount]'; exception when sqlstate 'P0003' then ok := ok + 1; end;
  execute 'reset role';
  begin perform beau_ph.create_request('coach_gari', 'aani', oref, 'CG-RACE', 130000, 'AED'); fail := fail + 1; log := log || ' [race: request on paid order]'; exception when sqlstate 'P0003' then ok := ok + 1; end;
  if (e1 ->> 'status') = 'processed'
     and (select count(*) from public.payments where order_id = ordid) = 1
     and (select count(*) from public.partner_earnings where order_id = ordid) = 1
     and (select count(*) from public.orders where session_pack_id = p3) = 1
     and (select payment_status from public.session_packs where id = p3) = 'paid'
     and (select payment_source from public.session_packs where id = p3) = 'stripe'
     and (select count(*) from beau_ph.payment_requests where external_reference = oref) = 1
     then ok := ok + 1; else fail := fail + 1; log := log || ' [race: stripe first ' || e1::text || ']'; end if;

  /* ---- 19. MULTI-TENANT ISOLATION: merchant B vs merchant A (and vs the Coach Gari host) ---- */
  insert into beau_ph.merchants (key, name, country, default_currency, mode) values ('ph_other', 'Other Host', 'ZW', 'USD', 'test');
  perform beau_ph.merchant_method_configure('ph_other', 'stripe', '{"enabled":true,"countries":["ZW"],"currencies":["USD"]}'::jsonb, 't');
  perform beau_ph.merchant_method_set('ph_other', 'bank_transfer', true, 'USD', '{"account_holder":"Other Co","iban":"ZZ99OTHER","bic":"OTHRZWHX"}'::jsonb, '{}'::jsonb, null, 't');
  -- (a) provider configuration never leaks across merchants
  if beau_ph.eligible_methods(mk, 'ZW', 'USD', rt)::text not like '%ZZ99OTHER%'
     and beau_ph.eligible_methods('ph_other', 'ZW', 'USD', rt)::text not like '%ZW00TEST%'
     and beau_ph.method_matrix('ph_other', 'AE', 'AED', rt)::text not like '%+971 50 000 0000%'
     and beau_ph.eligible_capabilities('ph_other', null, 'AED', rt, 'ios_pwa', 'merchant')::text not like '%SwipeX%'
     then ok := ok + 1; else fail := fail + 1; log := log || ' [tenant: config leak]'; end if;
  -- (b) public + external references are scoped per merchant: B may reuse A's references without collision or crossing
  jB := beau_ph.create_request('ph_other', 'bank_transfer', 'ORD-2', 'REF-2003', 7000, 'USD', 'ZW'); rB := (jB ->> 'id')::uuid;
  if rB <> r2 and (jB ->> 'status') = 'pending' and (jB -> 'instructions' ->> 'iban') = 'ZZ99OTHER'
     and jsonb_array_length(beau_ph.requests_for('ph_other', 'ORD-2')) = 1 and (beau_ph.requests_for('ph_other', 'ORD-2') -> 0 ->> 'id')::uuid = rB
     and (select count(*) from jsonb_array_elements(beau_ph.requests_for(mk, 'ORD-2')) e where (e ->> 'id')::uuid = rB) = 0
     and (select status from beau_ph.payment_requests where id = r2) = 'paid'
     then ok := ok + 1; else fail := fail + 1; log := log || ' [tenant: reference scope ' || jB::text || ']'; end if;
  -- (c) B cannot read / use / cancel / expire / confirm / reconcile A's requests
  j := beau_ph.create_request(mk, 'stripe', 'ORD-9', 'REF-2009', 3000, 'USD', 'ZW', null, '{}'::jsonb, rt); r3 := (j ->> 'id')::uuid;
  perform beau_ph.attach_attempt(r3, 'cs_a9', 'https://checkout.example/a9', now() + interval '30 min', mk);
  j := beau_ph.create_request(mk, 'bank_transfer', 'ORD-10', 'REF-2010', 8000, 'USD', 'ZW'); rA := (j ->> 'id')::uuid;
  if beau_ph.get_request(r3, 'ph_other') is null and beau_ph.request_events(r3, 'ph_other') = '[]'::jsonb
     and not beau_ph.owned_by(r3, 'ph_other') and beau_ph.owned_by(r3, mk) and beau_ph.get_request(r3, mk) is not null
     and jsonb_array_length(beau_ph.request_events(r3, mk)) = 2
     then ok := ok + 1; else fail := fail + 1; log := log || ' [tenant: read scope]'; end if;
  begin perform beau_ph.attach_attempt(r3, 'cs_hijack', 'https://x.example/h', now() + interval '10 min', 'ph_other'); fail := fail + 1; log := log || ' [tenant: B attached]'; exception when sqlstate 'P0002' then ok := ok + 1; end;
  begin perform beau_ph.cancel_request(r3, 'operator', 'opB', 'hijack', 'ph_other'); fail := fail + 1; log := log || ' [tenant: B cancelled]'; exception when sqlstate 'P0002' then ok := ok + 1; end;
  begin perform beau_ph.expire_request(r3, 'hijack', 'ph_other'); fail := fail + 1; log := log || ' [tenant: B expired]'; exception when sqlstate 'P0002' then ok := ok + 1; end;
  begin perform beau_ph.confirm_manual(rA, 'opB', 8000, 'USD', 'B-REF', null, null, 'ph_other'); fail := fail + 1; log := log || ' [tenant: B confirmed]'; exception when sqlstate 'P0002' then ok := ok + 1; end;
  begin perform beau_ph.mark_reconciled(ph_ev, 'other-ledger', null, 'ph_other'); fail := fail + 1; log := log || ' [tenant: B reconciled]'; exception when sqlstate 'P0002' then ok := ok + 1; end;
  if (select status from beau_ph.payment_requests where id = r3) = 'requires_action'
     and (select status from beau_ph.payment_requests where id = rA) = 'pending'
     and (select count(*) from beau_ph.payment_attempts where request_id = r3) = 1
     and (select count(*) from beau_ph.reconciliations where payment_event_id = ph_ev) = 1
     then ok := ok + 1; else fail := fail + 1; log := log || ' [tenant: A untouched]'; end if;
  -- (d) host adapters cannot cross-reconcile: a Stripe event whose Checkout Session belongs to merchant B's request,
  --     addressed (client_reference_id) to a pending Coach Gari order — Coach Gari must not pay its order with B's money
  jB := beau_ph.create_request('ph_other', 'stripe', 'ORD-B1', 'REF-B1', 4500, 'USD', 'ZW', null, '{}'::jsonb, rt); rB := (jB ->> 'id')::uuid;
  perform beau_ph.attach_attempt(rB, 'cs_other_1', 'https://checkout.example/o1', now() + interval '30 min', 'ph_other');
  insert into public.session_packs (crm_contact_id, title, total_sessions, price_amount, currency, payment_status, created_by)
    values (cA, '1-session pack #x', 1, 4500, 'AED', 'unpaid', 'seed') returning id into p3;
  j := public.cg_ph_request_for_pack(p3, 'stripe', rt); oref := j -> 'order' ->> 'reference';
  e1 := public.process_stripe_event(jsonb_build_object('id', 'evt_x1', 'type', 'checkout.session.completed', 'livemode', false,
          'data', jsonb_build_object('object', jsonb_build_object('id', 'cs_other_1', 'payment_status', 'paid', 'amount_total', 4500, 'currency', 'usd', 'payment_intent', 'pi_other_1', 'client_reference_id', oref))));
  if (e1 ->> 'status') = 'ignored' and (e1 ->> 'note') = 'foreign_merchant'
     and (select status from beau_ph.payment_requests where id = rB) = 'paid'                 -- B's own truth is intact; B's host reconciles it
     and not exists (select 1 from beau_ph.reconciliations where request_id = rB)
     and (select status from public.orders where reference = oref) = 'pending_payment'
     and not exists (select 1 from public.payments p join public.orders o on o.id = p.order_id where o.reference = oref)
     and (select payment_status from public.session_packs where id = p3) = 'unpaid'
     and exists (select 1 from public.webhook_events where event_id = 'evt_x1' and status = 'ignored' and note = 'beau_ph foreign_merchant')
     then ok := ok + 1; else fail := fail + 1; log := log || ' [tenant: cross-host ' || e1::text || ']'; end if;
  -- (e) the core is unreachable for an application user: no execute, deny-all RLS
  perform set_config('request.jwt.claims', '{"role":"authenticated","email":"fin@test.local"}', true);
  execute 'set local role authenticated';
  begin perform beau_ph.get_request(r3); fail := fail + 1; log := log || ' [tenant: authenticated called core]'; exception when insufficient_privilege then ok := ok + 1; end;
  begin select count(*) into nB from beau_ph.payment_requests; if nB = 0 then ok := ok + 1; else fail := fail + 1; log := log || ' [tenant: authenticated read core]'; end if;
  exception when insufficient_privilege then ok := ok + 1; end;
  execute 'reset role';

  /* ---- 20. PAYMENT MODE: test and live never cross (both directions) ---- */
  -- a LIVE merchant: a test-mode runtime is not eligible; a live runtime is; a test-mode event on a live request is refused
  update beau_ph.merchants set mode = 'live' where key = mk;
  j := beau_ph.method_matrix(mk, 'ZW', 'USD', rt);
  if (select e ->> 'reason' from jsonb_array_elements(j) e where e ->> 'provider' = 'stripe') = 'mode_mismatch'
     and beau_ph.eligible_methods(mk, 'ZW', 'USD', rt)::text not like '%"stripe"%'
     and beau_ph.eligible_methods(mk, 'ZW', 'USD', '{"stripe":{"configured":true,"mode":"live"}}'::jsonb)::text like '%"stripe"%'
     and beau_ph.eligible_methods(mk, 'ZW', 'USD', '{"stripe":{"configured":false,"mode":"live","reason":"key_mode_mismatch"}}'::jsonb)::text not like '%"stripe"%'
     then ok := ok + 1; else fail := fail + 1; log := log || ' [mode: live merchant eligibility ' || j::text || ']'; end if;
  begin perform beau_ph.create_request(mk, 'stripe', 'ORD-M1', 'REF-M1', 900, 'USD', 'ZW', null, '{}'::jsonb, rt); fail := fail + 1; log := log || ' [mode: test runtime request on live merchant]'; exception when sqlstate 'P0003' then ok := ok + 1; end;
  j := beau_ph.create_request(mk, 'stripe', 'ORD-M1', 'REF-M1', 900, 'USD', 'ZW', null, '{}'::jsonb, '{"stripe":{"configured":true,"mode":"live"}}'::jsonb); rA := (j ->> 'id')::uuid;
  perform beau_ph.attach_attempt(rA, 'cs_live_1', 'https://checkout.example/l1', now() + interval '30 min', mk);
  e1 := beau_ph.ingest_stripe_event(jsonb_build_object('id', 'evt_m1', 'type', 'checkout.session.completed', 'livemode', false,
          'data', jsonb_build_object('object', jsonb_build_object('id', 'cs_live_1', 'payment_status', 'paid', 'amount_total', 900, 'currency', 'usd', 'payment_intent', 'pi_m1'))));
  if (e1 ->> 'outcome') = 'rejected:mode_mismatch' and (select status from beau_ph.payment_requests where id = rA) = 'requires_action'
     and exists (select 1 from beau_ph.provider_events where provider_key = 'stripe' and provider_event_id = 'evt_m1' and outcome = 'rejected:mode_mismatch')
     then ok := ok + 1; else fail := fail + 1; log := log || ' [mode: test event on live merchant ' || e1::text || ']'; end if;
  e1 := beau_ph.ingest_stripe_event(jsonb_build_object('id', 'evt_m2', 'type', 'checkout.session.completed', 'livemode', true,
          'data', jsonb_build_object('object', jsonb_build_object('id', 'cs_live_1', 'payment_status', 'paid', 'amount_total', 900, 'currency', 'usd', 'payment_intent', 'pi_m1'))));
  if (e1 ->> 'outcome') = 'normalized' and (e1 ->> 'to') = 'paid' then ok := ok + 1; else fail := fail + 1; log := log || ' [mode: live event on live merchant ' || e1::text || ']'; end if;
  update beau_ph.merchants set mode = 'test' where key = mk;
  -- the production host merchant is intended LIVE: a test runtime offers no card on its report page; a live runtime does
  update beau_ph.merchants set mode = 'live' where key = 'coach_gari';
  insert into public.session_packs (crm_contact_id, title, total_sessions, price_amount, currency, payment_status, created_by)
    values (cA, '5-session pack #live', 5, 50000, 'AED', 'unpaid', 'seed') returning id into p4;
  perform set_config('request.jwt.claims', '{"role":"authenticated","email":"fin@test.local"}', true);
  execute 'set local role authenticated';
  tok := public.report_issue_link(p4) ->> 'token';
  execute 'reset role';
  if public.report_view(tok, rt)::text not like '%"stripe"%'
     and public.report_view(tok, '{"stripe":{"configured":true,"mode":"live"}}'::jsonb)::text like '%"stripe"%'
     and public.report_view(tok, '{}'::jsonb)::text not like '%"stripe"%'
     then ok := ok + 1; else fail := fail + 1; log := log || ' [mode: host report page]'; end if;
  begin perform public.cg_ph_request_for_pack(p4, 'stripe', rt); fail := fail + 1; log := log || ' [mode: host test request on live merchant]'; exception when sqlstate 'P0003' then ok := ok + 1; end;
  j := public.cg_ph_request_for_pack(p4, 'stripe', '{"stripe":{"configured":true,"mode":"live"}}'::jsonb); oref4 := j -> 'order' ->> 'reference';
  perform public.attach_checkout(oref4, 'cs_live_h1', 'https://checkout.example/lh1', now() + interval '30 min');   -- declares the merchant's own (live) mode
  e1 := public.process_stripe_event(jsonb_build_object('id', 'evt_mh1', 'type', 'checkout.session.completed', 'livemode', false,
          'data', jsonb_build_object('object', jsonb_build_object('id', 'cs_live_h1', 'payment_status', 'paid', 'amount_total', 50000, 'currency', 'aed', 'payment_intent', 'pi_mh1', 'client_reference_id', oref4))));
  e2 := public.process_stripe_event(jsonb_build_object('id', 'evt_mh2', 'type', 'checkout.session.completed', 'livemode', true,
          'data', jsonb_build_object('object', jsonb_build_object('id', 'cs_live_h1', 'payment_status', 'paid', 'amount_total', 50000, 'currency', 'aed', 'payment_intent', 'pi_mh1', 'client_reference_id', oref4))));
  if (e1 ->> 'status') = 'ignored' and (e1 ->> 'note') = 'rejected:mode_mismatch'
     and (e2 ->> 'status') = 'processed' and (select payment_status from public.session_packs where id = p4) = 'paid'
     and (select count(*) from public.payments p join public.orders o on o.id = p.order_id where o.reference = oref4) = 1
     then ok := ok + 1; else fail := fail + 1; log := log || ' [mode: host live webhook ' || e1::text || ' ' || e2::text || ']'; end if;
  update beau_ph.merchants set mode = 'test' where key = 'coach_gari';

  -- §21 EMBEDDED CHECKOUT: an attempt has a provider reference but no redirect URL; attaching never pays; the
  -- report token scopes exactly one pack; a completed session is paid only through the verified webhook path,
  -- once, whatever the browser says; a paid request cannot be re-initialised.
  update beau_ph.merchants set mode = 'live' where key = 'coach_gari';
  insert into public.session_packs (crm_contact_id, title, total_sessions, price_amount, currency, payment_status, created_by)
    values (cA, '1-session pack #embedded', 1, 1000, 'AED', 'unpaid', 'seed') returning id into p4;
  j := public.cg_ph_request_for_pack(p4, 'stripe', '{"stripe":{"configured":true,"mode":"live","embedded":true}}'::jsonb); oref4 := j -> 'order' ->> 'reference';
  if (j -> 'request' ->> 'amount') = '1000' and (j -> 'request' ->> 'currency') = 'AED' and (j -> 'order' ->> 'gross_amount') = '1000'
     then ok := ok + 1; else fail := fail + 1; log := log || ' [emb: amount is the pack snapshot ' || j::text || ']'; end if;
  perform public.attach_checkout(oref4, 'cs_live_emb1', null, now() + interval '30 min');
  if (select count(*) from beau_ph.payment_attempts a join beau_ph.payment_requests r on r.id = a.request_id
       where r.external_reference = oref4 and a.provider_reference = 'cs_live_emb1' and a.redirect_url is null and a.status = 'open') = 1
     and (select status from beau_ph.payment_requests where external_reference = oref4) in ('created','pending','requires_action')
     and (select payment_status from public.session_packs where id = p4) = 'unpaid'
     and (select status from public.orders where reference = oref4) = 'pending_payment'
     then ok := ok + 1; else fail := fail + 1; log := log || ' [emb: attempt without redirect url, nothing paid]'; end if;
  -- the browser clicking again (or a "completed" callback) can only open another attempt, never pay
  perform public.attach_checkout(oref4, 'cs_live_emb2', null, now() + interval '30 min');
  if (select count(*) from beau_ph.payment_attempts a join beau_ph.payment_requests r on r.id = a.request_id where r.external_reference = oref4 and a.status = 'open') = 1
     and (select count(*) from beau_ph.payment_attempts a join beau_ph.payment_requests r on r.id = a.request_id where r.external_reference = oref4) = 2
     and (select payment_status from public.session_packs where id = p4) = 'unpaid'
     and (select count(*) from public.payments p join public.orders o on o.id = p.order_id where o.reference = oref4) = 0
     then ok := ok + 1; else fail := fail + 1; log := log || ' [emb: second attempt supersedes, still unpaid]'; end if;
  -- the report token resolves to exactly its own pack; an unknown token resolves to nothing
  perform set_config('request.jwt.claims', '{"role":"authenticated","email":"fin@test.local"}', true);
  execute 'set local role authenticated';
  tok := public.report_issue_link(p4) ->> 'token';
  execute 'reset role';
  if public.report_pack_id(tok) = p4 and public.report_pack_id(tok) <> p1
     then ok := ok + 1; else fail := fail + 1; log := log || ' [emb: token scoped to its pack]'; end if;
  begin perform public.report_pack_id(repeat('0', 64)); fail := fail + 1; log := log || ' [emb: unknown token resolved]'; exception when sqlstate 'P0002' or sqlstate 'P0003' then ok := ok + 1; end;
  -- completion arrives only as a verified webhook: once paid, a second event for the same session (new event id) adds nothing
  e1 := public.process_stripe_event(jsonb_build_object('id', 'evt_emb1', 'type', 'checkout.session.completed', 'livemode', true,
          'data', jsonb_build_object('object', jsonb_build_object('id', 'cs_live_emb2', 'payment_status', 'paid', 'amount_total', 1000, 'currency', 'aed', 'payment_intent', 'pi_emb1', 'client_reference_id', oref4))));
  e2 := public.process_stripe_event(jsonb_build_object('id', 'evt_emb2', 'type', 'checkout.session.completed', 'livemode', true,
          'data', jsonb_build_object('object', jsonb_build_object('id', 'cs_live_emb2', 'payment_status', 'paid', 'amount_total', 1000, 'currency', 'aed', 'payment_intent', 'pi_emb1', 'client_reference_id', oref4))));
  if (e1 ->> 'status') = 'processed' and (select payment_status from public.session_packs where id = p4) = 'paid'
     and (select count(*) from public.payments p join public.orders o on o.id = p.order_id where o.reference = oref4) = 1
     and (select count(*) from public.partner_earnings pe join public.orders o on o.id = pe.order_id where o.reference = oref4) <= 1
     and (select status from beau_ph.payment_requests where external_reference = oref4) = 'paid'
     then ok := ok + 1; else fail := fail + 1; log := log || ' [emb: webhook pays once ' || e1::text || ' ' || e2::text || ']'; end if;
  -- a paid request cannot be re-initialised by the embedded client
  begin perform public.attach_checkout(oref4, 'cs_live_emb3', null, now() + interval '30 min'); fail := fail + 1; log := log || ' [emb: attach after paid]'; exception when sqlstate 'P0003' then ok := ok + 1; end;
  update beau_ph.merchants set mode = 'test' where key = 'coach_gari';


  /* ---- 22. RAIL CONFIGURATION: persisted, bounded by provider capability, explicit or not eligible ---- */
  j := beau_ph.merchant_method_configure(mk, 'stripe', '{"countries":["AE","ZW","KE"],"currencies":["AED","USD","KES"]}'::jsonb, 'cfg@test');
  if (j -> 'countries')::text = '["AE", "KE", "ZW"]' and (j -> 'currencies')::text = '["AED", "KES", "USD"]'
     and (beau_ph.merchant_method_get(mk, 'stripe') -> 'method' -> 'currencies')::text = '["AED", "KES", "USD"]' then ok := ok + 1; else fail := fail + 1; log := log || ' [cfg: countries/currencies persist ' || j::text || ']'; end if;
  -- a merchant can never broaden a provider (Aani = AE / AED only)
  begin perform beau_ph.merchant_method_configure(mk, 'aani', '{"countries":["AE","ZW"]}'::jsonb, 't'); fail := fail + 1; log := log || ' [cfg: broadened countries]'; exception when sqlstate 'P0003' then ok := ok + 1; end;
  begin perform beau_ph.merchant_method_configure(mk, 'aani', '{"currencies":["USD"]}'::jsonb, 't'); fail := fail + 1; log := log || ' [cfg: broadened currencies]'; exception when sqlstate 'P0003' then ok := ok + 1; end;
  begin perform beau_ph.merchant_method_configure(mk, 'aani', '{"capabilities":["online_checkout"]}'::jsonb, 't'); fail := fail + 1; log := log || ' [cfg: capability not offered]'; exception when sqlstate '22023' then ok := ok + 1; end;
  -- unsupported country / currency → ineligible with the reason; a disabled rail → ineligible
  if (select e ->> 'reason' from jsonb_array_elements(beau_ph.method_matrix(mk, 'FR', 'USD', rt)) e where e ->> 'provider' = 'stripe') = 'country'
     and (select e ->> 'reason' from jsonb_array_elements(beau_ph.method_matrix(mk, 'AE', 'GBP', rt)) e where e ->> 'provider' = 'stripe') = 'currency'
     and beau_ph.eligible_methods(mk, 'KE', 'KES', rt)::text like '%"stripe"%' then ok := ok + 1; else fail := fail + 1; log := log || ' [cfg: country/currency reasons]'; end if;
  perform beau_ph.merchant_method_configure(mk, 'stripe', '{"enabled":false}'::jsonb, 't');
  if beau_ph.eligible_methods(mk, 'AE', 'AED', rt)::text not like '%"stripe"%'
     and (select e ->> 'reason' from jsonb_array_elements(beau_ph.method_matrix(mk, 'AE', 'AED', rt)) e where e ->> 'provider' = 'stripe') = 'disabled' then ok := ok + 1; else fail := fail + 1; log := log || ' [cfg: disabled rail eligible]'; end if;
  perform beau_ph.merchant_method_configure(mk, 'stripe', '{"enabled":true}'::jsonb, 't');
  -- no countries = needs configuration, never "everywhere"
  perform beau_ph.merchant_method_configure(mk, 'stripe', '{"countries":null}'::jsonb, 't');
  if (select e ->> 'reason' from jsonb_array_elements(beau_ph.method_matrix(mk, 'AE', 'AED', rt)) e where e ->> 'provider' = 'stripe') = 'needs_configuration'
     and (select e ->> 'health' from jsonb_array_elements(beau_ph.method_matrix(mk, 'AE', 'AED', rt)) e where e ->> 'provider' = 'stripe') = 'needs_configuration'
     and beau_ph.eligible_methods(mk, 'AE', 'AED', rt)::text not like '%"stripe"%' then ok := ok + 1; else fail := fail + 1; log := log || ' [cfg: null countries read as any]'; end if;
  perform beau_ph.merchant_method_configure(mk, 'stripe', '{"countries":["AE","ZW","KE"]}'::jsonb, 't');
  -- intents: a rail may support or block a payment type
  perform beau_ph.merchant_method_configure(mk, 'stripe', '{"intents":["service","package"]}'::jsonb, 't');
  if (select e ->> 'reason' from jsonb_array_elements(beau_ph.method_matrix(mk, 'AE', 'AED', rt, null, 'customer', 'support')) e where e ->> 'provider' = 'stripe') = 'intent'
     and beau_ph.eligible_methods(mk, 'AE', 'AED', rt, null, 'customer', 'package')::text like '%"stripe"%' then ok := ok + 1; else fail := fail + 1; log := log || ' [cfg: intent dimension]'; end if;
  begin perform beau_ph.create_request(mk, 'stripe', 'ORD-INT', 'REF-INT', 1000, 'USD', 'ZW', null, '{}'::jsonb, rt, null, null, null, 'support'); fail := fail + 1; log := log || ' [cfg: blocked intent request]'; exception when sqlstate 'P0003' then ok := ok + 1; end;
  perform beau_ph.merchant_method_configure(mk, 'stripe', '{"intents":null}'::jsonb, 't');
  -- limits per currency
  perform beau_ph.merchant_method_configure(mk, 'stripe', '{"limits":{"USD":{"min":1000,"max":500000}}}'::jsonb, 't');
  begin perform beau_ph.create_request(mk, 'stripe', 'ORD-LIM', 'REF-LIM', 500, 'USD', 'ZW', null, '{}'::jsonb, rt); fail := fail + 1; log := log || ' [cfg: below minimum]'; exception when sqlstate 'P0003' then ok := ok + 1; end;
  begin perform beau_ph.create_request(mk, 'stripe', 'ORD-LIM', 'REF-LIM', 900000, 'USD', 'ZW', null, '{}'::jsonb, rt); fail := fail + 1; log := log || ' [cfg: above maximum]'; exception when sqlstate 'P0003' then ok := ok + 1; end;
  perform beau_ph.merchant_method_configure(mk, 'stripe', '{"limits":{}}'::jsonb, 't');
  -- "Remove" keeps history: a rail with requests is deactivated + unlisted, its requests untouched; an unused one is deleted
  select count(*) into nA from beau_ph.payment_requests r join beau_ph.merchants m on m.id = r.merchant_id where m.key = mk and r.provider_key = 'stripe';
  j := beau_ph.merchant_method_remove(mk, 'stripe', 'rm@test');
  if j ->> 'removed' = 'unlisted' and (j ->> 'history')::int = nA and nA > 0
     and (select count(*) from beau_ph.payment_requests r join beau_ph.merchants m on m.id = r.merchant_id where m.key = mk and r.provider_key = 'stripe') = nA
     and exists (select 1 from beau_ph.merchant_methods mm join beau_ph.merchants m on m.id = mm.merchant_id where m.key = mk and mm.provider_key = 'stripe' and not mm.enabled and not mm.listed)
     and beau_ph.merchant_methods_summary(mk)::text not like '%"stripe"%' and beau_ph.eligible_methods(mk, 'AE', 'AED', rt)::text not like '%"stripe"%'
     then ok := ok + 1; else fail := fail + 1; log := log || ' [cfg: remove with history ' || j::text || ']'; end if;
  perform beau_ph.merchant_method_configure(mk, 'stripe', '{"enabled":true,"listed":true}'::jsonb, 't');
  j := beau_ph.merchant_method_remove(mk, 'ozow', 'rm@test');
  if j ->> 'removed' = 'deleted' and not exists (select 1 from beau_ph.merchant_methods mm join beau_ph.merchants m on m.id = mm.merchant_id where m.key = mk and mm.provider_key = 'ozow') then ok := ok + 1; else fail := fail + 1; log := log || ' [cfg: delete unused]'; end if;
  -- settlement destinations are distinct from methods; a rail maps a currency to one destination of that currency
  j := beau_ph.settlement_destination_set(mk, '{"key":"usd_main","label":"USD account","kind":"bank_account","currency":"USD","details":{"bank":"Test Bank","account_hint":"•••• 1234"}}'::jsonb, 'dest@test');
  perform beau_ph.merchant_method_configure(mk, 'bank_transfer', '{"settlement":{"USD":"usd_main"}}'::jsonb, 't');
  if (beau_ph.merchant_method_get(mk, 'bank_transfer') -> 'method' -> 'settlement' ->> 'USD') = 'usd_main'
     and (beau_ph.settlement_destinations_list(mk) -> 0 -> 'used_by')::text like '%bank_transfer%' then ok := ok + 1; else fail := fail + 1; log := log || ' [cfg: settlement mapping]'; end if;
  begin perform beau_ph.merchant_method_configure(mk, 'bank_transfer', '{"settlement":{"AED":"usd_main"}}'::jsonb, 't'); fail := fail + 1; log := log || ' [cfg: settlement currency mismatch]'; exception when sqlstate '22023' then ok := ok + 1; end;
  j := beau_ph.settlement_destination_remove(mk, 'usd_main', 't');
  if j ->> 'removed' = 'deactivated' and exists (select 1 from beau_ph.settlement_destinations d join beau_ph.merchants m on m.id = d.merchant_id where m.key = mk and d.key = 'usd_main' and not d.active) then ok := ok + 1; else fail := fail + 1; log := log || ' [cfg: mapped destination deleted]'; end if;
  begin perform beau_ph.settlement_destination_set(mk, '{"key":"bad","label":"x","currency":"USD","details":{"api_key":"sk_test_abcdefghijklmnop"}}'::jsonb, 't'); fail := fail + 1; log := log || ' [cfg: secret in destination]'; exception when sqlstate '22023' then ok := ok + 1; end;
  -- audit: field-level rows with actor, before and after; nothing secret-shaped in the audit output
  j := beau_ph.config_audit_list(mk, 200);
  if exists (select 1 from jsonb_array_elements(j) a where a ->> 'area' = 'merchant_method' and a ->> 'entity' = 'stripe' and a ->> 'field' = 'currencies' and a ->> 'actor' = 'cfg@test' and (a -> 'new_value')::text like '%KES%')
     and exists (select 1 from jsonb_array_elements(j) a where a ->> 'field' = 'enabled' and a ->> 'actor' = 'rm@test')
     and exists (select 1 from jsonb_array_elements(j) a where a ->> 'area' = 'settlement_destination' and a ->> 'entity' = 'usd_main')
     and beau_ph.no_secret_keys(j) and beau_ph.no_secret_keys(beau_ph.rails_overview(mk)) and beau_ph.no_secret_keys(beau_ph.merchant_method_get(mk, 'stripe'))
     then ok := ok + 1; else fail := fail + 1; log := log || ' [cfg: audit trail]'; end if;
  -- the rails overview derives everything from persisted state (no literal "any")
  j := beau_ph.rails_overview(mk);
  if jsonb_array_length(j -> 'rails') >= 11
     and (select r -> 'merchant' ->> 'health' from jsonb_array_elements(j -> 'rails') r where r ->> 'provider' = 'stripe') = 'configured'
     and (select r -> 'merchant' -> 'currencies' from jsonb_array_elements(j -> 'rails') r where r ->> 'provider' = 'stripe')::text like '%KES%'
     and (select r -> 'merchant' from jsonb_array_elements(j -> 'rails') r where r ->> 'provider' = 'ozow') = 'null'::jsonb
     and (select jsonb_array_length(r -> 'secrets') from jsonb_array_elements(j -> 'rails') r where r ->> 'provider' = 'stripe') = 3
     and j::text not like '%"countries": "any"%' and j::text not like '%"currencies": "any"%' then ok := ok + 1; else fail := fail + 1; log := log || ' [cfg: rails overview]'; end if;

  /* ---- 23. BEAU FX: source recorded, freshness, fail closed, immutable expiring quotes, server-side amounts, isolation ---- */
  select id into mid from beau_ph.merchants where key = mk;
  delete from beau_ph.fx_quotes where merchant_id = mid;   -- suite hygiene inside the rolled-back transaction
  j := beau_ph.fx_ingest_rate('USD', 1.10, current_date, 'test_src');
  perform beau_ph.fx_ingest_rate('AED', 1.10 * 3.6725, current_date, 'test_src(USD)');
  perform beau_ph.fx_ingest_rate('GBP', 0.85, current_date, 'test_src');
  if (j ->> 'accepted')::boolean and (select source from beau_ph.fx_rate_on('USD', current_date)) = 'test_src'
     and (beau_ph.fx_currency_status('USD') ->> 'freshness') = 'fresh' and (beau_ph.fx_currency_status('USD') ->> 'source') = 'frankfurter' then ok := ok + 1; else fail := fail + 1; log := log || ' [fx: source + fresh ' || beau_ph.fx_currency_status('USD')::text || ']'; end if;
  -- anomaly rejection keeps the last valid rate
  j := beau_ph.fx_ingest_rate('USD', 1.60, current_date, 'test_src');
  if not (j ->> 'accepted')::boolean and (j ->> 'reason') like 'variation_%' and (select rate from beau_ph.fx_rate_on('USD', current_date)) = 1.10
     and beau_ph.fx_validate_rate(-1, null) = 'non_positive' and beau_ph.fx_validate_rate(null, 1) = 'not_numeric' and beau_ph.fx_validate_rate(1.15, 1.10) is null then ok := ok + 1; else fail := fail + 1; log := log || ' [fx: anomaly ' || j::text || ']'; end if;
  -- freshness categories from the last successful fetch
  update beau_ph.fx_rates set fetched_at = now() - interval '50 hours' where quote_currency = 'GBP';
  if (beau_ph.fx_currency_status('GBP') ->> 'freshness') = 'acceptable' and beau_ph.fx_freshness(80) = 'stale' and beau_ph.fx_freshness(null) = 'missing' and beau_ph.fx_freshness(36) = 'fresh' then ok := ok + 1; else fail := fail + 1; log := log || ' [fx: freshness]'; end if;
  -- FX off for the merchant → no conversion at all
  begin perform beau_ph.fx_quote(mk, 10000, 'USD', 'AED', true); fail := fail + 1; log := log || ' [fx: disabled merchant quoted]'; exception when sqlstate 'P0003' then ok := ok + 1; end;
  perform beau_ph.merchant_fx_set(mk, '{"enabled":true,"adjustment_bps":0,"quote_ttl_minutes":15}'::jsonb, 'fx@test');
  -- the amount is derived server-side through the EUR pivot: USD 100.00 → AED 367.25
  j := beau_ph.fx_quote(mk, 10000, 'USD', 'AED', true);
  if (j ->> 'payment_amount')::int = 36725 and (j ->> 'preview')::boolean and round((j ->> 'reference_rate')::numeric, 4) = 3.6725 and j ->> 'freshness' = 'fresh' then ok := ok + 1; else fail := fail + 1; log := log || ' [fx: preview ' || j::text || ']'; end if;
  if (beau_ph.fx_quote(mk, 10000, 'USD', 'USD', true) ->> 'same_currency')::boolean then ok := ok + 1; else fail := fail + 1; log := log || ' [fx: same currency]'; end if;
  -- a merchant adjustment is a separate component, never hidden in the reference rate
  perform beau_ph.merchant_fx_set(mk, '{"adjustment_bps":100}'::jsonb, 'fx@test');
  j := beau_ph.fx_quote(mk, 10000, 'USD', 'AED', true);
  if (j ->> 'payment_amount')::int = 37092 and round((j ->> 'reference_rate')::numeric, 4) = 3.6725 and round((j ->> 'customer_rate')::numeric, 4) = 3.7092 and (j ->> 'merchant_adjustment_bps')::int = 100 then ok := ok + 1; else fail := fail + 1; log := log || ' [fx: adjustment ' || j::text || ']'; end if;
  perform beau_ph.merchant_fx_set(mk, '{"adjustment_bps":0}'::jsonb, 'fx@test');
  -- stale or missing rate: fail closed
  update beau_ph.fx_rates set fetched_at = now() - interval '80 hours' where quote_currency = 'AED';
  begin perform beau_ph.fx_quote(mk, 10000, 'USD', 'AED', true); fail := fail + 1; log := log || ' [fx: stale converted]'; exception when sqlstate 'P0003' then ok := ok + 1; end;
  update beau_ph.fx_rates set fetched_at = now() where quote_currency = 'AED';
  begin perform beau_ph.fx_quote(mk, 10000, 'USD', 'KES', true); fail := fail + 1; log := log || ' [fx: missing converted]'; exception when sqlstate 'P0003' then ok := ok + 1; end;
  perform beau_ph.fx_currency_set('CHF', '{"enabled":true}'::jsonb, 'fx@test');
  begin perform beau_ph.fx_quote(mk, 10000, 'USD', 'CHF', true); fail := fail + 1; log := log || ' [fx: no rate converted]'; exception when sqlstate 'P0003' then ok := ok + 1; end;
  -- a real quote is an immutable row with an expiry
  q1 := beau_ph.fx_quote(mk, 10000, 'USD', 'AED', false); qid := (q1 ->> 'id')::uuid;
  if q1 ->> 'status' = 'active' and (q1 ->> 'expires_at')::timestamptz between now() + interval '14 minutes' and now() + interval '16 minutes' and (q1 ->> 'payment_amount')::int = 36725 then ok := ok + 1; else fail := fail + 1; log := log || ' [fx: quote row ' || q1::text || ']'; end if;
  begin update beau_ph.fx_quotes set payment_amount = 1 where id = qid; fail := fail + 1; log := log || ' [fx: quote amount mutated]'; exception when sqlstate 'P0003' then ok := ok + 1; end;
  begin update beau_ph.fx_quotes set expires_at = now() + interval '1 day' where id = qid; fail := fail + 1; log := log || ' [fx: quote expiry mutated]'; exception when sqlstate 'P0003' then ok := ok + 1; end;
  begin delete from beau_ph.fx_quotes where id = qid; fail := fail + 1; log := log || ' [fx: quote deleted]'; exception when sqlstate 'P0003' then ok := ok + 1; end;
  -- the browser cannot override the rate or the amount: the request must match the quote exactly, and another currency needs a quote
  begin perform beau_ph.create_request(mk, 'stripe', 'ORD-FX', 'REF-FX', 36726, 'AED', 'AE', null, '{}'::jsonb, rt, null, null, null, 'package', 10000, 'USD', qid); fail := fail + 1; log := log || ' [fx: amount override]'; exception when sqlstate 'P0003' then ok := ok + 1; end;
  begin perform beau_ph.create_request(mk, 'stripe', 'ORD-FX', 'REF-FX', 36725, 'AED', 'AE', null, '{}'::jsonb, rt, null, null, null, 'package', 10000, 'USD', null); fail := fail + 1; log := log || ' [fx: conversion without quote]'; exception when sqlstate 'P0003' then ok := ok + 1; end;
  j := beau_ph.create_request(mk, 'stripe', 'ORD-FX', 'REF-FX', 36725, 'AED', 'AE', null, '{}'::jsonb, rt, null, null, null, 'package', 10000, 'USD', qid);
  if j ->> 'currency' = 'AED' and (j ->> 'amount')::int = 36725 and j ->> 'pricing_currency' = 'USD' and (j ->> 'pricing_amount')::int = 10000 and (j ->> 'fx_quote_id')::uuid = qid and j ->> 'intent' = 'package'
     and (select status from beau_ph.fx_quotes where id = qid) = 'consumed' and (select request_id from beau_ph.fx_quotes where id = qid) = (j ->> 'id')::uuid then ok := ok + 1; else fail := fail + 1; log := log || ' [fx: request carries the quote ' || j::text || ']'; end if;
  -- a quote is consumed exactly once; an expired quote must be replaced by a new one
  begin perform beau_ph.fx_quote_consume(qid, mid, gen_random_uuid(), 36725, 'AED', 10000, 'USD'); fail := fail + 1; log := log || ' [fx: quote consumed twice]'; exception when sqlstate 'P0003' then ok := ok + 1; end;
  q2 := beau_ph.fx_quote(mk, 10000, 'USD', 'AED', false);
  update beau_ph.fx_quotes set status = 'expired' where id = (q2 ->> 'id')::uuid;
  begin perform beau_ph.fx_quote_consume((q2 ->> 'id')::uuid, mid, gen_random_uuid(), 36725, 'AED', 10000, 'USD'); fail := fail + 1; log := log || ' [fx: expired quote consumed]'; exception when sqlstate 'P0003' then ok := ok + 1; end;
  q2 := beau_ph.fx_quote(mk, 10000, 'USD', 'AED', false);
  if (q2 ->> 'id')::uuid <> qid and q2 ->> 'status' = 'active' then ok := ok + 1; else fail := fail + 1; log := log || ' [fx: replacement quote]'; end if;
  -- merchant isolation: another merchant cannot consume this merchant's quote
  begin perform beau_ph.fx_quote_consume((q2 ->> 'id')::uuid, (select id from beau_ph.merchants where key = 'coach_gari'), gen_random_uuid(), 36725, 'AED', 10000, 'USD'); fail := fail + 1; log := log || ' [fx: foreign merchant consumed]'; exception when sqlstate 'P0003' then ok := ok + 1; end;
  -- settings and currency configuration are audited
  j := beau_ph.config_audit_list(mk, 200);
  if exists (select 1 from jsonb_array_elements(j) a where a ->> 'area' = 'merchant_fx' and a ->> 'field' = 'enabled' and a ->> 'actor' = 'fx@test')
     and exists (select 1 from jsonb_array_elements(j) a where a ->> 'area' = 'fx_currency' and a ->> 'entity' = 'CHF' and a ->> 'field' = 'enabled') then ok := ok + 1; else fail := fail + 1; log := log || ' [fx: audit]'; end if;
  -- a refresh is observable: the run row exists and waits for the collector (no response inside this transaction)
  perform beau_ph.fx_refresh_start('fx@test');
  perform beau_ph.fx_refresh_collect();
  if exists (select 1 from beau_ph.fx_refresh_runs where requested_by = 'fx@test' and status = 'requested' and http ? 'frankfurter') then ok := ok + 1; else fail := fail + 1; log := log || ' [fx: refresh run]'; end if;
  j := beau_ph.fx_overview(mk);
  if (j -> 'health' ->> 'in_progress')::boolean and (j -> 'settings' ->> 'enabled')::boolean and jsonb_array_length(j -> 'currencies') >= 10 and beau_ph.no_secret_keys(j) then ok := ok + 1; else fail := fail + 1; log := log || ' [fx: overview]'; end if;

  /* ---- 24. HOST: a client pays a USD package in AED — quote, request, webhook, ledger in the collected currency ---- */
  update beau_ph.merchants set mode = 'test' where key = 'coach_gari';
  perform beau_ph.merchant_fx_set('coach_gari', '{"enabled":true,"adjustment_bps":0}'::jsonb, 'fx@test');
  insert into public.session_packs (crm_contact_id, title, total_sessions, price_amount, currency, payment_status, created_by)
    values (cA, 'USD pack paid in AED', 5, 10000, 'USD', 'unpaid', 'seed') returning id into p5;
  perform set_config('request.jwt.claims', '{"role":"authenticated","email":"fin@test.local"}', true);
  execute 'set local role authenticated';
  tok5 := public.report_issue_link(p5) ->> 'token';
  execute 'reset role';
  j5 := public.report_view(tok5, rt, 'AED');
  if j5 -> 'payment' ->> 'currency' = 'AED' and (j5 -> 'payment' ->> 'amount')::int = 36725 and j5 -> 'payment' ->> 'pricing_currency' = 'USD'
     and (select count(*) from jsonb_array_elements(j5 -> 'payment' -> 'options') o where o ->> 'currency' in ('USD','AED')) = 2
     and j5 -> 'payment' -> 'fx' ->> 'freshness' = 'fresh' and j5::text like '%"stripe"%' then ok := ok + 1; else fail := fail + 1; log := log || ' [host fx: report options ' || (j5 -> 'payment')::text || ']'; end if;
  j5 := public.report_view(tok5, rt, 'XXX');
  if j5 -> 'payment' ->> 'currency' = 'USD' and (j5 -> 'payment' ->> 'amount')::int = 10000 and (j5 -> 'payment' -> 'fx') = 'null'::jsonb then ok := ok + 1; else fail := fail + 1; log := log || ' [host fx: unknown currency falls back]'; end if;
  j5 := public.cg_ph_request_for_pack(p5, 'stripe', rt, 'AED');
  if j5 -> 'request' ->> 'currency' = 'AED' and (j5 -> 'request' ->> 'amount')::int = 36725 and j5 -> 'request' ->> 'pricing_currency' = 'USD' and (j5 -> 'request' ->> 'fx_quote_id') is not null
     and j5 -> 'order' ->> 'currency' = 'USD' then ok := ok + 1; else fail := fail + 1; log := log || ' [host fx: request ' || (j5 -> 'request')::text || ']'; end if;
  oref4 := j5 -> 'order' ->> 'reference';
  -- switching currency supersedes the live request; the same currency reuses it (locked amount)
  jB := public.cg_ph_request_for_pack(p5, 'stripe', rt, 'AED');
  if jB -> 'request' ->> 'id' = j5 -> 'request' ->> 'id' then ok := ok + 1; else fail := fail + 1; log := log || ' [host fx: same currency reused]'; end if;
  jB := public.cg_ph_request_for_pack(p5, 'stripe', rt, null);
  if jB -> 'request' ->> 'currency' = 'USD' and (jB -> 'request' ->> 'amount')::int = 10000 and (select status from beau_ph.payment_requests where id = (j5 -> 'request' ->> 'id')::uuid) = 'cancelled' then ok := ok + 1; else fail := fail + 1; log := log || ' [host fx: currency switch supersedes]'; end if;
  j5 := public.cg_ph_request_for_pack(p5, 'stripe', rt, 'AED');
  perform public.attach_checkout(oref4, 'cs_fx_1', null, now() + interval '30 min');
  e1 := public.process_stripe_event(jsonb_build_object('id', 'evt_fx_1', 'type', 'checkout.session.completed', 'livemode', false,
          'data', jsonb_build_object('object', jsonb_build_object('id', 'cs_fx_1', 'payment_status', 'paid', 'amount_total', 36725, 'currency', 'aed', 'payment_intent', 'pi_fx1', 'client_reference_id', oref4)),
          '_enrich', jsonb_build_object('charge_id', 'ch_fx', 'balance_transaction_id', 'txn_fx', 'fee_amount', 1200)));
  if (e1 ->> 'status') = 'processed' and (select payment_status from public.session_packs where id = p5) = 'paid'
     and (select p.currency from public.payments p join public.orders o on o.id = p.order_id where o.reference = oref4) = 'AED'
     and (select pe.currency from public.partner_earnings pe join public.orders o on o.id = pe.order_id where o.reference = oref4) = 'AED'
     and (select pe.gross_amount from public.partner_earnings pe join public.orders o on o.id = pe.order_id where o.reference = oref4) = 36725
     and (select status from beau_ph.fx_quotes where id = (j5 -> 'request' ->> 'fx_quote_id')::uuid) = 'consumed' then ok := ok + 1; else fail := fail + 1; log := log || ' [host fx: paid in AED, ledger in AED ' || e1::text || ']'; end if;
  -- a wrong amount (the pricing amount, or anything else) is refused by BEAU PH: the request is the authority
  e2 := public.process_stripe_event(jsonb_build_object('id', 'evt_fx_2', 'type', 'checkout.session.completed', 'livemode', false,
          'data', jsonb_build_object('object', jsonb_build_object('id', 'cs_fx_1', 'payment_status', 'paid', 'amount_total', 10000, 'currency', 'usd', 'payment_intent', 'pi_fx2', 'client_reference_id', oref4))));
  if (e2 ->> 'status') in ('ignored','processed') and (select count(*) from public.payments p join public.orders o on o.id = p.order_id where o.reference = oref4) = 1 then ok := ok + 1; else fail := fail + 1; log := log || ' [host fx: second amount accepted ' || e2::text || ']'; end if;
  perform set_config('request.jwt.claims', '{"role":"authenticated","email":"fin@test.local"}', true);
  execute 'set local role authenticated';
  j5 := public.finance_transactions(50);
  if exists (select 1 from jsonb_array_elements(j5) t where t ->> 'reference' = oref4 and t ->> 'currency' = 'AED' and (t ->> 'amount')::int = 36725 and (t ->> 'fx')::boolean and t ->> 'pricing_currency' = 'USD' and t ->> 'type' = 'package' and t ->> 'status' = 'paid')
     and (public.finance_transaction_detail(oref4) -> 'requests' -> 0 -> 'fx_quote' ->> 'status') = 'consumed'
     and public.finance_transaction_detail(oref4)::text not like '%SECRET-NOTE%' then ok := ok + 1; else fail := fail + 1; log := log || ' [host fx: transactions list]'; end if;
  execute 'reset role';
  perform beau_ph.merchant_fx_set('coach_gari', '{"enabled":false}'::jsonb, 'fx@test');

  /* ---- 25. cash is a rail: manual, in person, operator-confirmed, market-scoped ---- */
  j := beau_ph.rails_overview(mk);
  if exists (select 1 from jsonb_array_elements(j -> 'rails') r where r ->> 'provider' = 'cash' and r ->> 'kind' = 'manual' and r ->> 'confirmation' = 'operator' and r ->> 'readiness' = 'available' and (r -> 'merchant') = 'null'::jsonb) then ok := ok + 1; else fail := fail + 1; log := log || ' [cash: catalogue]'; end if;
  if beau_ph.eligible_methods(mk, 'ZW', 'USD', rt)::text not like '%"cash"%' then ok := ok + 1; else fail := fail + 1; log := log || ' [cash: offered unconfigured]'; end if;
  perform beau_ph.merchant_method_configure(mk, 'cash', '{"enabled":true,"listed":true,"currency":"USD","countries":["ZW"],"currencies":["USD"],"instructions":{"instructions":"Bring cash to the session."}}'::jsonb, 't');
  j := beau_ph.eligible_methods(mk, 'ZW', 'USD', rt);
  if exists (select 1 from jsonb_array_elements(j) e where e ->> 'provider' = 'cash' and e ->> 'capability' = 'cash' and e -> 'instructions' ->> 'instructions' = 'Bring cash to the session.') then ok := ok + 1; else fail := fail + 1; log := log || ' [cash: eligible]'; end if;
  if beau_ph.eligible_methods(mk, 'AE', 'USD', rt)::text not like '%"cash"%' and beau_ph.eligible_methods(mk, 'ZW', 'AED', rt)::text not like '%"cash"%' then ok := ok + 1; else fail := fail + 1; log := log || ' [cash: market scope]'; end if;
  if exists (select 1 from jsonb_array_elements(beau_ph.eligible_capabilities(mk, 'ZW', 'USD', rt, null, 'merchant')) c where c ->> 'provider' = 'cash' and (c ->> 'in_person')::boolean) then ok := ok + 1; else fail := fail + 1; log := log || ' [cash: collect option]'; end if;
  j := beau_ph.create_request(mk, 'cash', 'ORD-CASH', 'REF-2099', 4000, 'USD', 'ZW', null, '{}'::jsonb, rt, 'cash'); rC := (j ->> 'id')::uuid;
  if j ->> 'status' = 'pending' and j ->> 'capability' = 'cash' and j ->> 'channel' = 'in_person' then ok := ok + 1; else fail := fail + 1; log := log || ' [cash: request]'; end if;
  e1 := beau_ph.ingest_provider_event('cash', 'fake-cash-1', 'cash.received', '{"claimed":"paid"}'::jsonb, jsonb_build_object('request_id', rC, 'status', 'paid', 'amount', 4000, 'currency', 'USD'));
  if (e1 ->> 'outcome') = 'rejected:manual_provider_requires_operator' and (select status from beau_ph.payment_requests where id = rC) = 'pending' then ok := ok + 1; else fail := fail + 1; log := log || ' [cash: self-confirm]'; end if;
  begin perform beau_ph.confirm_manual(rC, 'op@test', 3900, 'USD'); fail := fail + 1; log := log || ' [cash: wrong amount]'; exception when sqlstate 'P0003' then ok := ok + 1; end;
  e1 := beau_ph.confirm_manual(rC, 'op@test', 4000, 'USD', null, now(), 'counted at the court');
  if (e1 ->> 'to') = 'paid' and exists (select 1 from beau_ph.payment_events where id = (e1 ->> 'payment_event_id')::uuid and actor = 'operator' and actor_id = 'op@test') then ok := ok + 1; else fail := fail + 1; log := log || ' [cash: operator confirm]'; end if;
  begin perform beau_ph.confirm_manual(rC, 'op@test', 4000, 'USD'); fail := fail + 1; log := log || ' [cash: confirmed twice]'; exception when sqlstate 'P0003' then ok := ok + 1; end;

  raise exception 'BEAU_PH_TESTS ok=% fail=% %', ok, fail, log;
end $$;

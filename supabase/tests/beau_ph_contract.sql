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
begin
  insert into beau_ph.merchants (key, name, country, default_currency, mode) values (mk, 'Contract Test', 'ZW', 'USD', 'test');
  perform beau_ph.merchant_method_set(mk, 'stripe', true, null, '{}'::jsonb, '{}'::jsonb, null, 't');
  perform beau_ph.merchant_method_set(mk, 'aani', true, 'AED', '{"display_value":"+971 50 000 0000"}'::jsonb, '{}'::jsonb, null, 't');
  perform beau_ph.merchant_method_set(mk, 'bank_transfer', true, 'USD', '{"account_holder":"Test Co","iban":"ZW00TEST","bic":"TESTZWHX"}'::jsonb, '{}'::jsonb, null, 't');
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
  begin perform beau_ph.merchant_method_set(mk, 'stripe', true, null, '{"webhook_secret":"whsec_abcdefghijklmnop"}'::jsonb, '{}'::jsonb, null, 't'); fail := fail + 1; log := log || ' [secret accepted in instructions]'; exception when check_violation then ok := ok + 1; end;
  begin perform beau_ph.merchant_method_set(mk, 'stripe', true, null, '{}'::jsonb, '{"api_key":"sk_test_abcdefghijklmnop"}'::jsonb, null, 't'); fail := fail + 1; log := log || ' [secret accepted in settings]'; exception when check_violation then ok := ok + 1; end;
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
  perform public.payment_method_set(jsonb_build_object('method', 'bank_transfer', 'enabled', true, 'account_holder', 'Coach Gari', 'iban', 'AE00TEST', 'bic', 'TESTAEAD', 'currency', 'AED'));
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
  perform beau_ph.merchant_method_set('ph_other', 'stripe', true, null, '{}'::jsonb, '{}'::jsonb, null, 't');
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

  raise exception 'BEAU_PH_TESTS ok=% fail=% %', ok, fail, log;
end $$;

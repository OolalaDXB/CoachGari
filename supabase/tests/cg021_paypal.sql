-- =====================================================================
-- CG-021 — PayPal reaching the ledger, Wise staying a manual rail, and the
-- peer-to-peer rail staying off a commercial request.
-- One rolled-back transaction. Proves: a verified capture marks the order paid
-- once and records the real PayPal fee; a replay changes nothing; a wrong
-- amount, a ghost order and an event type that must not move money are all
-- refused but recorded; the amount helper never guesses a currency's exponent;
-- and the ingest doors belong to service_role alone.
-- Run by scripts/db-tests.sh; nothing persists (final RAISE).
-- =====================================================================
do $$
declare
  ok int := 0; fail int := 0; log text := '';
  oid uuid; j jsonb; n int; ev jsonb; mid uuid; cap jsonb;
  rt jsonb := jsonb_build_object('paypal', jsonb_build_object('configured', true, 'mode', 'live'));
begin
  /* ---- 1. the amount helper ---- */
  if beau_ph.paypal_minor('45.00','AED') = 4500 then ok := ok + 1; else fail := fail + 1; log := log || ' [aed]'; end if;
  if beau_ph.paypal_minor('5000','JPY') = 5000 then ok := ok + 1; else fail := fail + 1; log := log || ' [jpy-divided]'; end if;
  if beau_ph.paypal_minor('45.000','KWD') is null then ok := ok + 1; else fail := fail + 1; log := log || ' [three-decimal-rounded]'; end if;
  if beau_ph.paypal_minor('forty-five','AED') is null then ok := ok + 1; else fail := fail + 1; log := log || ' [words-accepted]'; end if;
  if beau_ph.currency_exponent('jpy') = 0 and beau_ph.currency_exponent('AED') = 2 and beau_ph.currency_exponent('KWD') = 3
    then ok := ok + 1; else fail := fail + 1; log := log || ' [exponent]'; end if;

  /* ---- 2. the normalizer speaks the hub's vocabulary ---- */
  j := beau_ph.normalize_paypal_event(jsonb_build_object(
    'id','WH-N1','event_type','PAYMENT.CAPTURE.COMPLETED','beau_ph_livemode', false,
    'resource', jsonb_build_object('id','CAP-N1','invoice_id','CG-9999-3',
      'custom_id','11111111-1111-4111-8111-111111111111',
      'amount', jsonb_build_object('currency_code','AED','value','45.00'),
      'supplementary_data', jsonb_build_object('related_ids', jsonb_build_object('order_id','ORD-N1')))));
  if (j ->> 'status') = 'paid' and (j ->> 'amount')::int = 4500 and (j ->> 'external_reference') = 'CG-9999'
     and (j ->> 'provider_reference') = 'ORD-N1' and (j ->> 'payment_reference') = 'CAP-N1'
     and (j ->> 'request_id') = '11111111-1111-4111-8111-111111111111'
    then ok := ok + 1; else fail := fail + 1; log := log || ' [normalize:' || j::text || ']'; end if;

  -- an event we do not handle is ignored explicitly, so it stays visible
  j := beau_ph.normalize_paypal_event(jsonb_build_object('id','WH-N2','event_type','BILLING.SUBSCRIPTION.CREATED','resource', jsonb_build_object('id','X')));
  if (j ->> 'ignore') like 'unhandled:%' then ok := ok + 1; else fail := fail + 1; log := log || ' [unhandled-not-ignored]'; end if;
  j := beau_ph.normalize_paypal_event(jsonb_build_object('id','WH-N3','event_type','PAYMENT.CAPTURE.COMPLETED'));
  if (j ->> 'ignore') = 'no_resource' then ok := ok + 1; else fail := fail + 1; log := log || ' [no-resource]'; end if;

  /* ---- 3. a capture reaching the ledger ---- */
  insert into public.orders (reference, customer_name, customer_contact, currency, gross_amount, status, order_reason)
  values ('CG-PPTEST', 'Test Payer', 'pp@test.local', 'AED', 4500, 'pending_payment', 'support')
  returning id into oid;

  ev := jsonb_build_object(
    'id','WH-PP-1','event_type','PAYMENT.CAPTURE.COMPLETED','beau_ph_livemode', false,
    'resource', jsonb_build_object(
      'id','CAP-PP-1','invoice_id','CG-PPTEST-1',
      'amount', jsonb_build_object('currency_code','AED','value','45.00'),
      'seller_receivable_breakdown', jsonb_build_object(
        'paypal_fee', jsonb_build_object('currency_code','AED','value','1.80'),
        'net_amount', jsonb_build_object('currency_code','AED','value','43.20')),
      'supplementary_data', jsonb_build_object('related_ids', jsonb_build_object('order_id','ORD-PP-1'))));

  j := public.process_paypal_event(ev);
  if (j ->> 'status') = 'processed' and (j ->> 'order') = 'CG-PPTEST'
    then ok := ok + 1; else fail := fail + 1; log := log || ' [not-processed:' || coalesce(j::text,'null') || ']'; end if;
  if (select status from public.orders where id = oid) = 'paid'
    then ok := ok + 1; else fail := fail + 1; log := log || ' [order-not-paid]'; end if;
  -- the fee PayPal actually charged, not a guess
  if (select count(*) from public.payments where order_id = oid and provider = 'paypal'
        and provider_payment_intent_id = 'CAP-PP-1' and amount = 4500 and currency = 'AED'
        and fee_amount = 180 and fee_known) = 1
    then ok := ok + 1; else fail := fail + 1; log := log || ' [payment-row]'; end if;

  /* ---- 4. a replay changes nothing ---- */
  j := public.process_paypal_event(ev);
  if (j ->> 'duplicate')::boolean then ok := ok + 1; else fail := fail + 1; log := log || ' [replay-not-duplicate]'; end if;
  select count(*) into n from public.payments where order_id = oid;
  if n = 1 then ok := ok + 1; else fail := fail + 1; log := log || ' [double-payment=' || n || ']'; end if;

  /* ---- 5. what it refuses ---- */
  j := public.process_paypal_event(jsonb_build_object(
    'id','WH-PP-2','event_type','PAYMENT.CAPTURE.COMPLETED','beau_ph_livemode', false,
    'resource', jsonb_build_object('id','CAP-PP-2','invoice_id','CG-PPTEST-2',
      'amount', jsonb_build_object('currency_code','AED','value','5.00'))));
  if (j ->> 'note') = 'amount mismatch' then ok := ok + 1; else fail := fail + 1; log := log || ' [wrong-amount-accepted]'; end if;

  j := public.process_paypal_event(jsonb_build_object(
    'id','WH-PP-3','event_type','PAYMENT.CAPTURE.COMPLETED',
    'resource', jsonb_build_object('id','CAP-PP-3','invoice_id','CG-NOPE-1',
      'amount', jsonb_build_object('currency_code','AED','value','45.00'))));
  if (j ->> 'note') = 'unknown order' then ok := ok + 1; else fail := fail + 1; log := log || ' [ghost-order-accepted]'; end if;

  -- an approval is not a payment: recorded, never carried to the ledger
  j := public.process_paypal_event(jsonb_build_object(
    'id','WH-PP-4','event_type','CHECKOUT.ORDER.APPROVED',
    'resource', jsonb_build_object('id','ORD-PP-1')));
  if (j ->> 'status') = 'ignored' then ok := ok + 1; else fail := fail + 1; log := log || ' [approved-reached-ledger]'; end if;
  if (select count(*) from public.webhook_events where event_id = 'WH-PP-4') = 1
    then ok := ok + 1; else fail := fail + 1; log := log || ' [event-not-recorded]'; end if;

  /* ---- 6. the rails are registered as what they are ---- */
  if (select kind = 'online' and confirmation = 'provider_event' from beau_ph.providers where key = 'paypal')
    then ok := ok + 1; else fail := fail + 1; log := log || ' [paypal-kind]'; end if;
  if (select kind = 'manual' and confirmation = 'operator' from beau_ph.providers where key = 'wise')
    then ok := ok + 1; else fail := fail + 1; log := log || ' [wise-kind]'; end if;
  -- Wise can never confirm itself: no capability of it is provider-confirmed
  if not exists (select 1 from beau_ph.provider_capabilities where provider_key = 'wise' and confirmation = 'provider_event')
    then ok := ok + 1; else fail := fail + 1; log := log || ' [wise-self-confirms]'; end if;

  /* ---- 7. the doors ---- */
  if not exists (
    select 1 from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
     where ((ns.nspname = 'beau_ph' and p.proname = 'process_paypal_event')
         or (ns.nspname = 'public'  and p.proname = 'process_paypal_event'))
       and (has_function_privilege('authenticated', p.oid, 'execute') or has_function_privilege('anon', p.oid, 'execute')))
    then ok := ok + 1; else fail := fail + 1; log := log || ' [ingest-reachable]'; end if;

  /* ---- 8. the peer-to-peer rail exists, and only for a non-commercial intent ----
     BEAU PH is meant to be extracted and resold, so it has to express a personal
     transfer. What must never happen is that shape being offered for a sale. */
  select id into mid from beau_ph.merchants where key = 'coach_gari';
  insert into beau_ph.merchant_methods (merchant_id, provider_key, enabled, listed, countries, currencies, intents, capabilities, instructions)
  values (mid, 'paypal', true, true, '{AE,FR,NG}', '{AED,EUR}', '{package,personal}',
          '{online_checkout,manual_instructions,p2p_transfer}',
          jsonb_build_object('paypal_business_email','pay@example.com'))
  on conflict (merchant_id, provider_key) do update
    set enabled = true, listed = true, countries = excluded.countries, currencies = excluded.currencies,
        intents = excluded.intents, capabilities = excluded.capabilities;

  -- a COMMERCIAL request: checkout offered, peer-to-peer refused on the intent
  j := beau_ph.method_matrix('coach_gari','AE','AED', rt, null, 'customer', 'package');
  select e into cap from jsonb_array_elements(j) e where e ->> 'provider' = 'paypal';
  if (cap ->> 'eligible')::boolean and (cap ->> 'capability') = 'online_checkout'
    then ok := ok + 1; else fail := fail + 1; log := log || ' [commercial-checkout]'; end if;
  if (select (c ->> 'eligible')::boolean = false and (c ->> 'reason') = 'intent'
        from jsonb_array_elements(cap -> 'capabilities') c where c ->> 'capability' = 'p2p_transfer')
    then ok := ok + 1; else fail := fail + 1; log := log || ' [p2p-offered-on-a-sale]'; end if;

  -- a PERSONAL request: the mirror image
  j := beau_ph.method_matrix('coach_gari','AE','AED', rt, null, 'customer', 'personal');
  select e into cap from jsonb_array_elements(j) e where e ->> 'provider' = 'paypal';
  if (cap ->> 'eligible')::boolean and (cap ->> 'capability') = 'p2p_transfer' and (cap ->> 'confirmation') = 'operator'
    then ok := ok + 1; else fail := fail + 1; log := log || ' [personal-p2p]'; end if;
  if (select (c ->> 'eligible')::boolean = false and (c ->> 'reason') = 'intent'
        from jsonb_array_elements(cap -> 'capabilities') c where c ->> 'capability' = 'online_checkout')
    then ok := ok + 1; else fail := fail + 1; log := log || ' [checkout-offered-on-a-personal-transfer]'; end if;

  -- no opt-in on the capability: never offered, whatever the intent
  update beau_ph.merchant_methods set capabilities = '{online_checkout,manual_instructions}'
   where merchant_id = mid and provider_key = 'paypal';
  j := beau_ph.method_matrix('coach_gari','AE','AED', rt, null, 'customer', 'personal');
  select e into cap from jsonb_array_elements(j) e where e ->> 'provider' = 'paypal';
  if (select (c ->> 'reason') = 'disabled' from jsonb_array_elements(cap -> 'capabilities') c where c ->> 'capability' = 'p2p_transfer')
    then ok := ok + 1; else fail := fail + 1; log := log || ' [p2p-without-optin]'; end if;

  -- no opt-in on the personal intent: same
  update beau_ph.merchant_methods set capabilities = '{online_checkout,manual_instructions,p2p_transfer}', intents = '{package}'
   where merchant_id = mid and provider_key = 'paypal';
  j := beau_ph.method_matrix('coach_gari','AE','AED', rt, null, 'customer', 'personal');
  select e into cap from jsonb_array_elements(j) e where e ->> 'provider' = 'paypal';
  if (cap ->> 'eligible')::boolean = false and (cap ->> 'reason') = 'intent'
    then ok := ok + 1; else fail := fail + 1; log := log || ' [personal-intent-without-optin]'; end if;

  if beau_ph.is_capability('p2p_transfer') and beau_ph.is_intent('personal')
    then ok := ok + 1; else fail := fail + 1; log := log || ' [vocabulary]'; end if;
  if not beau_ph.is_intent('friends_and_family') then ok := ok + 1; else fail := fail + 1; log := log || ' [made-up-intent]'; end if;

  raise exception 'CG021_TESTS ok=% fail=% %', ok, fail, case when log = '' then '' else '—' || log end;
end $$;

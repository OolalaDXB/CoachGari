-- =====================================================================
-- BEAU PH — Coach Gari goes LIVE on Stripe (mode gate, both directions)
--
-- Deployment side (Edge, beau-ph/providers/stripe/adapter.ts): PAYMENTS_MODE
-- = test | live must match the key's mode; unset → everything refused.
-- Database side (this migration):
--   * the merchant's intended mode becomes 'live' (eligibility already
--     refuses a runtime whose mode differs from the merchant's: mode_mismatch);
--   * ingest_provider_event refuses evidence whose livemode does not match
--     the merchant's mode in BOTH directions (a test event can no longer
--     touch a live merchant; a live event still cannot touch a test one);
--   * attach_checkout no longer hardcodes a test runtime — it declares the
--     merchant's own mode (the Edge only creates a Checkout Session after the
--     request passed eligibility with the real runtime).
-- Merchant identity unchanged: Oolala's Stripe account, Coach Gari as host.
-- No secret is stored or referenced here. Forward migration only.
-- =====================================================================

-- ---------- 1. intended mode ----------
update beau_ph.merchants set mode = 'live', updated_at = now() where key = 'coach_gari';

update beau_ph.providers
   set notes = 'Hosted Checkout; a payment is confirmed only by a signature-verified webhook. Mode follows PAYMENTS_MODE (test | live) and must match the merchant mode.'
 where key = 'stripe';
update beau_ph.provider_capabilities
   set notes = 'Hosted Checkout; confirmed by a signature-verified webhook. Mode follows PAYMENTS_MODE.'
 where provider_key = 'stripe' and capability = 'online_checkout';

-- ---------- 2. core: symmetric livemode guard ----------
create or replace function beau_ph.ingest_provider_event(p_provider text, p_provider_event_id text, p_event_type text, p_payload jsonb, p_normalized jsonb)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare pv beau_ph.providers%rowtype; pe beau_ph.provider_events%rowtype; pe_id uuid; r beau_ph.payment_requests%rowtype; m beau_ph.merchants%rowtype;
  cap beau_ph.provider_capabilities%rowtype;
  ev beau_ph.payment_events%rowtype; v_to text; v_amount int; v_currency text; v_outcome text; existing_ev uuid; v_live boolean;
begin
  select * into pv from beau_ph.providers where key = p_provider;
  if not found then raise exception 'unknown provider' using errcode = 'P0002'; end if;
  if coalesce(p_provider_event_id, '') = '' or coalesce(p_event_type, '') = '' then raise exception 'malformed event' using errcode = '22023'; end if;

  insert into beau_ph.provider_events (provider_key, provider_event_id, event_type, payload)
  values (p_provider, p_provider_event_id, p_event_type, coalesce(p_payload, '{}'::jsonb))
  on conflict (provider_key, provider_event_id) do nothing returning id into pe_id;
  if pe_id is null then
    select * into pe from beau_ph.provider_events where provider_key = p_provider and provider_event_id = p_provider_event_id;
    select id into existing_ev from beau_ph.payment_events where provider_event_id = pe.id;
    return jsonb_build_object('ok', true, 'duplicate', true, 'outcome', pe.outcome, 'provider_event_id', pe.id,
                              'request_id', pe.request_id, 'payment_event_id', existing_ev);
  end if;

  if pv.confirmation <> 'provider_event' then
    v_outcome := 'rejected:' || case when pv.kind = 'manual' then 'manual_provider_requires_operator' else 'provider_cannot_confirm' end;
  elsif pv.readiness <> 'available' then
    v_outcome := 'rejected:provider_' || pv.readiness;
  elsif p_normalized ? 'ignore' then
    v_outcome := 'ignored:' || (p_normalized ->> 'ignore');
  end if;
  if v_outcome is not null then
    update beau_ph.provider_events set outcome = v_outcome, processed_at = now() where id = pe_id;
    return jsonb_build_object('ok', false, 'duplicate', false, 'outcome', v_outcome, 'provider_event_id', pe_id);
  end if;

  if (p_normalized ->> 'request_id') is not null then
    select * into r from beau_ph.payment_requests where id = (p_normalized ->> 'request_id')::uuid and provider_key = p_provider;
  end if;
  if r.id is null and (p_normalized ->> 'provider_reference') is not null then
    select * into r from beau_ph.payment_requests where provider_key = p_provider and provider_reference = p_normalized ->> 'provider_reference';
  end if;
  if r.id is null and (p_normalized ->> 'payment_reference') is not null then
    select * into r from beau_ph.payment_requests where provider_key = p_provider and payment_reference = p_normalized ->> 'payment_reference';
  end if;
  if r.id is null and (p_normalized ->> 'external_reference') is not null then
    select pr.* into r from beau_ph.payment_requests pr
      join beau_ph.merchants mm on mm.id = pr.merchant_id
     where pr.provider_key = p_provider and pr.external_reference = p_normalized ->> 'external_reference'
       and (p_normalized ->> 'merchant' is null or mm.key = p_normalized ->> 'merchant')
     order by case when pr.status in ('created','pending','requires_action') then 0 else 1 end, pr.created_at desc limit 1;
  end if;
  if r.id is null then
    update beau_ph.provider_events set outcome = 'no_request', processed_at = now() where id = pe_id;
    return jsonb_build_object('ok', false, 'duplicate', false, 'outcome', 'no_request', 'provider_event_id', pe_id);
  end if;
  select * into m from beau_ph.merchants where id = r.merchant_id;
  select * into cap from beau_ph.provider_capabilities where provider_key = r.provider_key and capability = r.capability;

  v_to := p_normalized ->> 'status'; v_amount := (p_normalized ->> 'amount')::int; v_currency := upper(p_normalized ->> 'currency');
  v_live := (p_normalized -> 'evidence' ->> 'livemode')::boolean;      -- null when the provider carries no mode (manual rails)
  if cap.capability is not null and cap.confirmation <> 'provider_event' then
    v_outcome := 'rejected:capability_requires_operator';
  elsif cap.capability is not null and cap.readiness <> 'available' then
    v_outcome := 'rejected:capability_' || cap.readiness;
  elsif not exists (select 1 from beau_ph.merchant_methods where merchant_id = r.merchant_id and provider_key = p_provider and enabled) then
    v_outcome := 'rejected:provider_disabled';
  elsif v_live is not null and v_live <> (m.mode = 'live') then
    v_outcome := 'rejected:mode_mismatch';                                -- both directions: test↔live never cross
  elsif v_to = 'paid' and (v_amount is null or v_amount <> r.amount or v_currency is null or v_currency <> r.currency) then
    v_outcome := 'rejected:amount_mismatch';
  elsif v_to = 'paid' and r.status in ('paid','refunded') then
    v_outcome := 'ignored:already_paid';
  elsif v_to = 'refunded' and coalesce((p_normalized ->> 'refund_amount')::int, r.amount) < r.amount then
    v_to := 'evidence';
  end if;
  if v_outcome is not null then
    update beau_ph.provider_events set request_id = r.id, outcome = v_outcome, processed_at = now() where id = pe_id;
    return jsonb_build_object('ok', false, 'duplicate', false, 'outcome', v_outcome, 'provider_event_id', pe_id, 'request_id', r.id,
                              'status', r.status, 'external_reference', r.external_reference, 'public_reference', r.public_reference, 'merchant', m.key);
  end if;
  if v_to = 'evidence' or v_to is null then v_to := r.status; end if;
  if not beau_ph.transition_allowed(r.status, v_to) then
    v_outcome := 'rejected:illegal_transition:' || r.status || '->' || v_to;
    update beau_ph.provider_events set request_id = r.id, outcome = v_outcome, processed_at = now() where id = pe_id;
    return jsonb_build_object('ok', false, 'duplicate', false, 'outcome', v_outcome, 'provider_event_id', pe_id, 'request_id', r.id, 'status', r.status);
  end if;

  ev := beau_ph.record_event(r.id, v_to, 'provider', null, pe_id, v_amount, v_currency, p_normalized ->> 'provider_status',
                             p_normalized ->> 'provider_reference', p_normalized ->> 'payment_reference', coalesce(p_normalized -> 'evidence', '{}'::jsonb));
  v_outcome := case when ev.from_status = ev.to_status then 'evidence' else 'normalized' end;
  update beau_ph.provider_events set request_id = r.id, outcome = v_outcome, processed_at = now() where id = pe_id;
  return jsonb_build_object('ok', true, 'duplicate', false, 'outcome', v_outcome, 'provider_event_id', pe_id, 'request_id', r.id,
                            'payment_event_id', ev.id, 'from', ev.from_status, 'to', ev.to_status,
                            'external_reference', r.external_reference, 'public_reference', r.public_reference, 'merchant', m.key,
                            'amount', r.amount, 'currency', r.currency);
end $$;
revoke all on function beau_ph.ingest_provider_event(text, text, text, jsonb, jsonb) from public, anon, authenticated;
grant execute on function beau_ph.ingest_provider_event(text, text, text, jsonb, jsonb) to service_role;

-- ---------- 3. host: attach_checkout declares the merchant's own mode ----------
create or replace function public.attach_checkout(p_order_reference text, p_session_id text, p_url text, p_expires_at timestamptz)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare o public.orders%rowtype; req jsonb; v_mode text;
begin
  update public.orders
     set stripe_checkout_session_id = p_session_id, checkout_url = p_url, checkout_expires_at = p_expires_at,
         checkout_attempts = checkout_attempts + 1
   where reference = p_order_reference and status = 'pending_payment'
   returning * into o;
  if not found then raise exception 'order not pending' using errcode = 'P0003'; end if;
  update public.bookings set status = 'pending_payment', hold_expires_at = p_expires_at
   where id = o.booking_id and status in ('hold','pending_payment');
  select mode into v_mode from beau_ph.merchants where key = 'coach_gari';
  -- a Checkout Session exists ⇒ the Edge created it with a key of the deployment's mode, after the request passed eligibility
  req := public.cg_ph_request_for_order(o, 'stripe', jsonb_build_object('stripe', jsonb_build_object('configured', true, 'mode', coalesce(v_mode, 'test'))), true);
  perform beau_ph.attach_attempt((req ->> 'id')::uuid, p_session_id, p_url, p_expires_at, 'coach_gari');
  return public.order_to_json(o);
end $$;

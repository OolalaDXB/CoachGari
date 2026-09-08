-- =====================================================================
-- BEAU PH — TENANT SCOPE GUARD + host double-pay guard (V0 merge gate)
--
-- Multi-tenant isolation review finding: the request-addressed core
-- functions (confirm / cancel / expire / attach / reconcile / read) were
-- keyed by the request uuid alone. They are reachable only by service_role
-- and by the host's definer functions, but nothing in the core itself
-- stopped a host adapter from acting on ANOTHER merchant's request if it
-- ever learned its id (or received a provider event that resolved to it).
--
-- Fix (forward only, no behaviour change for well-behaved callers):
--   * every request-addressed core function takes an optional merchant key;
--     when given, a request of another merchant is "not found" (P0002) —
--     never revealed, never acted on;
--   * beau_ph.owned_by(request, merchant) for hosts that need the check
--     before touching their own ledger;
--   * the Coach Gari host adapter always passes 'coach_gari', and its
--     Stripe webhook path refuses to reconcile an event whose BEAU PH
--     request belongs to another merchant (evidence kept, ledger untouched);
--   * host race guard: a receipt cannot be recorded against a pack that is
--     already paid (Stripe settled first → a later manual confirmation must
--     not double-pay the order).
-- =====================================================================

-- ---------- 1. core: ownership helper ----------
create or replace function beau_ph.owned_by(p_request_id uuid, p_merchant_key text)
returns boolean language sql stable security definer set search_path = '' as $$
  select p_merchant_key is null
      or exists (select 1 from beau_ph.payment_requests r join beau_ph.merchants m on m.id = r.merchant_id
                  where r.id = p_request_id and m.key = p_merchant_key)
$$;

-- ---------- 2. core: request-addressed functions gain p_merchant_key ----------
drop function if exists beau_ph.confirm_manual(uuid, text, int, text, text, timestamptz, text);
create or replace function beau_ph.confirm_manual(p_request_id uuid, p_operator text, p_amount int, p_currency text,
                                                  p_reference text default null, p_paid_at timestamptz default null, p_note text default null,
                                                  p_merchant_key text default null)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare r beau_ph.payment_requests%rowtype; pv beau_ph.providers%rowtype; cap beau_ph.provider_capabilities%rowtype;
  pe_id uuid; ev beau_ph.payment_events%rowtype; m beau_ph.merchants%rowtype; v_conf text; v_ready text; v_handoff boolean;
begin
  if coalesce(p_operator, '') = '' then raise exception 'operator identity required' using errcode = '42501'; end if;
  if not beau_ph.owned_by(p_request_id, p_merchant_key) then raise exception 'request not found' using errcode = 'P0002'; end if;
  select * into r from beau_ph.payment_requests where id = p_request_id for update;
  if not found then raise exception 'request not found' using errcode = 'P0002'; end if;
  select * into pv from beau_ph.providers where key = r.provider_key;
  select * into cap from beau_ph.provider_capabilities where provider_key = r.provider_key and capability = r.capability;
  v_conf := coalesce(cap.confirmation, pv.confirmation); v_ready := coalesce(cap.readiness, pv.readiness); v_handoff := coalesce(cap.handoff, false);
  if v_conf <> 'operator' then raise exception 'provider % (%) is not operator-confirmed', r.provider_key, coalesce(r.capability, '-') using errcode = 'P0003'; end if;
  if v_ready <> 'available' then raise exception 'provider % (%) is %', r.provider_key, coalesce(r.capability, '-'), v_ready using errcode = 'P0003'; end if;
  if r.status in ('paid','refunded') then raise exception 'already paid' using errcode = 'P0003'; end if;
  if r.status not in ('created','pending','requires_action') then raise exception 'request not open' using errcode = 'P0003'; end if;
  if p_amount is null or p_amount <> r.amount or upper(coalesce(p_currency, '')) <> r.currency then
    raise exception 'received amount/currency differ from the request (% %)', r.amount, r.currency using errcode = 'P0003';
  end if;
  if v_handoff and coalesce(btrim(p_reference), '') = '' then
    raise exception 'the provider app receipt / transaction reference is required for a % handoff', r.capability using errcode = '22023';
  end if;
  select * into m from beau_ph.merchants where id = r.merchant_id;
  insert into beau_ph.provider_events (provider_key, provider_event_id, event_type, payload, request_id, outcome, processed_at)
  values (r.provider_key, 'operator:' || gen_random_uuid()::text, 'operator.confirmed',
          jsonb_build_object('operator', p_operator, 'amount', p_amount, 'currency', upper(p_currency), 'reference', p_reference,
                             'paid_at', coalesce(p_paid_at, now()), 'note', p_note, 'capability', r.capability, 'handoff', v_handoff), r.id, 'normalized', now())
  returning id into pe_id;
  ev := beau_ph.record_event(r.id, 'paid', 'operator', p_operator, pe_id, p_amount, upper(p_currency), 'confirmed_by_operator', null, nullif(btrim(p_reference), ''),
                             jsonb_build_object('reference', p_reference, 'paid_at', coalesce(p_paid_at, now()), 'note', p_note, 'capability', r.capability,
                                                'verification', case when v_handoff then 'operator_attested_provider_receipt' else 'operator_attested' end));
  if p_paid_at is not null then update beau_ph.payment_requests set paid_at = p_paid_at where id = r.id; end if;
  return jsonb_build_object('ok', true, 'outcome', 'normalized', 'request_id', r.id, 'payment_event_id', ev.id, 'from', ev.from_status, 'to', 'paid',
                            'provider', r.provider_key, 'capability', r.capability, 'external_reference', r.external_reference, 'public_reference', r.public_reference,
                            'merchant', m.key, 'amount', r.amount, 'currency', r.currency, 'paid_at', coalesce(p_paid_at, now()));
end $$;

drop function if exists beau_ph.cancel_request(uuid, text, text, text);
create or replace function beau_ph.cancel_request(p_request_id uuid, p_actor text default 'system', p_actor_id text default null, p_reason text default null,
                                                  p_merchant_key text default null)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare r beau_ph.payment_requests%rowtype;
begin
  if not beau_ph.owned_by(p_request_id, p_merchant_key) then raise exception 'request not found' using errcode = 'P0002'; end if;
  select * into r from beau_ph.payment_requests where id = p_request_id for update;
  if not found then raise exception 'request not found' using errcode = 'P0002'; end if;
  if r.status in ('paid','refunded') then raise exception 'already paid' using errcode = 'P0003'; end if;
  if r.status in ('cancelled','expired','failed') then return beau_ph.request_json(r); end if;   -- idempotent
  perform beau_ph.record_event(r.id, 'cancelled', coalesce(p_actor, 'system'), p_actor_id, null, null, null, 'cancelled', null, null,
                               jsonb_build_object('reason', p_reason));
  select * into r from beau_ph.payment_requests where id = r.id;
  return beau_ph.request_json(r);
end $$;

drop function if exists beau_ph.expire_request(uuid, text);
create or replace function beau_ph.expire_request(p_request_id uuid, p_reason text default 'expired', p_merchant_key text default null)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare r beau_ph.payment_requests%rowtype;
begin
  if not beau_ph.owned_by(p_request_id, p_merchant_key) then raise exception 'request not found' using errcode = 'P0002'; end if;
  select * into r from beau_ph.payment_requests where id = p_request_id for update;
  if not found then raise exception 'request not found' using errcode = 'P0002'; end if;
  if r.status in ('paid','refunded') then raise exception 'already paid' using errcode = 'P0003'; end if;
  if r.status in ('cancelled','expired','failed') then return beau_ph.request_json(r); end if;
  perform beau_ph.record_event(r.id, 'expired', 'system', null, null, null, null, 'expired', null, null, jsonb_build_object('reason', p_reason));
  select * into r from beau_ph.payment_requests where id = r.id;
  return beau_ph.request_json(r);
end $$;

drop function if exists beau_ph.attach_attempt(uuid, text, text, timestamptz);
create or replace function beau_ph.attach_attempt(p_request_id uuid, p_provider_reference text, p_redirect_url text, p_expires_at timestamptz,
                                                  p_merchant_key text default null)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare r beau_ph.payment_requests%rowtype; a beau_ph.payment_attempts%rowtype; v_n int;
begin
  if not beau_ph.owned_by(p_request_id, p_merchant_key) then raise exception 'request not found' using errcode = 'P0002'; end if;
  select * into r from beau_ph.payment_requests where id = p_request_id for update;
  if not found then raise exception 'request not found' using errcode = 'P0002'; end if;
  if r.status not in ('created','pending','requires_action') then raise exception 'request not open' using errcode = 'P0003'; end if;
  update beau_ph.payment_attempts set status = 'superseded' where request_id = r.id and status = 'open';
  select coalesce(max(pa.n), 0) + 1 into v_n from beau_ph.payment_attempts pa where pa.request_id = r.id;
  insert into beau_ph.payment_attempts (request_id, n, provider_reference, redirect_url, expires_at)
  values (r.id, v_n, p_provider_reference, p_redirect_url, p_expires_at) returning * into a;
  perform beau_ph.record_event(r.id, 'requires_action', 'system', null, null, null, null, 'attempt_open', p_provider_reference, null,
                               jsonb_build_object('attempt', a.n, 'expires_at', p_expires_at));
  update beau_ph.payment_requests set expires_at = coalesce(p_expires_at, expires_at) where id = r.id;
  select * into r from beau_ph.payment_requests where id = r.id;
  return beau_ph.request_json(r);
end $$;

drop function if exists beau_ph.mark_reconciled(uuid, text, text);
create or replace function beau_ph.mark_reconciled(p_payment_event_id uuid, p_host_reference text, p_note text default null, p_merchant_key text default null)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare rid uuid; ex beau_ph.reconciliations%rowtype; v_req uuid;
begin
  select request_id into v_req from beau_ph.payment_events where id = p_payment_event_id;
  if v_req is null or not beau_ph.owned_by(v_req, p_merchant_key) then raise exception 'payment event not found' using errcode = 'P0002'; end if;
  insert into beau_ph.reconciliations (payment_event_id, request_id, merchant_id, host_reference, note)
  select ev.id, ev.request_id, r.merchant_id, p_host_reference, p_note
    from beau_ph.payment_events ev join beau_ph.payment_requests r on r.id = ev.request_id
   where ev.id = p_payment_event_id
  on conflict (payment_event_id) do nothing returning id into rid;
  if rid is null then
    select * into ex from beau_ph.reconciliations where payment_event_id = p_payment_event_id;
    return jsonb_build_object('ok', true, 'duplicate', true, 'id', ex.id, 'host_reference', ex.host_reference, 'reconciled_at', ex.reconciled_at);
  end if;
  return jsonb_build_object('ok', true, 'duplicate', false, 'id', rid, 'host_reference', p_host_reference);
end $$;

drop function if exists beau_ph.get_request(uuid);
create or replace function beau_ph.get_request(p_request_id uuid, p_merchant_key text default null)
returns jsonb language sql stable security definer set search_path = '' as $$
  select beau_ph.request_json(r) from beau_ph.payment_requests r
   where r.id = p_request_id and beau_ph.owned_by(r.id, p_merchant_key)
$$;

drop function if exists beau_ph.request_events(uuid);
create or replace function beau_ph.request_events(p_request_id uuid, p_merchant_key text default null)
returns jsonb language sql stable security definer set search_path = '' as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'id', ev.id, 'from', ev.from_status, 'to', ev.to_status, 'amount', ev.amount, 'currency', ev.currency,
           'provider_status', ev.provider_status, 'provider_reference', ev.provider_reference, 'actor', ev.actor, 'actor_id', ev.actor_id,
           'evidence', ev.evidence, 'reconciled', exists (select 1 from beau_ph.reconciliations rc where rc.payment_event_id = ev.id),
           'created_at', ev.created_at) order by ev.created_at), '[]'::jsonb)
    from beau_ph.payment_events ev
   where ev.request_id = p_request_id and beau_ph.owned_by(p_request_id, p_merchant_key)
$$;

do $$
declare f record;
begin
  for f in select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'beau_ph'
              and p.proname in ('owned_by','confirm_manual','cancel_request','expire_request','attach_attempt','mark_reconciled','get_request','request_events') loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;

-- ---------- 3. Coach Gari host adapter: always act as 'coach_gari' ----------
create or replace function public.attach_checkout(p_order_reference text, p_session_id text, p_url text, p_expires_at timestamptz)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare o public.orders%rowtype; req jsonb;
begin
  update public.orders
     set stripe_checkout_session_id = p_session_id, checkout_url = p_url, checkout_expires_at = p_expires_at,
         checkout_attempts = checkout_attempts + 1
   where reference = p_order_reference and status = 'pending_payment'
   returning * into o;
  if not found then raise exception 'order not pending' using errcode = 'P0003'; end if;
  update public.bookings set status = 'pending_payment', hold_expires_at = p_expires_at
   where id = o.booking_id and status in ('hold','pending_payment');
  req := public.cg_ph_request_for_order(o, 'stripe', jsonb_build_object('stripe', jsonb_build_object('configured', true, 'mode', 'test')), true);
  perform beau_ph.attach_attempt((req ->> 'id')::uuid, p_session_id, p_url, p_expires_at, 'coach_gari');
  return public.order_to_json(o);
end $$;

-- Stripe webhook: same body as 20260917 §6, plus (a) a normalized event whose BEAU PH request belongs to
-- another merchant is ignored (evidence kept in both ledgers, nothing paid here), (b) reconciliation is scoped.
create or replace function public.process_stripe_event(p_event jsonb)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare
  ev_id text := p_event ->> 'id'; ev_type text := p_event ->> 'type'; obj jsonb := p_event -> 'data' -> 'object';
  enrich jsonb := coalesce(p_event -> '_enrich', '{}'::jsonb);
  existing public.webhook_events%rowtype;
  o public.orders%rowtype; b public.bookings%rowtype; p public.payments%rowtype;
  v_amount int; v_currency text; v_pi text; v_total_refunded int; v_status text;
  ph jsonb; ph_event uuid; result jsonb;
begin
  if ev_id is null or ev_type is null then raise exception 'malformed event' using errcode = '22023'; end if;

  insert into public.webhook_events (event_id, event_type, payload) values (ev_id, ev_type, p_event)
  on conflict (event_id) do nothing;
  if not found then
    select * into existing from public.webhook_events where event_id = ev_id;
    if existing.status in ('processed','ignored') then
      return jsonb_build_object('event_id', ev_id, 'duplicate', true, 'status', existing.status);
    end if;
  end if;

  ph := beau_ph.ingest_stripe_event(p_event);
  ph_event := (ph ->> 'payment_event_id')::uuid;
  -- tenant scope: this host only ever reconciles its own merchant's requests
  if (ph ->> 'request_id') is not null and not beau_ph.owned_by((ph ->> 'request_id')::uuid, 'coach_gari') then
    update public.webhook_events set status = 'ignored', note = 'beau_ph foreign_merchant', processed_at = now() where event_id = ev_id;
    return jsonb_build_object('event_id', ev_id, 'status', 'ignored', 'note', 'foreign_merchant');
  end if;

  if ev_type = 'checkout.session.completed' then
    select * into o from public.orders where stripe_checkout_session_id = obj ->> 'id';
    if not found and (obj -> 'metadata' ->> 'order_id') is not null then
      select * into o from public.orders where id = (obj -> 'metadata' ->> 'order_id')::uuid;
    end if;
    if not found and (obj ->> 'client_reference_id') is not null then
      select * into o from public.orders where reference = obj ->> 'client_reference_id';
    end if;
    if not found then
      update public.webhook_events set status = 'ignored', note = 'unknown order', processed_at = now() where event_id = ev_id;
      return jsonb_build_object('event_id', ev_id, 'status', 'ignored', 'note', 'unknown order');
    end if;
    if coalesce(obj ->> 'payment_status', '') <> 'paid' then
      update public.webhook_events set status = 'ignored', note = 'payment_status ' || coalesce(obj ->> 'payment_status', 'null'), processed_at = now() where event_id = ev_id;
      return jsonb_build_object('event_id', ev_id, 'status', 'ignored', 'note', 'not paid');
    end if;
    v_amount := (obj ->> 'amount_total')::int; v_currency := upper(obj ->> 'currency'); v_pi := obj ->> 'payment_intent';

    if (ph ->> 'outcome') = 'no_request' then
      if v_amount <> o.gross_amount or v_currency <> o.currency then
        update public.webhook_events set status = 'ignored', note = format('amount mismatch: got %s %s, order %s %s', v_amount, v_currency, o.gross_amount, o.currency), processed_at = now() where event_id = ev_id;
        return jsonb_build_object('event_id', ev_id, 'status', 'ignored', 'note', 'amount mismatch');
      end if;
    elsif coalesce((ph ->> 'duplicate')::boolean, false) then
      if ph_event is null or beau_ph.is_reconciled(ph_event) then
        update public.webhook_events set status = 'processed', note = 'beau_ph duplicate', processed_at = now() where event_id = ev_id;
        return jsonb_build_object('event_id', ev_id, 'duplicate', true, 'status', 'processed');
      end if;
    elsif (ph ->> 'outcome') <> 'normalized' or (ph ->> 'to') <> 'paid' then
      update public.webhook_events set status = 'ignored', note = 'beau_ph ' || (ph ->> 'outcome'), processed_at = now() where event_id = ev_id;
      return jsonb_build_object('event_id', ev_id, 'status', 'ignored', 'note', ph ->> 'outcome');
    end if;

    insert into public.payments (order_id, provider_payment_intent_id, provider_charge_id, provider_balance_transaction_id,
                                 amount, currency, fee_amount, fee_known, status, paid_at, provider_event_id, ph_request_id, ph_event_id)
    values (o.id, v_pi, enrich ->> 'charge_id', enrich ->> 'balance_transaction_id', v_amount, v_currency,
            coalesce((enrich ->> 'fee_amount')::int, 0), (enrich ->> 'fee_amount') is not null, 'succeeded', now(), ev_id,
            (ph ->> 'request_id')::uuid, ph_event)
    on conflict (provider_payment_intent_id) do update
      set fee_amount = case when public.payments.fee_known then public.payments.fee_amount else excluded.fee_amount end,
          fee_known  = public.payments.fee_known or excluded.fee_known,
          provider_charge_id = coalesce(public.payments.provider_charge_id, excluded.provider_charge_id),
          provider_balance_transaction_id = coalesce(public.payments.provider_balance_transaction_id, excluded.provider_balance_transaction_id),
          ph_request_id = coalesce(public.payments.ph_request_id, excluded.ph_request_id),
          ph_event_id   = coalesce(public.payments.ph_event_id, excluded.ph_event_id)
    returning * into p;

    update public.orders set status = 'paid', paid_at = coalesce(paid_at, now())
     where id = o.id and status in ('pending_payment','paid');
    perform public.recompute_earning(o.id);
    if ph_event is not null then perform beau_ph.mark_reconciled(ph_event, p.id::text, 'public.payments', 'coach_gari'); end if;

    if o.booking_id is not null then
      update public.bookings set status = 'confirmed', hold_expires_at = null
       where id = o.booking_id and status in ('hold','pending_payment','confirmed');
      select * into b from public.bookings where id = o.booking_id;
      insert into public.email_events (booking_id, order_id, kind, to_address)
      values (b.id, o.id, 'booking_confirmed', case when b.customer_contact ~ '^[^\s@]+@[^\s@]+\.[^\s@]{2,}$' then b.customer_contact else null end),
             (b.id, o.id, 'payment_received', 'letsgo@coachgari.com')
      on conflict (order_id, kind) do nothing;
      update public.email_events set status = 'skipped', error = 'no email address (contact is a phone number)'
       where order_id = o.id and kind = 'booking_confirmed' and to_address is null and status = 'pending';
      result := jsonb_build_object('order', o.reference, 'payment_id', p.id, 'booking', b.reference, 'booking_status', 'confirmed');
    else
      perform public.project_pack_payment(o.id);
      result := jsonb_build_object('order', o.reference, 'payment_id', p.id, 'session_pack', o.session_pack_id);
    end if;
    result := result || jsonb_build_object('beau_ph', jsonb_build_object('request_id', ph ->> 'request_id', 'payment_event_id', ph_event, 'outcome', ph ->> 'outcome'));

  elsif ev_type = 'checkout.session.expired' then
    select * into o from public.orders where stripe_checkout_session_id = obj ->> 'id';
    if found then
      update public.orders set status = 'cancelled' where id = o.id and status = 'pending_payment';
      if o.booking_id is not null then
        update public.bookings set status = 'expired' where id = o.booking_id and status in ('hold','pending_payment');
      end if;
      result := jsonb_build_object('order', o.reference, 'status', 'expired', 'beau_ph', ph ->> 'outcome');
    else
      update public.webhook_events set status = 'ignored', note = 'unknown order', processed_at = now() where event_id = ev_id;
      return jsonb_build_object('event_id', ev_id, 'status', 'ignored');
    end if;

  elsif ev_type in ('refund.created','refund.updated') then
    v_pi := obj ->> 'payment_intent';
    select * into p from public.payments where provider_payment_intent_id = v_pi;
    if not found then
      update public.webhook_events set status = 'ignored', note = 'unknown payment', processed_at = now() where event_id = ev_id;
      return jsonb_build_object('event_id', ev_id, 'status', 'ignored');
    end if;
    v_status := case obj ->> 'status' when 'succeeded' then 'succeeded' when 'pending' then 'pending' when 'failed' then 'failed'
                     when 'canceled' then 'cancelled' else 'pending' end;
    insert into public.refunds (payment_id, order_id, amount, currency, reason, provider_refund_id, status, provider_event_id)
    values (p.id, p.order_id, (obj ->> 'amount')::int, upper(obj ->> 'currency'), obj ->> 'reason', obj ->> 'id', v_status, ev_id)
    on conflict (provider_refund_id) do update set status = excluded.status, amount = excluded.amount, reason = excluded.reason;
    select coalesce(sum(amount), 0) into v_total_refunded from public.refunds where order_id = p.order_id and status = 'succeeded';
    update public.orders set status = case when v_total_refunded >= p.amount then 'refunded'
                                           when v_total_refunded > 0 then 'partially_refunded' else status end
     where id = p.order_id;
    perform public.recompute_earning(p.order_id);
    perform public.project_pack_payment(p.order_id);
    result := jsonb_build_object('order_id', p.order_id, 'refunded', v_total_refunded, 'beau_ph', ph ->> 'outcome');

  elsif ev_type like 'charge.dispute.%' then
    v_pi := obj ->> 'payment_intent';
    select * into p from public.payments where provider_payment_intent_id = v_pi
       or (v_pi is null and provider_charge_id = obj ->> 'charge');
    if not found then
      update public.webhook_events set status = 'ignored', note = 'unknown payment', processed_at = now() where event_id = ev_id;
      return jsonb_build_object('event_id', ev_id, 'status', 'ignored');
    end if;
    insert into public.chargebacks (payment_id, order_id, amount, currency, provider_dispute_id, status, reason, provider_event_id)
    values (p.id, p.order_id, (obj ->> 'amount')::int, upper(obj ->> 'currency'), obj ->> 'id', obj ->> 'status', obj ->> 'reason', ev_id)
    on conflict (provider_dispute_id) do update set status = excluded.status, amount = excluded.amount, reason = excluded.reason;
    perform public.recompute_earning(p.order_id);
    result := jsonb_build_object('order_id', p.order_id, 'dispute', obj ->> 'status', 'beau_ph', ph ->> 'outcome');

  else
    update public.webhook_events set status = 'ignored', note = 'unhandled type', processed_at = now() where event_id = ev_id;
    return jsonb_build_object('event_id', ev_id, 'status', 'ignored', 'note', 'unhandled type');
  end if;

  update public.webhook_events set status = 'processed', processed_at = now() where event_id = ev_id;
  return jsonb_build_object('event_id', ev_id, 'status', 'processed') || coalesce(result, '{}'::jsonb);
end $$;

-- Manual / in-person receipt: same body as 20260920 §4, plus the pack double-pay guard and merchant-scoped core calls.
create or replace function public.payment_record_manual(
  p_pack_id uuid, p_amount int, p_currency text, p_source text default 'aani', p_reference text default null, p_paid_at timestamptz default null,
  p_capability text default null, p_platform text default null)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare e text := public.current_email(); sp public.session_packs%rowtype; o public.orders%rowtype; c public.crm_contacts%rowtype;
  v_ref text; pay public.payments%rowtype; req jsonb; conf jsonb; superseded text; psp boolean; v_cap text;
begin
  if not public.has_permission('finance:manage') then raise exception 'forbidden' using errcode = '42501'; end if;
  psp := p_source in ('network_international','magnati','adyen');
  if p_source not in ('aani','bank_transfer','cash','manual','external') and not psp then raise exception 'invalid source' using errcode = '22023'; end if;
  if p_amount is null or p_amount <= 0 then raise exception 'amount required' using errcode = '22023'; end if;
  if coalesce(p_currency,'') !~ '^[A-Z]{3}$' then raise exception 'currency required (ISO 4217)' using errcode = '22023'; end if;
  v_cap := case when psp then coalesce(p_capability, 'softpos') else p_capability end;
  if psp and coalesce(btrim(p_reference), '') = '' then
    raise exception 'the PSP app receipt / transaction reference is required for an in-person payment' using errcode = '22023';
  end if;
  select * into sp from public.session_packs where id = p_pack_id for update;
  if not found then raise exception 'pack not found' using errcode = 'P0002'; end if;
  -- race guard: another rail (e.g. a Stripe webhook) settled this pack first → a receipt must not pay it twice
  if sp.payment_status = 'paid' or exists (select 1 from public.orders oo where oo.session_pack_id = sp.id and oo.status = 'paid') then
    raise exception 'pack % is already paid', coalesce(sp.public_ref, sp.id::text) using errcode = 'P0003';
  end if;
  select * into c from public.crm_contacts where id = sp.crm_contact_id;

  select * into o from public.orders where session_pack_id = sp.id and status in ('pending_payment') limit 1;
  if found and (o.currency <> p_currency or o.gross_amount <> p_amount) then
    perform beau_ph.cancel_requests_for('coach_gari', o.reference, 'operator', e, 'superseded by a manual receipt of a different amount');
    update public.orders set status = 'cancelled' where id = o.id;
    superseded := o.reference; o := null;
  end if;
  if o.id is null then
    loop v_ref := 'OR-' || upper(substr(encode(extensions.gen_random_bytes(4),'hex'),1,6)); exit when not exists (select 1 from public.orders where reference = v_ref); end loop;
    insert into public.orders (reference, booking_id, session_pack_id, order_reason, customer_name, customer_contact, currency, gross_amount, status)
    values (v_ref, null, sp.id, 'session_pack', coalesce(c.display_name,'Client'), coalesce(c.email,c.phone,'n/a'), p_currency, p_amount, 'pending_payment')
    returning * into o;
  end if;

  if p_source in ('aani','bank_transfer') or psp then
    req  := public.cg_ph_request_for_order(o, p_source, '{}'::jsonb, false, v_cap, p_platform);
    conf := beau_ph.confirm_manual((req ->> 'id')::uuid, e, p_amount, p_currency, nullif(btrim(p_reference), ''), p_paid_at, null, 'coach_gari');
    insert into public.payments (order_id, provider, amount, currency, status, paid_at, note, ph_request_id, ph_event_id, capability)
    values (o.id, p_source, p_amount, p_currency, 'succeeded', coalesce(p_paid_at, now()), nullif(btrim(p_reference), ''),
            (req ->> 'id')::uuid, (conf ->> 'payment_event_id')::uuid, req ->> 'capability')
    returning * into pay;
    perform beau_ph.mark_reconciled((conf ->> 'payment_event_id')::uuid, pay.id::text, 'public.payments', 'coach_gari');
  else
    insert into public.payments (order_id, provider, amount, currency, status, paid_at, note, capability)
    values (o.id, p_source, p_amount, p_currency, 'succeeded', coalesce(p_paid_at, now()), nullif(p_reference,''), p_capability)
    returning * into pay;
  end if;
  update public.orders set status = 'paid', paid_at = coalesce(paid_at, pay.paid_at) where id = o.id;
  perform public.project_pack_payment(o.id);
  insert into public.admin_audit (area, entity_id, action, changed_by, summary)
  values ('payment', o.reference, 'manual', e, jsonb_build_object('pack', sp.id, 'source', p_source, 'capability', coalesce(req ->> 'capability', p_capability),
                                                                   'amount', p_amount, 'currency', p_currency, 'beau_ph_request', req ->> 'id', 'superseded_order', superseded));
  return jsonb_build_object('ok', true, 'order', o.reference, 'payment_id', pay.id, 'source', p_source, 'capability', coalesce(req ->> 'capability', p_capability),
                            'request_id', req ->> 'id', 'public_reference', req ->> 'public_reference', 'superseded_order', superseded);
end $$;

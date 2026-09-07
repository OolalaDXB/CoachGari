-- =====================================================================
-- BEAU PH — Coach Gari HOST ADAPTER (V0)
--
-- The only place where Coach Gari's commerce model and BEAU PH meet:
--   Coach Gari order (booking or session pack)  → BEAU PH payment request
--   BEAU PH normalized "paid" event              → public.payments / orders /
--                                                  partner ledger / pack projection
--                                                  (authoritative, exactly once)
-- BEAU PH never learns about packs, bookings, the CRM or health data; the
-- functions below do the translation. Coach Gari stays the accounting truth.
--
-- Preserved, by test: CG-003 booking checkout + webhook; CG-012 recap page,
-- Stripe test flow, Aani, bank transfer, manual reconciliation, renewal.
-- Forward migration only.
-- =====================================================================

-- ---------- 1. merchant + rails ----------
insert into beau_ph.merchants (key, name, country, default_currency, mode)
values ('coach_gari', 'Coach Gari', 'AE', 'AED', 'test') on conflict (key) do nothing;

-- Stripe is enabled at merchant level; whether a TEST key is actually deployed
-- is reported by the Stripe adapter at request time (runtime readiness).
select beau_ph.merchant_method_set('coach_gari', 'stripe', true, null, '{}'::jsonb, '{}'::jsonb, null, 'migration');

-- Move the CG-012 method configuration (Aani / bank transfer) into BEAU PH.
-- Data is preserved as entered by the owner; nothing is seeded.
do $$
declare pm record;
begin
  if to_regclass('public.payment_methods') is null then return; end if;
  for pm in select * from public.payment_methods loop
    if pm.method = 'aani' then
      perform beau_ph.merchant_method_set('coach_gari', 'aani', pm.enabled, pm.currency,
        jsonb_strip_nulls(jsonb_build_object('proxy_type', pm.proxy_type, 'proxy_value', pm.proxy_value, 'display_value', pm.display_value,
                                             'instructions', pm.instructions, 'qr_url', pm.qr_url)),
        '{}'::jsonb, null, coalesce(pm.updated_by, 'migration'));
    elsif pm.method = 'bank_transfer' then
      perform beau_ph.merchant_method_set('coach_gari', 'bank_transfer', pm.enabled, pm.currency,
        jsonb_strip_nulls(jsonb_build_object('account_holder', pm.account_holder, 'iban', pm.iban, 'bic', pm.bic, 'bank_name', pm.bank_name,
                                             'instructions', pm.instructions)),
        '{}'::jsonb, null, coalesce(pm.updated_by, 'migration'));
    end if;
  end loop;
end $$;
drop table if exists public.payment_methods;

-- ---------- 2. ledger ↔ BEAU PH traceability ----------
-- Logical references only (no cross-schema FK) so BEAU PH can be extracted later.
alter table public.payments add column if not exists ph_request_id uuid;
alter table public.payments add column if not exists ph_event_id   uuid;
create unique index if not exists payments_ph_event_idx on public.payments (ph_event_id) where ph_event_id is not null;

-- ---------- 3. customer country: CRM free text → ISO 3166-1 alpha-2 (unknown → null → merchant country) ----------
create or replace function public.cg_country_code(p text)
returns text language sql immutable set search_path = '' as $$
  select case
    when p is null or btrim(p) = '' then null
    when upper(btrim(p)) ~ '^[A-Z]{2}$' then upper(btrim(p))
    when p ~* '(united arab emirates|\muae\M|dubai|abu dhabi|sharjah|emirates)' then 'AE'
    when p ~* 'zimbabwe|harare|bulawayo' then 'ZW'
    when p ~* 'kenya|nairobi|mombasa' then 'KE'
    when p ~* 'south africa|johannesburg|cape town|durban|pretoria' then 'ZA'
    when p ~* '(united kingdom|\muk\M|england|london|scotland|wales)' then 'GB'
    when p ~* '(united states|\musa\M|new york|los angeles|miami)' then 'US'
    when p ~* 'france|paris|lyon|marseille' then 'FR'
    when p ~* 'saudi|riyadh|jeddah' then 'SA'
    when p ~* 'qatar|doha' then 'QA'
    when p ~* 'india|mumbai|delhi|bangalore' then 'IN'
    when p ~* 'nigeria|lagos|abuja' then 'NG'
    when p ~* 'ghana|accra' then 'GH'
    when p ~* 'egypt|cairo' then 'EG'
    when p ~* 'morocco|casablanca|rabat' then 'MA'
    when p ~* 'germany|berlin|munich' then 'DE'
    when p ~* 'spain|madrid|barcelona' then 'ES'
    when p ~* 'italy|rome|milan' then 'IT'
    when p ~* 'switzerland|zurich|geneva' then 'CH'
    when p ~* 'canada|toronto|montreal|vancouver' then 'CA'
    when p ~* 'australia|sydney|melbourne' then 'AU'
    else null end
$$;
revoke execute on function public.cg_country_code(text) from public, anon;
grant  execute on function public.cg_country_code(text) to authenticated, service_role;

-- ---------- 4. method configuration for the Finance screen (via BEAU PH) ----------
-- Flat shape identical to the former public.payment_methods rows.
create or replace function public.payment_methods_list()
returns jsonb language plpgsql stable security definer set search_path = '' as $$
begin
  if not public.has_permission('finance:view') then raise exception 'forbidden' using errcode = '42501'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object(
      'method', mm.provider_key, 'enabled', mm.enabled, 'currency', mm.currency, 'updated_by', mm.updated_by, 'updated_at', mm.updated_at,
      'proxy_type', mm.instructions ->> 'proxy_type', 'proxy_value', mm.instructions ->> 'proxy_value', 'display_value', mm.instructions ->> 'display_value',
      'instructions', mm.instructions ->> 'instructions', 'qr_url', mm.instructions ->> 'qr_url',
      'account_holder', mm.instructions ->> 'account_holder', 'iban', mm.instructions ->> 'iban', 'bic', mm.instructions ->> 'bic', 'bank_name', mm.instructions ->> 'bank_name')
      order by mm.provider_key)
    from beau_ph.merchant_methods mm join beau_ph.merchants m on m.id = mm.merchant_id where m.key = 'coach_gari'), '[]'::jsonb);
end $$;
revoke execute on function public.payment_methods_list() from public, anon;
grant  execute on function public.payment_methods_list() to authenticated, service_role;

-- Provider readiness matrix (product readiness × merchant enablement). Deployment
-- readiness (a test key present) is only known to the Edge adapters at request time.
create or replace function public.payment_rails()
returns jsonb language plpgsql stable security definer set search_path = '' as $$
begin
  if not public.has_permission('finance:view') then raise exception 'forbidden' using errcode = '42501'; end if;
  return (select jsonb_agg(jsonb_build_object(
      'provider', p.key, 'display_name', p.display_name, 'kind', p.kind, 'confirmation', p.confirmation, 'readiness', p.readiness,
      'countries', to_jsonb(coalesce(mm.countries, p.countries)), 'currencies', to_jsonb(p.currencies),
      'enabled', coalesce(mm.enabled, false), 'settlement_currency', mm.currency, 'notes', p.notes, 'updated_at', mm.updated_at) order by p.sort)
    from beau_ph.providers p
    left join beau_ph.merchant_methods mm on mm.provider_key = p.key and mm.merchant_id = (select id from beau_ph.merchants where key = 'coach_gari'));
end $$;
revoke execute on function public.payment_rails() from public, anon;
grant  execute on function public.payment_rails() to authenticated, service_role;

-- Same signature/inputs as CG-012b; now writes the BEAU PH merchant configuration.
create or replace function public.payment_method_set(p jsonb)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare e text := public.current_email(); m text := coalesce(p ->> 'method', 'aani'); row jsonb; ins jsonb;
begin
  if not public.has_permission('finance:manage') then raise exception 'forbidden' using errcode = '42501'; end if;
  if m not in ('aani','bank_transfer','stripe') then raise exception 'unknown method' using errcode = '22023'; end if;
  if m = 'aani' and nullif(p ->> 'proxy_type', '') is not null and (p ->> 'proxy_type') not in ('mobile','email','merchant','qr') then
    raise exception 'invalid proxy_type' using errcode = '22023';
  end if;
  ins := case m
    when 'aani' then jsonb_strip_nulls(jsonb_build_object('proxy_type', nullif(p ->> 'proxy_type', ''), 'proxy_value', nullif(p ->> 'proxy_value', ''),
                       'display_value', nullif(p ->> 'display_value', ''), 'instructions', nullif(p ->> 'instructions', ''), 'qr_url', nullif(p ->> 'qr_url', '')))
    when 'bank_transfer' then jsonb_strip_nulls(jsonb_build_object('account_holder', nullif(p ->> 'account_holder', ''), 'iban', nullif(p ->> 'iban', ''),
                       'bic', nullif(p ->> 'bic', ''), 'bank_name', nullif(p ->> 'bank_name', ''), 'instructions', nullif(p ->> 'instructions', '')))
    else '{}'::jsonb end;
  row := beau_ph.merchant_method_set('coach_gari', m, coalesce((p ->> 'enabled')::boolean, false),
           case when m = 'stripe' then null else coalesce(nullif(p ->> 'currency', ''), 'AED') end, ins, '{}'::jsonb, null, e);
  insert into public.admin_audit (area, entity_id, action, changed_by, summary)
  values ('payment_method', m, 'set', e, jsonb_build_object('enabled', (row ->> 'enabled')::boolean));
  return row;
end $$;
revoke execute on function public.payment_method_set(jsonb) from public, anon;
grant  execute on function public.payment_method_set(jsonb) to authenticated, service_role;

-- ---------- 5. order → BEAU PH request (the mapping) ----------
-- public_reference: booking reference (CG-XXXXXX) or pack public_ref (CG-1048) — never a UUID.
-- customer country: the CRM contact's country (offering); ignored when recording a receipt (fact).
create or replace function public.cg_ph_request_for_order(o public.orders, p_provider text, p_runtime jsonb default '{}'::jsonb, p_use_contact_country boolean default true)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare pub text; ctry text; meta jsonb;
begin
  if o.booking_id is not null then
    select b.reference into pub from public.bookings b where b.id = o.booking_id;
    meta := jsonb_build_object('order_id', o.id, 'booking_id', o.booking_id, 'reason', coalesce(o.order_reason, 'booking'));
  else
    select sp.public_ref, case when p_use_contact_country then public.cg_country_code(c.country) else null end into pub, ctry
      from public.session_packs sp left join public.crm_contacts c on c.id = sp.crm_contact_id where sp.id = o.session_pack_id;
    meta := jsonb_build_object('order_id', o.id, 'session_pack_id', o.session_pack_id, 'reason', coalesce(o.order_reason, 'session_pack'));
  end if;
  return beau_ph.create_request('coach_gari', p_provider, o.reference, coalesce(pub, o.reference), o.gross_amount, o.currency, ctry,
                                o.checkout_expires_at, meta, p_runtime);
end $$;
revoke execute on function public.cg_ph_request_for_order(public.orders, text, jsonb, boolean) from public, anon, authenticated;
grant  execute on function public.cg_ph_request_for_order(public.orders, text, jsonb, boolean) to service_role;

-- Report page "pay by card": pack → order (amount from the pack snapshot) → BEAU PH request.
create or replace function public.cg_ph_request_for_pack(p_pack_id uuid, p_provider text, p_runtime jsonb default '{}'::jsonb)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare oj jsonb; o public.orders%rowtype; req jsonb;
begin
  oj := public.create_order_for_pack(p_pack_id);
  select * into o from public.orders where reference = oj ->> 'reference';
  req := public.cg_ph_request_for_order(o, p_provider, p_runtime, true);
  return jsonb_build_object('request', req, 'order', oj);
end $$;
revoke execute on function public.cg_ph_request_for_pack(uuid, text, jsonb) from public, anon, authenticated;
grant  execute on function public.cg_ph_request_for_pack(uuid, text, jsonb) to service_role;

-- Booking checkout (CG-003): held booking → trusted order → BEAU PH request (symmetric with packs).
create or replace function public.cg_ph_request_for_booking(p_reference text, p_manage_token text, p_provider text default 'stripe', p_runtime jsonb default '{}'::jsonb)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare oj jsonb; o public.orders%rowtype; req jsonb;
begin
  oj := public.create_order_for_booking(p_reference, p_manage_token);
  select * into o from public.orders where reference = oj ->> 'reference';
  req := public.cg_ph_request_for_order(o, p_provider, p_runtime, true);
  return jsonb_build_object('request', req, 'order', oj);
end $$;
revoke execute on function public.cg_ph_request_for_booking(text, text, text, jsonb) from public, anon, authenticated;
grant  execute on function public.cg_ph_request_for_booking(text, text, text, jsonb) to service_role;

-- CG-003 contract unchanged (order + booking hold alignment); additionally guarantees a BEAU PH
-- request for the order and records the Checkout Session as a payment attempt.
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
  -- a Checkout Session exists ⇒ the Stripe adapter ran with a TEST key (it refuses live keys: CHECK-LICENCE-001)
  req := public.cg_ph_request_for_order(o, 'stripe', jsonb_build_object('stripe', jsonb_build_object('configured', true, 'mode', 'test')), true);
  perform beau_ph.attach_attempt((req ->> 'id')::uuid, p_session_id, p_url, p_expires_at);
  return public.order_to_json(o);
end $$;

-- ---------- 6. Stripe webhook → BEAU PH evidence/normalization → host ledger (exactly once) ----------
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

  -- BEAU PH: evidence is kept verbatim for every event; a request (when one exists) is normalized.
  ph := beau_ph.ingest_stripe_event(p_event);
  ph_event := (ph ->> 'payment_event_id')::uuid;

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
      -- order created before BEAU PH (no request on file): legacy validation, same rule
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
      -- BEAU PH refused the paid claim (amount mismatch, disabled rail, mode mismatch, already paid…): evidence kept, ledger untouched
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
    perform public.recompute_earning(o.id);   -- Stripe = Oolala-collected → commission applies (booking and pack alike)
    if ph_event is not null then perform beau_ph.mark_reconciled(ph_event, p.id::text, 'public.payments'); end if;

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

-- ---------- 7. manual / external receipt → BEAU PH manual confirmation → host ledger ----------
-- Aani and bank transfer are BEAU PH manual providers (request → operator confirmation →
-- normalized paid event → reconciled once). cash / manual / external are host-only
-- sources (not BEAU PH rails) recorded straight into the ledger, as before.
create or replace function public.payment_record_manual(
  p_pack_id uuid, p_amount int, p_currency text, p_source text default 'aani', p_reference text default null, p_paid_at timestamptz default null)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare e text := public.current_email(); sp public.session_packs%rowtype; o public.orders%rowtype; c public.crm_contacts%rowtype;
  v_ref text; pay public.payments%rowtype; req jsonb; conf jsonb; superseded text;
begin
  if not public.has_permission('finance:manage') then raise exception 'forbidden' using errcode = '42501'; end if;
  if p_source not in ('aani','bank_transfer','cash','manual','external') then raise exception 'invalid source' using errcode = '22023'; end if;
  if p_amount is null or p_amount <= 0 then raise exception 'amount required' using errcode = '22023'; end if;
  if coalesce(p_currency,'') !~ '^[A-Z]{3}$' then raise exception 'currency required (ISO 4217)' using errcode = '22023'; end if;
  select * into sp from public.session_packs where id = p_pack_id for update;
  if not found then raise exception 'pack not found' using errcode = 'P0002'; end if;
  select * into c from public.crm_contacts where id = sp.crm_contact_id;

  select * into o from public.orders where session_pack_id = sp.id and status in ('pending_payment') limit 1;
  if found and (o.currency <> p_currency or o.gross_amount <> p_amount) then
    -- the money received differs from the pending intent (e.g. an abandoned card attempt):
    -- supersede that intent explicitly — never convert, never guess
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

  if p_source in ('aani','bank_transfer') then
    -- BEAU PH manual rail: request (instructions issued) → authorised operator confirms receipt → normalized paid event
    req  := public.cg_ph_request_for_order(o, p_source, '{}'::jsonb, false);
    conf := beau_ph.confirm_manual((req ->> 'id')::uuid, e, p_amount, p_currency, nullif(p_reference, ''), p_paid_at, null);
    insert into public.payments (order_id, provider, amount, currency, status, paid_at, note, ph_request_id, ph_event_id)
    values (o.id, p_source, p_amount, p_currency, 'succeeded', coalesce(p_paid_at, now()), nullif(p_reference,''), (req ->> 'id')::uuid, (conf ->> 'payment_event_id')::uuid)
    returning * into pay;
    perform beau_ph.mark_reconciled((conf ->> 'payment_event_id')::uuid, pay.id::text, 'public.payments');
  else
    insert into public.payments (order_id, provider, amount, currency, status, paid_at, note)
    values (o.id, p_source, p_amount, p_currency, 'succeeded', coalesce(p_paid_at, now()), nullif(p_reference,''))
    returning * into pay;
  end if;
  update public.orders set status = 'paid', paid_at = coalesce(paid_at, pay.paid_at) where id = o.id;
  perform public.project_pack_payment(o.id);       -- source recorded on the pack; NO recompute_earning (not Oolala-collected)
  insert into public.admin_audit (area, entity_id, action, changed_by, summary)
  values ('payment', o.reference, 'manual', e, jsonb_build_object('pack', sp.id, 'source', p_source, 'amount', p_amount, 'currency', p_currency,
                                                                   'beau_ph_request', req ->> 'id', 'superseded_order', superseded));
  return jsonb_build_object('ok', true, 'order', o.reference, 'payment_id', pay.id, 'source', p_source,
                            'request_id', req ->> 'id', 'public_reference', req ->> 'public_reference', 'superseded_order', superseded);
end $$;

-- ---------- 8. report page: authoritative eligible-method list ----------
-- p_runtime is the adapters' deployment readiness reported by the Edge Function
-- (e.g. Stripe test key present). Legacy aani/bank blocks are derived from the list.
drop function if exists public.report_view(text);
create or replace function public.report_view(p_token text, p_runtime jsonb default '{}'::jsonb)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare t public.report_tokens%rowtype; recap jsonb; ref text; cur text; ctry text; methods jsonb; mth jsonb;
  aani_json jsonb := jsonb_build_object('enabled', false); bank_json jsonb := jsonb_build_object('enabled', false);
begin
  if p_token is null or p_token !~ '^[0-9a-f]{64}$' then raise exception 'invalid token' using errcode = 'P0002'; end if;
  select * into t from public.report_tokens where token_hash = encode(extensions.digest(p_token,'sha256'),'hex');
  if not found then raise exception 'invalid token' using errcode = 'P0002'; end if;
  if t.revoked_at is not null then raise exception 'this link has been revoked' using errcode = 'P0003'; end if;
  if t.expires_at is not null and t.expires_at < now() then raise exception 'this link has expired' using errcode = 'P0003'; end if;
  recap := public.pack_recap_data(t.session_pack_id, true);
  select sp.public_ref, sp.currency, public.cg_country_code(c.country) into ref, cur, ctry
    from public.session_packs sp left join public.crm_contacts c on c.id = sp.crm_contact_id where sp.id = t.session_pack_id;
  ref := coalesce(ref, 'CG-' || upper(substr(t.session_pack_id::text, 1, 6)));
  -- what this client can actually be offered: merchant config × country × currency × adapter readiness (server-side, BEAU PH)
  methods := (select coalesce(jsonb_agg(e || jsonb_build_object('reference', ref)), '[]'::jsonb)
                from jsonb_array_elements(beau_ph.eligible_methods('coach_gari', ctry, cur, p_runtime)) e);
  for mth in select * from jsonb_array_elements(methods) loop
    if mth ->> 'provider' = 'aani' then
      aani_json := jsonb_build_object('enabled', true, 'reference', ref, 'currency', mth ->> 'settlement_currency') || coalesce(mth -> 'instructions', '{}'::jsonb);
    elsif mth ->> 'provider' = 'bank_transfer' then
      bank_json := jsonb_build_object('enabled', true, 'reference', ref, 'currency', mth ->> 'settlement_currency') || coalesce(mth -> 'instructions', '{}'::jsonb);
    end if;
  end loop;
  return jsonb_build_object('ok', true, 'recap', recap, 'pay_ref', ref, 'currency', cur, 'customer_country', ctry,
                            'methods', methods, 'aani', aani_json, 'bank', bank_json);
end $$;
revoke execute on function public.report_view(text, jsonb) from public, anon, authenticated;
grant  execute on function public.report_view(text, jsonb) to service_role;

-- ---------- 9. pack payment history now shows the BEAU PH side (status per rail) ----------
create or replace function public.pack_payment_history(p_pack_id uuid)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare fin boolean := public.has_permission('finance:view');
begin
  if not public.has_permission('coach:operations') then raise exception 'forbidden' using errcode = '42501'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object(
      'order_reference', o.reference, 'status', o.status, 'created_at', o.created_at,
      'amount', case when fin then o.gross_amount else null end, 'currency', o.currency,
      'paid_at', o.paid_at,
      'source', (select p.provider from public.payments p where p.order_id = o.id and p.status='succeeded' order by p.paid_at desc nulls last limit 1),
      'requests', (select coalesce(jsonb_agg(jsonb_build_object('provider', r ->> 'provider', 'status', r ->> 'status', 'public_reference', r ->> 'public_reference',
                                                                'created_at', r ->> 'created_at', 'paid_at', r ->> 'paid_at')), '[]'::jsonb)
                     from jsonb_array_elements(beau_ph.requests_for('coach_gari', o.reference)) r)
    ) order by o.created_at desc)
    from public.orders o where o.session_pack_id = p_pack_id), '[]'::jsonb);
end $$;

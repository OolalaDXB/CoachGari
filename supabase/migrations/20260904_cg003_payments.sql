-- CG-003 — orders · payments · refunds · chargebacks · webhook_events ·
-- partner_earnings · partner_settlements(+items) · email_events
--
-- Stripe is payment infrastructure, not the business database. Only webhook-
-- driven, signature-verified, idempotent server state (process_stripe_event)
-- can mark an order paid and a booking confirmed. Economics are explicit:
--   net_collected     = gross − stripe_fee − refunds − chargebacks − tax
--   oolala_commission = max(0, round(net_collected × 10%))
--   gari_payable      = net_collected − oolala_commission
-- TEST MODE ONLY until CHECK-LICENCE-001 is cleared (the checkout function
-- refuses live keys in code).

/* ------------------------------------------------------------------ */
/* pending_payment must also expire (abandoned checkout ≠ reservation)  */
/* ------------------------------------------------------------------ */
create or replace function public.booking_is_active(p_status text, p_hold_expires_at timestamptz)
returns boolean language sql stable set search_path = '' as $$
  select p_status = 'confirmed'
      or (p_status in ('hold','pending_payment') and p_hold_expires_at is not null and p_hold_expires_at > now())
$$;

create or replace function public.expire_holds()
returns int language plpgsql volatile security definer set search_path = '' as $$
declare n int;
begin
  update public.bookings set status = 'expired'
   where status in ('hold','pending_payment') and hold_expires_at < now();
  get diagnostics n = row_count;
  -- an expired pending_payment leaves its order behind: close it
  update public.orders o set status = 'cancelled'
   where o.status = 'pending_payment'
     and exists (select 1 from public.bookings b where b.id = o.booking_id and b.status = 'expired');
  return n;
end $$;

/* ------------------------------------------------------------------ */
/* tables                                                              */
/* ------------------------------------------------------------------ */
create table if not exists public.orders (
  id                         uuid primary key default gen_random_uuid(),
  reference                  text not null unique,                 -- OR-XXXXXX
  booking_id                 uuid not null references public.bookings(id),
  customer_name              text not null,
  customer_contact           text not null,                        -- minimal reference for reconciliation
  currency                   text not null,
  gross_amount               int  not null check (gross_amount > 0),
  status                     text not null default 'pending_payment'
                             check (status in ('draft','pending_payment','paid','failed','cancelled','partially_refunded','refunded')),
  stripe_checkout_session_id text unique,
  checkout_url               text,
  checkout_expires_at        timestamptz,
  checkout_attempts          int not null default 0,
  paid_at                    timestamptz,
  created_at                 timestamptz not null default now(),
  updated_at                 timestamptz not null default now()
);
create unique index if not exists orders_one_live_per_booking on public.orders (booking_id)
  where status in ('pending_payment','paid','partially_refunded','refunded');
create trigger orders_updated_at before update on public.orders for each row execute function public.set_updated_at();

create table if not exists public.payments (
  id                              uuid primary key default gen_random_uuid(),
  order_id                        uuid not null references public.orders(id),
  provider                        text not null default 'stripe',
  provider_payment_intent_id      text unique,
  provider_charge_id              text,
  provider_balance_transaction_id text,
  amount                          int  not null,
  currency                        text not null,
  fee_amount                      int  not null default 0,          -- Stripe fee from the balance transaction
  fee_known                       boolean not null default false,
  status                          text not null check (status in ('succeeded','failed','pending')),
  paid_at                         timestamptz,
  provider_event_id               text,
  created_at                      timestamptz not null default now(),
  updated_at                      timestamptz not null default now()
);
create index if not exists payments_order_idx on public.payments (order_id);
create trigger payments_updated_at before update on public.payments for each row execute function public.set_updated_at();

create table if not exists public.refunds (
  id                 uuid primary key default gen_random_uuid(),
  payment_id         uuid references public.payments(id),
  order_id           uuid not null references public.orders(id),
  amount             int  not null check (amount > 0),
  currency           text not null,
  reason             text,
  provider_refund_id text unique,
  status             text not null check (status in ('pending','succeeded','failed','cancelled')),
  provider_event_id  text,
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now()
);
create index if not exists refunds_order_idx on public.refunds (order_id);
create trigger refunds_updated_at before update on public.refunds for each row execute function public.set_updated_at();

create table if not exists public.chargebacks (
  id                  uuid primary key default gen_random_uuid(),
  payment_id          uuid references public.payments(id),
  order_id            uuid not null references public.orders(id),
  amount              int  not null check (amount > 0),
  currency            text not null,
  provider_dispute_id text unique,
  status              text not null,                                 -- Stripe dispute status, kept verbatim; only 'lost' hits the ledger
  reason              text,
  provider_event_id   text,
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now()
);
create index if not exists chargebacks_order_idx on public.chargebacks (order_id);
create trigger chargebacks_updated_at before update on public.chargebacks for each row execute function public.set_updated_at();

create table if not exists public.webhook_events (
  id           uuid primary key default gen_random_uuid(),
  provider     text not null default 'stripe',
  event_id     text not null unique,
  event_type   text not null,
  payload      jsonb not null,
  status       text not null default 'received' check (status in ('received','processed','ignored')),
  note         text,
  received_at  timestamptz not null default now(),
  processed_at timestamptz
);

create table if not exists public.partner_earnings (
  id                uuid primary key default gen_random_uuid(),
  order_id          uuid not null unique references public.orders(id),
  payment_id        uuid references public.payments(id),
  partner           text not null default 'gari',
  currency          text not null,
  gross_amount      int  not null,
  stripe_fee        int  not null default 0,
  refund_amount     int  not null default 0,
  chargeback_amount int  not null default 0,
  tax_amount        int  not null default 0,
  net_collected     int  not null,
  commission_rate   numeric(6,4) not null default 0.1000,
  oolala_commission int  not null,
  gari_payable      int  not null,
  status            text not null default 'open' check (status in ('open','settled','cancelled')),
  settlement_id     uuid,
  adjusted_at       timestamptz,          -- set when economics change after settlement
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),
  check (net_collected = gross_amount - stripe_fee - refund_amount - chargeback_amount - tax_amount),
  check (gari_payable = net_collected - oolala_commission)
);
create trigger partner_earnings_updated_at before update on public.partner_earnings for each row execute function public.set_updated_at();

create table if not exists public.partner_settlements (
  id                      uuid primary key default gen_random_uuid(),
  reference               text not null unique,                   -- ST-XXXXXX
  partner                 text not null default 'gari',
  period_start            date not null,
  period_end              date not null,
  currency                text not null,
  gross_amount            int not null default 0,
  refund_amount           int not null default 0,
  chargeback_amount       int not null default 0,
  fee_amount              int not null default 0,
  net_collected           int not null default 0,
  oolala_commission       int not null default 0,
  amount_payable          int not null default 0,
  status                  text not null default 'open' check (status in ('open','ready','paid','reconciled','cancelled')),
  bank_transfer_reference text,
  paid_at                 timestamptz,
  reconciled_at           timestamptz,
  notes                   text,
  created_at              timestamptz not null default now(),
  updated_at              timestamptz not null default now(),
  check (period_end >= period_start)
);
create trigger partner_settlements_updated_at before update on public.partner_settlements for each row execute function public.set_updated_at();
alter table public.partner_earnings
  add constraint partner_earnings_settlement_fk foreign key (settlement_id) references public.partner_settlements(id);

create table if not exists public.partner_settlement_items (
  settlement_id uuid not null references public.partner_settlements(id) on delete cascade,
  earning_id    uuid not null unique references public.partner_earnings(id),
  order_id      uuid not null references public.orders(id),
  gross_amount int not null, stripe_fee int not null, refund_amount int not null, chargeback_amount int not null,
  net_collected int not null, oolala_commission int not null, gari_payable int not null,
  primary key (settlement_id, earning_id)
);

create table if not exists public.email_events (
  id                  uuid primary key default gen_random_uuid(),
  booking_id          uuid references public.bookings(id),
  order_id            uuid references public.orders(id),
  kind                text not null check (kind in ('booking_confirmed','payment_received','booking_cancelled','reminder','reschedule','session_link')),
  to_address          text,
  from_address        text not null default 'Coach Gari <yoursession@coachgari.com>',
  status              text not null default 'pending' check (status in ('pending','sent','skipped','failed')),
  provider_message_id text,
  error               text,
  attempts            int not null default 0,
  created_at          timestamptz not null default now(),
  sent_at             timestamptz,
  unique (order_id, kind)
);

/* ------------------------------------------------------------------ */
/* privileges                                                          */
/* ------------------------------------------------------------------ */
alter table public.orders enable row level security;
alter table public.payments enable row level security;
alter table public.refunds enable row level security;
alter table public.chargebacks enable row level security;
alter table public.webhook_events enable row level security;
alter table public.partner_earnings enable row level security;
alter table public.partner_settlements enable row level security;
alter table public.partner_settlement_items enable row level security;
alter table public.email_events enable row level security;
revoke all on public.orders, public.payments, public.refunds, public.chargebacks, public.webhook_events,
              public.partner_earnings, public.partner_settlements, public.partner_settlement_items, public.email_events
  from anon, authenticated;

/* ------------------------------------------------------------------ */
/* booking_to_json now carries the live order                          */
/* ------------------------------------------------------------------ */
create or replace function public.booking_to_json(b public.bookings)
returns jsonb language sql stable set search_path = '' as $$
  select jsonb_build_object(
    'reference', b.reference,
    'manage_token', b.manage_token,
    'status', b.status,
    'start_at', b.start_at,
    'end_at', b.end_at,
    'session_timezone', b.session_timezone,
    'local_start', to_char(b.start_at at time zone b.session_timezone, 'YYYY-MM-DD"T"HH24:MI'),
    'delivery_mode', b.delivery_mode,
    'participant_count', b.participant_count,
    'hold_expires_at', b.hold_expires_at,
    'price_amount', b.price_amount,
    'currency', b.currency,
    'customer_name', b.customer_name,
    'created_at', b.created_at,
    'service', (select jsonb_build_object('slug', s.slug, 'title', s.title, 'duration_minutes', s.duration_minutes,
                                          'delivery_mode', s.delivery_mode)
                from public.services s where s.id = b.service_id),
    'tour_stop', (select jsonb_build_object('slug', t.slug, 'city', t.city, 'country', t.country,
                                            'timezone', t.timezone, 'venue', t.venue, 'address', t.address,
                                            'location_notes', t.location_notes)
                  from public.tour_stops t where t.id = b.tour_stop_id),
    'order', (select jsonb_build_object('reference', o.reference, 'status', o.status, 'gross_amount', o.gross_amount,
                                        'currency', o.currency, 'paid_at', o.paid_at,
                                        'checkout_expires_at', o.checkout_expires_at)
              from public.orders o where o.booking_id = b.id
              order by (o.status in ('pending_payment','paid','partially_refunded','refunded')) desc, o.created_at desc
              limit 1)
  )
$$;

/* ------------------------------------------------------------------ */
/* orders                                                              */
/* ------------------------------------------------------------------ */
create or replace function public.order_to_json(o public.orders)
returns jsonb language sql stable set search_path = '' as $$
  select jsonb_build_object(
    'reference', o.reference, 'status', o.status, 'gross_amount', o.gross_amount, 'currency', o.currency,
    'checkout_url', o.checkout_url, 'checkout_expires_at', o.checkout_expires_at, 'checkout_attempts', o.checkout_attempts,
    'paid_at', o.paid_at, 'customer_name', o.customer_name, 'customer_contact', o.customer_contact,
    'booking', (select jsonb_build_object('reference', b.reference, 'start_at', b.start_at, 'session_timezone', b.session_timezone,
                                          'hold_expires_at', b.hold_expires_at, 'status', b.status,
                                          'service_title', (select s.title from public.services s where s.id = b.service_id))
                from public.bookings b where b.id = o.booking_id)
  )
$$;

-- Trusted order for a held booking: amount and currency come from the booking's
-- price snapshot (itself copied from the service), never from the caller.
create or replace function public.create_order_for_booking(p_reference text, p_manage_token text)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare b public.bookings%rowtype; o public.orders%rowtype; v_ref text;
begin
  select * into b from public.bookings where reference = upper(p_reference) and manage_token = p_manage_token for update;
  if not found then raise exception 'booking not found' using errcode = 'P0002'; end if;
  if b.status in ('hold','pending_payment') and b.hold_expires_at < now() then
    update public.bookings set status = 'expired' where id = b.id;
    raise exception 'hold expired' using errcode = 'P0003';
  end if;
  if b.status not in ('hold','pending_payment') then
    raise exception 'booking not payable in status %', b.status using errcode = 'P0003';
  end if;
  if b.price_amount is null then raise exception 'priced on request' using errcode = 'P0003'; end if;

  select * into o from public.orders where booking_id = b.id and status = 'pending_payment';
  if found then return public.order_to_json(o); end if;

  loop
    v_ref := 'OR-' || upper(substr(encode(extensions.gen_random_bytes(4), 'hex'), 1, 6));
    exit when not exists (select 1 from public.orders where reference = v_ref);
  end loop;
  insert into public.orders (reference, booking_id, customer_name, customer_contact, currency, gross_amount, status)
  values (v_ref, b.id, b.customer_name, b.customer_contact, b.currency, b.price_amount, 'pending_payment')
  returning * into o;
  return public.order_to_json(o);
end $$;

-- Called by the checkout function once Stripe created the session. Aligns the
-- hold with the Checkout expiry so an abandoned session releases capacity.
create or replace function public.attach_checkout(p_order_reference text, p_session_id text, p_url text, p_expires_at timestamptz)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare o public.orders%rowtype;
begin
  update public.orders
     set stripe_checkout_session_id = p_session_id, checkout_url = p_url, checkout_expires_at = p_expires_at,
         checkout_attempts = checkout_attempts + 1
   where reference = p_order_reference and status = 'pending_payment'
   returning * into o;
  if not found then raise exception 'order not pending' using errcode = 'P0003'; end if;
  update public.bookings set status = 'pending_payment', hold_expires_at = p_expires_at
   where id = o.booking_id and status in ('hold','pending_payment');
  return public.order_to_json(o);
end $$;

/* ------------------------------------------------------------------ */
/* ledger                                                              */
/* ------------------------------------------------------------------ */
create or replace function public.recompute_earning(p_order_id uuid)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare
  o public.orders%rowtype; p public.payments%rowtype;
  v_refunds int; v_chargebacks int; v_tax int := 0; v_net int; v_comm int; v_pay int; v_rate numeric(6,4) := 0.1000;
  e public.partner_earnings%rowtype;
begin
  select * into o from public.orders where id = p_order_id;
  if not found then raise exception 'order not found' using errcode = 'P0002'; end if;
  select * into p from public.payments where order_id = o.id and status = 'succeeded' order by paid_at desc nulls last limit 1;
  if not found then return null; end if;   -- nothing collected yet → no earning

  select coalesce(sum(amount), 0) into v_refunds from public.refunds where order_id = o.id and status = 'succeeded';
  select coalesce(sum(amount), 0) into v_chargebacks from public.chargebacks where order_id = o.id and status = 'lost';
  select coalesce((select commission_rate from public.partner_earnings where order_id = o.id), 0.1000) into v_rate;

  v_net  := p.amount - p.fee_amount - v_refunds - v_chargebacks - v_tax;
  v_comm := greatest(0, round(v_net * v_rate))::int;
  v_pay  := v_net - v_comm;

  insert into public.partner_earnings (order_id, payment_id, currency, gross_amount, stripe_fee, refund_amount, chargeback_amount,
                                       tax_amount, net_collected, commission_rate, oolala_commission, gari_payable)
  values (o.id, p.id, o.currency, p.amount, p.fee_amount, v_refunds, v_chargebacks, v_tax, v_net, v_rate, v_comm, v_pay)
  on conflict (order_id) do update
    set payment_id = excluded.payment_id, gross_amount = excluded.gross_amount, stripe_fee = excluded.stripe_fee,
        refund_amount = excluded.refund_amount, chargeback_amount = excluded.chargeback_amount, tax_amount = excluded.tax_amount,
        net_collected = excluded.net_collected, oolala_commission = excluded.oolala_commission, gari_payable = excluded.gari_payable,
        adjusted_at = case when public.partner_earnings.status = 'settled'
                            and (public.partner_earnings.net_collected <> excluded.net_collected) then now()
                           else public.partner_earnings.adjusted_at end
  returning * into e;
  return to_jsonb(e);
end $$;

/* ------------------------------------------------------------------ */
/* process_stripe_event — idempotent, the only path to "paid/confirmed" */
/* ------------------------------------------------------------------ */
create or replace function public.process_stripe_event(p_event jsonb)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare
  ev_id text := p_event ->> 'id'; ev_type text := p_event ->> 'type'; obj jsonb := p_event -> 'data' -> 'object';
  enrich jsonb := coalesce(p_event -> '_enrich', '{}'::jsonb);
  existing public.webhook_events%rowtype;
  o public.orders%rowtype; b public.bookings%rowtype; p public.payments%rowtype;
  v_amount int; v_currency text; v_pi text; v_charge text; v_refund jsonb; v_total_refunded int; v_status text; v_note text;
  result jsonb;
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

  /* ---- checkout.session.completed ------------------------------- */
  if ev_type = 'checkout.session.completed' then
    select * into o from public.orders where stripe_checkout_session_id = obj ->> 'id';
    if not found and (obj -> 'metadata' ->> 'order_id') is not null then
      select * into o from public.orders where id = (obj -> 'metadata' ->> 'order_id')::uuid;
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
    if v_amount <> o.gross_amount or v_currency <> o.currency then
      -- Never confirm on a mismatch: money stays in Stripe for manual review, the hold expires naturally.
      update public.webhook_events set status = 'ignored', note = format('amount mismatch: got %s %s, order %s %s', v_amount, v_currency, o.gross_amount, o.currency), processed_at = now() where event_id = ev_id;
      return jsonb_build_object('event_id', ev_id, 'status', 'ignored', 'note', 'amount mismatch');
    end if;

    insert into public.payments (order_id, provider_payment_intent_id, provider_charge_id, provider_balance_transaction_id,
                                 amount, currency, fee_amount, fee_known, status, paid_at, provider_event_id)
    values (o.id, v_pi, enrich ->> 'charge_id', enrich ->> 'balance_transaction_id', v_amount, v_currency,
            coalesce((enrich ->> 'fee_amount')::int, 0), (enrich ->> 'fee_amount') is not null, 'succeeded', now(), ev_id)
    on conflict (provider_payment_intent_id) do update
      set fee_amount = case when public.payments.fee_known then public.payments.fee_amount else excluded.fee_amount end,
          fee_known  = public.payments.fee_known or excluded.fee_known,
          provider_charge_id = coalesce(public.payments.provider_charge_id, excluded.provider_charge_id),
          provider_balance_transaction_id = coalesce(public.payments.provider_balance_transaction_id, excluded.provider_balance_transaction_id)
    returning * into p;

    update public.orders set status = 'paid', paid_at = coalesce(paid_at, now())
     where id = o.id and status in ('pending_payment','paid');
    update public.bookings set status = 'confirmed', hold_expires_at = null
     where id = o.booking_id and status in ('hold','pending_payment','confirmed');
    perform public.recompute_earning(o.id);

    select * into b from public.bookings where id = o.booking_id;
    insert into public.email_events (booking_id, order_id, kind, to_address)
    values (b.id, o.id, 'booking_confirmed', case when b.customer_contact ~ '^[^\s@]+@[^\s@]+\.[^\s@]{2,}$' then b.customer_contact else null end),
           (b.id, o.id, 'payment_received', 'letsgo@coachgari.com')
    on conflict (order_id, kind) do nothing;
    -- no email address → mark skipped (WhatsApp contact: Gari confirms manually)
    update public.email_events set status = 'skipped', error = 'no email address (contact is a phone number)'
     where order_id = o.id and kind = 'booking_confirmed' and to_address is null and status = 'pending';

    result := jsonb_build_object('order', o.reference, 'payment_id', p.id, 'booking', b.reference, 'booking_status', 'confirmed');

  /* ---- checkout.session.expired ---------------------------------- */
  elsif ev_type = 'checkout.session.expired' then
    select * into o from public.orders where stripe_checkout_session_id = obj ->> 'id';
    if found then
      update public.orders set status = 'cancelled' where id = o.id and status = 'pending_payment';
      update public.bookings set status = 'expired' where id = o.booking_id and status in ('hold','pending_payment');
      result := jsonb_build_object('order', o.reference, 'status', 'expired');
    else
      update public.webhook_events set status = 'ignored', note = 'unknown order', processed_at = now() where event_id = ev_id;
      return jsonb_build_object('event_id', ev_id, 'status', 'ignored');
    end if;

  /* ---- refund.created / refund.updated --------------------------- */
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
    result := jsonb_build_object('order_id', p.order_id, 'refunded', v_total_refunded);

  /* ---- charge.dispute.* ------------------------------------------ */
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
    on conflict (provider_dispute_id) do update set status = excluded.status, amount = excluded.amount;
    perform public.recompute_earning(p.order_id);
    result := jsonb_build_object('order_id', p.order_id, 'dispute', obj ->> 'status');

  else
    update public.webhook_events set status = 'ignored', note = 'unhandled type', processed_at = now() where event_id = ev_id;
    return jsonb_build_object('event_id', ev_id, 'status', 'ignored', 'type', ev_type);
  end if;

  update public.webhook_events set status = 'processed', processed_at = now() where event_id = ev_id;
  return result || jsonb_build_object('event_id', ev_id, 'status', 'processed');
end $$;

/* ------------------------------------------------------------------ */
/* settlements (manual bank payout, no API)                            */
/* ------------------------------------------------------------------ */
create or replace function public.create_settlement(p_partner text, p_period_start date, p_period_end date, p_currency text default 'USD')
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare s public.partner_settlements%rowtype; v_ref text; n int;
begin
  loop
    v_ref := 'ST-' || upper(substr(encode(extensions.gen_random_bytes(4), 'hex'), 1, 6));
    exit when not exists (select 1 from public.partner_settlements where reference = v_ref);
  end loop;
  insert into public.partner_settlements (reference, partner, period_start, period_end, currency, status)
  values (v_ref, p_partner, p_period_start, p_period_end, p_currency, 'open') returning * into s;

  insert into public.partner_settlement_items (settlement_id, earning_id, order_id, gross_amount, stripe_fee, refund_amount, chargeback_amount, net_collected, oolala_commission, gari_payable)
  select s.id, e.id, e.order_id, e.gross_amount, e.stripe_fee, e.refund_amount, e.chargeback_amount, e.net_collected, e.oolala_commission, e.gari_payable
  from public.partner_earnings e
  join public.orders o on o.id = e.order_id
  where e.partner = p_partner and e.status = 'open' and e.currency = p_currency
    and o.paid_at >= p_period_start and o.paid_at < (p_period_end + 1);
  get diagnostics n = row_count;

  update public.partner_earnings e set status = 'settled', settlement_id = s.id
   where e.id in (select earning_id from public.partner_settlement_items where settlement_id = s.id);

  update public.partner_settlements set
    gross_amount = coalesce((select sum(gross_amount) from public.partner_settlement_items where settlement_id = s.id), 0),
    refund_amount = coalesce((select sum(refund_amount) from public.partner_settlement_items where settlement_id = s.id), 0),
    chargeback_amount = coalesce((select sum(chargeback_amount) from public.partner_settlement_items where settlement_id = s.id), 0),
    fee_amount = coalesce((select sum(stripe_fee) from public.partner_settlement_items where settlement_id = s.id), 0),
    net_collected = coalesce((select sum(net_collected) from public.partner_settlement_items where settlement_id = s.id), 0),
    oolala_commission = coalesce((select sum(oolala_commission) from public.partner_settlement_items where settlement_id = s.id), 0),
    amount_payable = coalesce((select sum(gari_payable) from public.partner_settlement_items where settlement_id = s.id), 0),
    status = case when n > 0 then 'ready' else 'open' end
  where id = s.id returning * into s;
  return to_jsonb(s) || jsonb_build_object('items', n);
end $$;

create or replace function public.mark_settlement_paid(p_reference text, p_bank_transfer_reference text)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare s public.partner_settlements%rowtype;
begin
  update public.partner_settlements set status = 'paid', bank_transfer_reference = p_bank_transfer_reference, paid_at = now()
   where reference = p_reference and status = 'ready' returning * into s;
  if not found then raise exception 'settlement not ready' using errcode = 'P0003'; end if;
  return to_jsonb(s);
end $$;

create or replace function public.mark_settlement_reconciled(p_reference text)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare s public.partner_settlements%rowtype;
begin
  update public.partner_settlements set status = 'reconciled', reconciled_at = now()
   where reference = p_reference and status = 'paid' returning * into s;
  if not found then raise exception 'settlement not paid' using errcode = 'P0003'; end if;
  return to_jsonb(s);
end $$;

/* ------------------------------------------------------------------ */
/* function privileges                                                 */
/* ------------------------------------------------------------------ */
revoke execute on function public.order_to_json(public.orders)                                  from public, anon, authenticated;
revoke execute on function public.create_order_for_booking(text, text)                           from public, anon, authenticated;
revoke execute on function public.attach_checkout(text, text, text, timestamptz)                 from public, anon, authenticated;
revoke execute on function public.recompute_earning(uuid)                                        from public, anon, authenticated;
revoke execute on function public.process_stripe_event(jsonb)                                    from public, anon, authenticated;
revoke execute on function public.create_settlement(text, date, date, text)                      from public, anon, authenticated;
revoke execute on function public.mark_settlement_paid(text, text)                               from public, anon, authenticated;
revoke execute on function public.mark_settlement_reconciled(text)                               from public, anon, authenticated;
revoke execute on function public.booking_to_json(public.bookings)                               from public, anon, authenticated;
revoke execute on function public.booking_is_active(text, timestamptz)                           from public, anon, authenticated;
revoke execute on function public.expire_holds()                                                 from public, anon, authenticated;
grant execute on function public.create_order_for_booking(text, text)                            to service_role;
grant execute on function public.attach_checkout(text, text, text, timestamptz)                  to service_role;
grant execute on function public.process_stripe_event(jsonb)                                     to service_role;
grant execute on function public.recompute_earning(uuid)                                         to service_role;
grant execute on function public.create_settlement(text, date, date, text)                       to service_role;
grant execute on function public.mark_settlement_paid(text, text)                                to service_role;
grant execute on function public.mark_settlement_reconciled(text)                                to service_role;
grant execute on function public.expire_holds()                                                  to service_role;

comment on table public.partner_earnings is 'CG-003 — per-order economics. net = gross − fee − refunds − chargebacks − tax; commission = max(0, round(net×rate)); payable = net − commission.';
comment on table public.webhook_events is 'CG-003 — every Stripe event once; processed/ignored; the idempotency anchor.';

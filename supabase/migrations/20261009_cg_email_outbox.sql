-- =====================================================================
-- Coach Gari — transactional email outbox (Resend)
--
-- One outbox (public.email_events) for every customer / owner email. Rows are
-- QUEUED by the authoritative state change (a payment reconciled by BEAU PH, a
-- confirmed booking cancelled or rescheduled, an enquiry stored) and SENT by
-- the Edge Functions (stripe-webhook / contact / booking drain their own rows
-- right away, the `email-outbox` function drains the rest on a schedule).
--
--  * idempotent: every row carries a dedupe_key; queuing is `on conflict do
--    nothing`, so a replayed webhook, a double click or a re-run never
--    queues (or sends) twice
--  * sending never touches booking / order / payment state: a failed send is a
--    row in pending (retry, exponential backoff) or failed, nothing else
--  * the payload is the render data only (name, reference, service, time,
--    amount): no notes, no health data, no CRM content
--  * the Resend API key never enters the database; delivery state is the
--    provider message id + a short error text
-- Forward migration only.
-- =====================================================================

-- ---------- 1. outbox columns + kinds ----------
alter table public.email_events
  add column if not exists contact_id      uuid references public.contacts(id) on delete set null,
  add column if not exists dedupe_key      text,
  add column if not exists payload         jsonb not null default '{}'::jsonb,
  add column if not exists next_attempt_at timestamptz not null default now(),
  add column if not exists last_attempt_at timestamptz;
create unique index if not exists email_events_dedupe_key_key on public.email_events (dedupe_key) where dedupe_key is not null;
create index if not exists email_events_pending_idx on public.email_events (next_attempt_at) where status = 'pending';
alter table public.email_events drop constraint if exists email_events_kind_check;
alter table public.email_events add constraint email_events_kind_check
  check (kind in ('booking_confirmed','payment_received','booking_cancelled','reminder','reschedule','session_link',
                  'payment_confirmed','support_thanks','enquiry_received','lead_notification'));
update public.email_events set dedupe_key = 'order:' || order_id || ':' || kind where dedupe_key is null and order_id is not null;
update public.email_events set dedupe_key = 'booking:' || booking_id || ':' || kind || ':' || id where dedupe_key is null and booking_id is not null;

-- the owner's human mailbox (leads, notices); the sender identities live in the Edge Function secrets
create or replace function public.email_owner_address() returns text language sql immutable as $$ select 'letsgo@coachgari28.com'::text $$;
create or replace function public.is_email_address(p text) returns boolean language sql immutable as $$ select coalesce(p, '') ~ '^[^\s@]+@[^\s@]+\.[^\s@]{2,}$' $$;

-- ---------- 2. queue ----------
-- Returns the new row id, or null when the key already exists (or the row was skipped for want of an address).
create or replace function public.email_queue(p_kind text, p_to text, p_payload jsonb, p_dedupe_key text,
                                              p_booking_id uuid default null, p_order_id uuid default null, p_contact_id uuid default null)
returns uuid language plpgsql volatile security definer set search_path = '' as $$
declare v_id uuid;
begin
  insert into public.email_events (booking_id, order_id, contact_id, kind, to_address, dedupe_key, payload, status, error)
  values (p_booking_id, p_order_id, p_contact_id, p_kind, case when public.is_email_address(p_to) then lower(btrim(p_to)) else null end, p_dedupe_key,
          coalesce(p_payload, '{}'::jsonb),
          case when public.is_email_address(p_to) then 'pending' else 'skipped' end,
          case when public.is_email_address(p_to) then null else 'no email address' end)
  on conflict do nothing
  returning id into v_id;
  return v_id;
end $$;
revoke execute on function public.email_queue(text, text, jsonb, text, uuid, uuid, uuid) from public, anon, authenticated;
grant  execute on function public.email_queue(text, text, jsonb, text, uuid, uuid, uuid) to service_role;

-- render data for a booking: what the customer needs, nothing else (no notes, no ip, no tokens)
create or replace function public.email_payload_booking(b public.bookings)
returns jsonb language sql stable security definer set search_path = '' as $$
  select jsonb_build_object(
    'name', b.customer_name, 'reference', b.reference,
    'service_title', coalesce(b.service_title, (select s.title from public.services s where s.id = b.service_id)),
    'start_at', b.start_at, 'end_at', b.end_at, 'timezone', b.session_timezone,
    'duration_minutes', coalesce(b.service_duration_minutes, (extract(epoch from (b.end_at - b.start_at)) / 60)::int),
    'delivery_mode', b.delivery_mode,
    'where', case when b.tour_stop_id is not null then (select t.city || ', ' || t.country || coalesce(' · ' || t.venue, '') from public.tour_stops t where t.id = b.tour_stop_id)
                  when b.delivery_mode = 'online' then 'Online' else 'In person' end)
$$;

-- ---------- 3. producers ----------
-- A payment reconciled as paid (Stripe webhook after BEAU PH normalisation, or an operator-confirmed manual rail).
-- booking  → booking_confirmed (customer) + payment_received (owner)
-- pack     → payment_confirmed (customer, from the CRM contact's email) + payment_received (owner)
-- support  → support_thanks (payer email as captured by Stripe Checkout) + payment_received (owner)
create or replace function public.email_on_order_paid(p_order_id uuid, p_payer_email text default null)
returns void language plpgsql volatile security definer set search_path = '' as $$
declare o public.orders%rowtype; b public.bookings%rowtype; sp public.session_packs%rowtype; c public.crm_contacts%rowtype;
  pay public.payments%rowtype; pub text; base jsonb; owner_to text := public.email_owner_address();
begin
  select * into o from public.orders where id = p_order_id;
  if not found or o.status <> 'paid' then return; end if;
  select * into pay from public.payments where order_id = o.id and status = 'succeeded' order by paid_at desc nulls last limit 1;
  select r.public_reference into pub from beau_ph.payment_requests r where r.external_reference = o.reference and r.status = 'paid' order by r.created_at desc limit 1;
  base := jsonb_build_object('order_reference', o.reference, 'amount', o.gross_amount, 'currency', o.currency, 'paid_at', coalesce(pay.paid_at, o.paid_at),
                             'paid_amount', pay.amount, 'paid_currency', pay.currency, 'method', coalesce(pay.provider, 'stripe'), 'reason', o.order_reason);
  if o.booking_id is not null then
    select * into b from public.bookings where id = o.booking_id;
    perform public.email_queue('booking_confirmed', b.customer_contact, public.email_payload_booking(b) || base, 'order:' || o.id || ':booking_confirmed', b.id, o.id);
    perform public.email_queue('payment_received', owner_to, public.email_payload_booking(b) || base || jsonb_build_object('type', 'booking', 'contact', b.customer_contact),
                               'order:' || o.id || ':payment_received', b.id, o.id);
  elsif o.session_pack_id is not null then
    select * into sp from public.session_packs where id = o.session_pack_id;
    select * into c from public.crm_contacts where id = sp.crm_contact_id;
    base := base || jsonb_build_object('name', coalesce(c.display_name, o.customer_name), 'pack_title', sp.title, 'sessions', sp.total_sessions, 'public_ref', coalesce(pub, sp.public_ref));
    perform public.email_queue('payment_confirmed', c.email, base, 'order:' || o.id || ':payment_confirmed', null, o.id);
    perform public.email_queue('payment_received', owner_to, base || jsonb_build_object('type', 'package', 'contact', coalesce(c.email, c.phone, o.customer_contact)),
                               'order:' || o.id || ':payment_received', null, o.id);
  elsif o.order_reason = 'support' then
    base := base || jsonb_build_object('public_ref', pub);
    perform public.email_queue('support_thanks', p_payer_email, base, 'order:' || o.id || ':support_thanks', null, o.id);
    perform public.email_queue('payment_received', owner_to, base || jsonb_build_object('type', 'support'), 'order:' || o.id || ':payment_received', null, o.id);
  end if;
end $$;
revoke execute on function public.email_on_order_paid(uuid, text) from public, anon, authenticated;
grant  execute on function public.email_on_order_paid(uuid, text) to service_role;

-- A confirmed booking cancelled (by the customer or by the coach) → booking_cancelled, once per booking.
create or replace function public.email_on_booking_cancelled(p_booking_id uuid)
returns void language plpgsql volatile security definer set search_path = '' as $$
declare b public.bookings%rowtype;
begin
  select * into b from public.bookings where id = p_booking_id;
  if not found or b.status <> 'cancelled' then return; end if;
  perform public.email_queue('booking_cancelled', b.customer_contact,
                             public.email_payload_booking(b) || jsonb_build_object('cancelled_by', b.cancelled_by, 'cancelled_at', b.cancelled_at),
                             'booking:' || b.id || ':booking_cancelled', b.id, (select id from public.orders where booking_id = b.id order by created_at desc limit 1));
end $$;
revoke execute on function public.email_on_booking_cancelled(uuid) from public, anon, authenticated;
grant  execute on function public.email_on_booking_cancelled(uuid) to service_role;

-- An enquiry stored → lead_notification (owner) + enquiry_received (customer, when the contact is an email)
create or replace function public.email_on_enquiry(p_contact_id uuid)
returns void language plpgsql volatile security definer set search_path = '' as $$
declare c public.contacts%rowtype; base jsonb;
begin
  select * into c from public.contacts where id = p_contact_id;
  if not found then return; end if;
  base := jsonb_build_object('name', c.name, 'interest', c.interest, 'where', coalesce(nullif(concat_ws(', ', c.city, c.country), ''), c.location_raw));
  perform public.email_queue('lead_notification', public.email_owner_address(),
                             base || jsonb_build_object('contact', c.contact, 'message', c.message, 'page', c.page, 'created_at', c.created_at, 'record', c.id,
                                                        'attribution', concat_ws(' · ', 'source: ' || c.utm_source, 'medium: ' || c.utm_medium, 'campaign: ' || c.utm_campaign,
                                                                                 'referrer: ' || c.referrer, 'landing: ' || c.landing_page)),
                             'contact:' || c.id || ':lead_notification', null, null, c.id);
  perform public.email_queue('enquiry_received', c.contact, base, 'contact:' || c.id || ':enquiry_received', null, null, c.id);
end $$;
revoke execute on function public.email_on_enquiry(uuid) from public, anon, authenticated;
grant  execute on function public.email_on_enquiry(uuid) to service_role;

-- ---------- 4. cancel paths queue the email ----------
-- customer (manage token): same body as 20260904, plus the outbox call for a booking that was confirmed
create or replace function public.cancel_booking(p_reference text, p_manage_token text, p_reason text default null)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare b public.bookings%rowtype; was_confirmed boolean;
begin
  select * into b from public.bookings where reference = upper(p_reference) and manage_token = p_manage_token for update;
  if not found then raise exception 'booking not found' using errcode = 'P0002'; end if;
  if b.status not in ('hold','pending_payment','confirmed') then
    raise exception 'booking cannot be cancelled in status %', b.status using errcode = 'P0003';
  end if;
  if b.start_at <= now() then
    raise exception 'session already started' using errcode = 'P0003';
  end if;
  was_confirmed := b.status = 'confirmed';
  update public.bookings
     set status = 'cancelled', cancelled_at = now(), cancelled_by = 'customer',
         cancel_reason = nullif(btrim(coalesce(p_reason, '')), '')
   where id = b.id returning * into b;
  if was_confirmed then perform public.email_on_booking_cancelled(b.id); end if;
  return public.booking_to_json(b);
end $$;

-- coach: same body as 20260905, the cancel email goes through the outbox (confirmed bookings only)
create or replace function public.ops_set_booking_status(p_reference text, p_status text, p_reason text default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare b public.bookings; v_price int; was_confirmed boolean;
begin
  if not public.has_permission('coach:operations') then raise exception 'forbidden' using errcode = '42501'; end if;
  select * into b from public.bookings where reference = upper(trim(p_reference)) for update;
  if not found then raise exception 'booking not found' using errcode = 'P0002'; end if;
  select price_amount into v_price from public.services where id = b.service_id;

  if p_status = 'cancelled' then
    if b.status not in ('hold','pending_payment','confirmed') then raise exception 'cannot cancel a % booking', b.status using errcode = 'P0003'; end if;
    was_confirmed := b.status = 'confirmed';
    update public.bookings set status = 'cancelled', cancelled_at = now(), cancelled_by = 'coach', cancel_reason = left(p_reason, 500) where id = b.id;
    update public.orders set status = 'cancelled' where booking_id = b.id and status in ('draft','pending_payment');
    if was_confirmed then perform public.email_on_booking_cancelled(b.id); end if;
  elsif p_status in ('completed','no_show') then
    if b.status <> 'confirmed' then raise exception 'only a confirmed booking can be marked %', p_status using errcode = 'P0003'; end if;
    if b.start_at > now() then raise exception 'the session has not started yet' using errcode = 'P0003'; end if;
    update public.bookings set status = p_status where id = b.id;
  elsif p_status = 'confirmed' then
    if b.status <> 'hold' or v_price is not null then
      raise exception 'only an unpriced hold can be confirmed by hand; paid bookings confirm through payment' using errcode = 'P0003';
    end if;
    update public.bookings set status = 'confirmed', hold_expires_at = null where id = b.id;
  else
    raise exception 'unsupported status %', p_status using errcode = '22023';
  end if;
  select * into b from public.bookings where id = b.id;
  return jsonb_build_object('reference', b.reference, 'status', b.status, 'cancelled_by', b.cancelled_by);
end $$;

-- ---------- 5. reschedule ----------
-- A website booking materialises one coaching_session (sync_session_from_booking). When the coach moves THAT
-- session (Schedule → Edit / reschedule), the booking follows and the customer gets the new details once per
-- actual change. Only a confirmed booking is rescheduled; nothing here confirms, cancels or charges.
create or replace function public.sync_booking_from_session() returns trigger
language plpgsql security definer set search_path = '' as $$
declare b public.bookings%rowtype; old_start timestamptz; old_tz text;
begin
  if new.booking_id is null then return new; end if;
  if new.start_at = old.start_at and new.end_at = old.end_at and new.session_timezone = old.session_timezone then return new; end if;
  select * into b from public.bookings where id = new.booking_id;
  if not found or b.status <> 'confirmed' then return new; end if;
  if b.start_at = new.start_at and b.end_at = new.end_at and b.session_timezone = new.session_timezone then return new; end if;   -- the booking already says so (e.g. the sync from the booking side)
  old_start := b.start_at; old_tz := b.session_timezone;
  update public.bookings set start_at = new.start_at, end_at = new.end_at, session_timezone = new.session_timezone, updated_at = now()
   where id = b.id returning * into b;
  perform public.email_queue('reschedule', b.customer_contact,
                             public.email_payload_booking(b) || jsonb_build_object('previous_start_at', old_start, 'previous_timezone', old_tz),
                             'booking:' || b.id || ':reschedule:' || to_char(b.start_at at time zone 'UTC', 'YYYYMMDDHH24MI'), b.id,
                             (select id from public.orders where booking_id = b.id order by created_at desc limit 1));
  return new;
end $$;
revoke all on function public.sync_booking_from_session() from public, anon, authenticated;
drop trigger if exists sync_booking_from_session on public.coaching_sessions;
create trigger sync_booking_from_session after update of start_at, end_at, session_timezone on public.coaching_sessions
  for each row execute function public.sync_booking_from_session();

-- ---------- 6. manual rails: a receipt-style confirmation for a pack paid by Aani / bank / cash / PSP ----------
-- Adds one line at the end of the 20261005 body; nothing else changes.
create or replace function public.payment_record_manual(
  p_pack_id uuid, p_amount int, p_currency text, p_source text default 'aani', p_reference text default null, p_paid_at timestamptz default null,
  p_capability text default null, p_platform text default null)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare e text := public.current_email(); sp public.session_packs%rowtype; o public.orders%rowtype; c public.crm_contacts%rowtype;
  v_ref text; pay public.payments%rowtype; req jsonb; conf jsonb; superseded text; psp boolean; v_cap text; via_ph boolean;
begin
  if not public.has_permission('finance:manage') then raise exception 'forbidden' using errcode = '42501'; end if;
  psp := p_source in ('network_international','magnati','adyen');
  if p_source not in ('aani','bank_transfer','cash','manual','external') and not psp then raise exception 'invalid source' using errcode = '22023'; end if;
  if p_amount is null or p_amount <= 0 then raise exception 'amount required' using errcode = '22023'; end if;
  if coalesce(p_currency,'') !~ '^[A-Z]{3}$' then raise exception 'currency required (ISO 4217)' using errcode = '22023'; end if;
  via_ph := p_source in ('aani','bank_transfer','cash') or psp;
  v_cap := case when psp then coalesce(p_capability, 'softpos') when p_source = 'cash' then coalesce(p_capability, 'cash') else p_capability end;
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

  if via_ph then
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
  perform public.email_on_order_paid(o.id);            -- outbox: pack receipt to the client, notice to the owner
  insert into public.admin_audit (area, entity_id, action, changed_by, summary)
  values ('payment', o.reference, 'manual', e, jsonb_build_object('pack', sp.id, 'source', p_source, 'capability', coalesce(req ->> 'capability', p_capability),
                                                                   'amount', p_amount, 'currency', p_currency, 'beau_ph_request', req ->> 'id', 'superseded_order', superseded));
  return jsonb_build_object('ok', true, 'order', o.reference, 'payment_id', pay.id, 'source', p_source, 'capability', coalesce(req ->> 'capability', p_capability),
                            'request_id', req ->> 'id', 'public_reference', req ->> 'public_reference', 'superseded_order', superseded);
end $$;

-- ---------- 7. Stripe webhook: the outbox replaces the inline email rows (same body as 20260921 otherwise) ----------
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
      perform public.email_on_order_paid(o.id, obj -> 'customer_details' ->> 'email');   -- outbox: customer confirmation + owner notice, once per order
      result := jsonb_build_object('order', o.reference, 'payment_id', p.id, 'booking', b.reference, 'booking_status', 'confirmed');
    else
      perform public.project_pack_payment(o.id);
      perform public.email_on_order_paid(o.id, obj -> 'customer_details' ->> 'email');   -- pack receipt / support thank-you (the payer email comes from Stripe Checkout)
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


-- ---------- 8. sender side: claim / result (service_role only, used by the Edge Functions) ----------
-- Claim leases the due rows for two minutes (a concurrent drain skips them), so the webhook drain and the scheduled
-- drain never send the same row twice. The result call is the only thing that moves a row to sent / failed.
create or replace function public.email_outbox_claim(p_limit int default 20, p_order_id uuid default null, p_booking_id uuid default null, p_contact_id uuid default null)
returns setof public.email_events language plpgsql volatile security definer set search_path = '' as $$
begin
  return query
  with due as (
    select e.id from public.email_events e
     where e.status = 'pending' and e.next_attempt_at <= now()
       and (p_order_id is null or e.order_id = p_order_id)
       and (p_booking_id is null or e.booking_id = p_booking_id)
       and (p_contact_id is null or e.contact_id = p_contact_id)
     order by e.created_at
     limit greatest(1, least(coalesce(p_limit, 20), 100))
     for update skip locked)
  update public.email_events e
     set attempts = e.attempts + 1, last_attempt_at = now(), next_attempt_at = now() + interval '2 minutes'
    from due where e.id = due.id
  returning e.*;
end $$;
revoke execute on function public.email_outbox_claim(int, uuid, uuid, uuid) from public, anon, authenticated;
grant  execute on function public.email_outbox_claim(int, uuid, uuid, uuid) to service_role;

create or replace function public.email_outbox_result(p_id uuid, p_ok boolean, p_provider_message_id text default null, p_error text default null)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare e public.email_events%rowtype; max_attempts int := 6;
begin
  select * into e from public.email_events where id = p_id for update;
  if not found then raise exception 'email event not found' using errcode = 'P0002'; end if;
  if e.status = 'sent' then return jsonb_build_object('id', e.id, 'status', 'sent', 'already', true); end if;
  if p_ok then
    update public.email_events set status = 'sent', sent_at = now(), provider_message_id = left(p_provider_message_id, 120), error = null where id = e.id;
    return jsonb_build_object('id', e.id, 'status', 'sent');
  end if;
  if e.attempts >= max_attempts then
    update public.email_events set status = 'failed', error = left(p_error, 300) where id = e.id;
    return jsonb_build_object('id', e.id, 'status', 'failed', 'attempts', e.attempts);
  end if;
  update public.email_events set error = left(p_error, 300), next_attempt_at = now() + (interval '1 minute' * power(2, e.attempts)) where id = e.id;
  return jsonb_build_object('id', e.id, 'status', 'pending', 'attempts', e.attempts, 'next_attempt_at', e.next_attempt_at);
end $$;
revoke execute on function public.email_outbox_result(uuid, boolean, text, text) from public, anon, authenticated;
grant  execute on function public.email_outbox_result(uuid, boolean, text, text) to service_role;

-- an operator can mark a row for a fresh attempt (coach:operations) — never resets a sent row
create or replace function public.email_outbox_retry(p_id uuid)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare e public.email_events%rowtype;
begin
  if not public.has_permission('coach:operations') then raise exception 'forbidden' using errcode = '42501'; end if;
  update public.email_events set status = 'pending', next_attempt_at = now(), attempts = 0, error = null
   where id = p_id and status in ('failed','skipped') and to_address is not null returning * into e;
  if not found then raise exception 'not retryable' using errcode = 'P0003'; end if;
  return jsonb_build_object('id', e.id, 'status', e.status);
end $$;
revoke execute on function public.email_outbox_retry(uuid) from public, anon;
grant  execute on function public.email_outbox_retry(uuid) to authenticated, service_role;

-- ---------- 9. scheduled drain: pg_cron → pg_net → email-outbox function ----------
-- The function is called with a key the database generated here (never shown, stored hashed on the function side
-- through email_outbox_authorize). No Supabase secret is involved and nothing has to be pasted anywhere.
create table if not exists public.outbox_keys (
  name       text primary key,
  key        text not null,
  created_at timestamptz not null default now()
);
alter table public.outbox_keys enable row level security;
revoke all on public.outbox_keys from public, anon, authenticated;
insert into public.outbox_keys (name, key) values ('email', encode(extensions.gen_random_bytes(32), 'hex')) on conflict (name) do nothing;

create or replace function public.email_outbox_authorize(p_key text)
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.outbox_keys k where k.name = 'email' and length(coalesce(p_key, '')) = 64 and k.key = p_key)
$$;
revoke execute on function public.email_outbox_authorize(text) from public, anon, authenticated;
grant  execute on function public.email_outbox_authorize(text) to service_role;

create or replace function public.email_outbox_kick()
returns bigint language plpgsql volatile security definer set search_path = '' as $$
declare k text; rid bigint;
begin
  if not exists (select 1 from public.email_events where status = 'pending' and next_attempt_at <= now()) then return null; end if;
  select key into k from public.outbox_keys where name = 'email';
  select net.http_post(url := 'https://acrjrlgeeyseyolmofuq.supabase.co/functions/v1/email-outbox',
                       headers := jsonb_build_object('Content-Type', 'application/json', 'x-outbox-key', k),
                       body := '{"action":"drain"}'::jsonb, timeout_milliseconds := 20000) into rid;
  return rid;
end $$;
revoke execute on function public.email_outbox_kick() from public, anon, authenticated;
grant  execute on function public.email_outbox_kick() to service_role;

do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') and exists (select 1 from pg_extension where extname = 'pg_net') then
    perform cron.unschedule(jobid) from cron.job where jobname = 'cg-email-outbox';
    perform cron.schedule('cg-email-outbox', '*/2 * * * *', $cron$select public.email_outbox_kick()$cron$);
  end if;
end $$;

-- ---------- 10. operator view: delivery state without addresses (coach:operations) ----------
create or replace function public.email_outbox_status(p_limit int default 50)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
begin
  if not public.has_permission('coach:operations') then raise exception 'forbidden' using errcode = '42501'; end if;
  return jsonb_build_object(
    'counts', (select coalesce(jsonb_object_agg(status, n), '{}'::jsonb) from (select status, count(*) n from public.email_events group by status) s),
    'recent', (select coalesce(jsonb_agg(jsonb_build_object('id', e.id, 'kind', e.kind, 'status', e.status, 'attempts', e.attempts, 'error', e.error,
                                                            'to', regexp_replace(coalesce(e.to_address, ''), '^(.).*(@.*)$', '\1***\2'),
                                                            'reference', coalesce(e.payload ->> 'reference', e.payload ->> 'order_reference'),
                                                            'created_at', e.created_at, 'sent_at', e.sent_at, 'provider_message_id', e.provider_message_id)
                                            order by e.created_at desc), '[]'::jsonb)
                 from (select * from public.email_events order by created_at desc limit greatest(1, least(p_limit, 200))) e));
end $$;
revoke execute on function public.email_outbox_status(int) from public, anon;
grant  execute on function public.email_outbox_status(int) to authenticated, service_role;

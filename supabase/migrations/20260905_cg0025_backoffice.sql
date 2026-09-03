-- =============================================================
-- CG-002.5 — lightweight back-office: permissions + RLS
--
-- Canonical rule: People belong to Gari. Payments belong to Oolala.
-- Public website content is controlled through Git. Aggregate analytics
-- may be shared.
--
-- Authentication: Supabase Auth magic link. Authorisation: this file.
-- A signed-in user has NO access until an owner inserts their email in
-- app_users + app_permissions (SQL editor). Permissions:
--   coach:operations  Gari  — leads, calendar, bookings, availability,
--                             exceptions, tour stops
--   finance:view      Oolala — orders, payments, refunds, chargebacks,
--                             earnings, settlements (no customer identity)
--   finance:manage    Oolala — create / mark settlements
--   analytics:view    both  — aggregates only, never a lead body
-- There is deliberately no content:* permission.
--
-- Mechanics: table grants are given to `authenticated` on an explicit
-- column list (never manage_token, ip_hash, idempotency_key, webhook
-- payloads); RLS policies gate rows by permission; anything that changes
-- state beyond Gari's own calendar goes through SECURITY DEFINER RPCs
-- that check the permission themselves. anon keeps zero access.
-- =============================================================

-- ---------- users & permissions ----------
create table if not exists public.app_users (
  email        text primary key check (email = lower(email) and email ~ '^[^@\s]+@[^@\s]+\.[^@\s]{2,}$'),
  display_name text,
  party        text not null check (party in ('gari','oolala','studio')),
  active       boolean not null default true,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now()
);
create table if not exists public.app_permissions (
  email      text not null references public.app_users(email) on delete cascade on update cascade,
  permission text not null check (permission in ('coach:operations','finance:view','finance:manage','analytics:view')),
  granted_at timestamptz not null default now(),
  primary key (email, permission)
);
drop trigger if exists app_users_updated_at on public.app_users;
create trigger app_users_updated_at before update on public.app_users for each row execute function public.set_updated_at();

alter table public.app_users       enable row level security;
alter table public.app_permissions enable row level security;
revoke all on public.app_users, public.app_permissions from anon, authenticated;

-- ---------- identity helpers ----------
create or replace function public.current_email()
returns text language sql stable security definer set search_path = '' as $$
  select lower(nullif(trim(coalesce(auth.jwt() ->> 'email', '')), ''))
$$;

create or replace function public.has_permission(p_permission text)
returns boolean language sql stable security definer set search_path = '' as $$
  select auth.role() = 'authenticated'
     and exists (
       select 1 from public.app_permissions ap
       join public.app_users u on u.email = ap.email
       where ap.email = public.current_email() and ap.permission = p_permission and u.active)
$$;

create or replace function public.my_permissions()
returns jsonb language sql stable security definer set search_path = '' as $$
  select jsonb_build_object(
    'email', public.current_email(),
    'display_name', (select display_name from public.app_users where email = public.current_email() and active),
    'party', (select party from public.app_users where email = public.current_email() and active),
    'permissions', coalesce((select jsonb_agg(ap.permission order by ap.permission)
                             from public.app_permissions ap join public.app_users u on u.email = ap.email
                             where ap.email = public.current_email() and u.active), '[]'::jsonb))
$$;

revoke execute on function public.current_email(), public.has_permission(text), public.my_permissions() from public, anon;
grant  execute on function public.current_email(), public.has_permission(text), public.my_permissions() to authenticated, service_role;

-- users see their own row only; nobody writes through the API
grant select on public.app_users, public.app_permissions to authenticated;
drop policy if exists app_users_self on public.app_users;
create policy app_users_self on public.app_users for select to authenticated using (email = public.current_email());
drop policy if exists app_permissions_self on public.app_permissions;
create policy app_permissions_self on public.app_permissions for select to authenticated using (email = public.current_email());

-- ---------- Gari: operations (coach:operations) ----------
-- leads: read everything except the rate-limit hash; update the status only
grant select (id, submission_id, name, contact, country, city, location_raw, interest, message,
              utm_source, utm_medium, utm_campaign, utm_content, utm_term, referrer, landing_page,
              first_visit_at, page, source, status, notified_at, created_at, updated_at)
  on public.contacts to authenticated;
grant update (status) on public.contacts to authenticated;
drop policy if exists contacts_coach_select on public.contacts;
create policy contacts_coach_select on public.contacts for select to authenticated using (public.has_permission('coach:operations'));
drop policy if exists contacts_coach_update on public.contacts;
create policy contacts_coach_update on public.contacts for update to authenticated
  using (public.has_permission('coach:operations')) with check (public.has_permission('coach:operations'));

-- bookings: read (no manage_token / idempotency_key / ip_hash); state changes via ops_set_booking_status
grant select (id, reference, service_id, contact_id, customer_name, customer_contact, start_at, end_at, session_timezone,
              tour_stop_id, delivery_mode, participant_count, status, hold_expires_at, price_amount, currency, notes,
              cancel_reason, cancelled_at, cancelled_by, created_at, updated_at)
  on public.bookings to authenticated;
drop policy if exists bookings_coach_select on public.bookings;
create policy bookings_coach_select on public.bookings for select to authenticated using (public.has_permission('coach:operations'));

-- services: labels for every signed-in party with any permission (no PII); no writes (catalogue lives in Git + migrations)
grant select on public.services to authenticated;
drop policy if exists services_any_permission on public.services;
create policy services_any_permission on public.services for select to authenticated
  using (public.has_permission('coach:operations') or public.has_permission('finance:view') or public.has_permission('analytics:view'));

-- availability, exceptions, tour stops: Gari edits directly
grant select, insert, update, delete on public.availability_rules, public.availability_exceptions,
                                        public.tour_stops, public.tour_stop_services to authenticated;
do $$ declare t text; begin
  foreach t in array array['availability_rules','availability_exceptions','tour_stops','tour_stop_services'] loop
    execute format('drop policy if exists %I on public.%I', t || '_coach_all', t);
    execute format('create policy %I on public.%I for all to authenticated using (public.has_permission(''coach:operations'')) with check (public.has_permission(''coach:operations''))', t || '_coach_all', t);
  end loop;
end $$;

-- Gari changes a booking's state (never money): cancel, complete, no-show, or confirm an unpriced hold
create or replace function public.ops_set_booking_status(p_reference text, p_status text, p_reason text default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare b public.bookings; v_price int;
begin
  if not public.has_permission('coach:operations') then raise exception 'forbidden' using errcode = '42501'; end if;
  select * into b from public.bookings where reference = upper(trim(p_reference)) for update;
  if not found then raise exception 'booking not found' using errcode = 'P0002'; end if;
  select price_amount into v_price from public.services where id = b.service_id;

  if p_status = 'cancelled' then
    if b.status not in ('hold','pending_payment','confirmed') then raise exception 'cannot cancel a % booking', b.status using errcode = 'P0003'; end if;
    update public.bookings set status = 'cancelled', cancelled_at = now(), cancelled_by = 'coach', cancel_reason = left(p_reason, 500) where id = b.id;
    update public.orders set status = 'cancelled' where booking_id = b.id and status in ('draft','pending_payment');
    if b.customer_contact ~ '^[^@\s]+@[^@\s]+\.[^@\s]{2,}$' then
      insert into public.email_events (booking_id, kind, to_address, status) values (b.id, 'booking_cancelled', b.customer_contact, 'pending') on conflict do nothing;
    end if;
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
revoke execute on function public.ops_set_booking_status(text, text, text) from public, anon;
grant  execute on function public.ops_set_booking_status(text, text, text) to authenticated, service_role;

-- ---------- Oolala: finance (finance:view / finance:manage) ----------
-- orders: no customer identity columns
grant select (id, reference, booking_id, currency, gross_amount, status, stripe_checkout_session_id,
              checkout_expires_at, checkout_attempts, paid_at, created_at, updated_at)
  on public.orders to authenticated;
grant select on public.payments, public.refunds, public.chargebacks, public.partner_earnings,
                public.partner_settlements, public.partner_settlement_items to authenticated;
do $$ declare t text; begin
  foreach t in array array['orders','payments','refunds','chargebacks','partner_earnings','partner_settlements','partner_settlement_items'] loop
    execute format('drop policy if exists %I on public.%I', t || '_finance_select', t);
    execute format('create policy %I on public.%I for select to authenticated using (public.has_permission(''finance:view''))', t || '_finance_select', t);
  end loop;
end $$;

-- one row per order with the session context finance needs, without the person
create or replace view public.finance_orders with (security_invoker = false) as
  select o.id, o.reference, o.status, o.currency, o.gross_amount, o.paid_at, o.created_at, o.stripe_checkout_session_id,
         b.reference as booking_reference, b.start_at as session_start_at, b.session_timezone, b.status as booking_status, b.delivery_mode,
         s.slug as service_slug, s.title as service_title,
         pe.stripe_fee, pe.refund_amount, pe.chargeback_amount, pe.net_collected, pe.oolala_commission, pe.gari_payable,
         pe.status as earning_status, pe.settlement_id, pe.adjusted_at
  from public.orders o
  join public.bookings b on b.id = o.booking_id
  join public.services s on s.id = b.service_id
  left join public.partner_earnings pe on pe.order_id = o.id
  where public.has_permission('finance:view');

-- webhook log without payloads (payloads can carry customer details from Stripe)
create or replace view public.finance_webhook_log with (security_invoker = false) as
  select id, provider, event_id, event_type, status, note, received_at, processed_at
  from public.webhook_events
  where public.has_permission('finance:view');

revoke all on public.finance_orders, public.finance_webhook_log from anon, public;
grant select on public.finance_orders, public.finance_webhook_log to authenticated, service_role;

create or replace function public.finance_create_settlement(p_period_start date, p_period_end date, p_currency text default 'USD')
returns jsonb language plpgsql security definer set search_path = '' as $$
begin
  if not public.has_permission('finance:manage') then raise exception 'forbidden' using errcode = '42501'; end if;
  return public.create_settlement('gari', p_period_start, p_period_end, p_currency);
end $$;
create or replace function public.finance_mark_settlement_paid(p_reference text, p_bank_transfer_reference text)
returns jsonb language plpgsql security definer set search_path = '' as $$
begin
  if not public.has_permission('finance:manage') then raise exception 'forbidden' using errcode = '42501'; end if;
  return public.mark_settlement_paid(p_reference, p_bank_transfer_reference);
end $$;
create or replace function public.finance_mark_settlement_reconciled(p_reference text)
returns jsonb language plpgsql security definer set search_path = '' as $$
begin
  if not public.has_permission('finance:manage') then raise exception 'forbidden' using errcode = '42501'; end if;
  return public.mark_settlement_reconciled(p_reference);
end $$;
revoke execute on function public.finance_create_settlement(date, date, text), public.finance_mark_settlement_paid(text, text),
                           public.finance_mark_settlement_reconciled(text) from public, anon;
grant  execute on function public.finance_create_settlement(date, date, text), public.finance_mark_settlement_paid(text, text),
                           public.finance_mark_settlement_reconciled(text) to authenticated, service_role;

-- ---------- aggregate analytics (analytics:view) ----------
create or replace function public.analytics_summary()
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare r jsonb;
begin
  if not public.has_permission('analytics:view') then raise exception 'forbidden' using errcode = '42501'; end if;
  select jsonb_build_object(
    'generated_at', now(),
    'leads', jsonb_build_object(
      'total', (select count(*) from public.contacts where status <> 'spam'),
      'last_30d', (select count(*) from public.contacts where status <> 'spam' and created_at > now() - interval '30 days'),
      'by_week', (select coalesce(jsonb_agg(jsonb_build_object('week', w, 'count', c) order by w), '[]'::jsonb) from (
                    select date_trunc('week', created_at)::date w, count(*) c from public.contacts
                    where status <> 'spam' and created_at > now() - interval '12 weeks' group by 1) x),
      'by_interest', (select coalesce(jsonb_object_agg(coalesce(interest, 'unspecified'), c), '{}'::jsonb) from (
                    select interest, count(*) c from public.contacts where status <> 'spam' group by 1) x),
      'by_country', (select coalesce(jsonb_agg(jsonb_build_object('country', country, 'count', c) order by c desc), '[]'::jsonb) from (
                    select coalesce(country, 'unknown') country, count(*) c from public.contacts where status <> 'spam' group by 1 order by 2 desc limit 10) x),
      'by_source', (select coalesce(jsonb_object_agg(coalesce(utm_source, 'direct'), c), '{}'::jsonb) from (
                    select utm_source, count(*) c from public.contacts where status <> 'spam' group by 1) x)),
    'bookings', jsonb_build_object(
      'by_status', (select coalesce(jsonb_object_agg(status, c), '{}'::jsonb) from (select status, count(*) c from public.bookings group by 1) x),
      'confirmed_last_30d', (select count(*) from public.bookings where status in ('confirmed','completed') and created_at > now() - interval '30 days'),
      'by_service', (select coalesce(jsonb_agg(jsonb_build_object('service', s.title, 'count', c) order by c desc), '[]'::jsonb) from (
                    select service_id, count(*) c from public.bookings where status in ('confirmed','completed','no_show') group by 1) x
                    join public.services s on s.id = x.service_id),
      'by_delivery_mode', (select coalesce(jsonb_object_agg(delivery_mode, c), '{}'::jsonb) from (
                    select delivery_mode, count(*) c from public.bookings where status in ('confirmed','completed','no_show') group by 1) x)),
    'revenue', jsonb_build_object(
      'currency', 'USD',
      'by_month', (select coalesce(jsonb_agg(jsonb_build_object('month', m, 'orders', n, 'gross', g, 'net', nt, 'commission', cm, 'payable', p) order by m), '[]'::jsonb) from (
                    select to_char(date_trunc('month', o.paid_at), 'YYYY-MM') m, count(*) n, sum(pe.gross_amount) g, sum(pe.net_collected) nt,
                           sum(pe.oolala_commission) cm, sum(pe.gari_payable) p
                    from public.partner_earnings pe join public.orders o on o.id = pe.order_id
                    where o.paid_at is not null and pe.status <> 'cancelled' group by 1) x),
      'totals', (select jsonb_build_object('gross', coalesce(sum(gross_amount), 0), 'net', coalesce(sum(net_collected), 0),
                                           'commission', coalesce(sum(oolala_commission), 0), 'payable', coalesce(sum(gari_payable), 0))
                 from public.partner_earnings where status <> 'cancelled')))
  into r;
  return r;
end $$;
revoke execute on function public.analytics_summary() from public, anon;
grant  execute on function public.analytics_summary() to authenticated, service_role;

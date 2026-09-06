-- =====================================================================
-- CG-011 — Schedule as Gari's operating calendar
-- Canonical coaching_sessions (the actual session occurrence, whether
-- from a website booking or entered manually) and session_packs (the
-- purchased/agreed entitlement, e.g. 10 sessions). Package consumption
-- is derived from sessions EXPLICITLY LINKED to a pack — never from date
-- arithmetic. "Block time" reuses availability_exceptions (kind='closed')
-- so there is ONE authoritative source of unavailability that the public
-- booking engine (available_slots) already honours.
--
-- Designed so CG-012 (reports / Stripe payment requests / renewals) can
-- consume this model without migration churn: price/currency/paid_at/
-- order_id/payment_source are snapshotted on the pack; renewal is a NEW
-- pack (renewed_from_pack_id) and never overwrites history.
--
-- Forward migration only. Nothing from CG-002/003/009/010 is dropped or
-- rewritten. body_measurements, consent and the finance ledger are
-- untouched.
-- =====================================================================

-- ---------- 1. audit areas ----------
alter table public.admin_audit drop constraint if exists admin_audit_area_check;
alter table public.admin_audit add constraint admin_audit_area_check
  check (area in ('crm_contact','crm_note','body_measurement','permission','consent','merge',
                  'coaching_session','session_pack','block'));

-- ---------- 2. calendar blocks reuse availability_exceptions ----------
-- A "Block time" is a closed exception. available_slots already suppresses
-- rule slots overlapping an active closed exception (tour_stop_id null), so
-- the public booking engine cannot offer a locked period. These columns only
-- add calendar display/audit metadata; private_note is NEVER selected by any
-- public API (available_slots returns none of these columns).
alter table public.availability_exceptions add column if not exists label        text;
alter table public.availability_exceptions add column if not exists private_note text;
alter table public.availability_exceptions add column if not exists source       text not null default 'config'
  check (source in ('config','calendar_block','tour'));
alter table public.availability_exceptions add column if not exists created_by   text;

-- ---------- 3. session_packs — the purchased/agreed entitlement ----------
create table if not exists public.session_packs (
  id                   uuid primary key default gen_random_uuid(),
  crm_contact_id       uuid not null references public.crm_contacts(id) on delete cascade,
  service_id           uuid references public.services(id),
  title                text not null,                                 -- snapshot label, e.g. '10-session coaching pack'
  total_sessions       int  not null check (total_sessions > 0),      -- 10 is a common config, NOT a schema constant
  -- financial snapshot (independent of session dates and of the agreement date)
  price_amount         int  check (price_amount is null or price_amount >= 0),   -- minor units
  currency             text not null default 'USD' check (currency ~ '^[A-Z]{3}$'),
  payment_status       text not null default 'unpaid' check (payment_status in ('unpaid','partial','paid','cancelled')),
  payment_source       text check (payment_source in ('stripe','bank_transfer','cash','manual','external')),
  order_id             uuid references public.orders(id),             -- CG-012: set when paid through commerce
  paid_at              timestamptz,                                   -- Stripe-confirmed or manually recorded payment time
  agreement_date       date,                                         -- when the pack was agreed/started
  status               text not null default 'active' check (status in ('active','completed','cancelled')),
  renewed_from_pack_id uuid references public.session_packs(id),      -- renewal chain; never overwrite the prior pack
  note                 text,
  created_by           text,
  created_at           timestamptz not null default now(),
  updated_at           timestamptz not null default now()
);
create index if not exists session_packs_contact_idx on public.session_packs (crm_contact_id, created_at desc);
create trigger session_packs_updated_at before update on public.session_packs
  for each row execute function public.set_updated_at();

-- ---------- 4. coaching_sessions — the actual session occurrence ----------
create table if not exists public.coaching_sessions (
  id               uuid primary key default gen_random_uuid(),
  crm_contact_id   uuid not null references public.crm_contacts(id) on delete cascade,
  session_pack_id  uuid references public.session_packs(id) on delete set null,
  service_id       uuid references public.services(id),
  booking_id       uuid unique references public.bookings(id) on delete set null,  -- dedup link to a website booking
  title            text,                                             -- session type label (snapshot)
  start_at         timestamptz not null,
  end_at           timestamptz not null,
  session_timezone text not null default 'Asia/Dubai',
  delivery_mode    text not null default 'in_person' check (delivery_mode in ('online','in_person')),
  status           text not null default 'scheduled' check (status in ('scheduled','completed','cancelled','no_show')),
  chargeable       boolean not null default false,                   -- only meaningful for no_show: consumes a unit if true
  location_name    text,
  location_address text,
  location_lat     numeric check (location_lat is null or location_lat between -90 and 90),
  location_lng     numeric check (location_lng is null or location_lng between -180 and 180),
  meeting_url      text,
  note             text,
  completed_at     timestamptz,
  cancelled_at     timestamptz,
  cancel_reason    text,
  created_by       text,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now(),
  check (end_at > start_at)
);
create index if not exists coaching_sessions_range_idx on public.coaching_sessions (start_at, end_at);
create index if not exists coaching_sessions_contact_idx on public.coaching_sessions (crm_contact_id, start_at desc);
create index if not exists coaching_sessions_pack_idx on public.coaching_sessions (session_pack_id) where session_pack_id is not null;
create trigger coaching_sessions_updated_at before update on public.coaching_sessions
  for each row execute function public.set_updated_at();
create trigger coaching_sessions_tz before insert or update on public.coaching_sessions
  for each row execute function public.validate_timezone_column('session_timezone');

-- a session may only be linked to a pack belonging to the SAME client, so a
-- wrong-client session can never consume another client's package.
create or replace function public.coaching_sessions_pack_guard() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if new.session_pack_id is not null
     and (select crm_contact_id from public.session_packs where id = new.session_pack_id) is distinct from new.crm_contact_id then
    raise exception 'session and pack belong to different clients' using errcode = '22023';
  end if;
  return new;
end $$;
drop trigger if exists coaching_sessions_pack_guard on public.coaching_sessions;
create trigger coaching_sessions_pack_guard before insert or update on public.coaching_sessions
  for each row execute function public.coaching_sessions_pack_guard();

-- ---------- 5. website booking -> coaching_session (dedup by booking_id) ----------
-- A confirmed/completed booking materialises exactly one coaching_session so
-- the calendar shows website and manual sessions together, with no duplicates.
-- Booking-originated sessions carry no pack (public funnel is not a manual pack).
create or replace function public.sync_session_from_booking() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if new.crm_contact_id is null then return new; end if;
  if new.status in ('confirmed','completed') then
    insert into public.coaching_sessions
      (crm_contact_id, service_id, booking_id, title, start_at, end_at, session_timezone, delivery_mode, status, created_by)
    values
      (new.crm_contact_id, new.service_id, new.id,
       (select title from public.services where id = new.service_id),
       new.start_at, new.end_at, new.session_timezone,
       case when new.delivery_mode = 'online' then 'online' else 'in_person' end,
       case when new.status = 'completed' then 'completed' else 'scheduled' end,
       'system:booking')
    on conflict (booking_id) do update set
      start_at = excluded.start_at,
      end_at   = excluded.end_at,
      status   = case when new.status = 'completed' then 'completed'
                      when public.coaching_sessions.status = 'cancelled' then 'scheduled'
                      else public.coaching_sessions.status end;
  elsif new.status in ('cancelled','expired') then
    update public.coaching_sessions set status = 'cancelled', cancelled_at = now(),
           cancel_reason = 'booking ' || new.status
     where booking_id = new.id and status <> 'completed';
  end if;
  return new;
end $$;
drop trigger if exists sync_session_from_booking on public.bookings;
create trigger sync_session_from_booking after insert or update of status on public.bookings
  for each row execute function public.sync_session_from_booking();

-- ---------- 6. RLS + read grants (writes are RPC-only) ----------
alter table public.session_packs     enable row level security;
alter table public.coaching_sessions enable row level security;
revoke all on public.session_packs, public.coaching_sessions from anon, authenticated;

-- coaching_sessions has no financial columns: coach:operations reads the row.
grant select on public.coaching_sessions to authenticated;
drop policy if exists coaching_sessions_view on public.coaching_sessions;
create policy coaching_sessions_view on public.coaching_sessions for select to authenticated
  using (public.has_permission('coach:operations'));

-- session_packs: coach:operations reads the OPERATIONAL columns only. The
-- financial columns (price/currency/payment_status/payment_source/order_id/
-- paid_at) are not column-granted; they are exposed only through the pack /
-- calendar RPCs, and only when the caller has finance:view.
grant select (id, crm_contact_id, service_id, title, total_sessions, status,
              agreement_date, renewed_from_pack_id, note, created_by, created_at, updated_at)
  on public.session_packs to authenticated;
drop policy if exists session_packs_view on public.session_packs;
create policy session_packs_view on public.session_packs for select to authenticated
  using (public.has_permission('coach:operations'));

-- ---------- 7. consumption helper (authoritative, from linked sessions) ----------
-- completed consumes one unit; no_show consumes only if explicitly chargeable;
-- scheduled and cancelled never consume.
create or replace function public.pack_used(p_pack uuid)
returns int language sql stable security definer set search_path = '' as $$
  select count(*)::int from public.coaching_sessions
   where session_pack_id = p_pack
     and (status = 'completed' or (status = 'no_show' and chargeable))
$$;
revoke execute on function public.pack_used(uuid) from public, anon;
grant  execute on function public.pack_used(uuid) to authenticated, service_role;

-- pack summary shaped per permission (financial only with finance:view)
create or replace function public.pack_json(p public.session_packs)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare used int := public.pack_used(p.id); j jsonb;
begin
  j := jsonb_build_object(
    'id', p.id, 'crm_contact_id', p.crm_contact_id, 'service_id', p.service_id,
    'title', p.title, 'total_sessions', p.total_sessions,
    'used', used, 'remaining', greatest(p.total_sessions - used, 0),
    'status', p.status, 'agreement_date', p.agreement_date,
    'renewed_from_pack_id', p.renewed_from_pack_id, 'created_at', p.created_at);
  if public.has_permission('finance:view') then
    j := j || jsonb_build_object(
      'price_amount', p.price_amount, 'currency', p.currency,
      'payment_status', p.payment_status, 'payment_source', p.payment_source,
      'order_id', p.order_id, 'paid_at', p.paid_at);
  end if;
  return j;
end $$;
revoke execute on function public.pack_json(public.session_packs) from public, anon;
grant  execute on function public.pack_json(public.session_packs) to authenticated, service_role;

-- ---------- 8. pack RPCs ----------
create or replace function public.pack_create(p jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare e text := public.current_email(); row public.session_packs%rowtype;
  has_financial boolean := (p ? 'price_amount') or (p ? 'payment_status') or (p ? 'payment_source') or (p ? 'paid_at') or (p ? 'order_id');
begin
  if not public.has_permission('coach:operations') then raise exception 'forbidden' using errcode = '42501'; end if;
  if has_financial and not public.has_permission('finance:manage') then raise exception 'finance:manage required for financial fields' using errcode = '42501'; end if;
  if coalesce(nullif(p->>'crm_contact_id',''),'') = '' then raise exception 'crm_contact_id required' using errcode = '22023'; end if;
  if coalesce((p->>'total_sessions')::int, 0) <= 0 then raise exception 'total_sessions must be positive' using errcode = '22023'; end if;
  insert into public.session_packs (crm_contact_id, service_id, title, total_sessions,
      price_amount, currency, payment_status, payment_source, order_id, paid_at, agreement_date, renewed_from_pack_id, note, created_by)
  values ((p->>'crm_contact_id')::uuid, nullif(p->>'service_id','')::uuid,
      coalesce(nullif(p->>'title',''), 'Session pack'), (p->>'total_sessions')::int,
      nullif(p->>'price_amount','')::int, coalesce(nullif(p->>'currency',''),'USD'),
      coalesce(nullif(p->>'payment_status',''),'unpaid'), nullif(p->>'payment_source',''),
      nullif(p->>'order_id','')::uuid, nullif(p->>'paid_at','')::timestamptz,
      nullif(p->>'agreement_date','')::date, nullif(p->>'renewed_from_pack_id','')::uuid,
      nullif(p->>'note',''), e)
  returning * into row;
  insert into public.admin_audit (area, entity_id, action, changed_by, summary)
  values ('session_pack', row.id::text, 'create', e, jsonb_build_object('contact', row.crm_contact_id, 'total', row.total_sessions));
  return public.pack_json(row);
end $$;
revoke execute on function public.pack_create(jsonb) from public, anon;
grant  execute on function public.pack_create(jsonb) to authenticated, service_role;

-- financial changes on a pack require finance:manage
create or replace function public.pack_set_payment(
  p_pack_id uuid, p_price_amount int default null, p_currency text default null,
  p_payment_status text default null, p_payment_source text default null, p_paid_at timestamptz default null, p_order_id uuid default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare e text := public.current_email(); row public.session_packs%rowtype;
begin
  if not public.has_permission('finance:manage') then raise exception 'forbidden' using errcode = '42501'; end if;
  update public.session_packs set
    price_amount   = coalesce(p_price_amount, price_amount),
    currency       = coalesce(p_currency, currency),
    payment_status = coalesce(p_payment_status, payment_status),
    payment_source = coalesce(p_payment_source, payment_source),
    paid_at        = coalesce(p_paid_at, paid_at),
    order_id       = coalesce(p_order_id, order_id)
  where id = p_pack_id returning * into row;
  if not found then raise exception 'pack not found' using errcode = 'P0002'; end if;
  insert into public.admin_audit (area, entity_id, action, changed_by, summary)
  values ('session_pack', p_pack_id::text, 'set_payment', e, jsonb_build_object('payment_status', row.payment_status, 'source', row.payment_source));
  return public.pack_json(row);
end $$;
revoke execute on function public.pack_set_payment(uuid, int, text, text, text, timestamptz, uuid) from public, anon;
grant  execute on function public.pack_set_payment(uuid, int, text, text, text, timestamptz, uuid) to authenticated, service_role;

create or replace function public.packs_for_contact(p_contact_id uuid)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
begin
  if not public.has_permission('coach:operations') then raise exception 'forbidden' using errcode = '42501'; end if;
  return coalesce((select jsonb_agg(public.pack_json(sp) order by sp.created_at desc)
                   from public.session_packs sp where sp.crm_contact_id = p_contact_id), '[]'::jsonb);
end $$;
revoke execute on function public.packs_for_contact(uuid) from public, anon;
grant  execute on function public.packs_for_contact(uuid) to authenticated, service_role;

-- ---------- 9. session RPCs ----------
create or replace function public.session_write(p jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare e text := public.current_email(); v_id uuid := nullif(p->>'id','')::uuid; row public.coaching_sessions%rowtype; act text;
begin
  if not public.has_permission('coach:operations') then raise exception 'forbidden' using errcode = '42501'; end if;
  if v_id is null then
    if coalesce(nullif(p->>'crm_contact_id',''),'') = '' then raise exception 'crm_contact_id required' using errcode = '22023'; end if;
    if coalesce(nullif(p->>'start_at',''),'') = '' or coalesce(nullif(p->>'end_at',''),'') = '' then raise exception 'start_at and end_at required' using errcode = '22023'; end if;
    insert into public.coaching_sessions
      (crm_contact_id, session_pack_id, service_id, title, start_at, end_at, session_timezone, delivery_mode,
       location_name, location_address, location_lat, location_lng, meeting_url, note, created_by)
    values ((p->>'crm_contact_id')::uuid, nullif(p->>'session_pack_id','')::uuid, nullif(p->>'service_id','')::uuid,
       nullif(p->>'title',''), (p->>'start_at')::timestamptz, (p->>'end_at')::timestamptz,
       coalesce(nullif(p->>'session_timezone',''),'Asia/Dubai'),
       coalesce(nullif(p->>'delivery_mode',''),'in_person'),
       nullif(p->>'location_name',''), nullif(p->>'location_address',''),
       nullif(p->>'location_lat','')::numeric, nullif(p->>'location_lng','')::numeric,
       nullif(p->>'meeting_url',''), nullif(p->>'note',''), e)
    returning * into row;
    act := 'create';
  else
    update public.coaching_sessions set
      session_pack_id  = case when p ? 'session_pack_id' then nullif(p->>'session_pack_id','')::uuid else session_pack_id end,
      service_id       = case when p ? 'service_id' then nullif(p->>'service_id','')::uuid else service_id end,
      title            = case when p ? 'title' then nullif(p->>'title','') else title end,
      start_at         = coalesce(nullif(p->>'start_at','')::timestamptz, start_at),
      end_at           = coalesce(nullif(p->>'end_at','')::timestamptz, end_at),
      session_timezone = coalesce(nullif(p->>'session_timezone',''), session_timezone),
      delivery_mode    = coalesce(nullif(p->>'delivery_mode',''), delivery_mode),
      location_name    = case when p ? 'location_name' then nullif(p->>'location_name','') else location_name end,
      location_address = case when p ? 'location_address' then nullif(p->>'location_address','') else location_address end,
      location_lat     = case when p ? 'location_lat' then nullif(p->>'location_lat','')::numeric else location_lat end,
      location_lng     = case when p ? 'location_lng' then nullif(p->>'location_lng','')::numeric else location_lng end,
      meeting_url      = case when p ? 'meeting_url' then nullif(p->>'meeting_url','') else meeting_url end,
      note             = case when p ? 'note' then nullif(p->>'note','') else note end
    where id = v_id returning * into row;
    if not found then raise exception 'session not found' using errcode = 'P0002'; end if;
    act := 'update';
  end if;
  insert into public.admin_audit (area, entity_id, action, changed_by, summary)
  values ('coaching_session', row.id::text, act, e, jsonb_build_object('contact', row.crm_contact_id, 'start', row.start_at));
  return to_jsonb(row);
end $$;
revoke execute on function public.session_write(jsonb) from public, anon;
grant  execute on function public.session_write(jsonb) to authenticated, service_role;

create or replace function public.session_set_status(p_id uuid, p_status text, p_chargeable boolean default false, p_reason text default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare e text := public.current_email(); row public.coaching_sessions%rowtype;
begin
  if not public.has_permission('coach:operations') then raise exception 'forbidden' using errcode = '42501'; end if;
  if p_status not in ('scheduled','completed','cancelled','no_show') then raise exception 'invalid status' using errcode = '22023'; end if;
  update public.coaching_sessions set
    status        = p_status,
    chargeable    = case when p_status = 'no_show' then coalesce(p_chargeable, false) else false end,
    completed_at  = case when p_status = 'completed' then now() else null end,
    cancelled_at  = case when p_status = 'cancelled' then now() else null end,
    cancel_reason = case when p_status = 'cancelled' then p_reason else null end
  where id = p_id returning * into row;
  if not found then raise exception 'session not found' using errcode = 'P0002'; end if;
  insert into public.admin_audit (area, entity_id, action, changed_by, summary)
  values ('coaching_session', p_id::text, 'status:' || p_status, e, jsonb_build_object('chargeable', row.chargeable));
  return to_jsonb(row);
end $$;
revoke execute on function public.session_set_status(uuid, text, boolean, text) from public, anon;
grant  execute on function public.session_set_status(uuid, text, boolean, text) to authenticated, service_role;

-- Delete only where safe: a manually-created, not-yet-completed session with no
-- booking behind it. A booking-linked or completed session is cancelled, not deleted.
create or replace function public.session_delete(p_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare e text := public.current_email(); row public.coaching_sessions%rowtype;
begin
  if not public.has_permission('coach:operations') then raise exception 'forbidden' using errcode = '42501'; end if;
  select * into row from public.coaching_sessions where id = p_id;
  if not found then raise exception 'session not found' using errcode = 'P0002'; end if;
  if row.booking_id is not null then raise exception 'this session comes from a website booking - cancel it instead of deleting' using errcode = '22023'; end if;
  if row.status = 'completed' then raise exception 'a completed session is kept for the record - cancel or leave it' using errcode = '22023'; end if;
  delete from public.coaching_sessions where id = p_id;
  insert into public.admin_audit (area, entity_id, action, changed_by, summary)
  values ('coaching_session', p_id::text, 'delete', e, jsonb_build_object('contact', row.crm_contact_id));
  return jsonb_build_object('deleted', 1);
end $$;
revoke execute on function public.session_delete(uuid) from public, anon;
grant  execute on function public.session_delete(uuid) to authenticated, service_role;

-- ---------- 10. calendar range (sessions + blocks), shaped for the UI ----------
create or replace function public.calendar_range(p_from timestamptz, p_to timestamptz)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare sessions jsonb; blocks jsonb;
begin
  if not public.has_permission('coach:operations') then raise exception 'forbidden' using errcode = '42501'; end if;
  if p_to <= p_from or (p_to - p_from) > interval '62 days' then raise exception 'invalid range' using errcode = '22023'; end if;

  select coalesce(jsonb_agg(jsonb_build_object(
      'id', s.id, 'crm_contact_id', s.crm_contact_id, 'client_name', c.display_name,
      'title', coalesce(s.title, sv.title), 'start_at', s.start_at, 'end_at', s.end_at,
      'session_timezone', s.session_timezone, 'delivery_mode', s.delivery_mode, 'status', s.status,
      'location_name', s.location_name, 'meeting_url', s.meeting_url,
      'booking_id', s.booking_id, 'session_pack_id', s.session_pack_id,
      'pack', case when s.session_pack_id is not null then public.pack_json(sp) else null end
    ) order by s.start_at), '[]'::jsonb)
  into sessions
  from public.coaching_sessions s
  left join public.crm_contacts c on c.id = s.crm_contact_id
  left join public.services sv on sv.id = s.service_id
  left join public.session_packs sp on sp.id = s.session_pack_id
  where s.start_at < p_to and s.end_at > p_from and s.status <> 'cancelled';

  select coalesce(jsonb_agg(jsonb_build_object(
      'id', e.id, 'start_at', e.start_at, 'end_at', e.end_at, 'timezone', e.timezone,
      'label', coalesce(e.label, e.reason), 'private_note', e.private_note, 'source', e.source
    ) order by e.start_at), '[]'::jsonb)
  into blocks
  from public.availability_exceptions e
  where e.active and e.kind = 'closed' and e.tour_stop_id is null
    and e.start_at < p_to and e.end_at > p_from;

  return jsonb_build_object('sessions', sessions, 'blocks', blocks);
end $$;
revoke execute on function public.calendar_range(timestamptz, timestamptz) from public, anon;
grant  execute on function public.calendar_range(timestamptz, timestamptz) to authenticated, service_role;

-- upcoming sessions for the Overview "next session" card
create or replace function public.sessions_upcoming(p_limit int default 5)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
begin
  if not public.has_permission('coach:operations') then raise exception 'forbidden' using errcode = '42501'; end if;
  return coalesce((select jsonb_agg(x order by x->>'start_at') from (
    select jsonb_build_object(
      'id', s.id, 'crm_contact_id', s.crm_contact_id, 'client_name', c.display_name,
      'title', coalesce(s.title, sv.title), 'start_at', s.start_at, 'end_at', s.end_at,
      'delivery_mode', s.delivery_mode, 'location_name', s.location_name, 'meeting_url', s.meeting_url,
      'pack', case when s.session_pack_id is not null then public.pack_json(sp) else null end) as x
    from public.coaching_sessions s
    left join public.crm_contacts c on c.id = s.crm_contact_id
    left join public.services sv on sv.id = s.service_id
    left join public.session_packs sp on sp.id = s.session_pack_id
    where s.status = 'scheduled' and s.end_at > now()
    order by s.start_at limit greatest(least(p_limit, 50), 1)) t), '[]'::jsonb);
end $$;
revoke execute on function public.sessions_upcoming(int) from public, anon;
grant  execute on function public.sessions_upcoming(int) to authenticated, service_role;

-- filterable sessions list for the Sessions sub-tab
create or replace function public.sessions_list(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare f_contact uuid := nullif(p->>'crm_contact_id','')::uuid;
  f_status text := nullif(p->>'status',''); f_mode text := nullif(p->>'delivery_mode','');
  f_from timestamptz := nullif(p->>'from','')::timestamptz; f_to timestamptz := nullif(p->>'to','')::timestamptz;
  f_pack uuid := nullif(p->>'session_pack_id','')::uuid; f_q text := nullif(lower(p->>'q'),'');
begin
  if not public.has_permission('coach:operations') then raise exception 'forbidden' using errcode = '42501'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object(
      'id', s.id, 'crm_contact_id', s.crm_contact_id, 'client_name', c.display_name,
      'title', coalesce(s.title, sv.title), 'start_at', s.start_at, 'end_at', s.end_at,
      'delivery_mode', s.delivery_mode, 'status', s.status, 'session_pack_id', s.session_pack_id,
      'pack', case when s.session_pack_id is not null then public.pack_json(sp) else null end
    ) order by s.start_at desc)
    from public.coaching_sessions s
    left join public.crm_contacts c on c.id = s.crm_contact_id
    left join public.services sv on sv.id = s.service_id
    left join public.session_packs sp on sp.id = s.session_pack_id
    where (f_contact is null or s.crm_contact_id = f_contact)
      and (f_status is null or s.status = f_status)
      and (f_mode is null or s.delivery_mode = f_mode)
      and (f_pack is null or s.session_pack_id = f_pack)
      and (f_from is null or s.start_at >= f_from)
      and (f_to is null or s.start_at < f_to)
      and (f_q is null or lower(coalesce(c.display_name,'')) like '%'||f_q||'%' or lower(coalesce(s.title,'')) like '%'||f_q||'%')
    limit 500), '[]'::jsonb);
end $$;
revoke execute on function public.sessions_list(jsonb) from public, anon;
grant  execute on function public.sessions_list(jsonb) to authenticated, service_role;

-- ---------- 11. block RPCs (calendar unavailability = closed exception) ----------
create or replace function public.block_create(p jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare e text := public.current_email(); row public.availability_exceptions%rowtype;
begin
  if not public.has_permission('coach:operations') then raise exception 'forbidden' using errcode = '42501'; end if;
  if coalesce(nullif(p->>'start_at',''),'') = '' or coalesce(nullif(p->>'end_at',''),'') = '' then raise exception 'start_at and end_at required' using errcode = '22023'; end if;
  insert into public.availability_exceptions (kind, start_at, end_at, timezone, reason, label, private_note, source, created_by, active)
  values ('closed', (p->>'start_at')::timestamptz, (p->>'end_at')::timestamptz,
          coalesce(nullif(p->>'timezone',''),'Asia/Dubai'),
          nullif(p->>'label',''), nullif(p->>'label',''), nullif(p->>'private_note',''), 'calendar_block', e, true)
  returning * into row;
  insert into public.admin_audit (area, entity_id, action, changed_by, summary)
  values ('block', row.id::text, 'create', e, jsonb_build_object('start', row.start_at, 'end', row.end_at));
  return to_jsonb(row);
end $$;
revoke execute on function public.block_create(jsonb) from public, anon;
grant  execute on function public.block_create(jsonb) to authenticated, service_role;

create or replace function public.block_update(p_id uuid, p jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare e text := public.current_email(); row public.availability_exceptions%rowtype;
begin
  if not public.has_permission('coach:operations') then raise exception 'forbidden' using errcode = '42501'; end if;
  update public.availability_exceptions set
    start_at     = coalesce(nullif(p->>'start_at','')::timestamptz, start_at),
    end_at       = coalesce(nullif(p->>'end_at','')::timestamptz, end_at),
    timezone     = coalesce(nullif(p->>'timezone',''), timezone),
    label        = case when p ? 'label' then nullif(p->>'label','') else label end,
    reason       = case when p ? 'label' then nullif(p->>'label','') else reason end,
    private_note = case when p ? 'private_note' then nullif(p->>'private_note','') else private_note end
  where id = p_id and source = 'calendar_block' returning * into row;
  if not found then raise exception 'block not found' using errcode = 'P0002'; end if;
  insert into public.admin_audit (area, entity_id, action, changed_by, summary)
  values ('block', p_id::text, 'update', e, jsonb_build_object('start', row.start_at, 'end', row.end_at));
  return to_jsonb(row);
end $$;
revoke execute on function public.block_update(uuid, jsonb) from public, anon;
grant  execute on function public.block_update(uuid, jsonb) to authenticated, service_role;

create or replace function public.block_remove(p_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare e text := public.current_email(); n int;
begin
  if not public.has_permission('coach:operations') then raise exception 'forbidden' using errcode = '42501'; end if;
  delete from public.availability_exceptions where id = p_id and source = 'calendar_block';
  get diagnostics n = row_count;
  if n = 0 then raise exception 'block not found' using errcode = 'P0002'; end if;
  insert into public.admin_audit (area, entity_id, action, changed_by, summary)
  values ('block', p_id::text, 'remove', e, '{}'::jsonb);
  return jsonb_build_object('removed', n);
end $$;
revoke execute on function public.block_remove(uuid) from public, anon;
grant  execute on function public.block_remove(uuid) to authenticated, service_role;

-- ---------- 12. backfill existing confirmed/completed bookings ----------
-- Idempotent (unique booking_id): materialise a coaching_session for bookings
-- that predate the sync trigger, so the calendar reflects existing bookings.
insert into public.coaching_sessions
  (crm_contact_id, service_id, booking_id, title, start_at, end_at, session_timezone, delivery_mode, status, created_by)
select b.crm_contact_id, b.service_id, b.id, s.title, b.start_at, b.end_at, b.session_timezone,
       case when b.delivery_mode = 'online' then 'online' else 'in_person' end,
       case when b.status = 'completed' then 'completed' else 'scheduled' end, 'system:booking'
from public.bookings b left join public.services s on s.id = b.service_id
where b.status in ('confirmed','completed') and b.crm_contact_id is not null
on conflict (booking_id) do nothing;

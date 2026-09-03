-- CG-002 — internal booking engine
-- services · availability_rules · availability_exceptions · tour_stops ·
-- tour_stop_services · bookings · atomic RPCs (available_slots, create_hold,
-- get_booking, cancel_booking, expire_holds).
--
-- Principles: timestamps in UTC, IANA timezone kept next to them; the database
-- is authoritative for price, duration and capacity; capacity checks are
-- serialised per service with an advisory lock; holds expire lazily (and via
-- pg_cron when available); every write goes through SECURITY DEFINER RPCs
-- callable by the service role only. Capacity-aware (capacity N), but only
-- individual bookings are shipped — group sessions are a prepared capability.

create extension if not exists pgcrypto;

/* ------------------------------------------------------------------ */
/* generic helpers                                                     */
/* ------------------------------------------------------------------ */
create or replace function public.set_updated_at()
returns trigger language plpgsql set search_path = '' as $$
begin new.updated_at = now(); return new; end $$;

-- Rejects a row whose timezone column (name in TG_ARGV[0]) is not a valid IANA zone.
create or replace function public.validate_timezone_column()
returns trigger language plpgsql set search_path = '' as $$
declare v_tz text; v_probe timestamp;
begin
  v_tz := to_jsonb(new) ->> TG_ARGV[0];
  if v_tz is null then raise exception '% is required', TG_ARGV[0] using errcode = '22023'; end if;
  begin
    v_probe := now() at time zone v_tz;
  exception when others then
    raise exception 'invalid IANA timezone "%" in %', v_tz, TG_ARGV[0] using errcode = '22023';
  end;
  return new;
end $$;

/* ------------------------------------------------------------------ */
/* services                                                            */
/* ------------------------------------------------------------------ */
create table if not exists public.services (
  id               uuid primary key default gen_random_uuid(),
  slug             text not null unique check (slug ~ '^[a-z0-9-]{2,60}$'),
  title            text not null,
  category         text not null check (category in ('coaching','mentoring','onsite')),
  description      text,
  duration_minutes int  not null check (duration_minutes between 15 and 480),
  price_amount     int  check (price_amount is null or price_amount >= 0),  -- minor units; NULL = on request, not payable online
  currency         text not null default 'USD' check (currency ~ '^[A-Z]{3}$'),
  delivery_mode    text not null check (delivery_mode in ('online','onsite')),
  default_capacity int  not null default 1 check (default_capacity between 1 and 100),
  booking_mode     text not null default 'slot' check (booking_mode in ('slot')),
  active           boolean not null default true,
  listed           boolean not null default true,   -- shown in the public picker
  sort_order       int not null default 100,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now()
);
create trigger services_updated_at before update on public.services
  for each row execute function public.set_updated_at();

/* ------------------------------------------------------------------ */
/* tour stops — trips Gari has actually decided to make                */
/* ------------------------------------------------------------------ */
create table if not exists public.tour_stops (
  id                 uuid primary key default gen_random_uuid(),
  slug               text not null unique check (slug ~ '^[a-z0-9-]{2,80}$'),
  city               text not null,
  country            text not null,
  timezone           text not null,                     -- destination IANA zone
  start_at           timestamptz not null,
  end_at             timestamptz not null,
  booking_opens_at   timestamptz,
  booking_closes_at  timestamptz,
  venue              text,
  address            text,
  location_notes     text,
  status             text not null default 'draft'
                     check (status in ('draft','open','closed','completed','cancelled')),
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now(),
  check (end_at > start_at)
);
create trigger tour_stops_updated_at before update on public.tour_stops
  for each row execute function public.set_updated_at();
create trigger tour_stops_tz before insert or update on public.tour_stops
  for each row execute function public.validate_timezone_column('timezone');

create table if not exists public.tour_stop_services (
  tour_stop_id uuid not null references public.tour_stops(id) on delete cascade,
  service_id   uuid not null references public.services(id) on delete cascade,
  primary key (tour_stop_id, service_id)
);

/* ------------------------------------------------------------------ */
/* availability                                                        */
/* ------------------------------------------------------------------ */
create table if not exists public.availability_rules (
  id          uuid primary key default gen_random_uuid(),
  weekday     smallint not null check (weekday between 1 and 7),   -- ISO: 1 = Monday … 7 = Sunday
  start_time  time not null,
  end_time    time not null,
  timezone    text not null default 'Asia/Dubai',
  service_ids uuid[],                 -- NULL = every active service
  valid_from  date,
  valid_to    date,
  active      boolean not null default true,
  notes       text,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  check (end_time > start_time),
  check (valid_from is null or valid_to is null or valid_to >= valid_from)
);
create trigger availability_rules_updated_at before update on public.availability_rules
  for each row execute function public.set_updated_at();
create trigger availability_rules_tz before insert or update on public.availability_rules
  for each row execute function public.validate_timezone_column('timezone');

create table if not exists public.availability_exceptions (
  id           uuid primary key default gen_random_uuid(),
  kind         text not null check (kind in ('closed','open')),   -- closed = blocked time; open = exceptional opening / tour window
  start_at     timestamptz not null,
  end_at       timestamptz not null,
  timezone     text not null,          -- zone the window is expressed and displayed in
  reason       text,
  service_ids  uuid[],                 -- NULL = all applicable services
  tour_stop_id uuid references public.tour_stops(id) on delete cascade,
  active       boolean not null default true,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now(),
  check (end_at > start_at)
);
create index if not exists availability_exceptions_window_idx on public.availability_exceptions (start_at, end_at) where active;
create trigger availability_exceptions_updated_at before update on public.availability_exceptions
  for each row execute function public.set_updated_at();
create trigger availability_exceptions_tz before insert or update on public.availability_exceptions
  for each row execute function public.validate_timezone_column('timezone');

/* ------------------------------------------------------------------ */
/* bookings                                                            */
/* ------------------------------------------------------------------ */
create table if not exists public.bookings (
  id                uuid primary key default gen_random_uuid(),
  reference         text not null unique,                     -- CG-XXXXXX, shown to the customer
  service_id        uuid not null references public.services(id),
  contact_id        uuid references public.contacts(id) on delete set null,
  customer_name     text not null,
  customer_contact  text not null,                            -- email or phone, as typed
  start_at          timestamptz not null,
  end_at            timestamptz not null,
  session_timezone  text not null,                            -- zone the session is held/displayed in
  tour_stop_id      uuid references public.tour_stops(id) on delete set null,
  delivery_mode     text not null check (delivery_mode in ('online','onsite','tour')),
  participant_count int  not null default 1 check (participant_count between 1 and 100),
  status            text not null default 'hold'
                    check (status in ('hold','pending_payment','confirmed','cancelled','expired','completed','no_show')),
  hold_expires_at   timestamptz,
  idempotency_key   uuid not null unique,
  manage_token      text not null,                            -- secret handle for read/cancel by reference
  price_amount      int,                                      -- snapshot at hold time (minor units), NULL = on request
  currency          text not null default 'USD',
  notes             text,
  cancel_reason     text,
  cancelled_at      timestamptz,
  cancelled_by      text check (cancelled_by in ('customer','coach','system')),
  ip_hash           text,
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),
  check (end_at > start_at)
);
create index if not exists bookings_slot_idx on public.bookings (service_id, start_at, end_at)
  where status in ('hold','pending_payment','confirmed');
create index if not exists bookings_status_idx on public.bookings (status, start_at);
create index if not exists bookings_ip_hash_idx on public.bookings (ip_hash, created_at desc);
create trigger bookings_updated_at before update on public.bookings
  for each row execute function public.set_updated_at();
create trigger bookings_tz before insert or update on public.bookings
  for each row execute function public.validate_timezone_column('session_timezone');

/* ------------------------------------------------------------------ */
/* capacity helpers                                                    */
/* ------------------------------------------------------------------ */
-- A booking consumes capacity while pending/confirmed, or while its hold is still valid.
create or replace function public.booking_is_active(p_status text, p_hold_expires_at timestamptz)
returns boolean language sql stable set search_path = '' as $$
  select p_status in ('pending_payment','confirmed')
      or (p_status = 'hold' and p_hold_expires_at is not null and p_hold_expires_at > now())
$$;

create or replace function public.slot_capacity_used(p_service_id uuid, p_start timestamptz, p_end timestamptz)
returns int language sql stable set search_path = '' as $$
  select coalesce(sum(b.participant_count), 0)::int
  from public.bookings b
  where b.service_id = p_service_id
    and b.start_at < p_end and b.end_at > p_start
    and public.booking_is_active(b.status, b.hold_expires_at)
$$;

/* ------------------------------------------------------------------ */
/* available_slots                                                     */
/* ------------------------------------------------------------------ */
-- Slots for one service between two local dates (in p_tz). Sources:
--   * recurring rules (evaluated per day in the rule's own timezone, so DST is right),
--   * 'open' exceptions — exceptional openings and tour-stop windows (only when the
--     stop is open, inside its booking window, and the service is eligible).
-- 'closed' exceptions suppress rule-generated slots only; explicit openings are
-- never suppressed. Slots start at least 2 hours from now. Remaining capacity is
-- computed against active bookings (valid holds + pending + confirmed).
create or replace function public.available_slots(
  p_service_slug text, p_from date, p_to date, p_tz text default 'UTC'
) returns table (
  start_at timestamptz, end_at timestamptz, session_timezone text,
  tour_stop_id uuid, tour_stop_slug text, city text, country text, venue text,
  remaining int, local_start text
) language sql stable set search_path = '' as $$
  with svc as (
    select * from public.services where slug = p_service_slug and active
  ),
  bounds as (
    select case when p_to < p_from or (p_to - p_from) > 62 then null else p_from end as f, p_to as t
  ),
  days as (
    select gs::date as d
    from bounds, generate_series(bounds.f::timestamp, bounds.t::timestamp, interval '1 day') gs
    where bounds.f is not null
  ),
  rule_windows as (
    select ((dy.d::text || ' ' || r.start_time::text)::timestamp at time zone r.timezone) as w_start,
           ((dy.d::text || ' ' || r.end_time::text)::timestamp   at time zone r.timezone) as w_end,
           r.timezone as tz, null::uuid as tour_stop_id, 'rule'::text as source
    from days dy
    join public.availability_rules r
      on r.active
     and r.weekday = extract(isodow from dy.d)
     and (r.valid_from is null or dy.d >= r.valid_from)
     and (r.valid_to   is null or dy.d <= r.valid_to)
    cross join svc
    where r.service_ids is null or svc.id = any (r.service_ids)
  ),
  open_windows as (
    select e.start_at as w_start, e.end_at as w_end, e.timezone as tz, e.tour_stop_id, 'open'::text as source
    from public.availability_exceptions e
    cross join svc
    cross join bounds
    left join public.tour_stops ts on ts.id = e.tour_stop_id
    where e.active and e.kind = 'open'
      and bounds.f is not null
      and (e.service_ids is null or svc.id = any (e.service_ids))
      and e.end_at   > ((bounds.f - 1)::timestamp at time zone p_tz)
      and e.start_at < ((bounds.t + 2)::timestamp at time zone p_tz)
      and (e.tour_stop_id is null or (
            ts.status = 'open'
        and (ts.booking_opens_at  is null or now() >= ts.booking_opens_at)
        and (ts.booking_closes_at is null or now() <= ts.booking_closes_at)
        and exists (select 1 from public.tour_stop_services x where x.tour_stop_id = ts.id and x.service_id = svc.id)
      ))
  ),
  windows as (select * from rule_windows union all select * from open_windows),
  slots as (
    select gs as slot_start,
           gs + make_interval(mins => svc.duration_minutes) as slot_end,
           w.tz, w.tour_stop_id, w.source
    from windows w
    cross join svc
    cross join lateral generate_series(
      w.w_start,
      w.w_end - make_interval(mins => svc.duration_minutes),
      make_interval(mins => svc.duration_minutes)
    ) gs
  ),
  filtered as (
    select distinct on (sl.slot_start, sl.tour_stop_id) sl.*
    from slots sl
    cross join svc
    where sl.slot_start >= now() + interval '2 hours'
      and (sl.slot_start at time zone p_tz)::date between p_from and p_to
      and (
        sl.source = 'open'
        or not exists (
          select 1 from public.availability_exceptions c
          where c.active and c.kind = 'closed' and c.tour_stop_id is null
            and (c.service_ids is null or svc.id = any (c.service_ids))
            and c.start_at < sl.slot_end and c.end_at > sl.slot_start
        )
      )
    order by sl.slot_start, sl.tour_stop_id, sl.source
  )
  select f.slot_start, f.slot_end, f.tz,
         f.tour_stop_id, ts.slug, ts.city, ts.country, ts.venue,
         (svc.default_capacity - public.slot_capacity_used(svc.id, f.slot_start, f.slot_end)) as remaining,
         to_char(f.slot_start at time zone p_tz, 'YYYY-MM-DD"T"HH24:MI') as local_start
  from filtered f
  cross join svc
  left join public.tour_stops ts on ts.id = f.tour_stop_id
  where (svc.default_capacity - public.slot_capacity_used(svc.id, f.slot_start, f.slot_end)) >= 1
  order by f.slot_start, f.tour_stop_id nulls first
$$;

/* ------------------------------------------------------------------ */
/* booking_to_json                                                     */
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
                  from public.tour_stops t where t.id = b.tour_stop_id)
  )
$$;

/* ------------------------------------------------------------------ */
/* create_hold — atomic, idempotent                                    */
/* ------------------------------------------------------------------ */
-- Never trusts the caller for price, duration or capacity: everything comes
-- from services/availability. Serialised per service with an advisory lock so
-- two concurrent requests for the last seat cannot both win.
create or replace function public.create_hold(
  p_service_slug text, p_start_at timestamptz, p_participants int, p_idempotency_key uuid,
  p_customer_name text, p_customer_contact text,
  p_tour_stop_slug text default null, p_notes text default null, p_ip_hash text default null
) returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare
  s     public.services%rowtype;
  ts    public.tour_stops%rowtype;
  b     public.bookings%rowtype;
  slot  record;
  v_ref text; v_token text; v_end timestamptz; v_mode text; v_day date;
begin
  if p_idempotency_key is null then
    raise exception 'idempotency_key required' using errcode = '22023';
  end if;

  -- Idempotent: same key → same booking, no second row.
  select * into b from public.bookings where idempotency_key = p_idempotency_key;
  if found then return public.booking_to_json(b); end if;

  if p_participants is null or p_participants < 1 or p_participants > 100 then
    raise exception 'invalid participant count' using errcode = '22023';
  end if;
  if coalesce(btrim(p_customer_name), '') = '' or coalesce(btrim(p_customer_contact), '') = '' then
    raise exception 'name and contact are required' using errcode = '22023';
  end if;
  if p_start_at is null then raise exception 'start_at required' using errcode = '22023'; end if;

  select * into s from public.services where slug = p_service_slug and active;
  if not found then raise exception 'unknown or inactive service' using errcode = 'P0002'; end if;

  if p_tour_stop_slug is not null then
    select * into ts from public.tour_stops where slug = p_tour_stop_slug and status = 'open';
    if not found then raise exception 'tour stop not open' using errcode = 'P0002'; end if;
  end if;

  -- Serialise capacity checks for this service.
  perform pg_advisory_xact_lock(hashtext('booking:' || s.id::text));

  v_day := (p_start_at at time zone 'UTC')::date;
  select * into slot
  from public.available_slots(s.slug, v_day - 1, v_day + 1, 'UTC') a
  where a.start_at = p_start_at
    and a.tour_stop_id is not distinct from ts.id
  limit 1;
  if not found then raise exception 'slot not available' using errcode = 'P0003'; end if;
  if slot.remaining < p_participants then raise exception 'insufficient capacity' using errcode = 'P0003'; end if;

  v_end   := p_start_at + make_interval(mins => s.duration_minutes);
  v_mode  := case when ts.id is not null then 'tour' else s.delivery_mode end;
  v_token := encode(gen_random_bytes(24), 'hex');
  loop
    v_ref := 'CG-' || upper(substr(encode(gen_random_bytes(4), 'hex'), 1, 6));
    exit when not exists (select 1 from public.bookings where reference = v_ref);
  end loop;

  insert into public.bookings (
    reference, service_id, contact_id, customer_name, customer_contact,
    start_at, end_at, session_timezone, tour_stop_id, delivery_mode, participant_count,
    status, hold_expires_at, idempotency_key, manage_token, price_amount, currency, notes, ip_hash
  ) values (
    v_ref, s.id,
    (select c.id from public.contacts c where c.contact = btrim(p_customer_contact) order by c.created_at desc limit 1),
    btrim(p_customer_name), btrim(p_customer_contact),
    p_start_at, v_end, slot.session_timezone, ts.id, v_mode, p_participants,
    'hold', now() + interval '10 minutes', p_idempotency_key, v_token,
    case when s.price_amount is null then null else s.price_amount * p_participants end,
    s.currency, nullif(btrim(coalesce(p_notes, '')), ''), p_ip_hash
  ) returning * into b;

  return public.booking_to_json(b);
exception when unique_violation then
  -- A concurrent request with the same idempotency key won the insert: return it.
  select * into b from public.bookings where idempotency_key = p_idempotency_key;
  if found then return public.booking_to_json(b); end if;
  raise;
end $$;

/* ------------------------------------------------------------------ */
/* get_booking / cancel_booking / expire_holds                         */
/* ------------------------------------------------------------------ */
create or replace function public.get_booking(p_reference text, p_manage_token text)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare b public.bookings%rowtype;
begin
  select * into b from public.bookings where reference = upper(p_reference) and manage_token = p_manage_token;
  if not found then raise exception 'booking not found' using errcode = 'P0002'; end if;
  if b.status = 'hold' and b.hold_expires_at < now() then
    update public.bookings set status = 'expired' where id = b.id returning * into b;
  end if;
  return public.booking_to_json(b);
end $$;

create or replace function public.cancel_booking(p_reference text, p_manage_token text, p_reason text default null)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare b public.bookings%rowtype;
begin
  select * into b from public.bookings where reference = upper(p_reference) and manage_token = p_manage_token for update;
  if not found then raise exception 'booking not found' using errcode = 'P0002'; end if;
  if b.status not in ('hold','pending_payment','confirmed') then
    raise exception 'booking cannot be cancelled in status %', b.status using errcode = 'P0003';
  end if;
  if b.start_at <= now() then
    raise exception 'session already started' using errcode = 'P0003';
  end if;
  update public.bookings
     set status = 'cancelled', cancelled_at = now(), cancelled_by = 'customer',
         cancel_reason = nullif(btrim(coalesce(p_reason, '')), '')
   where id = b.id returning * into b;
  return public.booking_to_json(b);
end $$;

-- Marks expired holds. Capacity logic already ignores expired holds lazily,
-- so this is bookkeeping, not correctness.
create or replace function public.expire_holds()
returns int language plpgsql volatile security definer set search_path = '' as $$
declare n int;
begin
  update public.bookings set status = 'expired'
   where status = 'hold' and hold_expires_at < now();
  get diagnostics n = row_count;
  return n;
end $$;

-- Optional pg_cron sweep (every minute). Silently skipped if the extension is unavailable.
do $$
begin
  begin
    create extension if not exists pg_cron;
  exception when others then
    raise notice 'pg_cron unavailable (%). Holds still expire lazily.', sqlerrm;
  end;
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.unschedule(jobid) from cron.job where jobname = 'cg-expire-holds';
    perform cron.schedule('cg-expire-holds', '* * * * *', 'select public.expire_holds()');
  end if;
end $$;

/* ------------------------------------------------------------------ */
/* privileges — nothing for anon/authenticated, RPCs for service role  */
/* ------------------------------------------------------------------ */
alter table public.services               enable row level security;
alter table public.tour_stops             enable row level security;
alter table public.tour_stop_services     enable row level security;
alter table public.availability_rules     enable row level security;
alter table public.availability_exceptions enable row level security;
alter table public.bookings               enable row level security;

revoke all on public.services, public.tour_stops, public.tour_stop_services,
              public.availability_rules, public.availability_exceptions, public.bookings
  from anon, authenticated;

revoke execute on function public.available_slots(text, date, date, text)                                            from public, anon, authenticated;
revoke execute on function public.create_hold(text, timestamptz, int, uuid, text, text, text, text, text)             from public, anon, authenticated;
revoke execute on function public.get_booking(text, text)                                                            from public, anon, authenticated;
revoke execute on function public.cancel_booking(text, text, text)                                                   from public, anon, authenticated;
revoke execute on function public.expire_holds()                                                                     from public, anon, authenticated;
revoke execute on function public.booking_to_json(public.bookings)                                                   from public, anon, authenticated;
revoke execute on function public.slot_capacity_used(uuid, timestamptz, timestamptz)                                 from public, anon, authenticated;
revoke execute on function public.booking_is_active(text, timestamptz)                                               from public, anon, authenticated;

grant execute on function public.available_slots(text, date, date, text)                                to service_role;
grant execute on function public.create_hold(text, timestamptz, int, uuid, text, text, text, text, text) to service_role;
grant execute on function public.get_booking(text, text)                                                to service_role;
grant execute on function public.cancel_booking(text, text, text)                                       to service_role;
grant execute on function public.expire_holds()                                                         to service_role;

/* ------------------------------------------------------------------ */
/* seed — approved offers only (Route C catalogue), no invented prices */
/* ------------------------------------------------------------------ */
insert into public.services (slug, title, category, description, duration_minutes, price_amount, currency, delivery_mode, default_capacity, active, listed, sort_order)
values
  ('conversation', 'The Conversation', 'mentoring',
   'An hour to talk it through — what you''re stuck on, why the last three attempts stopped, what you actually want.',
   60, 4500, 'USD', 'online', 1, true, true, 10),
  ('online-coaching-session', 'Online coaching — live session', 'coaching',
   'One to one, live on video. Priced per month in the catalogue (2 live sessions); per-session price to be set before activation.',
   60, null, 'USD', 'online', 1, false, false, 20),
  ('onsite-one-to-one', 'One-to-one, in person', 'onsite',
   'Sixty minutes in person (Dubai, or during a tour stop). Price on request until set.',
   60, null, 'USD', 'onsite', 1, false, false, 30)
on conflict (slug) do nothing;

-- Placeholder default hours so the engine has something to offer. Gari sets the
-- real hours in the back-office (CG-002.5); these rows are meant to be edited.
insert into public.availability_rules (weekday, start_time, end_time, timezone, service_ids, notes)
select w, time '09:00', time '17:00', 'Asia/Dubai', null, 'Placeholder default hours — edit in the back-office'
from generate_series(1, 5) w
where not exists (select 1 from public.availability_rules);

comment on table public.services is 'CG-002 — bookable services. DB is authoritative for price/duration/capacity.';
comment on table public.bookings is 'CG-002 — bookings. Active capacity = pending/confirmed + unexpired holds.';
comment on table public.tour_stops is 'CG-002 — Gari on tour: confirmed trips with bookable onsite windows (via open availability_exceptions).';

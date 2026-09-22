-- =====================================================================
-- A price per client, a price per session, and which session this is.
--
-- The back-office already priced a package — session_packs.price_amount is
-- free per client — but a session on its own had no money on it at all, and
-- the card proved it: AMAN's session showed no price and no position,
-- because both lines only exist inside the Package section and AMAN's
-- session is not attached to a package.
--
-- THREE PLACES A PRICE CAN COME FROM, IN THIS ORDER.
--   1. The session itself. What this one costs, whatever the rule says —
--      a longer session, a favour, a session at the far end of town.
--   2. The package it belongs to. price_amount divided by total_sessions,
--      because that is what one session of that package is worth.
--   3. The client's rate. What Gari charges THIS client by default, which
--      is the thing that was missing and the reason for the request.
--
-- Each level only overrides the one below it when it has something to say,
-- so setting a client's rate changes every future session without touching
-- any of them, and a single session can still disagree.
--
-- The answer carries where it came from ('session' / 'pack' / 'client'), so
-- the card can say "AED 350 · client rate" rather than presenting a derived
-- figure as if someone had typed it. A number whose origin is invisible is
-- one nobody can correct.
--
-- MONEY STAYS BEHIND finance:view, exactly as pack_json already does. A
-- coach without it sees the session and its number and no amount.
--
-- WHICH SESSION THIS IS. Inside a package: position among that package's
-- sessions in time, out of total_sessions — "3 of 10". Cancelled ones are
-- not counted, since a cancelled session is not one of the ten. Outside a
-- package there is no denominator to give, so it is the plain count of
-- sessions with that client — "3rd session" — which is still the thing Gari
-- wants to know out loud before walking onto the court.
-- =====================================================================

alter table public.coaching_sessions
  add column if not exists price_amount   int,
  add column if not exists price_currency text;
alter table public.coaching_sessions drop constraint if exists coaching_sessions_price_amount_check;
alter table public.coaching_sessions add  constraint coaching_sessions_price_amount_check
  check (price_amount is null or price_amount >= 0);
alter table public.coaching_sessions drop constraint if exists coaching_sessions_price_currency_check;
alter table public.coaching_sessions add  constraint coaching_sessions_price_currency_check
  check (price_currency is null or price_currency ~ '^[A-Z]{3}$');

-- the audit ledger has a closed list of areas; a rate change is a new kind of entry
alter table public.admin_audit drop constraint if exists admin_audit_area_check;
alter table public.admin_audit add  constraint admin_audit_area_check check (area = any (array[
  'crm_contact','crm_note','body_measurement','permission','consent','merge','coaching_session',
  'session_pack','block','report','payment','payment_method','beau_ph_rail','beau_ph_fx',
  'settlement_destination','collaboration','email','commission','enquiry','analytics','whatsapp',
  'agreement','subscription','client_rate']));

-- ---------- the client's own rate, kept where money is kept ----------
/* Not a column on crm_contacts. The client profile reads that table with a plain
   `select *` under a policy that only asks for client_profile:view, so a rate stored
   there would be visible to everyone who can open a profile. What Gari charges a
   particular client is a commercial fact, and it belongs behind finance:view like
   every other amount in this schema. Its own table can say so in its own policy. */
create table if not exists public.client_rates (
  crm_contact_id uuid primary key references public.crm_contacts(id) on delete cascade,
  amount     int  not null check (amount >= 0),
  currency   text not null default 'AED' check (currency ~ '^[A-Z]{3}$'),
  note       text,
  updated_by text,
  updated_at timestamptz not null default now()
);
alter table public.client_rates enable row level security;
drop policy if exists client_rates_view on public.client_rates;
create policy client_rates_view on public.client_rates for select to authenticated
  using (public.has_permission('finance:view'));

create or replace function public.client_rate_set(p_contact_id uuid, p_amount int, p_currency text default 'AED', p_note text default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare e text := public.current_email(); row public.client_rates%rowtype;
begin
  if not public.has_permission('finance:manage') then raise exception 'forbidden' using errcode = '42501'; end if;
  if not exists (select 1 from public.crm_contacts where id = p_contact_id) then
    raise exception 'contact not found' using errcode = 'P0002'; end if;

  /* A null amount is "this client has no special rate", not "this client is free".
     Clearing it puts them back on whatever their package says. */
  if p_amount is null then
    delete from public.client_rates where crm_contact_id = p_contact_id;
    insert into public.admin_audit (area, entity_id, action, changed_by, summary)
    values ('client_rate', p_contact_id::text, 'clear', e, '{}'::jsonb);
    return jsonb_build_object('cleared', p_contact_id);
  end if;

  insert into public.client_rates (crm_contact_id, amount, currency, note, updated_by)
  values (p_contact_id, p_amount, coalesce(nullif(p_currency,''),'AED'), nullif(btrim(coalesce(p_note,'')),''), e)
  on conflict (crm_contact_id) do update
    set amount = excluded.amount, currency = excluded.currency,
        note = excluded.note, updated_by = excluded.updated_by, updated_at = now()
  returning * into row;
  insert into public.admin_audit (area, entity_id, action, changed_by, summary)
  values ('client_rate', p_contact_id::text, 'set', e, jsonb_build_object('amount', row.amount, 'currency', row.currency));
  return to_jsonb(row);
end $$;
revoke execute on function public.client_rate_set(uuid, int, text, text) from public, anon;
grant  execute on function public.client_rate_set(uuid, int, text, text) to authenticated, service_role;

create or replace function public.client_rate_get(p_contact_id uuid)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare row public.client_rates%rowtype;
begin
  if not public.has_permission('finance:view') then raise exception 'forbidden' using errcode = '42501'; end if;
  select * into row from public.client_rates where crm_contact_id = p_contact_id;
  if not found then return null; end if;
  return to_jsonb(row);
end $$;
revoke execute on function public.client_rate_get(uuid) from public, anon;
grant  execute on function public.client_rate_get(uuid) to authenticated, service_role;

-- ---------- what this session costs, and why ----------
create or replace function public.session_price_json(p_id uuid)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare s public.coaching_sessions%rowtype; sp public.session_packs%rowtype; cr public.client_rates%rowtype;
begin
  -- the amount is finance, the rest of the card is not; refusing here would
  -- hide the whole session from a coach who may legitimately see it
  if not public.has_permission('finance:view') then return null; end if;
  select * into s from public.coaching_sessions where id = p_id;
  if not found then return null; end if;

  if s.price_amount is not null then
    return jsonb_build_object('amount', s.price_amount,
      'currency', coalesce(s.price_currency, 'AED'), 'source', 'session');
  end if;

  if s.session_pack_id is not null then
    select * into sp from public.session_packs where id = s.session_pack_id;
    if found and sp.price_amount is not null and sp.total_sessions > 0 then
      -- what one session of that package is worth; rounded, because a package
      -- of three at 1000 does not divide and the card must still show a number
      return jsonb_build_object('amount', round(sp.price_amount::numeric / sp.total_sessions)::int,
        'currency', sp.currency, 'source', 'pack');
    end if;
  end if;

  select * into cr from public.client_rates where crm_contact_id = s.crm_contact_id;
  if found then
    return jsonb_build_object('amount', cr.amount, 'currency', cr.currency, 'source', 'client');
  end if;

  return null;   -- nothing has been priced yet; the card says so rather than guessing zero
end $$;
revoke execute on function public.session_price_json(uuid) from public, anon;
grant  execute on function public.session_price_json(uuid) to authenticated, service_role;

-- ---------- which session this is ----------
create or replace function public.session_seq_json(p_id uuid)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare s public.coaching_sessions%rowtype; n int; total int;
begin
  /* Not money, but still someone's schedule: the same gate as every RPC that returns a
     session at all. Without it any signed-in account could ask where an arbitrary
     session id sits in a package. */
  if not public.has_permission('coach:operations') then return null; end if;
  select * into s from public.coaching_sessions where id = p_id;
  if not found then return null; end if;
  if s.status = 'cancelled' then return null; end if;   -- a cancelled session has no place in the count

  if s.session_pack_id is not null then
    select count(*) into n from public.coaching_sessions o
     where o.session_pack_id = s.session_pack_id and o.status <> 'cancelled'
       and (o.start_at, o.id) <= (s.start_at, s.id);
    select total_sessions into total from public.session_packs where id = s.session_pack_id;
    return jsonb_build_object('n', n, 'of', total);
  end if;

  select count(*) into n from public.coaching_sessions o
   where o.crm_contact_id = s.crm_contact_id and o.session_pack_id is null and o.status <> 'cancelled'
     and (o.start_at, o.id) <= (s.start_at, s.id);
  return jsonb_build_object('n', n, 'of', null);
end $$;
revoke execute on function public.session_seq_json(uuid) from public, anon;
grant  execute on function public.session_seq_json(uuid) to authenticated, service_role;

-- ---------- the session writer accepts a price ----------
create or replace function public.session_write(p jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare e text := public.current_email(); v_id uuid := nullif(p->>'id','')::uuid; row public.coaching_sessions%rowtype; act text;
begin
  if not public.has_permission('coach:operations') then raise exception 'forbidden' using errcode = '42501'; end if;
  -- setting an amount is a finance act even when it rides along with a reschedule
  if (p ? 'price_amount' or p ? 'price_currency') and not public.has_permission('finance:manage') then
    raise exception 'finance:manage required to price a session' using errcode = '42501';
  end if;
  if v_id is null then
    if coalesce(nullif(p->>'crm_contact_id',''),'') = '' then raise exception 'crm_contact_id required' using errcode = '22023'; end if;
    if coalesce(nullif(p->>'start_at',''),'') = '' or coalesce(nullif(p->>'end_at',''),'') = '' then raise exception 'start_at and end_at required' using errcode = '22023'; end if;
    insert into public.coaching_sessions
      (crm_contact_id, session_pack_id, service_id, title, start_at, end_at, session_timezone, delivery_mode,
       location_name, location_address, location_lat, location_lng, meeting_url, note, price_amount, price_currency, created_by)
    values ((p->>'crm_contact_id')::uuid, nullif(p->>'session_pack_id','')::uuid, nullif(p->>'service_id','')::uuid,
       nullif(p->>'title',''), (p->>'start_at')::timestamptz, (p->>'end_at')::timestamptz,
       coalesce(nullif(p->>'session_timezone',''),'Asia/Dubai'),
       coalesce(nullif(p->>'delivery_mode',''),'in_person'),
       nullif(p->>'location_name',''), nullif(p->>'location_address',''),
       nullif(p->>'location_lat','')::numeric, nullif(p->>'location_lng','')::numeric,
       nullif(p->>'meeting_url',''), nullif(p->>'note',''),
       nullif(p->>'price_amount','')::int, nullif(p->>'price_currency',''), e)
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
      note             = case when p ? 'note' then nullif(p->>'note','') else note end,
      -- an empty string clears it, which is how the field goes back to "follow the package or the client rate"
      price_amount     = case when p ? 'price_amount' then nullif(p->>'price_amount','')::int else price_amount end,
      price_currency   = case when p ? 'price_currency' then nullif(p->>'price_currency','') else price_currency end
    where id = v_id returning * into row;
    if not found then raise exception 'session not found' using errcode = 'P0002'; end if;
    act := 'update';
  end if;
  insert into public.admin_audit (area, entity_id, action, changed_by, summary)
  values ('coaching_session', row.id::text, act, e, jsonb_build_object('contact', row.crm_contact_id, 'start', row.start_at));
  return to_jsonb(row) || jsonb_build_object('price', public.session_price_json(row.id), 'seq', public.session_seq_json(row.id));
end $$;
revoke execute on function public.session_write(jsonb) from public, anon;
grant  execute on function public.session_write(jsonb) to authenticated, service_role;

-- ---------- the three read paths carry price and number ----------
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
      'price', public.session_price_json(s.id), 'seq', public.session_seq_json(s.id),
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

create or replace function public.sessions_upcoming(p_limit int default 5)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
begin
  if not public.has_permission('coach:operations') then raise exception 'forbidden' using errcode = '42501'; end if;
  return coalesce((select jsonb_agg(x order by x->>'start_at') from (
    select jsonb_build_object(
      'id', s.id, 'crm_contact_id', s.crm_contact_id, 'client_name', c.display_name,
      'title', coalesce(s.title, sv.title), 'start_at', s.start_at, 'end_at', s.end_at,
      'delivery_mode', s.delivery_mode, 'location_name', s.location_name, 'meeting_url', s.meeting_url,
      'price', public.session_price_json(s.id), 'seq', public.session_seq_json(s.id),
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

create or replace function public.sessions_list(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare f_contact uuid := nullif(p->>'crm_contact_id','')::uuid;
  f_status text := nullif(p->>'status',''); f_mode text := nullif(p->>'delivery_mode','');
  f_from timestamptz := nullif(p->>'from','')::timestamptz; f_to timestamptz := nullif(p->>'to','')::timestamptz;
  f_pack uuid := nullif(p->>'session_pack_id','')::uuid; f_q text := nullif(lower(p->>'q'),'');
  f_origin text := nullif(p->>'origin','');   -- 'site' | 'manual' | null
begin
  if not public.has_permission('coach:operations') then raise exception 'forbidden' using errcode = '42501'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object(
      'id', s.id, 'crm_contact_id', s.crm_contact_id, 'client_name', coalesce(c.display_name, b.customer_name),
      'title', coalesce(s.title, sv.title), 'start_at', s.start_at, 'end_at', s.end_at,
      'delivery_mode', s.delivery_mode, 'status', s.status, 'session_pack_id', s.session_pack_id,
      'price', public.session_price_json(s.id), 'seq', public.session_seq_json(s.id),
      'pack', case when s.session_pack_id is not null then public.pack_json(sp) else null end,
      'booking', case when b.id is null then null else jsonb_build_object(
        'id', b.id, 'reference', b.reference, 'status', b.status, 'price_amount', b.price_amount, 'currency', b.currency) end
    ) order by s.start_at desc)
    from public.coaching_sessions s
    left join public.crm_contacts c on c.id = s.crm_contact_id
    left join public.services sv on sv.id = s.service_id
    left join public.session_packs sp on sp.id = s.session_pack_id
    left join public.bookings b on b.id = s.booking_id
    where (f_contact is null or s.crm_contact_id = f_contact)
      and (f_status is null or s.status = f_status)
      and (f_mode is null or s.delivery_mode = f_mode)
      and (f_pack is null or s.session_pack_id = f_pack)
      and (f_from is null or s.start_at >= f_from)
      and (f_to is null or s.start_at < f_to)
      and (f_origin is null or (f_origin = 'site' and s.booking_id is not null) or (f_origin = 'manual' and s.booking_id is null))
      and (f_q is null or lower(coalesce(c.display_name,'')) like '%'||f_q||'%' or lower(coalesce(s.title,'')) like '%'||f_q||'%'
           or lower(coalesce(b.reference,'')) like '%'||f_q||'%' or lower(coalesce(b.customer_name,'')) like '%'||f_q||'%')
    limit 500), '[]'::jsonb);
end $$;
revoke execute on function public.sessions_list(jsonb) from public, anon;
grant  execute on function public.sessions_list(jsonb) to authenticated, service_role;

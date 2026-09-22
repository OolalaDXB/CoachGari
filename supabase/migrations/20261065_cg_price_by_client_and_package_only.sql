-- =====================================================================
-- Two places a price lives, not three: the client, and the package.
--
-- 20261064 put a third level under them — an amount on the session itself,
-- for the longer one or the favour. Gari does not want it. A price that can
-- be typed anywhere is a price nobody can quote back: "what do I charge
-- Amanda?" stops having one answer as soon as thirty sessions may each
-- disagree with it, and the card showing the origin only softens that, it
-- does not fix it.
--
-- So the cascade is now two steps, and both of them are a decision someone
-- made once and can look up:
--
--   1. The package it belongs to. price_amount over total_sessions, which
--      is what one session of that package is worth.
--   2. The client's rate. What Gari charges THIS client, for anything not
--      inside a package.
--
-- A session that needs a different price gets its own package, or the
-- client's rate changes. Both leave a record of the decision; an amount
-- typed into one session's form did not.
--
-- The columns go rather than being left to rot. They were added an hour
-- ago and no session in production carries one, so there is nothing to
-- preserve and a dead column that the writer no longer fills is a trap for
-- whoever reads this table next.
-- =====================================================================

alter table public.coaching_sessions drop constraint if exists coaching_sessions_price_amount_check;
alter table public.coaching_sessions drop constraint if exists coaching_sessions_price_currency_check;
alter table public.coaching_sessions drop column if exists price_amount;
alter table public.coaching_sessions drop column if exists price_currency;

create or replace function public.session_price_json(p_id uuid)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare s public.coaching_sessions%rowtype; sp public.session_packs%rowtype; cr public.client_rates%rowtype;
begin
  -- the amount is finance, the rest of the card is not; refusing here would
  -- hide the whole session from a coach who may legitimately see it
  if not public.has_permission('finance:view') then return null; end if;
  select * into s from public.coaching_sessions where id = p_id;
  if not found then return null; end if;

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

-- the writer stops accepting a price, and stops pretending it might
create or replace function public.session_write(p jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare e text := public.current_email(); v_id uuid := nullif(p->>'id','')::uuid; row public.coaching_sessions%rowtype; act text;
begin
  if not public.has_permission('coach:operations') then raise exception 'forbidden' using errcode = '42501'; end if;
  /* Refuse loudly rather than dropping it on the floor. A caller still sending a price
     is running against an older idea of this schema, and silently ignoring the field
     would let it believe the session was priced. */
  if p ? 'price_amount' or p ? 'price_currency' then
    raise exception 'a session is priced by its package or by the client rate, not on its own' using errcode = '22023';
  end if;
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
  return to_jsonb(row) || jsonb_build_object('price', public.session_price_json(row.id), 'seq', public.session_seq_json(row.id));
end $$;
revoke execute on function public.session_write(jsonb) from public, anon;
grant  execute on function public.session_write(jsonb) to authenticated, service_role;

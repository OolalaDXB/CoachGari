-- CG-002 fix — create_hold ran with search_path = '' and could not see pgcrypto's
-- gen_random_bytes (installed in the `extensions` schema on Supabase). Fully
-- qualify the call. Caught by supabase/tests/cg002_booking.sql.

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
  v_token := encode(extensions.gen_random_bytes(24), 'hex');
  loop
    v_ref := 'CG-' || upper(substr(encode(extensions.gen_random_bytes(4), 'hex'), 1, 6));
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

revoke execute on function public.create_hold(text, timestamptz, int, uuid, text, text, text, text, text) from public, anon, authenticated;
grant  execute on function public.create_hold(text, timestamptz, int, uuid, text, text, text, text, text) to service_role;

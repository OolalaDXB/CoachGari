-- =====================================================================
-- CRM, part two: delete a real client record, and warn before a duplicate
-- is created by hand.
--
-- 20261059 gave delete a blanket refusal on anyone with history, which is
-- safe and not usable: the test client the owner wants gone has a session
-- pack, and every genuine client has sessions. Deleting a person has to be
-- possible, and the question is only what it is allowed to take with it.
--
-- WHERE THE LINE IS, AND WHY IT IS THERE.
-- The schema already answers most of this. Deleting a crm_contact cascades
-- to sessions, packs, subscriptions, notes, consents, measurements, tokens
-- and exemptions; it is blocked outright by bookings, collaborations and
-- enquiries (NO ACTION); and deleting a pack is blocked by orders, which in
-- turn carry payments, refunds, chargebacks and partner earnings.
--
-- So: with p_cascade the delete removes everything that records coaching —
-- sessions, packs, bookings, plans, measurements, notes — and REFUSES when
-- an order or a payment is attached. That is not timidity. A payment is the
-- one record an audit depends on, ours has to agree with Stripe's, and a
-- back-office that can erase money on a confirm dialog is a back-office
-- nobody can vouch for. Those people get archived; the row stays and stops
-- being in the way.
--
-- crm_delete_preview says exactly what a delete would take, so the
-- confirmation names real numbers rather than asking for a leap of faith.
--
-- THE WARNING ON CREATE AND UPDATE.
-- crm_save_contact inserted whatever it was given. The matcher only ever
-- ran on enquiries and bookings, so the New contact form — and any edit
-- that typed in an existing email — made a duplicate in one click, with
-- nothing said. It now refuses when the email or phone already belongs to
-- someone else, unless the caller passes allow_duplicate, and when it is
-- forced both records are flagged for review.
-- =====================================================================

-- ---------- 1. what would go ----------
create or replace function public.crm_delete_preview(p_id uuid)
returns jsonb language plpgsql security definer stable set search_path = '' as $$
declare r jsonb;
begin
  if not public.has_permission('client_profile:view') then raise exception 'forbidden' using errcode = '42501'; end if;
  select jsonb_build_object(
    'sessions',     (select count(*) from public.coaching_sessions   where crm_contact_id = p_id),
    'packs',        (select count(*) from public.session_packs       where crm_contact_id = p_id),
    'bookings',     (select count(*) from public.bookings            where crm_contact_id = p_id),
    'subscriptions',(select count(*) from public.subscriptions       where crm_contact_id = p_id),
    'collaborations',(select count(*) from public.collaboration_deals where crm_contact_id = p_id),
    'measurements', (select count(*) from public.body_measurements   where crm_contact_id = p_id),
    'notes',        (select count(*) from public.crm_notes           where crm_contact_id = p_id),
    'enquiries',    (select count(*) from public.contacts            where crm_contact_id = p_id),
    -- money is counted separately because it is the thing that stops the delete
    'orders',       (select count(*) from public.orders o
                      where o.session_pack_id in (select id from public.session_packs where crm_contact_id = p_id)
                         or o.booking_id      in (select id from public.bookings      where crm_contact_id = p_id)),
    'payments',     (select count(*) from public.payments pay where pay.order_id in (
                       select o.id from public.orders o
                        where o.session_pack_id in (select id from public.session_packs where crm_contact_id = p_id)
                           or o.booking_id      in (select id from public.bookings      where crm_contact_id = p_id)))
  ) into r;
  return r;
end $$;
revoke execute on function public.crm_delete_preview(uuid) from public, anon;
grant  execute on function public.crm_delete_preview(uuid) to authenticated;

-- ---------- 2. delete, with the cascade the operator asked for ----------
drop function if exists public.crm_delete_contact(uuid);
create or replace function public.crm_delete_contact(p_id uuid, p_cascade boolean default false)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare e text := public.current_email(); row public.crm_contacts%rowtype; c jsonb; n int;
begin
  if not public.has_permission('client_profile:manage') then raise exception 'forbidden' using errcode = '42501'; end if;
  select * into row from public.crm_contacts where id = p_id for update;
  if not found then raise exception 'contact not found' using errcode = 'P0002'; end if;
  c := public.crm_delete_preview(p_id);

  /* Money always stops it, cascade or not. An order and its payment must go on agreeing
     with Stripe, and nothing reachable from a confirm dialog should be able to change
     that. Archiving is the answer for these, and it is not a lesser one. */
  if (c ->> 'orders')::int > 0 or (c ->> 'payments')::int > 0 then
    raise exception 'This person has % order(s) and % payment(s) on file. Those records have to stay — archive them instead; the row stops appearing in the lists.',
      c ->> 'orders', c ->> 'payments' using errcode = '23503';
  end if;

  if not p_cascade and (
       (c ->> 'sessions')::int + (c ->> 'packs')::int + (c ->> 'bookings')::int
     + (c ->> 'subscriptions')::int + (c ->> 'collaborations')::int + (c ->> 'measurements')::int) > 0 then
    raise exception 'This person has coaching history on file. Deleting takes it with them — confirm that, or archive instead.' using errcode = '23503';
  end if;

  /* Order matters: the children that block the delete go first, and packs go after the
     sessions that point at them, which is the reverse of the merge for the same reason. */
  delete from public.coaching_sessions   where crm_contact_id = p_id;
  delete from public.session_packs       where crm_contact_id = p_id;
  delete from public.bookings            where crm_contact_id = p_id;
  delete from public.subscriptions       where crm_contact_id = p_id;
  delete from public.collaboration_deals where crm_contact_id = p_id;

  -- an enquiry outlives the CRM record it was attached to, exactly as lead_delete keeps
  -- the CRM record when an enquiry goes: neither one owns the other
  update public.contacts set crm_contact_id = null where crm_contact_id = p_id;
  get diagnostics n = row_count;

  delete from public.crm_contacts where id = p_id;   -- notes, consents, measurements and tokens cascade

  insert into public.admin_audit (area, entity_id, action, changed_by, summary)
  values ('crm_contact', p_id::text, 'delete', e,
          jsonb_build_object('display_name', row.display_name, 'email', row.email, 'phone', row.phone,
                             'status', row.status, 'cascade', p_cascade,
                             'destroyed', c, 'enquiries_detached', n));
  return jsonb_build_object('deleted', p_id, 'destroyed', c, 'enquiries_detached', n);
end $$;
revoke execute on function public.crm_delete_contact(uuid, boolean) from public, anon;
grant  execute on function public.crm_delete_contact(uuid, boolean) to authenticated;

-- ---------- 3. who else already has this email or phone ----------
create or replace function public.crm_find_duplicates(p_email text, p_phone text, p_exclude uuid default null)
returns jsonb language plpgsql security definer stable set search_path = '' as $$
declare em text := public.crm_normalize_email(p_email); ph text := public.crm_normalize_phone(p_phone); r jsonb;
begin
  if not public.has_permission('client_profile:view') then raise exception 'forbidden' using errcode = '42501'; end if;
  if em is null and ph is null then return '[]'::jsonb; end if;
  select coalesce(jsonb_agg(jsonb_build_object(
           'id', c.id, 'display_name', c.display_name, 'email', c.email, 'phone', c.phone,
           'status', c.status, 'matched_on', case when em is not null and c.email_norm = em then 'email' else 'phone' end)
         order by c.first_seen_at nulls last), '[]'::jsonb)
    into r
    from public.crm_contacts c
   where (p_exclude is null or c.id <> p_exclude)
     and ((em is not null and c.email_norm = em) or (ph is not null and c.phone_norm = ph));
  return r;
end $$;
revoke execute on function public.crm_find_duplicates(text, text, uuid) from public, anon;
grant  execute on function public.crm_find_duplicates(text, text, uuid) to authenticated;

-- ---------- 4. the form stops making duplicates too ----------
create or replace function public.crm_save_contact(p jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare e text := public.current_email(); v_id uuid := nullif(p ->> 'id','')::uuid; before jsonb; row public.crm_contacts%rowtype; changed text[];
        dups jsonb; forced boolean := coalesce((p ->> 'allow_duplicate')::boolean, false);
begin
  if not public.has_permission('client_profile:manage') then raise exception 'forbidden' using errcode = '42501'; end if;
  if coalesce(btrim(p ->> 'display_name'),'') = '' then raise exception 'display name is required' using errcode = '22023'; end if;
  if p ? 'status' and (p ->> 'status') not in ('lead','active','past','archived') then raise exception 'invalid status' using errcode = '22023'; end if;

  /* The matcher ran on enquiries and bookings only, so the New contact form made a
     duplicate in one click and said nothing. The caller has to acknowledge it. */
  dups := public.crm_find_duplicates(p ->> 'email', p ->> 'phone', v_id);
  if jsonb_array_length(dups) > 0 and not forced then
    raise exception 'DUPLICATE: % already has this email or phone.', dups -> 0 ->> 'display_name'
      using errcode = '23505', detail = dups::text;
  end if;

  if v_id is not null then
    select * into row from public.crm_contacts where id = v_id for update;
    if not found then raise exception 'contact not found' using errcode = 'P0002'; end if;
    before := to_jsonb(row);
    update public.crm_contacts set
      display_name = btrim(p ->> 'display_name'),
      email = nullif(btrim(coalesce(p ->> 'email','')),''), email_norm = public.crm_normalize_email(p ->> 'email'),
      phone = nullif(btrim(coalesce(p ->> 'phone','')),''), phone_norm = public.crm_normalize_phone(p ->> 'phone'),
      city = nullif(btrim(coalesce(p ->> 'city','')),''), country = nullif(btrim(coalesce(p ->> 'country','')),''),
      preferred_timezone = nullif(btrim(coalesce(p ->> 'preferred_timezone','')),''),
      preferred_language = nullif(btrim(coalesce(p ->> 'preferred_language','')),''),
      goals = nullif(btrim(coalesce(p ->> 'goals','')),''),
      height_cm = nullif(p ->> 'height_cm','')::numeric,
      status = coalesce(nullif(p ->> 'status',''), status),
      needs_review = coalesce((p ->> 'needs_review')::boolean, needs_review) or (jsonb_array_length(dups) > 0),
      updated_by = e
    where id = row.id returning * into row;
    changed := array(select k from jsonb_object_keys(to_jsonb(row)) k where to_jsonb(row) -> k is distinct from before -> k and k not in ('updated_at'));
  else
    insert into public.crm_contacts (display_name, email, email_norm, phone, phone_norm, city, country,
                                     preferred_timezone, preferred_language, goals, height_cm, status, needs_review, created_by, updated_by)
    values (btrim(p ->> 'display_name'),
            nullif(btrim(coalesce(p ->> 'email','')),''), public.crm_normalize_email(p ->> 'email'),
            nullif(btrim(coalesce(p ->> 'phone','')),''), public.crm_normalize_phone(p ->> 'phone'),
            nullif(btrim(coalesce(p ->> 'city','')),''), nullif(btrim(coalesce(p ->> 'country','')),''),
            nullif(btrim(coalesce(p ->> 'preferred_timezone','')),''), nullif(btrim(coalesce(p ->> 'preferred_language','')),''),
            nullif(btrim(coalesce(p ->> 'goals','')),''), nullif(p ->> 'height_cm','')::numeric,
            coalesce(nullif(p ->> 'status',''),'lead'), jsonb_array_length(dups) > 0, e, e)
    returning * into row;
    changed := array['created'];
  end if;

  -- a knowingly created duplicate marks BOTH sides, so the pair is findable from either
  if jsonb_array_length(dups) > 0 then
    update public.crm_contacts set needs_review = true
     where id in (select (x ->> 'id')::uuid from jsonb_array_elements(dups) x);
  end if;

  insert into public.admin_audit (area, entity_id, action, changed_by, summary)
  values ('crm_contact', row.id::text, case when v_id is null then 'create' else 'update' end, e,
          jsonb_build_object('changed', to_jsonb(changed), 'duplicate_of', case when jsonb_array_length(dups) > 0 then dups end));
  return to_jsonb(row);
end $$;
revoke execute on function public.crm_save_contact(jsonb) from public, anon;
grant  execute on function public.crm_save_contact(jsonb) to authenticated;

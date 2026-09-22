-- =====================================================================
-- CRM: stop making duplicates, stop losing history when merging them,
-- and give the back-office a way to delete one.
--
-- Three faults, found from a screenshot of four identical "AMAN" rows
-- carrying the same phone number.
--
-- 1. THE MATCHER MADE MORE DUPLICATES THAN IT PREVENTED.
--    crm_link_contact looked for a contact with the same normalised email,
--    then the same normalised phone. On exactly one match it linked. On
--    SEVERAL matches it set review := true, left cid null — and fell
--    through to the insert, creating yet another row.
--
--    So the first duplicate, however it arose, guaranteed an unbounded
--    series: two matches produced a third, three produced a fourth. Every
--    later enquiry or booking from that person minted another record. That
--    is the opposite of what a deduplicator is for, and it is why the same
--    phone number appears four times.
--
--    Now: several matches link to the OLDEST of them and flag it for
--    review. Ambiguity is a thing to tell a human about, never a reason to
--    create a new person.
--
-- 2. MERGING A DUPLICATE DESTROYED ITS HISTORY.
--    crm_merge_contacts moved contacts, bookings, crm_notes,
--    body_measurements and client_consents to the target, then deleted the
--    source. Everything else that references crm_contacts does so with
--    ON DELETE CASCADE, and was written after that function:
--    coaching_sessions, session_packs, subscriptions, collaboration_deals,
--    commission_exemptions, report_tokens, consent_tokens, whatsapp_events.
--
--    So an operator tidying a duplicate would silently delete the sessions,
--    the paid session packs and the live subscription attached to the row
--    being merged away. This is worse than the duplicates themselves: the
--    obvious way to fix the visible problem quietly destroys money and
--    history. Nobody had merged a contact with a subscription yet.
--
--    Now every child table moves, and a merge that cannot move something
--    safely refuses instead of guessing.
--
-- 3. THERE WAS NO WAY TO DELETE A CONTACT.
--    Archive existed (crm_set_status). Delete did not, so the test rows and
--    the duplicates could only pile up. crm_delete_contact adds it, and
--    refuses on anyone with sessions, packs, bookings, subscriptions or a
--    collaboration — for those, archiving or merging is the honest action,
--    because deleting would take the history with them.
-- =====================================================================

-- ---------- 1. the matcher ----------
create or replace function public.crm_link_contact(
  p_name text, p_contact text, p_city text default null, p_country text default null,
  p_at timestamptz default now(), p_created_by text default null)
returns uuid language plpgsql security definer set search_path = '' as $$
declare em text; ph text; ids uuid[]; cid uuid; review boolean := false;
begin
  em := public.crm_normalize_email(p_contact);
  ph := case when em is null then public.crm_normalize_phone(p_contact) else null end;

  -- oldest first: the original record is the one to keep accumulating on
  if em is not null then
    select array_agg(id order by first_seen_at nulls last, id) into ids
      from public.crm_contacts where email_norm = em;
    if coalesce(array_length(ids, 1), 0) > 0 then
      cid := ids[1];
      review := array_length(ids, 1) > 1;    -- several: link anyway, and say so
    end if;
  end if;

  if cid is null and ph is not null then
    select array_agg(id order by first_seen_at nulls last, id) into ids
      from public.crm_contacts where phone_norm = ph;
    if coalesce(array_length(ids, 1), 0) > 0 then
      cid := ids[1];
      review := array_length(ids, 1) > 1;
    end if;
  end if;

  if cid is null then
    -- genuinely new: nothing matched, so there is nothing ambiguous about it
    insert into public.crm_contacts (display_name, email, email_norm, phone, phone_norm, city, country, needs_review, first_seen_at, last_activity_at, created_by)
    values (nullif(btrim(coalesce(p_name, '')), ''),
            case when em is not null then btrim(p_contact) end, em,
            case when ph is not null then btrim(p_contact) end, ph,
            nullif(btrim(coalesce(p_city, '')), ''), nullif(btrim(coalesce(p_country, '')), ''),
            false, p_at, p_at, p_created_by)
    returning id into cid;
  else
    update public.crm_contacts set
      last_activity_at = greatest(last_activity_at, p_at),
      first_seen_at    = least(first_seen_at, p_at),
      display_name     = coalesce(display_name, nullif(btrim(coalesce(p_name, '')), '')),
      city             = coalesce(city, nullif(btrim(coalesce(p_city, '')), '')),
      country          = coalesce(country, nullif(btrim(coalesce(p_country, '')), '')),
      phone            = case when phone is null and ph is not null then btrim(p_contact) else phone end,
      phone_norm       = coalesce(phone_norm, ph),
      email            = case when email is null and em is not null then btrim(p_contact) else email end,
      email_norm       = coalesce(email_norm, em),
      needs_review     = needs_review or review
    where id = cid;
  end if;
  return cid;
end $$;
revoke execute on function public.crm_link_contact(text, text, text, text, timestamptz, text) from public, anon, authenticated;
grant  execute on function public.crm_link_contact(text, text, text, text, timestamptz, text) to service_role;

-- ---------- 2. merge: move everything, or refuse ----------
create or replace function public.crm_merge_contacts(p_source uuid, p_target uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare e text := public.current_email(); moved jsonb; clash text;
begin
  if not public.has_permission('client_profile:manage') then raise exception 'forbidden' using errcode = '42501'; end if;
  if p_source is null or p_target is null or p_source = p_target then raise exception 'choose two different contacts' using errcode = '22023'; end if;
  if not exists (select 1 from public.crm_contacts where id = p_source) or not exists (select 1 from public.crm_contacts where id = p_target)
    then raise exception 'contact not found' using errcode = 'P0002'; end if;

  /* A live subscription is unique per (person, service). If both sides hold one for the
     same service, moving the source's would break that index — and silently cancelling
     one of two live plans is not a decision a merge button gets to make. */
  select s.service_id::text into clash
    from public.subscriptions s
   where s.crm_contact_id = p_source and s.status in ('active', 'past_due', 'paused')
     and exists (select 1 from public.subscriptions t
                  where t.crm_contact_id = p_target and t.service_id = s.service_id
                    and t.status in ('active', 'past_due', 'paused'))
   limit 1;
  if clash is not null then
    raise exception 'Both records have a live subscription to the same service. End one of them first, then merge.' using errcode = '23505';
  end if;

  -- if both have an active consent of the same type, withdraw the source's first (keeps the unique index happy, preserves provenance)
  update public.client_consents s set status = 'withdrawn', withdrawn_at = now(),
         evidence = evidence || jsonb_build_object('superseded_by_merge_into', p_target)
   where s.crm_contact_id = p_source and s.status = 'active'
     and exists (select 1 from public.client_consents t where t.crm_contact_id = p_target and t.consent_type = s.consent_type and t.status = 'active');

  update public.contacts             set crm_contact_id = p_target where crm_contact_id = p_source;
  update public.bookings             set crm_contact_id = p_target where crm_contact_id = p_source;
  update public.crm_notes            set crm_contact_id = p_target where crm_contact_id = p_source;
  update public.body_measurements    set crm_contact_id = p_target where crm_contact_id = p_source;
  update public.client_consents      set crm_contact_id = p_target where crm_contact_id = p_source;
  /* everything below cascades on delete and was written after this function existed —
     without these five lines a merge deletes the sessions, the packs, the money and the
     plan belonging to the record being merged away */
  /* Packs BEFORE sessions, and the order is load-bearing: coaching_sessions_pack_guard
     refuses a session whose pack belongs to a different client, so moving the sessions
     first raises "session and pack belong to different clients" halfway through the
     merge. That guard caught this exact mistake in the first version of this migration. */
  update public.session_packs        set crm_contact_id = p_target where crm_contact_id = p_source;
  update public.coaching_sessions    set crm_contact_id = p_target where crm_contact_id = p_source;
  update public.subscriptions        set crm_contact_id = p_target where crm_contact_id = p_source;
  update public.collaboration_deals  set crm_contact_id = p_target where crm_contact_id = p_source;
  update public.commission_exemptions set crm_contact_id = p_target where crm_contact_id = p_source;
  /* tokens and delivery receipts point at a person only to be addressed; they follow the
     person rather than being re-issued */
  update public.report_tokens        set crm_contact_id = p_target where crm_contact_id = p_source;
  update public.consent_tokens       set crm_contact_id = p_target where crm_contact_id = p_source;
  update public.whatsapp_events      set crm_contact_id = p_target where crm_contact_id = p_source;

  update public.crm_contacts set needs_review = false,
         last_activity_at = greatest(last_activity_at, (select last_activity_at from public.crm_contacts where id = p_source)),
         first_seen_at    = least(first_seen_at, (select first_seen_at from public.crm_contacts where id = p_source)),
         display_name     = coalesce(display_name, (select display_name from public.crm_contacts where id = p_source)),
         email            = coalesce(email,        (select email        from public.crm_contacts where id = p_source)),
         email_norm       = coalesce(email_norm,   (select email_norm   from public.crm_contacts where id = p_source)),
         phone            = coalesce(phone,        (select phone        from public.crm_contacts where id = p_source)),
         phone_norm       = coalesce(phone_norm,   (select phone_norm   from public.crm_contacts where id = p_source)),
         city             = coalesce(city,         (select city         from public.crm_contacts where id = p_source)),
         country          = coalesce(country,      (select country      from public.crm_contacts where id = p_source))
   where id = p_target;

  delete from public.crm_contacts where id = p_source;
  moved := jsonb_build_object('source', p_source, 'target', p_target);
  insert into public.admin_audit (area, entity_id, action, changed_by, summary)
  values ('merge', p_target::text, 'merge', e, moved);
  return moved;
end $$;
revoke execute on function public.crm_merge_contacts(uuid, uuid) from public, anon;
grant  execute on function public.crm_merge_contacts(uuid, uuid) to authenticated;

-- ---------- 3. delete ----------
create or replace function public.crm_delete_contact(p_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare e text := public.current_email(); row public.crm_contacts%rowtype; blockers text[] := '{}'; n int;
begin
  if not public.has_permission('client_profile:manage') then raise exception 'forbidden' using errcode = '42501'; end if;
  select * into row from public.crm_contacts where id = p_id for update;
  if not found then raise exception 'contact not found' using errcode = 'P0002'; end if;

  /* What must never be deleted by way of a person: anything that records something
     that happened, or money. Each of these cascades, so a delete would take it with
     it silently — which is exactly the failure this migration fixes in the merge. */
  if exists (select 1 from public.coaching_sessions where crm_contact_id = p_id) then blockers := array_append(blockers, 'coaching sessions'); end if;
  if exists (select 1 from public.session_packs     where crm_contact_id = p_id) then blockers := array_append(blockers, 'session packs'); end if;
  if exists (select 1 from public.subscriptions     where crm_contact_id = p_id) then blockers := array_append(blockers, 'a subscription'); end if;
  if exists (select 1 from public.bookings          where crm_contact_id = p_id) then blockers := array_append(blockers, 'bookings'); end if;
  if exists (select 1 from public.collaboration_deals where crm_contact_id = p_id) then blockers := array_append(blockers, 'a collaboration'); end if;
  if exists (select 1 from public.body_measurements where crm_contact_id = p_id) then blockers := array_append(blockers, 'health measurements'); end if;

  if coalesce(array_length(blockers, 1), 0) > 0 then
    raise exception 'This person has % on file. Archive them instead, or merge them into the record you are keeping — deleting would take that history with them.',
      array_to_string(blockers, ', ') using errcode = '23503';
  end if;

  -- an enquiry outlives the CRM record it was attached to, exactly as lead_delete keeps
  -- the CRM record when an enquiry goes: neither one owns the other
  update public.contacts set crm_contact_id = null where crm_contact_id = p_id;
  get diagnostics n = row_count;

  delete from public.crm_contacts where id = p_id;   -- notes, consents and tokens cascade

  insert into public.admin_audit (area, entity_id, action, changed_by, summary)
  values ('crm_contact', p_id::text, 'delete', e,
          jsonb_build_object('display_name', row.display_name, 'email', row.email, 'phone', row.phone,
                             'status', row.status, 'enquiries_detached', n));
  return jsonb_build_object('deleted', p_id, 'enquiries_detached', n);
end $$;
revoke execute on function public.crm_delete_contact(uuid) from public, anon;
grant  execute on function public.crm_delete_contact(uuid) to authenticated;

-- ---------- 4. surface the duplicates that already exist ----------
/* The matcher will not create more, but the ones already there are invisible until
   something flags them: needs_review is what puts the Merge button on a row. This marks
   every contact that shares a normalised email or phone with another. */
update public.crm_contacts c
   set needs_review = true
 where not c.needs_review
   and exists (
     select 1 from public.crm_contacts o
      where o.id <> c.id
        and ((o.email_norm is not null and o.email_norm = c.email_norm)
          or (o.phone_norm is not null and o.phone_norm = c.phone_norm)));

-- =====================================================================
-- One action, one row. Closing the four ways the back-office made twins.
--
-- WHAT THE EVIDENCE SAYS. session_write writes an audit line per call, so
-- the ledger settles the question that guesswork could not:
--
--   AMAN   create 19:57:57.436063  create 19:57:57.437537   1.5 ms apart
--   Hrishi create 19:59:11.931845  create 19:59:11.932883   1.0 ms apart
--   Sami   create 20:00:45.995728  create 20:00:45.995957   0.23 ms apart
--
-- Two distinct `create` entries, two distinct ids. The database did not
-- duplicate anything — it was asked twice. Nobody taps twice in 230
-- microseconds, so one gesture produced two requests. Whether that is a
-- double-fired submit on a particular browser, a retried POST, or a tap
-- registered twice on a touch screen, the back-office cannot tell from
-- here and should not have to: a coach cannot have two sessions with the
-- same client at the same minute, so the second request is the same
-- session and is answered with it.
--
-- The notes are a DIFFERENT fault with the same symptom, and the timings
-- prove it: 14:13:40, 14:13:42, 14:13:46 — three seconds apart, three
-- deliberate presses. The button worked every time and looked like it had
-- not, because session_note_quick INSERTS a new note on every call. A
-- session has one note; saving it again is a correction, not a second
-- note. So it now updates the one it already wrote.
--
-- Editing that note from the client profile changed the note and left
-- coaching_sessions.note as it was — the session card went on showing the
-- old sentence. Two rows holding one fact, drifting apart. crm_edit_note
-- now carries the correction back to the session.
--
-- And the contacts, created 30 microseconds apart, are the same race one
-- level up: crm_save_contact looks for a duplicate and then inserts, so
-- two calls in the same instant both look, both find nothing, and both
-- insert. The check was never wrong; it was not atomic. A lock on the
-- normalised key makes the second call wait and then see the first.
-- =====================================================================

-- ---------- 1. creating the same session twice answers with the first ----------
create or replace function public.session_write(p jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare e text := public.current_email(); v_id uuid := nullif(p->>'id','')::uuid; row public.coaching_sessions%rowtype; act text;
        v_contact uuid; v_start timestamptz; v_end timestamptz; twin public.coaching_sessions%rowtype;
begin
  if not public.has_permission('coach:operations') then raise exception 'forbidden' using errcode = '42501'; end if;
  if p ? 'price_amount' or p ? 'price_currency' then
    raise exception 'a session is priced by its package or by the client rate, not on its own' using errcode = '22023';
  end if;
  if v_id is null then
    if coalesce(nullif(p->>'crm_contact_id',''),'') = '' then raise exception 'crm_contact_id required' using errcode = '22023'; end if;
    if coalesce(nullif(p->>'start_at',''),'') = '' or coalesce(nullif(p->>'end_at',''),'') = '' then raise exception 'start_at and end_at required' using errcode = '22023'; end if;
    v_contact := (p->>'crm_contact_id')::uuid;
    v_start   := (p->>'start_at')::timestamptz;
    v_end     := (p->>'end_at')::timestamptz;

    /* Two requests a millisecond apart must not both get past the look-up below, so
       they queue here on the one thing that identifies the session: who, and when.
       The lock is held to the end of the transaction and costs nothing when there is
       no contention. */
    perform pg_advisory_xact_lock(hashtext('cg:session:' || v_contact::text || ':' || v_start::text));

    select * into twin from public.coaching_sessions
     where crm_contact_id = v_contact and start_at = v_start and end_at = v_end
       and status <> 'cancelled'
     order by created_at limit 1;
    if found then
      /* Not an error: the caller asked for a session with this client at this minute
         and there is one. Saying so beats refusing (which would look broken after a
         tap that did work) and beats inserting a twin. */
      insert into public.admin_audit (area, entity_id, action, changed_by, summary)
      values ('coaching_session', twin.id::text, 'create:duplicate-ignored', e,
              jsonb_build_object('contact', v_contact, 'start', v_start));
      return to_jsonb(twin) || jsonb_build_object('existing', true,
        'price', public.session_price_json(twin.id), 'seq', public.session_seq_json(twin.id));
    end if;

    insert into public.coaching_sessions
      (crm_contact_id, session_pack_id, service_id, title, start_at, end_at, session_timezone, delivery_mode,
       location_name, location_address, location_lat, location_lng, meeting_url, note, created_by)
    values (v_contact, nullif(p->>'session_pack_id','')::uuid, nullif(p->>'service_id','')::uuid,
       nullif(p->>'title',''), v_start, v_end,
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

-- ---------- 2. a session has one note, and saving it again corrects it ----------
create or replace function public.session_note_quick(p_id uuid, p_text text, p_scope text default 'operational')
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare v_contact uuid; v_note uuid; v_body text := btrim(coalesce(p_text, '')); v_act text;
begin
  if not public.has_permission('coach:operations') then raise exception 'forbidden' using errcode = '42501'; end if;
  if p_scope not in ('operational','coach_private') then raise exception 'bad scope' using errcode = '22023'; end if;
  if p_scope = 'coach_private' then
    if not public.has_permission('coaching_sensitive:manage') then raise exception 'forbidden' using errcode = '42501'; end if;
  elsif not public.has_permission('client_profile:manage') then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  if v_body = '' then raise exception 'empty note' using errcode = '22023'; end if;
  if length(v_body) > 500 then raise exception 'one line, not an essay' using errcode = '22023'; end if;

  select crm_contact_id into v_contact from public.coaching_sessions where id = p_id;
  if v_contact is null then raise exception 'no such session' using errcode = 'P0002'; end if;

  update public.coaching_sessions set note = v_body where id = p_id;

  /* The note on the card and the note in the client's history are one fact. Saving the
     line again is a correction, not a second note — which is why the same sentence
     appeared three times: the button worked, and looked as if it had not. The scope is
     part of the identity: an operational line and a private coaching line are two
     different notes about the same session, and neither overwrites the other. */
  select id into v_note from public.crm_notes
   where session_id = p_id and scope = p_scope
   order by created_at limit 1;

  if v_note is not null then
    update public.crm_notes set body = v_body where id = v_note;
    v_act := 'note:update';
  else
    insert into public.crm_notes (crm_contact_id, session_id, body, category, scope, author)
    values (v_contact, p_id, v_body, 'session', p_scope, coalesce(public.current_email(), 'system'))
    returning id into v_note;
    v_act := 'note';
  end if;

  insert into public.admin_audit (area, entity_id, action, changed_by, summary)
  values ('coaching_session', p_id::text, v_act, coalesce(public.current_email(), 'system'),
          jsonb_build_object('note_id', v_note, 'scope', p_scope, 'length', length(v_body)));

  return jsonb_build_object('ok', true, 'note_id', v_note, 'session_id', p_id);
end $$;
revoke execute on function public.session_note_quick(uuid, text, text) from public, anon;
grant  execute on function public.session_note_quick(uuid, text, text) to authenticated, service_role;

-- ---------- 3. editing a session's note reaches the session card ----------
/* The five-argument signature is the live one; the four-argument form was dropped in
   20260910 precisely so a call could never be ambiguous. Patch the one in service. */
create or replace function public.crm_edit_note(p_note_id uuid, p_body text, p_pinned boolean default null,
                                                p_category text default null, p_scope text default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare e text := public.current_email(); before public.crm_notes%rowtype; row public.crm_notes%rowtype; v_scope text;
begin
  select * into before from public.crm_notes where id = p_note_id for update;
  if not found then raise exception 'note not found' using errcode = 'P0002'; end if;
  v_scope := coalesce(nullif(p_scope,''), before.scope);
  if v_scope not in ('operational','coach_private') then raise exception 'invalid note scope' using errcode = '22023'; end if;
  if before.scope = 'coach_private' or v_scope = 'coach_private' then
    if not public.has_permission('coaching_sensitive:manage') then raise exception 'forbidden' using errcode = '42501'; end if;
  else
    if not public.has_permission('client_profile:manage') then raise exception 'forbidden' using errcode = '42501'; end if;
  end if;
  if coalesce(btrim(p_body),'') = '' then raise exception 'note body is required' using errcode = '22023'; end if;
  update public.crm_notes set body = btrim(p_body), pinned = coalesce(p_pinned, pinned),
         category = coalesce(nullif(p_category,''), category), scope = v_scope
   where id = p_note_id returning * into row;

  /* A note written from a session is the same sentence the session card shows. Correcting
     it in the profile and leaving the card on the old words is two rows holding one fact
     and drifting apart, which is how a back-office starts disagreeing with itself. */
  if row.session_id is not null then
    update public.coaching_sessions set note = row.body where id = row.session_id;
  end if;

  insert into public.admin_audit (area, entity_id, action, changed_by, summary)
  values ('crm_note', row.id::text, 'update', e, jsonb_build_object('scope', row.scope));
  return to_jsonb(row);
end $$;
revoke execute on function public.crm_edit_note(uuid, text, boolean, text, text) from public, anon;
grant  execute on function public.crm_edit_note(uuid, text, boolean, text, text) to authenticated, service_role;

-- ---------- 4. the duplicate check becomes atomic ----------
/* crm_save_contact looked for a duplicate and then inserted. Two calls in the same
   instant both looked, both found nothing, and both inserted — which is exactly what
   the four AMAN rows, 30 microseconds apart, are. The check was never wrong; it was
   not atomic. Serialising on the normalised key makes the second call wait, then see
   the first and raise the duplicate warning it was always supposed to raise. */
create or replace function public.crm_save_contact(p jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare e text := public.current_email(); v_id uuid := nullif(p ->> 'id','')::uuid; before jsonb; row public.crm_contacts%rowtype; changed text[];
        dups jsonb; forced boolean := coalesce((p ->> 'allow_duplicate')::boolean, false);
        em text := public.crm_normalize_email(p ->> 'email'); ph text := public.crm_normalize_phone(p ->> 'phone');
begin
  if not public.has_permission('client_profile:manage') then raise exception 'forbidden' using errcode = '42501'; end if;
  if coalesce(btrim(p ->> 'display_name'),'') = '' then raise exception 'display name is required' using errcode = '22023'; end if;
  if p ? 'status' and (p ->> 'status') not in ('lead','active','past','archived') then raise exception 'invalid status' using errcode = '22023'; end if;

  -- one queue per person, so look-then-insert cannot interleave with itself
  perform pg_advisory_xact_lock(hashtext('cg:contact:' || coalesce(em, ph, lower(btrim(p ->> 'display_name')))));

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
      email = nullif(btrim(coalesce(p ->> 'email','')),''), email_norm = em,
      phone = nullif(btrim(coalesce(p ->> 'phone','')),''), phone_norm = ph,
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
            nullif(btrim(coalesce(p ->> 'email','')),''), em,
            nullif(btrim(coalesce(p ->> 'phone','')),''), ph,
            nullif(btrim(coalesce(p ->> 'city','')),''), nullif(btrim(coalesce(p ->> 'country','')),''),
            nullif(btrim(coalesce(p ->> 'preferred_timezone','')),''), nullif(btrim(coalesce(p ->> 'preferred_language','')),''),
            nullif(btrim(coalesce(p ->> 'goals','')),''), nullif(p ->> 'height_cm','')::numeric,
            coalesce(nullif(p ->> 'status',''),'lead'), jsonb_array_length(dups) > 0, e, e)
    returning * into row;
    changed := array['created'];
  end if;

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

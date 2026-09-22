-- =====================================================================
-- The twin guard becomes a window, because as a rule it blocked real work.
--
-- 20261066 answered any create for an existing (client, start, end) with the
-- session already there. That killed the twins — and, it turns out, killed
-- legitimate work with them: recreating a session at the same slot after
-- deleting it, or simply trying again, silently returned the old row. From
-- the coach's side that reads as "I can no longer create a session", which
-- is exactly what was reported.
--
-- The fault was never "two sessions at the same minute exist". It was "one
-- gesture produced two requests", and the evidence said how far apart:
-- 1.5 ms, 1.0 ms, 0.23 ms. A window of ten seconds covers every one of
-- those by four orders of magnitude and cannot reach a human who comes
-- back to the same slot a minute later.
--
-- So the guard now asks a narrower question: was an identical session
-- created *just now*? If yes it is the same gesture and the caller gets
-- that session. If it was created earlier — even a minute earlier — the
-- coach means it, and a second session is created.
--
-- The lesson worth keeping: a guard written as a permanent rule forbids a
-- legitimate action forever in order to stop an accident that lasts
-- milliseconds. Bound the guard to the accident.
-- =====================================================================

create or replace function public.session_write(p jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare e text := public.current_email(); v_id uuid := nullif(p->>'id','')::uuid; row public.coaching_sessions%rowtype; act text;
        v_contact uuid; v_start timestamptz; v_end timestamptz; twin public.coaching_sessions%rowtype;
begin
  if not public.has_permission('coach:operations') then raise exception 'forbidden' using errcode = '42501'; end if;
  /* An empty price is not an attempt to price a session — it is an older client sending a
     field it no longer fills. Refusing that would break a browser still running yesterday's
     bundle, which a service worker guarantees for at least one load. Only a real amount is
     refused. */
  if nullif(p->>'price_amount','') is not null or nullif(p->>'price_currency','') is not null then
    raise exception 'a session is priced by its package or by the client rate, not on its own' using errcode = '22023';
  end if;
  if v_id is null then
    if coalesce(nullif(p->>'crm_contact_id',''),'') = '' then raise exception 'crm_contact_id required' using errcode = '22023'; end if;
    if coalesce(nullif(p->>'start_at',''),'') = '' or coalesce(nullif(p->>'end_at',''),'') = '' then raise exception 'start_at and end_at required' using errcode = '22023'; end if;
    v_contact := (p->>'crm_contact_id')::uuid;
    v_start   := (p->>'start_at')::timestamptz;
    v_end     := (p->>'end_at')::timestamptz;

    perform pg_advisory_xact_lock(hashtext('cg:session:' || v_contact::text || ':' || v_start::text));

    /* Ten seconds: four orders of magnitude above the 0.23 ms that started this, and far
       below anything a person does on purpose. */
    select * into twin from public.coaching_sessions
     where crm_contact_id = v_contact and start_at = v_start and end_at = v_end
       and status <> 'cancelled'
       and created_at > now() - interval '10 seconds'
     order by created_at limit 1;
    if found then
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

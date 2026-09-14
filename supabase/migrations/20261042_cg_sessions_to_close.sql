-- =====================================================================
-- Coach Gari — the sessions waiting to be closed (CG-019)
--
-- sessions_upcoming answers "what is next". The daily gesture needs the
-- opposite question: which sessions have already happened and are still sitting
-- at 'scheduled', because nobody said whether the client turned up.
--
-- Those are the ones that deserve a card on the Overview with two buttons and a
-- line to type. A session older than the window is not chased forever — after a
-- few days an unclosed session is a fact of the past, not a task, and the
-- Sessions list is where it is dealt with.
-- =====================================================================
create or replace function public.sessions_to_close(p_hours int default 72, p_limit int default 6)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
begin
  if not public.has_permission('coach:operations') then raise exception 'forbidden' using errcode = '42501'; end if;
  return coalesce((select jsonb_agg(x order by x->>'start_at' desc) from (
    select jsonb_build_object(
      'id', s.id, 'crm_contact_id', s.crm_contact_id, 'client_name', c.display_name,
      'title', coalesce(s.title, sv.title), 'start_at', s.start_at, 'end_at', s.end_at,
      'delivery_mode', s.delivery_mode, 'location_name', s.location_name,
      'note', s.note,
      'pack', case when s.session_pack_id is not null then public.pack_json(sp) else null end) as x
    from public.coaching_sessions s
    left join public.crm_contacts c on c.id = s.crm_contact_id
    left join public.services sv on sv.id = s.service_id
    left join public.session_packs sp on sp.id = s.session_pack_id
    where s.status = 'scheduled'
      and s.end_at <= now()
      and s.end_at > now() - (greatest(least(coalesce(p_hours, 72), 720), 1) || ' hours')::interval
    order by s.start_at desc
    limit greatest(least(coalesce(p_limit, 6), 50), 1)) t), '[]'::jsonb);
end $$;
revoke execute on function public.sessions_to_close(int, int) from public, anon;
grant  execute on function public.sessions_to_close(int, int) to authenticated, service_role;

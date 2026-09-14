-- =====================================================================
-- Coach Gari — Sessions list carries its booking
--
-- The back-office folds the Bookings tab into Sessions: one list of the time,
-- with an Origin column (website booking / entered by the coach) and the
-- booking's payment state next to it. sessions_list therefore returns, per
-- session, the booking it came from (reference, status, price) when there is
-- one. Same filters, same permission, one extra left join.
-- =====================================================================
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

-- CG-011 backfill: every confirmed or completed booking that already belongs to
-- a CRM contact becomes a coaching session, so the calendar is not empty on the
-- day it ships. Idempotent (one session per booking).
insert into public.coaching_sessions
  (crm_contact_id, service_id, booking_id, title, start_at, end_at, session_timezone, delivery_mode, status, created_by)
select b.crm_contact_id, b.service_id, b.id, s.title, b.start_at, b.end_at, b.session_timezone,
       case when b.delivery_mode = 'online' then 'online' else 'in_person' end,
       case when b.status = 'completed' then 'completed' else 'scheduled' end, 'system:booking'
from public.bookings b left join public.services s on s.id = b.service_id
where b.status in ('confirmed','completed') and b.crm_contact_id is not null
on conflict (booking_id) do nothing;

-- CG-007 (b) — belt and braces for historical integrity: whatever inserts a
-- booking (create_hold today, any future path), the commercial snapshot is
-- filled from the service at insert time when the caller left it empty.
-- Never updated afterwards: catalogue edits affect future bookings only.
create or replace function public.bookings_snapshot_service()
returns trigger language plpgsql set search_path = '' as $$
begin
  if new.service_title is null or new.service_slug is null or new.service_duration_minutes is null then
    select coalesce(new.service_slug, s.slug), coalesce(new.service_title, s.title), coalesce(new.service_duration_minutes, s.duration_minutes)
      into new.service_slug, new.service_title, new.service_duration_minutes
      from public.services s where s.id = new.service_id;
  end if;
  return new;
end $$;
drop trigger if exists bookings_snapshot_service on public.bookings;
create trigger bookings_snapshot_service before insert on public.bookings
  for each row execute function public.bookings_snapshot_service();

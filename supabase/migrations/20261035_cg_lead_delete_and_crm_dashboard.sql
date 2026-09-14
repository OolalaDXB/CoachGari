-- =====================================================================
-- Coach Gari — CRM: delete a lead for good, and a dashboard for the CRM tab
--
-- Two things the owner asked for:
--   1. Leads must be deletable, otherwise they pollute. "Archive" was only a
--      status; a spam or a dead enquiry stayed in the table for ever.
--      lead_delete(id) removes the enquiry row, its attachments (the rows by
--      cascade, the storage objects explicitly) and audits it. It never touches
--      the CRM person: a person can have several enquiries, bookings, notes —
--      that record is governed by CG-010 (export / erasure), not by a lead.
--   2. Lead handling (convert, archive, delete) belongs in CRM, not in the
--      Overview. crm_dashboard() gives the CRM tab its own headline numbers so
--      the Overview can go back to being a cockpit, not a second inbox.
-- Forward-only; both RPCs gated by coach:operations (the permission that
-- already reads and updates public.contacts).
-- =====================================================================

alter table public.admin_audit drop constraint if exists admin_audit_area_check;
alter table public.admin_audit add constraint admin_audit_area_check check (area = any (array[
  'crm_contact','crm_note','body_measurement','permission','consent','merge','coaching_session',
  'session_pack','block','report','payment','payment_method','beau_ph_rail','beau_ph_fx',
  'settlement_destination','collaboration','email','commission','enquiry']));

-- ---------- 1. delete a lead (the enquiry), for good ----------
-- Supabase forbids deleting storage.objects from SQL (storage.protect_delete), so the
-- files go through the Storage API: the RPC removes the rows and returns the paths, the
-- back-office removes the objects right after, under the delete policy below (coach only,
-- this bucket only). An object left behind by a failed second step is harmless — the row
-- that named it is gone, nothing can sign a URL to it.
drop policy if exists enquiry_media_coach_delete on storage.objects;
create policy enquiry_media_coach_delete on storage.objects for delete to authenticated
  using (bucket_id = 'enquiry-media' and public.has_permission('coach:operations'));

create or replace function public.lead_delete(p_id uuid)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare e text := public.current_email(); c public.contacts%rowtype; paths text[];
begin
  if not public.has_permission('coach:operations') then raise exception 'forbidden' using errcode = '42501'; end if;
  select * into c from public.contacts where id = p_id for update;
  if not found then raise exception 'lead not found' using errcode = 'P0002'; end if;
  select coalesce(array_agg(cm.storage_path), '{}') into paths from public.contact_media cm where cm.contact_id = c.id;
  delete from public.contacts where id = c.id;   -- contact_media cascade; bookings / email_events set null
  -- the audit row keeps the fact, never the content (no name, no message)
  insert into public.admin_audit (area, entity_id, action, changed_by, summary)
  values ('enquiry', c.id::text, 'delete', e, jsonb_strip_nulls(jsonb_build_object('status', c.status, 'crm_contact_id', c.crm_contact_id, 'media', coalesce(array_length(paths, 1), 0))));
  return jsonb_build_object('ok', true, 'id', c.id, 'paths', to_jsonb(paths));
end $$;
revoke all on function public.lead_delete(uuid) from public, anon;
grant execute on function public.lead_delete(uuid) to authenticated, service_role;

-- ---------- 2. the CRM tab's own numbers ----------
create or replace function public.crm_dashboard()
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare out jsonb := '{}'::jsonb;
begin
  if public.has_permission('coach:operations') then
    out := out || jsonb_build_object('leads', jsonb_build_object(
      'new',        (select count(*) from public.contacts where status = 'new'),
      'contacted',  (select count(*) from public.contacts where status = 'contacted'),
      'qualified',  (select count(*) from public.contacts where status = 'qualified'),
      'closed',     (select count(*) from public.contacts where status = 'closed'),
      'spam',       (select count(*) from public.contacts where status = 'spam'),
      'total',      (select count(*) from public.contacts),
      'last_7d',    (select count(*) from public.contacts where created_at >= now() - interval '7 days'),
      'last_30d',   (select count(*) from public.contacts where created_at >= now() - interval '30 days'),
      'oldest_new_days', (select extract(day from now() - min(created_at))::int from public.contacts where status = 'new')));
  end if;
  if public.has_permission('client_profile:view') then
    out := out || jsonb_build_object('contacts', jsonb_build_object(
      'lead',         (select count(*) from public.crm_contacts where status = 'lead'),
      'active',       (select count(*) from public.crm_contacts where status = 'active'),
      'past',         (select count(*) from public.crm_contacts where status = 'past'),
      'archived',     (select count(*) from public.crm_contacts where status = 'archived'),
      'total',        (select count(*) from public.crm_contacts),
      'needs_review', (select count(*) from public.crm_contacts where needs_review)));
  end if;
  if out = '{}'::jsonb then raise exception 'forbidden' using errcode = '42501'; end if;
  return out;
end $$;
revoke all on function public.crm_dashboard() from public, anon;
grant execute on function public.crm_dashboard() to authenticated, service_role;

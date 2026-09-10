-- =====================================================================
-- Coach Gari — CRM quick actions
--
-- The back-office could open a contact and edit the whole record, but had no
-- safe one-click lifecycle action (convert a lead to a client, archive, restore)
-- and no way to dismiss a false duplicate flag. crm_save_contact rewrites every
-- column, so it cannot be used for a status-only change without wiping fields.
-- Two narrow, audited RPCs fill that gap. Nothing here deletes data: "archive"
-- is a status, and the needs-review flag is cleared, never the row removed.
-- Forward migration only; both gated by client_profile:manage.
-- =====================================================================

-- Change only the lifecycle status of a CRM contact (lead → active → past → archived).
create or replace function public.crm_set_status(p_id uuid, p_status text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare e text := public.current_email(); row public.crm_contacts%rowtype; old_status text;
begin
  if not public.has_permission('client_profile:manage') then raise exception 'forbidden' using errcode = '42501'; end if;
  if p_status not in ('lead','active','past','archived') then raise exception 'invalid status' using errcode = '22023'; end if;
  select * into row from public.crm_contacts where id = p_id for update;
  if not found then raise exception 'contact not found' using errcode = 'P0002'; end if;
  old_status := row.status;
  update public.crm_contacts set status = p_status, updated_by = e where id = row.id returning * into row;
  insert into public.admin_audit (area, entity_id, action, changed_by, summary)
  values ('crm_contact', row.id::text, 'status', e, jsonb_build_object('from', old_status, 'to', p_status));
  return jsonb_build_object('id', row.id, 'status', row.status);
end $$;
revoke all on function public.crm_set_status(uuid, text) from public, anon;
grant execute on function public.crm_set_status(uuid, text) to authenticated, service_role;

-- Dismiss a needs-review (ambiguous-match) flag when the record is NOT a duplicate.
create or replace function public.crm_clear_review(p_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare e text := public.current_email(); row public.crm_contacts%rowtype;
begin
  if not public.has_permission('client_profile:manage') then raise exception 'forbidden' using errcode = '42501'; end if;
  select * into row from public.crm_contacts where id = p_id for update;
  if not found then raise exception 'contact not found' using errcode = 'P0002'; end if;
  update public.crm_contacts set needs_review = false, updated_by = e where id = row.id returning * into row;
  insert into public.admin_audit (area, entity_id, action, changed_by, summary)
  values ('crm_contact', row.id::text, 'clear_review', e, '{}'::jsonb);
  return jsonb_build_object('id', row.id, 'needs_review', row.needs_review);
end $$;
revoke all on function public.crm_clear_review(uuid) from public, anon;
grant execute on function public.crm_clear_review(uuid) to authenticated, service_role;

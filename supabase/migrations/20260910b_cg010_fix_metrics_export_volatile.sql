-- metrics_export writes an audit row, so it cannot be STABLE.
create or replace function public.metrics_export(p_contact_id uuid)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare e text := public.current_email();
begin
  if not public.has_permission('health_metrics:view') then raise exception 'forbidden' using errcode = '42501'; end if;
  insert into public.admin_audit (area, entity_id, action, changed_by, summary)
  values ('body_measurement', p_contact_id::text, 'export', e, jsonb_build_object('contact', p_contact_id));
  return coalesce((select jsonb_agg(jsonb_build_object('measured_at', measured_at, 'height_cm', height_cm_snapshot,
             'weight_kg', weight_kg, 'bmi', bmi, 'body_fat_pct', body_fat_pct, 'muscle_pct', muscle_pct,
             'source', source, 'note', note, 'created_at', created_at) order by measured_at)
           from public.body_measurements where crm_contact_id = p_contact_id), '[]'::jsonb);
end $$;
revoke execute on function public.metrics_export(uuid) from public, anon;
grant  execute on function public.metrics_export(uuid) to authenticated, service_role;

-- =============================================================
-- CG-010 — coaching-sensitive privacy gate, explicit consent, review/merge
--
-- Forward-only. Adds:
--  1. coaching_sensitive:view/manage — an independent boundary for private
--     coaching notes. client_profile:* alone never reveals them.
--  2. crm_notes.scope (operational | coach_private) enforced by RLS + RPC.
--  3. client_consents — an auditable consent HISTORY (not a boolean) for
--     fitness_progress_tracking, with a versioned notice, source (client link
--     vs admin fallback), and withdrawal as a distinct event.
--  4. Server-side consent enforcement on body_measurements: no active consent
--     -> insert DENIED; withdrawn -> DENIED. Minors are blocked entirely.
--  5. Progress export / history deletion RPCs (client-scoped, audited) —
--     withdrawal (stop future collection) and deletion (remove history) are
--     distinct actions.
--  6. needs_review is filterable; a safe, transactional, audited manual merge
--     moves every linked row (enquiries, bookings, notes, measurements,
--     consents) — never a fuzzy auto-merge.
-- No medical interpretation is produced anywhere. BMI stays derived.
-- =============================================================

-- ---------- 1. permissions + audit area ----------
alter table public.app_permissions drop constraint if exists app_permissions_permission_check;
alter table public.app_permissions add constraint app_permissions_permission_check
  check (permission in ('coach:operations','finance:view','finance:manage','analytics:view','platform:admin',
                        'catalog:view','catalog:manage',
                        'client_profile:view','client_profile:manage','health_metrics:view','health_metrics:manage',
                        'coaching_sensitive:view','coaching_sensitive:manage'));

alter table public.admin_audit drop constraint if exists admin_audit_area_check;
alter table public.admin_audit add constraint admin_audit_area_check
  check (area in ('crm_contact','crm_note','body_measurement','permission','consent','merge'));

-- ---------- 2. note scope ----------
alter table public.crm_notes add column if not exists scope text not null default 'operational'
  check (scope in ('operational','coach_private'));

-- operational notes: client_profile:view. coach_private notes: also coaching_sensitive:view.
drop policy if exists crm_notes_view on public.crm_notes;
create policy crm_notes_view on public.crm_notes for select to authenticated
  using (public.has_permission('client_profile:view')
         and (scope = 'operational' or public.has_permission('coaching_sensitive:view')));

create or replace function public.crm_add_note(p_contact_id uuid, p_body text, p_category text default null,
                                               p_pinned boolean default false, p_scope text default 'operational')
returns jsonb language plpgsql security definer set search_path = '' as $$
declare e text := public.current_email(); row public.crm_notes%rowtype;
begin
  if coalesce(p_scope,'operational') not in ('operational','coach_private') then raise exception 'invalid note scope' using errcode = '22023'; end if;
  if p_scope = 'coach_private' then
    if not public.has_permission('coaching_sensitive:manage') then raise exception 'forbidden' using errcode = '42501'; end if;
  else
    if not public.has_permission('client_profile:manage') then raise exception 'forbidden' using errcode = '42501'; end if;
  end if;
  if coalesce(btrim(p_body),'') = '' then raise exception 'note body is required' using errcode = '22023'; end if;
  insert into public.crm_notes (crm_contact_id, body, category, pinned, author, scope)
  values (p_contact_id, btrim(p_body), nullif(p_category,''), coalesce(p_pinned,false), e, p_scope) returning * into row;
  insert into public.admin_audit (area, entity_id, action, changed_by, summary)
  values ('crm_note', row.id::text, 'create', e, jsonb_build_object('contact', p_contact_id, 'scope', p_scope));
  return to_jsonb(row);
end $$;

create or replace function public.crm_edit_note(p_note_id uuid, p_body text, p_pinned boolean default null,
                                                p_category text default null, p_scope text default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare e text := public.current_email(); before public.crm_notes%rowtype; row public.crm_notes%rowtype; v_scope text;
begin
  select * into before from public.crm_notes where id = p_note_id for update;
  if not found then raise exception 'note not found' using errcode = 'P0002'; end if;
  v_scope := coalesce(nullif(p_scope,''), before.scope);
  if v_scope not in ('operational','coach_private') then raise exception 'invalid note scope' using errcode = '22023'; end if;
  -- editing (or moving to) a coach_private note needs the sensitive permission; else client_profile:manage
  if before.scope = 'coach_private' or v_scope = 'coach_private' then
    if not public.has_permission('coaching_sensitive:manage') then raise exception 'forbidden' using errcode = '42501'; end if;
  else
    if not public.has_permission('client_profile:manage') then raise exception 'forbidden' using errcode = '42501'; end if;
  end if;
  if coalesce(btrim(p_body),'') = '' then raise exception 'note body is required' using errcode = '22023'; end if;
  update public.crm_notes set body = btrim(p_body), pinned = coalesce(p_pinned, pinned),
         category = coalesce(nullif(p_category,''), category), scope = v_scope
   where id = p_note_id returning * into row;
  insert into public.admin_audit (area, entity_id, action, changed_by, summary)
  values ('crm_note', row.id::text, 'update', e, jsonb_build_object('scope', row.scope));
  return to_jsonb(row);
end $$;

-- the old signatures are dropped (not just revoked) so a call is never ambiguous
drop function if exists public.crm_add_note(uuid, text, text, boolean);
drop function if exists public.crm_edit_note(uuid, text, boolean, text);
revoke execute on function public.crm_add_note(uuid, text, text, boolean, text),
                          public.crm_edit_note(uuid, text, boolean, text, text) from public, anon;
grant  execute on function public.crm_add_note(uuid, text, text, boolean, text),
                          public.crm_edit_note(uuid, text, boolean, text, text) to authenticated, service_role;

-- ---------- 3. minors flag ----------
alter table public.crm_contacts add column if not exists is_minor boolean not null default false;

-- ---------- 4. consent history + tokens ----------
create table if not exists public.client_consents (
  id             uuid primary key default gen_random_uuid(),
  crm_contact_id uuid not null references public.crm_contacts(id) on delete cascade,
  consent_type   text not null check (consent_type in ('fitness_progress_tracking')),
  purpose        text,
  notice_version text not null,
  status         text not null check (status in ('active','withdrawn','declined')),
  source         text not null check (source in ('client_link','admin_recorded')),
  consented_at   timestamptz,
  withdrawn_at   timestamptz,
  evidence       jsonb not null default '{}'::jsonb,
  created_by     text,
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now()
);
create index if not exists client_consents_contact_idx on public.client_consents (crm_contact_id, created_at desc);
-- at most one ACTIVE consent per (contact, type)
create unique index if not exists client_consents_one_active on public.client_consents (crm_contact_id, consent_type) where status = 'active';
drop trigger if exists client_consents_updated_at on public.client_consents;
create trigger client_consents_updated_at before update on public.client_consents for each row execute function public.set_updated_at();

create table if not exists public.consent_tokens (
  token_hash     text primary key,
  crm_contact_id uuid not null references public.crm_contacts(id) on delete cascade,
  consent_type   text not null,
  notice_version text not null,
  expires_at     timestamptz not null,
  used_at        timestamptz,
  created_by     text,
  created_at     timestamptz not null default now()
);

-- the versioned notice served to the client (bump the version when the text changes)
create or replace function public.consent_notice(p_type text)
returns jsonb language sql immutable set search_path = '' as $$
  select case when p_type = 'fitness_progress_tracking' then jsonb_build_object(
    'consent_type', 'fitness_progress_tracking',
    'notice_version', 'fitness-progress-v1-2026-09',
    'title', 'Progress tracking consent',
    'purpose', 'To record your fitness coaching progress over time.',
    'data', jsonb_build_array('height','weight','derived BMI','body-fat %','muscle %','progress history'),
    'access', 'Authorised Coach Gari operators may view this information to support your coaching.',
    'withdraw', 'You can withdraw at any time; withdrawal stops future recording. Ask Coach Gari, who will action it.',
    'retention', 'Records are kept for the duration of your coaching relationship unless you ask for deletion.',
    'rights', 'You can ask to access, export or delete your progress data.',
    'contact', 'letsgo@coachgari.com',
    'disclaimer', 'Progress tracking is for fitness coaching purposes only. It is not medical advice, diagnosis or treatment. For medical concerns, consult a qualified healthcare professional.')
  else null end
$$;
revoke execute on function public.consent_notice(text) from public, anon;
grant  execute on function public.consent_notice(text) to authenticated, anon, service_role;  -- the client link needs it

-- helper: is there an active consent?
create or replace function public.has_active_consent(p_contact_id uuid, p_type text)
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.client_consents where crm_contact_id = p_contact_id and consent_type = p_type and status = 'active')
$$;
revoke execute on function public.has_active_consent(uuid, text) from public, anon;
grant  execute on function public.has_active_consent(uuid, text) to authenticated, service_role;

-- RLS: consent history readable by health_metrics:view; writes RPC-only
alter table public.client_consents enable row level security;
alter table public.consent_tokens  enable row level security;
revoke all on public.client_consents, public.consent_tokens from anon, authenticated;
grant select on public.client_consents to authenticated;
drop policy if exists client_consents_view on public.client_consents;
create policy client_consents_view on public.client_consents for select to authenticated using (public.has_permission('health_metrics:view'));

-- admin: issue a scoped, expiring client link (health_metrics:manage); refuse minors
create or replace function public.consent_issue_link(p_contact_id uuid, p_consent_type text default 'fitness_progress_tracking')
returns jsonb language plpgsql security definer set search_path = '' as $$
declare e text := public.current_email(); tok text; nv text;
begin
  if not public.has_permission('health_metrics:manage') then raise exception 'forbidden' using errcode = '42501'; end if;
  if (public.consent_notice(p_consent_type)) is null then raise exception 'unknown consent type' using errcode = '22023'; end if;
  if coalesce((select is_minor from public.crm_contacts where id = p_contact_id), false) then raise exception 'progress tracking is not available for minors' using errcode = 'P0005'; end if;
  nv := public.consent_notice(p_consent_type) ->> 'notice_version';
  tok := encode(extensions.gen_random_bytes(32), 'hex');
  insert into public.consent_tokens (token_hash, crm_contact_id, consent_type, notice_version, expires_at, created_by)
  values (encode(extensions.digest(tok,'sha256'),'hex'), p_contact_id, p_consent_type, nv, now() + interval '7 days', e);
  insert into public.admin_audit (area, entity_id, action, changed_by, summary)
  values ('consent', p_contact_id::text, 'issue_link', e, jsonb_build_object('type', p_consent_type, 'notice_version', nv));
  return jsonb_build_object('token', tok, 'expires_in_days', 7, 'notice_version', nv);
end $$;
revoke execute on function public.consent_issue_link(uuid, text) from public, anon;
grant  execute on function public.consent_issue_link(uuid, text) to authenticated, service_role;

-- admin: exceptional fallback recording (clearly marked source=admin_recorded)
create or replace function public.consent_record_admin(p_contact_id uuid, p_consent_type text default 'fitness_progress_tracking')
returns jsonb language plpgsql security definer set search_path = '' as $$
declare e text := public.current_email(); nv text; row public.client_consents%rowtype;
begin
  if not public.has_permission('health_metrics:manage') then raise exception 'forbidden' using errcode = '42501'; end if;
  if (public.consent_notice(p_consent_type)) is null then raise exception 'unknown consent type' using errcode = '22023'; end if;
  if coalesce((select is_minor from public.crm_contacts where id = p_contact_id), false) then raise exception 'progress tracking is not available for minors' using errcode = 'P0005'; end if;
  nv := public.consent_notice(p_consent_type) ->> 'notice_version';
  update public.client_consents set status = 'withdrawn', withdrawn_at = now()
   where crm_contact_id = p_contact_id and consent_type = p_consent_type and status = 'active';
  insert into public.client_consents (crm_contact_id, consent_type, purpose, notice_version, status, source, consented_at, evidence, created_by)
  values (p_contact_id, p_consent_type, public.consent_notice(p_consent_type) ->> 'purpose', nv, 'active', 'admin_recorded', now(),
          jsonb_build_object('recorded_by', e, 'method', 'admin_fallback'), e)
  returning * into row;
  insert into public.admin_audit (area, entity_id, action, changed_by, summary)
  values ('consent', p_contact_id::text, 'record_admin', e, jsonb_build_object('type', p_consent_type, 'notice_version', nv, 'consent_id', row.id));
  return to_jsonb(row);
end $$;
revoke execute on function public.consent_record_admin(uuid, text) from public, anon;
grant  execute on function public.consent_record_admin(uuid, text) to authenticated, service_role;

-- admin: withdraw (distinct from deletion; stops future collection)
create or replace function public.consent_withdraw(p_contact_id uuid, p_consent_type text default 'fitness_progress_tracking')
returns jsonb language plpgsql security definer set search_path = '' as $$
declare e text := public.current_email(); n int;
begin
  if not public.has_permission('health_metrics:manage') then raise exception 'forbidden' using errcode = '42501'; end if;
  update public.client_consents set status = 'withdrawn', withdrawn_at = now()
   where crm_contact_id = p_contact_id and consent_type = p_consent_type and status = 'active';
  get diagnostics n = row_count;
  insert into public.admin_audit (area, entity_id, action, changed_by, summary)
  values ('consent', p_contact_id::text, 'withdraw', e, jsonb_build_object('type', p_consent_type, 'withdrew', n));
  return jsonb_build_object('withdrawn', n);
end $$;
revoke execute on function public.consent_withdraw(uuid, text) from public, anon;
grant  execute on function public.consent_withdraw(uuid, text) to authenticated, service_role;

-- admin: current status + short history (health_metrics:view)
create or replace function public.consent_status(p_contact_id uuid, p_consent_type text default 'fitness_progress_tracking')
returns jsonb language plpgsql stable security definer set search_path = '' as $$
begin
  if not public.has_permission('health_metrics:view') then raise exception 'forbidden' using errcode = '42501'; end if;
  return jsonb_build_object(
    'active', public.has_active_consent(p_contact_id, p_consent_type),
    'is_minor', coalesce((select is_minor from public.crm_contacts where id = p_contact_id), false),
    'notice_version', public.consent_notice(p_consent_type) ->> 'notice_version',
    'history', coalesce((select jsonb_agg(jsonb_build_object('status', status, 'source', source, 'notice_version', notice_version,
                 'consented_at', consented_at, 'withdrawn_at', withdrawn_at, 'created_at', created_at) order by created_at desc)
               from public.client_consents where crm_contact_id = p_contact_id and consent_type = p_consent_type), '[]'::jsonb));
end $$;
revoke execute on function public.consent_status(uuid, text) from public, anon;
grant  execute on function public.consent_status(uuid, text) to authenticated, service_role;

-- client-link path (service role, called by the consent Edge Function). No CRM exposure beyond a first name.
create or replace function public.consent_view(p_token text)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare t public.consent_tokens%rowtype; fname text;
begin
  if p_token is null or p_token !~ '^[0-9a-f]{64}$' then raise exception 'invalid token' using errcode = 'P0002'; end if;
  select * into t from public.consent_tokens where token_hash = encode(extensions.digest(p_token,'sha256'),'hex');
  if not found then raise exception 'invalid token' using errcode = 'P0002'; end if;
  if t.used_at is not null then raise exception 'this link has already been used' using errcode = 'P0003'; end if;
  if t.expires_at < now() then raise exception 'this link has expired' using errcode = 'P0003'; end if;
  select split_part(coalesce(display_name,''), ' ', 1) into fname from public.crm_contacts where id = t.crm_contact_id;
  return jsonb_build_object('ok', true, 'first_name', nullif(fname,''), 'consent_type', t.consent_type, 'notice', public.consent_notice(t.consent_type));
end $$;
revoke execute on function public.consent_view(text) from public, anon, authenticated;
grant  execute on function public.consent_view(text) to service_role;

create or replace function public.consent_submit(p_token text, p_decision text, p_evidence jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare t public.consent_tokens%rowtype; row public.client_consents%rowtype;
begin
  if p_token is null or p_token !~ '^[0-9a-f]{64}$' then raise exception 'invalid token' using errcode = 'P0002'; end if;
  if p_decision not in ('accept','decline') then raise exception 'invalid decision' using errcode = '22023'; end if;
  select * into t from public.consent_tokens where token_hash = encode(extensions.digest(p_token,'sha256'),'hex') for update;
  if not found then raise exception 'invalid token' using errcode = 'P0002'; end if;
  if t.used_at is not null then raise exception 'this link has already been used' using errcode = 'P0003'; end if;
  if t.expires_at < now() then raise exception 'this link has expired' using errcode = 'P0003'; end if;
  if coalesce((select is_minor from public.crm_contacts where id = t.crm_contact_id), false) then raise exception 'not available' using errcode = 'P0005'; end if;
  update public.consent_tokens set used_at = now() where token_hash = t.token_hash;
  if p_decision = 'accept' then
    update public.client_consents set status = 'withdrawn', withdrawn_at = now()
     where crm_contact_id = t.crm_contact_id and consent_type = t.consent_type and status = 'active';
    insert into public.client_consents (crm_contact_id, consent_type, purpose, notice_version, status, source, consented_at, evidence)
    values (t.crm_contact_id, t.consent_type, public.consent_notice(t.consent_type) ->> 'purpose', t.notice_version, 'active', 'client_link', now(),
            coalesce(p_evidence,'{}'::jsonb) || jsonb_build_object('via','client_link'))
    returning * into row;
    insert into public.admin_audit (area, entity_id, action, changed_by, summary)
    values ('consent', t.crm_contact_id::text, 'client_accept', 'client', jsonb_build_object('type', t.consent_type, 'notice_version', t.notice_version, 'consent_id', row.id));
  else
    insert into public.client_consents (crm_contact_id, consent_type, notice_version, status, source, evidence)
    values (t.crm_contact_id, t.consent_type, t.notice_version, 'declined', 'client_link', jsonb_build_object('via','client_link'));
    insert into public.admin_audit (area, entity_id, action, changed_by, summary)
    values ('consent', t.crm_contact_id::text, 'client_decline', 'client', jsonb_build_object('type', t.consent_type));
  end if;
  return jsonb_build_object('ok', true, 'decision', p_decision);
end $$;
revoke execute on function public.consent_submit(text, text, jsonb) from public, anon, authenticated;
grant  execute on function public.consent_submit(text, text, jsonb) to service_role;

-- ---------- 5. metrics: consent + minor enforcement, export, deletion ----------
create or replace function public.metrics_add(
  p_contact_id uuid, p_measured_at date default current_date, p_weight numeric default null,
  p_body_fat numeric default null, p_muscle numeric default null, p_height numeric default null,
  p_source text default null, p_note text default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare e text := public.current_email(); snap numeric; row public.body_measurements%rowtype;
begin
  if not public.has_permission('health_metrics:manage') then raise exception 'forbidden' using errcode = '42501'; end if;
  if coalesce((select is_minor from public.crm_contacts where id = p_contact_id), false) then raise exception 'progress tracking is not available for minors' using errcode = 'P0005'; end if;
  if not public.has_active_consent(p_contact_id, 'fitness_progress_tracking') then raise exception 'no active progress-tracking consent for this client' using errcode = 'P0004'; end if;
  if p_weight is null and p_body_fat is null and p_muscle is null then raise exception 'record at least one of weight, body fat or muscle' using errcode = '22023'; end if;
  snap := coalesce(p_height, (select height_cm from public.crm_contacts where id = p_contact_id));
  insert into public.body_measurements (crm_contact_id, measured_at, height_cm_snapshot, weight_kg, body_fat_pct, muscle_pct, source, note, created_by)
  values (p_contact_id, coalesce(p_measured_at, current_date), snap, p_weight, p_body_fat, p_muscle, nullif(p_source,''), nullif(p_note,''), e)
  returning * into row;
  if p_height is not null and public.has_permission('client_profile:manage') then
    update public.crm_contacts set height_cm = p_height, updated_by = e where id = p_contact_id;
  end if;
  insert into public.admin_audit (area, entity_id, action, changed_by, summary)
  values ('body_measurement', row.id::text, 'create', e, jsonb_build_object('contact', p_contact_id));  -- id/action only, never the values
  return to_jsonb(row);
end $$;
revoke execute on function public.metrics_add(uuid, date, numeric, numeric, numeric, numeric, text, text) from public, anon;
grant  execute on function public.metrics_add(uuid, date, numeric, numeric, numeric, numeric, text, text) to authenticated, service_role;

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

-- deletion of progress history is DISTINCT from withdrawal (which only stops future collection)
create or replace function public.metrics_delete_history(p_contact_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare e text := public.current_email(); n int;
begin
  if not public.has_permission('health_metrics:manage') then raise exception 'forbidden' using errcode = '42501'; end if;
  delete from public.body_measurements where crm_contact_id = p_contact_id;  -- scoped strictly to this contact
  get diagnostics n = row_count;
  insert into public.admin_audit (area, entity_id, action, changed_by, summary)
  values ('body_measurement', p_contact_id::text, 'delete_history', e, jsonb_build_object('contact', p_contact_id, 'deleted', n));
  return jsonb_build_object('deleted', n);
end $$;
revoke execute on function public.metrics_delete_history(uuid) from public, anon;
grant  execute on function public.metrics_delete_history(uuid) to authenticated, service_role;

-- ---------- 6. needs_review filter + safe transactional merge ----------
drop function if exists public.crm_list_contacts(text);   -- retire the 1-arg form so calls are never ambiguous
create or replace function public.crm_list_contacts(p_search text default null, p_review_only boolean default false)
returns table (
  id uuid, display_name text, email text, phone text, city text, country text, status text,
  needs_review boolean, is_minor boolean, main_interest text, enquiry_count bigint, booking_count bigint,
  first_seen_at timestamptz, last_activity_at timestamptz)
language plpgsql stable security definer set search_path = '' as $$
begin
  if not public.has_permission('client_profile:view') then raise exception 'forbidden' using errcode = '42501'; end if;
  return query
    select c.id, c.display_name, c.email, c.phone, c.city, c.country, c.status, c.needs_review, c.is_minor,
           (select ct.interest from public.contacts ct where ct.crm_contact_id = c.id and ct.interest is not null order by ct.created_at desc limit 1),
           (select count(*) from public.contacts ct where ct.crm_contact_id = c.id),
           (select count(*) from public.bookings b where b.crm_contact_id = c.id),
           c.first_seen_at, c.last_activity_at
    from public.crm_contacts c
    where (not p_review_only or c.needs_review)
      and (p_search is null or btrim(p_search) = ''
           or c.display_name ilike '%' || p_search || '%' or c.email ilike '%' || p_search || '%'
           or c.phone ilike '%' || p_search || '%' or c.city ilike '%' || p_search || '%' or c.country ilike '%' || p_search || '%')
    order by c.last_activity_at desc
    limit 500;
end $$;
revoke execute on function public.crm_list_contacts(text, boolean) from public, anon;
grant  execute on function public.crm_list_contacts(text, boolean) to authenticated, service_role;

-- Manual, explicit, transactional merge: move every linked row from source to
-- target, resolve a duplicate active consent, then remove the source. Audited.
create or replace function public.crm_merge_contacts(p_source uuid, p_target uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare e text := public.current_email(); moved jsonb;
begin
  if not public.has_permission('client_profile:manage') then raise exception 'forbidden' using errcode = '42501'; end if;
  if p_source is null or p_target is null or p_source = p_target then raise exception 'choose two different contacts' using errcode = '22023'; end if;
  if not exists (select 1 from public.crm_contacts where id = p_source) or not exists (select 1 from public.crm_contacts where id = p_target)
    then raise exception 'contact not found' using errcode = 'P0002'; end if;
  -- if both have an active consent of the same type, withdraw the source's first (keeps the unique index happy, preserves provenance)
  update public.client_consents s set status = 'withdrawn', withdrawn_at = now(),
         evidence = evidence || jsonb_build_object('superseded_by_merge_into', p_target)
   where s.crm_contact_id = p_source and s.status = 'active'
     and exists (select 1 from public.client_consents t where t.crm_contact_id = p_target and t.consent_type = s.consent_type and t.status = 'active');
  update public.contacts          set crm_contact_id = p_target where crm_contact_id = p_source;
  update public.bookings          set crm_contact_id = p_target where crm_contact_id = p_source;
  update public.crm_notes         set crm_contact_id = p_target where crm_contact_id = p_source;
  update public.body_measurements set crm_contact_id = p_target where crm_contact_id = p_source;
  update public.client_consents   set crm_contact_id = p_target where crm_contact_id = p_source;
  update public.crm_contacts set needs_review = false,
         last_activity_at = greatest(last_activity_at, (select first_seen_at from public.crm_contacts where id = p_source))
   where id = p_target;
  delete from public.crm_contacts where id = p_source;
  moved := jsonb_build_object('source', p_source, 'target', p_target);
  insert into public.admin_audit (area, entity_id, action, changed_by, summary)
  values ('merge', p_target::text, 'merge', e, moved);
  return moved;
end $$;
revoke execute on function public.crm_merge_contacts(uuid, uuid) from public, anon;
grant  execute on function public.crm_merge_contacts(uuid, uuid) to authenticated, service_role;

-- =============================================================
-- CG-006 — launch access model + upload credential hardening
--
-- 1. platform:admin — a narrow permission for access administration
--    (list users, grant / revoke permissions). It never bypasses RLS on
--    business tables: business access still requires the explicit
--    coach:operations / finance:* / analytics:view permissions.
-- 2. Provisioning is operational data, done through set_app_access()
--    (service role / SQL editor) or the admin_* RPCs, and refuses an email
--    that has no auth.users identity — no fake records.
-- 3. Enquiry attachments: the client-generated submission_id is only an
--    idempotency key. Upload capability now needs a server-issued,
--    high-entropy, 30-minute token tied to exactly one enquiry.
-- 4. Strict MIME allowlist (no SVG, nothing executable) enforced in the
--    database, the bucket and the Edge Function.
-- =============================================================

-- ---------- 1. platform:admin ----------
alter table public.app_permissions drop constraint if exists app_permissions_permission_check;
alter table public.app_permissions add constraint app_permissions_permission_check
  check (permission in ('coach:operations','finance:view','finance:manage','analytics:view','platform:admin'));

-- access configuration is readable by its owner (own rows) and by platform:admin (all rows)
drop policy if exists app_users_self on public.app_users;
create policy app_users_self on public.app_users for select to authenticated
  using (email = public.current_email() or public.has_permission('platform:admin'));
drop policy if exists app_permissions_self on public.app_permissions;
create policy app_permissions_self on public.app_permissions for select to authenticated
  using (email = public.current_email() or public.has_permission('platform:admin'));

create or replace function public.auth_identity_exists(p_email text)
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (select 1 from auth.users where lower(email) = lower(trim(p_email)))
$$;
revoke execute on function public.auth_identity_exists(text) from public, anon, authenticated;

-- Idempotent provisioning for the owner (SQL editor / service role).
-- Refuses an email with no auth identity: invite the person first.
create or replace function public.set_app_access(p_email text, p_display_name text, p_party text, p_permissions text[])
returns jsonb language plpgsql security definer set search_path = '' as $$
declare e text := lower(trim(p_email)); p text;
begin
  if not public.auth_identity_exists(e) then
    raise exception 'no auth identity for %; invite the user in Supabase Auth first', e using errcode = 'P0002';
  end if;
  insert into public.app_users (email, display_name, party, active) values (e, p_display_name, p_party, true)
    on conflict (email) do update set display_name = excluded.display_name, party = excluded.party, active = true;
  delete from public.app_permissions where email = e and not (permission = any (p_permissions));
  foreach p in array p_permissions loop
    insert into public.app_permissions (email, permission) values (e, p) on conflict do nothing;
  end loop;
  return jsonb_build_object('email', e, 'permissions', (select coalesce(jsonb_agg(permission order by permission), '[]'::jsonb) from public.app_permissions where email = e));
end $$;
revoke execute on function public.set_app_access(text, text, text, text[]) from public, anon, authenticated;
grant  execute on function public.set_app_access(text, text, text, text[]) to service_role;

-- platform:admin RPCs — access administration only
create or replace function public.admin_list_access()
returns jsonb language plpgsql stable security definer set search_path = '' as $$
begin
  if not public.has_permission('platform:admin') then raise exception 'forbidden' using errcode = '42501'; end if;
  return (select coalesce(jsonb_agg(jsonb_build_object(
            'email', u.email, 'display_name', u.display_name, 'party', u.party, 'active', u.active,
            'auth_exists', public.auth_identity_exists(u.email),
            'permissions', (select coalesce(jsonb_agg(p.permission order by p.permission), '[]'::jsonb) from public.app_permissions p where p.email = u.email))
          order by u.email), '[]'::jsonb) from public.app_users u);
end $$;

create or replace function public.admin_set_user(p_email text, p_display_name text, p_party text, p_active boolean)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare e text := lower(trim(p_email));
begin
  if not public.has_permission('platform:admin') then raise exception 'forbidden' using errcode = '42501'; end if;
  if not public.auth_identity_exists(e) then raise exception 'no auth identity for this email; invite the user first' using errcode = 'P0002'; end if;
  if e = public.current_email() and not p_active then raise exception 'you cannot deactivate yourself' using errcode = 'P0003'; end if;
  insert into public.app_users (email, display_name, party, active) values (e, p_display_name, p_party, p_active)
    on conflict (email) do update set display_name = excluded.display_name, party = excluded.party, active = excluded.active;
  return jsonb_build_object('email', e, 'active', p_active);
end $$;

create or replace function public.admin_grant(p_email text, p_permission text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare e text := lower(trim(p_email));
begin
  if not public.has_permission('platform:admin') then raise exception 'forbidden' using errcode = '42501'; end if;
  if not exists (select 1 from public.app_users where email = e) then raise exception 'unknown application user' using errcode = 'P0002'; end if;
  insert into public.app_permissions (email, permission) values (e, p_permission) on conflict do nothing;
  return jsonb_build_object('email', e, 'permission', p_permission, 'granted', true);
end $$;

create or replace function public.admin_revoke(p_email text, p_permission text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare e text := lower(trim(p_email));
begin
  if not public.has_permission('platform:admin') then raise exception 'forbidden' using errcode = '42501'; end if;
  if e = public.current_email() and p_permission = 'platform:admin' then raise exception 'you cannot revoke your own platform:admin' using errcode = 'P0003'; end if;
  delete from public.app_permissions where email = e and permission = p_permission;
  return jsonb_build_object('email', e, 'permission', p_permission, 'granted', false);
end $$;

revoke execute on function public.admin_list_access(), public.admin_set_user(text, text, text, boolean),
                           public.admin_grant(text, text), public.admin_revoke(text, text) from public, anon;
grant  execute on function public.admin_list_access(), public.admin_set_user(text, text, text, boolean),
                           public.admin_grant(text, text), public.admin_revoke(text, text) to authenticated, service_role;

-- ---------- 3. server-issued upload credential ----------
alter table public.contacts add column if not exists upload_token_hash text;
alter table public.contacts add column if not exists upload_token_expires_at timestamptz;

create or replace function public.issue_upload_token(p_contact_id uuid)
returns text language plpgsql security definer set search_path = '' as $$
declare tok text;
begin
  tok := encode(extensions.gen_random_bytes(32), 'hex');           -- 256 bits, never stored in clear
  update public.contacts
     set upload_token_hash = encode(extensions.digest(tok, 'sha256'), 'hex'), upload_token_expires_at = now() + interval '30 minutes'
   where id = p_contact_id;
  if not found then raise exception 'enquiry not found' using errcode = 'P0002'; end if;
  return tok;
end $$;
revoke execute on function public.issue_upload_token(uuid) from public, anon, authenticated;
grant  execute on function public.issue_upload_token(uuid) to service_role;

-- ---------- 4. strict MIME allowlist ----------
create or replace function public.media_type_allowed(p text)
returns boolean language sql immutable set search_path = '' as $$
  select p = any (array['image/jpeg','image/png','image/webp','image/heic','image/heif','image/gif',
                        'video/mp4','video/quicktime','video/webm','video/x-m4v','video/3gpp'])
$$;
revoke execute on function public.media_type_allowed(text) from public, anon, authenticated;

alter table public.contact_media drop constraint if exists contact_media_content_type_check;
alter table public.contact_media add constraint contact_media_content_type_check check (public.media_type_allowed(content_type));

update storage.buckets
   set allowed_mime_types = array['image/jpeg','image/png','image/webp','image/heic','image/heif','image/gif',
                                  'video/mp4','video/quicktime','video/webm','video/x-m4v','video/3gpp'],
       file_size_limit = 52428800, public = false
 where id = 'enquiry-media';

-- reserve / confirm now take the upload token; the submission_id signatures are removed
drop function if exists public.reserve_contact_media(uuid, text, text, bigint);
drop function if exists public.confirm_contact_media(uuid, text, boolean);

create or replace function public.reserve_contact_media(p_upload_token text, p_original_name text, p_content_type text, p_size_bytes bigint)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare c record; n int; total bigint; ext text; path text; mid uuid;
begin
  if p_upload_token is null or p_upload_token !~ '^[0-9a-f]{64}$' then raise exception 'invalid upload token' using errcode = 'P0002'; end if;
  select id, upload_token_expires_at into c from public.contacts
   where upload_token_hash = encode(extensions.digest(p_upload_token, 'sha256'), 'hex');
  if not found then raise exception 'invalid upload token' using errcode = 'P0002'; end if;
  if c.upload_token_expires_at is null or c.upload_token_expires_at < now() then raise exception 'upload window closed' using errcode = 'P0003'; end if;
  if not public.media_type_allowed(p_content_type) then raise exception 'only photos and videos (jpeg, png, webp, heic, gif, mp4, mov, webm)' using errcode = '22023'; end if;
  if p_size_bytes is null or p_size_bytes <= 0 or p_size_bytes > 52428800 then raise exception 'file too large (50 MB max)' using errcode = '22023'; end if;
  perform pg_advisory_xact_lock(hashtext('contact_media:' || c.id::text));
  select count(*), coalesce(sum(size_bytes), 0) into n, total from public.contact_media where contact_id = c.id and status <> 'failed';
  if n >= 3 then raise exception 'three files maximum' using errcode = 'P0003'; end if;
  if total + p_size_bytes > 52428800 then raise exception '50 MB in total maximum' using errcode = 'P0003'; end if;
  ext := lower(nullif(regexp_replace(coalesce(p_original_name, ''), '^.*\.', ''), coalesce(p_original_name, '')));
  if ext is null or ext !~ '^[a-z0-9]{1,8}$' then ext := split_part(p_content_type, '/', 2); end if;
  mid := gen_random_uuid();
  path := 'contacts/' || c.id::text || '/' || mid::text || '.' || ext;
  insert into public.contact_media (id, contact_id, storage_path, original_name, content_type, size_bytes)
  values (mid, c.id, path, left(coalesce(p_original_name, 'file'), 200), p_content_type, p_size_bytes);
  return jsonb_build_object('media_id', mid, 'path', path, 'contact_id', c.id);
end $$;

create or replace function public.confirm_contact_media(p_upload_token text, p_path text, p_ok boolean)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare m record;
begin
  if p_upload_token is null or p_upload_token !~ '^[0-9a-f]{64}$' then raise exception 'invalid upload token' using errcode = 'P0002'; end if;
  select cm.* into m from public.contact_media cm join public.contacts c on c.id = cm.contact_id
   where c.upload_token_hash = encode(extensions.digest(p_upload_token, 'sha256'), 'hex') and cm.storage_path = p_path;
  if not found then raise exception 'file not found' using errcode = 'P0002'; end if;
  update public.contact_media set status = case when p_ok then 'uploaded' else 'failed' end, uploaded_at = case when p_ok then now() else null end where id = m.id;
  return jsonb_build_object('media_id', m.id, 'status', case when p_ok then 'uploaded' else 'failed' end);
end $$;

revoke execute on function public.reserve_contact_media(text, text, text, bigint), public.confirm_contact_media(text, text, boolean) from public, anon, authenticated;
grant  execute on function public.reserve_contact_media(text, text, text, bigint), public.confirm_contact_media(text, text, boolean) to service_role;

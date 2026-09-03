-- =============================================================
-- CG-004 — enquiry attachments (photos / videos)
-- Up to 3 files, 50 MB in total, per enquiry, for every category.
-- Private bucket; the browser never gets a bucket key — it asks the
-- public `upload` Edge Function for a signed upload URL, proving it
-- owns the enquiry with the submission_id it generated itself, within
-- 30 minutes of the enquiry. Only coach:operations can read the files
-- (People belong to Gari); finance and anon see nothing.
-- =============================================================

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('enquiry-media', 'enquiry-media', false, 52428800, array['image/*', 'video/*'])
on conflict (id) do update set public = false, file_size_limit = 52428800, allowed_mime_types = array['image/*', 'video/*'];

create table if not exists public.contact_media (
  id             uuid primary key default gen_random_uuid(),
  contact_id     uuid not null references public.contacts(id) on delete cascade,
  storage_path   text not null unique,
  original_name  text not null,
  content_type   text not null check (content_type ~ '^(image|video)/[a-z0-9.+-]+$'),
  size_bytes     bigint not null check (size_bytes > 0 and size_bytes <= 52428800),
  status         text not null default 'pending' check (status in ('pending', 'uploaded', 'failed')),
  created_at     timestamptz not null default now(),
  uploaded_at    timestamptz
);
create index if not exists contact_media_contact_idx on public.contact_media (contact_id);

alter table public.contact_media enable row level security;
revoke all on public.contact_media from anon, authenticated;
grant select on public.contact_media to authenticated;
drop policy if exists contact_media_coach_select on public.contact_media;
create policy contact_media_coach_select on public.contact_media for select to authenticated
  using (public.has_permission('coach:operations'));

-- storage objects: the coach may read (signed download URLs); nobody else
drop policy if exists enquiry_media_coach_read on storage.objects;
create policy enquiry_media_coach_read on storage.objects for select to authenticated
  using (bucket_id = 'enquiry-media' and public.has_permission('coach:operations'));

-- Reserve a slot for one file: ownership by submission_id, 30-minute window,
-- 3 files and 50 MB per enquiry. Returns the storage path to sign.
create or replace function public.reserve_contact_media(p_submission_id uuid, p_original_name text, p_content_type text, p_size_bytes bigint)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare c record; n int; total bigint; ext text; path text; mid uuid;
begin
  select id, created_at into c from public.contacts where submission_id = p_submission_id;
  if not found then raise exception 'enquiry not found' using errcode = 'P0002'; end if;
  if c.created_at < now() - interval '30 minutes' then raise exception 'upload window closed' using errcode = 'P0003'; end if;
  if p_content_type !~ '^(image|video)/[a-z0-9.+-]+$' then raise exception 'only photos and videos' using errcode = '22023'; end if;
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

-- Mark a reserved file as uploaded (called by the Edge Function after checking the object exists).
create or replace function public.confirm_contact_media(p_submission_id uuid, p_path text, p_ok boolean)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare m record;
begin
  select cm.* into m from public.contact_media cm join public.contacts c on c.id = cm.contact_id
   where c.submission_id = p_submission_id and cm.storage_path = p_path;
  if not found then raise exception 'file not found' using errcode = 'P0002'; end if;
  update public.contact_media set status = case when p_ok then 'uploaded' else 'failed' end, uploaded_at = case when p_ok then now() else null end where id = m.id;
  return jsonb_build_object('media_id', m.id, 'status', case when p_ok then 'uploaded' else 'failed' end);
end $$;

revoke execute on function public.reserve_contact_media(uuid, text, text, bigint), public.confirm_contact_media(uuid, text, boolean) from public, anon, authenticated;
grant  execute on function public.reserve_contact_media(uuid, text, text, bigint), public.confirm_contact_media(uuid, text, boolean) to service_role;

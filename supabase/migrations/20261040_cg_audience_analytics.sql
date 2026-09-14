-- =====================================================================
-- Coach Gari — Audience analytics (CG-018): website + social, one screen
--
-- The Analytics tab showed counts the Overview and Clients already show. The
-- owner wants it done properly: the website (Plausible), Instagram, TikTok,
-- YouTube — synced where an API exists, uploaded or typed where it does not.
--
--   web_daily          one row per day from Plausible (visitors, pageviews, visits,
--                      bounce, duration). Synced daily by the analytics-sync function.
--   social_snapshots   one row per platform per day: followers, views, likes …
--                      source = api (YouTube), csv (a platform export), manual.
--   analytics_config   one row: handles / channel id, the last Plausible sources
--                      and goals (30 d), sync timestamps.
--
-- Access: analytics:view reads; the new analytics:manage writes snapshots and
-- config (granted here to everyone who already holds analytics:view). The sync
-- function authenticates with a database-issued key held only in Vault (same
-- shape as the email and push drains) and is kicked by pg_cron once a day.
-- No name, no message, no PII anywhere in these tables — aggregates only.
-- =====================================================================

-- ---------- permission ----------
alter table public.app_permissions drop constraint if exists app_permissions_permission_check;
alter table public.app_permissions add constraint app_permissions_permission_check check (permission in (
  'coach:operations','finance:view','finance:manage','analytics:view','analytics:manage','platform:admin',
  'catalog:view','catalog:manage','client_profile:view','client_profile:manage',
  'health_metrics:view','health_metrics:manage','coaching_sensitive:view','coaching_sensitive:manage',
  'collab:view','collab:manage'));
insert into public.app_permissions (email, permission)
select email, 'analytics:manage' from public.app_permissions where permission = 'analytics:view'
on conflict do nothing;

alter table public.admin_audit drop constraint if exists admin_audit_area_check;
alter table public.admin_audit add constraint admin_audit_area_check check (area = any (array[
  'crm_contact','crm_note','body_measurement','permission','consent','merge','coaching_session',
  'session_pack','block','report','payment','payment_method','beau_ph_rail','beau_ph_fx',
  'settlement_destination','collaboration','email','commission','enquiry','analytics']));

-- ---------- tables ----------
create table if not exists public.web_daily (
  day            date primary key,
  visitors       int not null default 0,
  pageviews      int not null default 0,
  visits         int not null default 0,
  bounce_rate    numeric(5,2),
  visit_duration int,                       -- seconds
  synced_at      timestamptz not null default now()
);

create table if not exists public.social_snapshots (
  id             uuid primary key default gen_random_uuid(),
  platform       text not null check (platform in ('instagram','tiktok','youtube','facebook','linkedin','x','other')),
  snapshot_date  date not null,
  followers      int    check (followers is null or followers >= 0),
  views          bigint check (views is null or views >= 0),
  likes          bigint check (likes is null or likes >= 0),
  comments       bigint check (comments is null or comments >= 0),
  shares         bigint check (shares is null or shares >= 0),
  profile_views  bigint check (profile_views is null or profile_views >= 0),
  posts          int    check (posts is null or posts >= 0),
  source         text not null check (source in ('api','csv','manual')),
  note           text,
  created_by     text,
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now(),
  unique (platform, snapshot_date)
);
create index if not exists social_snapshots_platform_date_idx on public.social_snapshots (platform, snapshot_date desc);
create trigger social_snapshots_updated_at before update on public.social_snapshots for each row execute function public.set_updated_at();

create table if not exists public.analytics_config (
  id                 int primary key check (id = 1),
  plausible_site_id  text not null default 'coachgari28.com',
  youtube_channel_id text,
  instagram_handle   text,
  tiktok_handle      text,
  web_sources        jsonb not null default '[]'::jsonb,   -- [{source, visitors}] last 30 d
  web_goals          jsonb not null default '[]'::jsonb,   -- [{goal, visitors, events}] last 30 d
  web_synced_at      timestamptz,
  youtube_synced_at  timestamptz,
  last_sync_error    text,
  updated_at         timestamptz not null default now()
);
insert into public.analytics_config (id) values (1) on conflict (id) do nothing;

alter table public.web_daily enable row level security;
alter table public.social_snapshots enable row level security;
alter table public.analytics_config enable row level security;
revoke all on public.web_daily, public.social_snapshots, public.analytics_config from anon, authenticated;
grant select on public.web_daily, public.social_snapshots to authenticated;
grant select (id, plausible_site_id, youtube_channel_id, instagram_handle, tiktok_handle, web_sources, web_goals, web_synced_at, youtube_synced_at, last_sync_error, updated_at) on public.analytics_config to authenticated;
drop policy if exists web_daily_view on public.web_daily;
create policy web_daily_view on public.web_daily for select to authenticated using (public.has_permission('analytics:view'));
drop policy if exists social_snapshots_view on public.social_snapshots;
create policy social_snapshots_view on public.social_snapshots for select to authenticated using (public.has_permission('analytics:view'));
drop policy if exists analytics_config_view on public.analytics_config;
create policy analytics_config_view on public.analytics_config for select to authenticated using (public.has_permission('analytics:view'));

-- ---------- writes: the back-office (analytics:manage) ----------
-- One snapshot, upserted on (platform, date). Null metrics leave the existing value alone.
create or replace function public.audience_snapshot_upsert(p jsonb)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare e text := public.current_email(); r public.social_snapshots%rowtype;
  v_platform text := lower(coalesce(p ->> 'platform', '')); v_date date := nullif(p ->> 'date','')::date;
  v_source text := coalesce(nullif(p ->> 'source',''), 'manual');
begin
  if not public.has_permission('analytics:manage') then raise exception 'forbidden' using errcode = '42501'; end if;
  if v_platform not in ('instagram','tiktok','youtube','facebook','linkedin','x','other') then raise exception 'unknown platform' using errcode = '22023'; end if;
  if v_date is null or v_date > current_date then raise exception 'a date, today or earlier' using errcode = '22023'; end if;
  if v_source not in ('csv','manual') then v_source := 'manual'; end if;
  insert into public.social_snapshots (platform, snapshot_date, followers, views, likes, comments, shares, profile_views, posts, source, note, created_by)
  values (v_platform, v_date, nullif(p ->> 'followers','')::int, nullif(p ->> 'views','')::bigint, nullif(p ->> 'likes','')::bigint,
          nullif(p ->> 'comments','')::bigint, nullif(p ->> 'shares','')::bigint, nullif(p ->> 'profile_views','')::bigint, nullif(p ->> 'posts','')::int,
          v_source, nullif(left(btrim(coalesce(p ->> 'note','')), 200),''), e)
  on conflict (platform, snapshot_date) do update set
    followers = coalesce(excluded.followers, public.social_snapshots.followers),
    views = coalesce(excluded.views, public.social_snapshots.views),
    likes = coalesce(excluded.likes, public.social_snapshots.likes),
    comments = coalesce(excluded.comments, public.social_snapshots.comments),
    shares = coalesce(excluded.shares, public.social_snapshots.shares),
    profile_views = coalesce(excluded.profile_views, public.social_snapshots.profile_views),
    posts = coalesce(excluded.posts, public.social_snapshots.posts),
    source = excluded.source, note = coalesce(excluded.note, public.social_snapshots.note), created_by = e
  returning * into r;
  return jsonb_build_object('ok', true, 'id', r.id, 'platform', r.platform, 'date', r.snapshot_date);
end $$;
revoke all on function public.audience_snapshot_upsert(jsonb) from public, anon;
grant execute on function public.audience_snapshot_upsert(jsonb) to authenticated, service_role;

-- A platform export (CSV parsed in the browser): up to 400 rows in one call, all-or-nothing, one audit row.
create or replace function public.audience_snapshots_import(p_platform text, p_rows jsonb)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare e text := public.current_email(); n int := 0; row jsonb;
begin
  if not public.has_permission('analytics:manage') then raise exception 'forbidden' using errcode = '42501'; end if;
  if jsonb_typeof(p_rows) <> 'array' or jsonb_array_length(p_rows) = 0 then raise exception 'nothing to import' using errcode = '22023'; end if;
  if jsonb_array_length(p_rows) > 400 then raise exception 'too many rows (400 per import)' using errcode = '22023'; end if;
  for row in select * from jsonb_array_elements(p_rows) loop
    perform public.audience_snapshot_upsert(row || jsonb_build_object('platform', p_platform, 'source', 'csv'));
    n := n + 1;
  end loop;
  insert into public.admin_audit (area, entity_id, action, changed_by, summary)
  values ('analytics', p_platform, 'import', e, jsonb_build_object('rows', n));
  return jsonb_build_object('ok', true, 'imported', n);
end $$;
revoke all on function public.audience_snapshots_import(text, jsonb) from public, anon;
grant execute on function public.audience_snapshots_import(text, jsonb) to authenticated, service_role;

create or replace function public.audience_snapshot_delete(p_id uuid)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
begin
  if not public.has_permission('analytics:manage') then raise exception 'forbidden' using errcode = '42501'; end if;
  delete from public.social_snapshots where id = p_id;
  return jsonb_build_object('ok', true);
end $$;
revoke all on function public.audience_snapshot_delete(uuid) from public, anon;
grant execute on function public.audience_snapshot_delete(uuid) to authenticated, service_role;

create or replace function public.analytics_config_set(p jsonb)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare e text := public.current_email();
begin
  if not public.has_permission('analytics:manage') then raise exception 'forbidden' using errcode = '42501'; end if;
  update public.analytics_config set
    plausible_site_id  = coalesce(nullif(btrim(p ->> 'plausible_site_id'), ''), plausible_site_id),
    youtube_channel_id = case when p ? 'youtube_channel_id' then nullif(btrim(p ->> 'youtube_channel_id'), '') else youtube_channel_id end,
    instagram_handle   = case when p ? 'instagram_handle' then nullif(btrim(p ->> 'instagram_handle'), '') else instagram_handle end,
    tiktok_handle      = case when p ? 'tiktok_handle' then nullif(btrim(p ->> 'tiktok_handle'), '') else tiktok_handle end,
    updated_at = now()
  where id = 1;
  insert into public.admin_audit (area, entity_id, action, changed_by, summary) values ('analytics', 'config', 'update', e, p - 'web_sources' - 'web_goals');
  return jsonb_build_object('ok', true);
end $$;
revoke all on function public.analytics_config_set(jsonb) from public, anon;
grant execute on function public.analytics_config_set(jsonb) to authenticated, service_role;

-- ---------- writes: the sync function (service_role) ----------
create or replace function public.web_daily_upsert(p_rows jsonb, p_sources jsonb default null, p_goals jsonb default null)
returns int language plpgsql volatile security definer set search_path = '' as $$
declare n int := 0; r jsonb;
begin
  for r in select * from jsonb_array_elements(coalesce(p_rows, '[]'::jsonb)) loop
    insert into public.web_daily (day, visitors, pageviews, visits, bounce_rate, visit_duration, synced_at)
    values ((r ->> 'day')::date, coalesce((r ->> 'visitors')::int, 0), coalesce((r ->> 'pageviews')::int, 0), coalesce((r ->> 'visits')::int, 0),
            nullif(r ->> 'bounce_rate','')::numeric, nullif(r ->> 'visit_duration','')::int, now())
    on conflict (day) do update set visitors = excluded.visitors, pageviews = excluded.pageviews, visits = excluded.visits,
      bounce_rate = excluded.bounce_rate, visit_duration = excluded.visit_duration, synced_at = now();
    n := n + 1;
  end loop;
  update public.analytics_config set web_sources = coalesce(p_sources, web_sources), web_goals = coalesce(p_goals, web_goals),
         web_synced_at = now(), last_sync_error = null, updated_at = now() where id = 1;
  return n;
end $$;
revoke all on function public.web_daily_upsert(jsonb, jsonb, jsonb) from public, anon, authenticated;
grant execute on function public.web_daily_upsert(jsonb, jsonb, jsonb) to service_role;

create or replace function public.social_snapshot_api(p_platform text, p jsonb)
returns void language plpgsql volatile security definer set search_path = '' as $$
begin
  insert into public.social_snapshots (platform, snapshot_date, followers, views, likes, comments, shares, profile_views, posts, source, created_by)
  values (p_platform, current_date, nullif(p ->> 'followers','')::int, nullif(p ->> 'views','')::bigint, nullif(p ->> 'likes','')::bigint,
          nullif(p ->> 'comments','')::bigint, nullif(p ->> 'shares','')::bigint, nullif(p ->> 'profile_views','')::bigint, nullif(p ->> 'posts','')::int, 'api', 'analytics-sync')
  on conflict (platform, snapshot_date) do update set
    followers = coalesce(excluded.followers, public.social_snapshots.followers), views = coalesce(excluded.views, public.social_snapshots.views),
    likes = coalesce(excluded.likes, public.social_snapshots.likes), comments = coalesce(excluded.comments, public.social_snapshots.comments),
    shares = coalesce(excluded.shares, public.social_snapshots.shares), profile_views = coalesce(excluded.profile_views, public.social_snapshots.profile_views),
    posts = coalesce(excluded.posts, public.social_snapshots.posts), source = 'api', created_by = 'analytics-sync';
  if p_platform = 'youtube' then update public.analytics_config set youtube_synced_at = now(), updated_at = now() where id = 1; end if;
end $$;
revoke all on function public.social_snapshot_api(text, jsonb) from public, anon, authenticated;
grant execute on function public.social_snapshot_api(text, jsonb) to service_role;

create or replace function public.analytics_sync_error(p_error text)
returns void language sql volatile security definer set search_path = '' as $$
  update public.analytics_config set last_sync_error = left(p_error, 300), updated_at = now() where id = 1;
$$;
revoke all on function public.analytics_sync_error(text) from public, anon, authenticated;
grant execute on function public.analytics_sync_error(text) to service_role;

-- ---------- the read: everything the screen needs, in one call ----------
create or replace function public.audience_overview(p_days int default 30)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare n int := greatest(7, least(coalesce(p_days, 30), 365)); d0 date := current_date - n; d1 date := current_date - 2 * n; cfg public.analytics_config;
begin
  if not public.has_permission('analytics:view') then raise exception 'forbidden' using errcode = '42501'; end if;
  select * into cfg from public.analytics_config where id = 1;
  return jsonb_build_object(
    'days', n,
    'can_manage', public.has_permission('analytics:manage'),
    'config', jsonb_build_object('plausible_site_id', cfg.plausible_site_id, 'youtube_channel_id', cfg.youtube_channel_id,
                                 'instagram_handle', cfg.instagram_handle, 'tiktok_handle', cfg.tiktok_handle,
                                 'web_synced_at', cfg.web_synced_at, 'youtube_synced_at', cfg.youtube_synced_at, 'last_sync_error', cfg.last_sync_error),
    'web', jsonb_build_object(
      'series', (select coalesce(jsonb_agg(jsonb_build_object('day', w.day, 'visitors', w.visitors, 'pageviews', w.pageviews, 'visits', w.visits) order by w.day), '[]'::jsonb)
                   from public.web_daily w where w.day > d0),
      'visitors', (select coalesce(sum(visitors), 0) from public.web_daily where day > d0),
      'visitors_prev', (select coalesce(sum(visitors), 0) from public.web_daily where day > d1 and day <= d0),
      'pageviews', (select coalesce(sum(pageviews), 0) from public.web_daily where day > d0),
      'bounce_rate', (select round(avg(bounce_rate), 1) from public.web_daily where day > d0 and bounce_rate is not null),
      'sources', cfg.web_sources, 'goals', cfg.web_goals),
    'social', (select coalesce(jsonb_object_agg(pl.platform, jsonb_build_object(
        'latest', (select jsonb_build_object('date', s.snapshot_date, 'followers', s.followers, 'views', s.views, 'likes', s.likes, 'comments', s.comments,
                                             'shares', s.shares, 'profile_views', s.profile_views, 'posts', s.posts, 'source', s.source)
                     from public.social_snapshots s where s.platform = pl.platform order by s.snapshot_date desc limit 1),
        'followers_before', (select s.followers from public.social_snapshots s where s.platform = pl.platform and s.snapshot_date <= d0 and s.followers is not null order by s.snapshot_date desc limit 1),
        'views_period', (select sum(s.views) from public.social_snapshots s where s.platform = pl.platform and s.snapshot_date > d0 and s.source <> 'api'),
        'series', (select coalesce(jsonb_agg(jsonb_build_object('date', s.snapshot_date, 'followers', s.followers, 'views', s.views) order by s.snapshot_date), '[]'::jsonb)
                     from public.social_snapshots s where s.platform = pl.platform and s.snapshot_date > d0),
        'rows', (select count(*) from public.social_snapshots s where s.platform = pl.platform))), '{}'::jsonb)
      from (select distinct platform from public.social_snapshots) pl),
    'funnel', jsonb_build_object(
      'visitors', (select coalesce(sum(visitors), 0) from public.web_daily where day > d0),
      'enquiries', (select count(*) from public.contacts where created_at::date > d0 and status <> 'spam'),
      'collab_requests', (select count(*) from public.collaboration_deals where created_at::date > d0),
      'bookings', (select count(*) from public.bookings where created_at::date > d0 and status in ('confirmed','completed')),
      'clients', (select count(*) from public.crm_contacts where first_seen_at::date > d0 and status in ('active','past'))),
    'recent', (select coalesce(jsonb_agg(jsonb_build_object('id', s.id, 'platform', s.platform, 'date', s.snapshot_date, 'followers', s.followers, 'views', s.views,
                                                             'likes', s.likes, 'source', s.source, 'note', s.note) order by s.snapshot_date desc, s.platform), '[]'::jsonb)
                 from (select * from public.social_snapshots order by snapshot_date desc limit 40) s));
end $$;
revoke all on function public.audience_overview(int) from public, anon;
grant execute on function public.audience_overview(int) to authenticated, service_role;

-- ---------- the sync key (Vault), its check, the daily kick, and a manual kick ----------
do $$
declare k text;
begin
  if not exists (select 1 from vault.decrypted_secrets where name = 'outbox_analytics_key') then
    k := encode(extensions.gen_random_bytes(32), 'hex');
    perform vault.create_secret(k, 'outbox_analytics_key', 'Analytics sync key (clear; only its SHA-256 hash is stored in public.outbox_keys)');
    insert into public.outbox_keys (name, key_sha256) values ('analytics', extensions.digest(k, 'sha256'))
      on conflict (name) do update set key_sha256 = excluded.key_sha256;
  end if;
end $$;

create or replace function public.analytics_sync_authorize(p_key text)
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.outbox_keys k where k.name = 'analytics' and length(coalesce(p_key, '')) = 64
                   and public.ct_bytea_eq(k.key_sha256, extensions.digest(p_key, 'sha256')))
$$;
revoke execute on function public.analytics_sync_authorize(text) from public, anon, authenticated;
grant  execute on function public.analytics_sync_authorize(text) to service_role;

create or replace function public.analytics_sync_kick()
returns bigint language plpgsql volatile security definer set search_path = '' as $$
declare k text; rid bigint;
begin
  select decrypted_secret into k from vault.decrypted_secrets where name = 'outbox_analytics_key' limit 1;
  if k is null then return null; end if;
  select net.http_post(url := 'https://acrjrlgeeyseyolmofuq.supabase.co/functions/v1/analytics-sync',
                       headers := jsonb_build_object('Content-Type', 'application/json', 'x-outbox-key', k),
                       body := '{"action":"sync"}'::jsonb, timeout_milliseconds := 30000) into rid;
  return rid;
end $$;
revoke execute on function public.analytics_sync_kick() from public, anon, authenticated;
grant  execute on function public.analytics_sync_kick() to service_role;

-- "Sync now" from the back-office: analytics:manage may ask for a run; the key never leaves the database.
create or replace function public.analytics_sync_now()
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare rid bigint;
begin
  if not public.has_permission('analytics:manage') then raise exception 'forbidden' using errcode = '42501'; end if;
  rid := public.analytics_sync_kick();
  return jsonb_build_object('ok', rid is not null, 'request_id', rid);
end $$;
revoke all on function public.analytics_sync_now() from public, anon;
grant execute on function public.analytics_sync_now() to authenticated, service_role;

do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') and exists (select 1 from pg_extension where extname = 'pg_net') then
    perform cron.unschedule(jobid) from cron.job where jobname = 'cg-analytics-sync';
    perform cron.schedule('cg-analytics-sync', '30 5 * * *', $cron$select public.analytics_sync_kick()$cron$);
  end if;
end $$;

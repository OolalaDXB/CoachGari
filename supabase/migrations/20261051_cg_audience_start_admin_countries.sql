-- =====================================================================
-- Audience: the numbers start when the site went live, count clients only,
-- and say where people are
--
-- THREE CORRECTIONS, ALL THE SAME KIND: the website figures were counting
-- things that are not the audience.
--
-- 1. THE HISTORY STARTS ON 15 SEPTEMBER. Everything before it is the build:
--    the owner's own visits, the checks before launch, the test payment. Left
--    in, it inflates the first month by roughly its own size and there is no
--    way to tell later which visit was a client and which was us. The start
--    date is configuration, not a constant, because "when did this site go
--    live" is a fact about this project and the next host will have another.
--
-- 2. THE BACK-OFFICE IS NOT TRAFFIC. /admin is Gari at work. Counting his
--    working day as audience is the most flattering and least useful mistake a
--    dashboard can make: the number goes up exactly when nobody new arrived.
--    Excluded in the query, not after the fact, so it never lands in the table.
--
-- 3. WHERE PEOPLE ARE. The whole commercial question — what to price in what
--    currency, which rails to open — is a question about countries, and the
--    answer was not being stored at all.
--
-- Plausible's own record is untouched; this only changes what we ask it for.
-- =====================================================================

-- ---------- 1. configuration, not constants ----------
alter table public.analytics_config add column if not exists web_start_date date;
alter table public.analytics_config add column if not exists web_countries jsonb not null default '[]'::jsonb;
alter table public.analytics_config add column if not exists web_exclude_paths text[] not null default array['/admin'];

comment on column public.analytics_config.web_start_date is
  'The first day worth counting — the day the site went live. Days before it are the build, not the audience.';
comment on column public.analytics_config.web_countries is
  '[{country, visitors}] for the period, as reported by Plausible. Country only, never a city or an address.';
comment on column public.analytics_config.web_exclude_paths is
  'Page prefixes that are work, not audience. Applied in the Plausible query, so excluded traffic never reaches web_daily.';

update public.analytics_config
   set web_start_date = coalesce(web_start_date, date '2026-09-15'),
       web_exclude_paths = case when web_exclude_paths = '{}' then array['/admin'] else web_exclude_paths end
 where id = 1;

/* The days already collected before the start date were the build. They are
   deleted rather than hidden: a row nobody may count is a row that will be
   counted by the next person who writes a query. */
delete from public.web_daily w
 where w.day < (select coalesce(c.web_start_date, date '2026-09-15') from public.analytics_config c where c.id = 1);

-- ---------- 2. the sync writes countries too ----------
create or replace function public.web_daily_upsert(p_rows jsonb, p_sources jsonb default null, p_goals jsonb default null,
                                                   p_countries jsonb default null)
returns int language plpgsql volatile security definer set search_path = '' as $$
declare n int := 0; r jsonb; v_start date;
begin
  select coalesce(web_start_date, date '2026-09-15') into v_start from public.analytics_config where id = 1;
  for r in select * from jsonb_array_elements(coalesce(p_rows, '[]'::jsonb)) loop
    /* The guard is here as well as in the query. The sync asks for the right
       window, but this function is the only door into the table, and a table
       that enforces its own rule cannot be got round by a future caller that
       forgets. */
    continue when (r ->> 'day')::date < v_start;
    insert into public.web_daily (day, visitors, pageviews, visits, bounce_rate, visit_duration, synced_at)
    values ((r ->> 'day')::date, coalesce((r ->> 'visitors')::int, 0), coalesce((r ->> 'pageviews')::int, 0), coalesce((r ->> 'visits')::int, 0),
            nullif(r ->> 'bounce_rate','')::numeric, nullif(r ->> 'visit_duration','')::int, now())
    on conflict (day) do update set visitors = excluded.visitors, pageviews = excluded.pageviews, visits = excluded.visits,
      bounce_rate = excluded.bounce_rate, visit_duration = excluded.visit_duration, synced_at = now();
    n := n + 1;
  end loop;
  update public.analytics_config set web_sources = coalesce(p_sources, web_sources), web_goals = coalesce(p_goals, web_goals),
         web_countries = coalesce(p_countries, web_countries),
         web_synced_at = now(), last_sync_error = null, updated_at = now() where id = 1;
  return n;
end $$;
revoke all on function public.web_daily_upsert(jsonb, jsonb, jsonb, jsonb) from public, anon, authenticated;
grant execute on function public.web_daily_upsert(jsonb, jsonb, jsonb, jsonb) to service_role;

/* The three-argument signature is dropped, not left beside the new one: two
   overloads differing only by a trailing default is how a caller ends up
   silently writing to the old one for a year. */
drop function if exists public.web_daily_upsert(jsonb, jsonb, jsonb);

-- ---------- 3. what the sync needs to know before it asks ----------
create or replace function public.analytics_sync_config()
returns jsonb language sql stable security definer set search_path = '' as $$
  select jsonb_build_object(
    'site_id', c.plausible_site_id,
    'start_date', coalesce(c.web_start_date, date '2026-09-15'),
    'exclude_paths', to_jsonb(c.web_exclude_paths),
    'youtube_channel_id', c.youtube_channel_id)
  from public.analytics_config c where c.id = 1;
$$;
revoke execute on function public.analytics_sync_config() from public, anon, authenticated;
grant  execute on function public.analytics_sync_config() to service_role;

-- ---------- 4. the operator can move the start date and the exclusions ----------
create or replace function public.analytics_web_config_set(p jsonb)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare e text := public.current_email(); v_start date; v_paths text[]; p_el text;
begin
  if not public.has_permission('analytics:manage') then raise exception 'forbidden' using errcode = '42501'; end if;

  if p ? 'web_start_date' then
    v_start := nullif(p ->> 'web_start_date', '')::date;
    if v_start is null then raise exception 'a start date is required' using errcode = '22023'; end if;
    if v_start > current_date then raise exception 'the site cannot have gone live in the future' using errcode = '22023'; end if;
  end if;

  if p ? 'web_exclude_paths' then
    select coalesce(array_agg(x), '{}') into v_paths
      from (select btrim(value) as x from jsonb_array_elements_text(p -> 'web_exclude_paths')
             where btrim(value) <> '') s;
    foreach p_el in array coalesce(v_paths, '{}') loop
      if left(p_el, 1) <> '/' then raise exception 'an excluded path must start with / (got %)', p_el using errcode = '22023'; end if;
    end loop;
  end if;

  update public.analytics_config
     set web_start_date = coalesce(v_start, web_start_date),
         web_exclude_paths = coalesce(v_paths, web_exclude_paths),
         updated_at = now()
   where id = 1;

  /* Moving the start date forward makes the days behind it uncountable, so they
     go, here and not on the next sync — a chart must never disagree with the
     rule that produced it. */
  delete from public.web_daily w
   where w.day < (select coalesce(c.web_start_date, date '2026-09-15') from public.analytics_config c where c.id = 1);

  insert into public.admin_audit (area, entity_id, action, changed_by, summary)
  values ('analytics', 'web', 'config', e, jsonb_strip_nulls(jsonb_build_object('start_date', v_start, 'exclude_paths', to_jsonb(v_paths))));

  return (select jsonb_build_object('web_start_date', web_start_date, 'web_exclude_paths', to_jsonb(web_exclude_paths))
            from public.analytics_config where id = 1);
end $$;
revoke execute on function public.analytics_web_config_set(jsonb) from public, anon;
grant  execute on function public.analytics_web_config_set(jsonb) to authenticated, service_role;

-- ---------- 5. the screen reads countries with everything else ----------
grant select (id, plausible_site_id, youtube_channel_id, instagram_handle, tiktok_handle,
              web_sources, web_goals, web_countries, web_start_date, web_exclude_paths,
              web_synced_at, youtube_synced_at, last_sync_error, updated_at)
  on public.analytics_config to authenticated;

-- ---------- 6. the overview carries countries, the start date, and the exclusions ----------
/* Only the config block and the web block change; everything else is the
   function as it was. It is re-issued whole because a plpgsql body cannot be
   patched in place, not because the rest was wrong. */
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
                                 'web_start_date', cfg.web_start_date, 'web_exclude_paths', to_jsonb(cfg.web_exclude_paths),
                                 'web_synced_at', cfg.web_synced_at, 'youtube_synced_at', cfg.youtube_synced_at, 'last_sync_error', cfg.last_sync_error),
    'web', jsonb_build_object(
      'series', (select coalesce(jsonb_agg(jsonb_build_object('day', w.day, 'visitors', w.visitors, 'pageviews', w.pageviews, 'visits', w.visits) order by w.day), '[]'::jsonb)
                   from public.web_daily w where w.day > d0),
      'visitors', (select coalesce(sum(visitors), 0) from public.web_daily where day > d0),
      'visitors_prev', (select coalesce(sum(visitors), 0) from public.web_daily where day > d1 and day <= d0),
      'pageviews', (select coalesce(sum(pageviews), 0) from public.web_daily where day > d0),
      'bounce_rate', (select round(avg(bounce_rate), 1) from public.web_daily where day > d0 and bounce_rate is not null),
      /* The comparison period is only honest once there IS one. Before the site
         has been live for two full periods, "visitors_prev" compares against
         days that did not exist, and a chart that shows +100 % because the
         previous month is empty is worse than a chart that shows nothing. */
      'has_previous', (cfg.web_start_date is not null and cfg.web_start_date <= d1),
      'sources', cfg.web_sources, 'goals', cfg.web_goals, 'countries', cfg.web_countries),
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

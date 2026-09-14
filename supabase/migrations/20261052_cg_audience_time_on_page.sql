-- =====================================================================
-- Audience: time on page replaces bounce rate, because this site is one page
--
-- Plausible counts a bounce as a session with a single pageview. The public
-- site is ONE page — index.html with thirteen anchors — so a visitor who lands,
-- reads everything, scrolls through the prices and sends an enquiry records
-- exactly one pageview, and counts as a bounce. The figure therefore sits near
-- 100 % whatever anyone does, and it will still sit there when the site works
-- perfectly. It is not a small sample problem that volume will fix: it is the
-- wrong instrument for this shape of site.
--
-- What does measure engagement on a one-pager is how long people stay.
-- visit_duration has been collected since the first sync and never shown.
--
-- Averaged across days WEIGHTED BY VISITS, not a mean of daily means: a day
-- with two visits must not count as much as a day with two hundred.
-- =====================================================================
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
      -- seconds, weighted by the visits of each day; null rather than 0 when nothing was measured
      'visit_duration', (select case when sum(visits) filter (where visit_duration is not null) > 0
                                     then round(sum(visit_duration::numeric * visits) filter (where visit_duration is not null)
                                                / sum(visits) filter (where visit_duration is not null))
                                end
                           from public.web_daily where day > d0),
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

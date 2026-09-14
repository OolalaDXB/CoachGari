-- =====================================================================
-- CG-018 — Audience analytics (website + social, sync, import, RLS)
-- One rolled-back transaction. Proves: the read is gated on analytics:view and
-- the writes on analytics:manage; a snapshot is one row per platform per day and
-- an update never wipes what it does not carry; an import is all-or-nothing and
-- audited; the sync RPCs belong to service_role alone; anon reaches nothing; and
-- the overview counts the period, the platforms and the funnel correctly.
-- Run by scripts/db-tests.sh; nothing persists (final RAISE).
-- =====================================================================
do $$
declare
  ok int := 0; fail int := 0; log text := '';
  j jsonb; n int; q text; sid uuid;
begin
  insert into public.app_users (email, display_name, party) values
    ('anmanage@test.local','Manager','studio'), ('anview@test.local','Viewer','studio'), ('anno@test.local','Nobody','gari')
  on conflict (email) do nothing;
  insert into public.app_permissions (email, permission) values
    ('anmanage@test.local','analytics:view'), ('anmanage@test.local','analytics:manage'),
    ('anview@test.local','analytics:view'), ('anno@test.local','coach:operations')
  on conflict do nothing;

  /* The counting window is configuration, and this suite writes days around
     today, so it sets a start date well behind them. Section 9 tests the window
     itself. */
  update public.analytics_config set web_start_date = current_date - 400 where id = 1;

  /* ---- 1. the website series is written by the sync path only, and read back per period ---- */
  perform public.web_daily_upsert(jsonb_build_array(
    jsonb_build_object('day', (current_date - 1)::text, 'visitors', 100, 'pageviews', 250, 'visits', 120, 'bounce_rate', 40.0),
    jsonb_build_object('day', (current_date - 2)::text, 'visitors', 80,  'pageviews', 200, 'visits', 90,  'bounce_rate', 50.0),
    jsonb_build_object('day', (current_date - 40)::text,'visitors', 999, 'pageviews', 999, 'visits', 999, 'bounce_rate', 90.0)),
    jsonb_build_array(jsonb_build_object('source','Instagram','visitors',640)),
    jsonb_build_array(jsonb_build_object('goal','booking_started','visitors',38,'events',51)));
  if (select visitors from public.web_daily where day = current_date - 1) = 100
     and (select web_synced_at is not null from public.analytics_config where id = 1)
    then ok := ok + 1; else fail := fail + 1; log := log || ' [web-upsert]'; end if;
  -- the same day again replaces, never duplicates (the sync re-reads the last 60 days daily)
  perform public.web_daily_upsert(jsonb_build_array(jsonb_build_object('day', (current_date - 1)::text, 'visitors', 111, 'pageviews', 260, 'visits', 130)));
  select count(*) into n from public.web_daily where day = current_date - 1;
  if n = 1 and (select visitors from public.web_daily where day = current_date - 1) = 111 then ok := ok + 1; else fail := fail + 1; log := log || ' [web-upsert-not-idempotent]'; end if;

  /* ---- 2. a snapshot: one row per platform per day, a blank field never wipes a stored one ---- */
  perform set_config('request.jwt.claims', '{"role":"authenticated","sub":"00000000-0000-4000-8000-0000000000a1","email":"anmanage@test.local"}', true);
  execute 'set local role authenticated';
  j := public.audience_snapshot_upsert(jsonb_build_object('platform','instagram','date',(current_date - 1)::text,'followers',17600,'views',51000,'likes',3600));
  sid := (j ->> 'id')::uuid;
  if (j ->> 'ok') = 'true' and (select followers from public.social_snapshots where id = sid) = 17600 then ok := ok + 1; else fail := fail + 1; log := log || ' [snapshot-insert]'; end if;
  -- the same day again with followers only: views and likes must survive
  perform public.audience_snapshot_upsert(jsonb_build_object('platform','instagram','date',(current_date - 1)::text,'followers',17700));
  select count(*) into n from public.social_snapshots where platform = 'instagram' and snapshot_date = current_date - 1;
  if n = 1 and (select followers from public.social_snapshots where id = sid) = 17700
     and (select views from public.social_snapshots where id = sid) = 51000
     and (select likes from public.social_snapshots where id = sid) = 3600
    then ok := ok + 1; else fail := fail + 1; log := log || ' [snapshot-update-wiped-a-value]'; end if;
  -- a platform nobody knows, and a date in the future, are refused
  begin perform public.audience_snapshot_upsert(jsonb_build_object('platform','myspace','date',current_date::text,'followers',1)); fail := fail + 1; log := log || ' [unknown-platform-accepted]'; exception when sqlstate '22023' then ok := ok + 1; end;
  begin perform public.audience_snapshot_upsert(jsonb_build_object('platform','tiktok','date',(current_date + 1)::text,'followers',1)); fail := fail + 1; log := log || ' [future-date-accepted]'; exception when sqlstate '22023' then ok := ok + 1; end;
  begin perform public.audience_snapshot_upsert(jsonb_build_object('platform','tiktok','date',(current_date)::text,'followers',-5)); fail := fail + 1; log := log || ' [negative-count-accepted]'; exception when check_violation then ok := ok + 1; end;

  /* ---- 3. an import: every row or none, audited by count, never by content ---- */
  j := public.audience_snapshots_import('tiktok', jsonb_build_array(
    jsonb_build_object('date',(current_date - 3)::text,'followers',7800),
    jsonb_build_object('date',(current_date - 2)::text,'followers',8600),
    jsonb_build_object('date',(current_date - 1)::text,'followers',9240,'views',512000)));
  select count(*) into n from public.social_snapshots where platform = 'tiktok';
  if (j ->> 'imported') = '3' and n = 3
     and (select source from public.social_snapshots where platform = 'tiktok' and snapshot_date = current_date - 1) = 'csv'
    then ok := ok + 1; else fail := fail + 1; log := log || ' [import]'; end if;
  -- one bad row rolls the whole import back (the function raises; the caller's statement is undone)
  begin
    perform public.audience_snapshots_import('tiktok', jsonb_build_array(
      jsonb_build_object('date',(current_date - 5)::text,'followers',100),
      jsonb_build_object('date',(current_date + 9)::text,'followers',200)));
    fail := fail + 1; log := log || ' [bad-row-imported]';
  exception when sqlstate '22023' then
    select count(*) into n from public.social_snapshots where platform = 'tiktok' and snapshot_date = current_date - 5;
    if n = 0 then ok := ok + 1; else fail := fail + 1; log := log || ' [import-not-atomic]'; end if;
  end;
  begin perform public.audience_snapshots_import('tiktok', '[]'::jsonb); fail := fail + 1; log := log || ' [empty-import-accepted]'; exception when sqlstate '22023' then ok := ok + 1; end;
  begin perform public.audience_snapshots_import('tiktok', (select jsonb_agg(jsonb_build_object('date','2026-01-01','followers',i)) from generate_series(1, 401) i));
    fail := fail + 1; log := log || ' [401-rows-accepted]'; exception when sqlstate '22023' then ok := ok + 1; end;

  /* the audit row is checked as the owner: admin_audit is RLS-gated, the operator who
     wrote it cannot read it back — which is the point of an audit trail */
  execute 'reset role';
  if exists (select 1 from public.admin_audit where area = 'analytics' and entity_id = 'tiktok' and action = 'import'
               and changed_by = 'anmanage@test.local' and (summary ->> 'rows') = '3' and not (summary ? 'followers'))
    then ok := ok + 1; else fail := fail + 1; log := log || ' [import-audit]'; end if;
  perform set_config('request.jwt.claims', '{"role":"authenticated","sub":"00000000-0000-4000-8000-0000000000a1","email":"anmanage@test.local"}', true);
  execute 'set local role authenticated';

  /* ---- 4. the overview: the period, the platforms, the funnel, the permission flag ---- */
  j := public.audience_overview(30);
  if (j -> 'web' ->> 'visitors')::int = 191                                  -- 111 + 80; the 40-day-old row is outside the period
     and (j -> 'web' -> 'sources' -> 0 ->> 'source') = 'Instagram'
     and (j -> 'social' -> 'instagram' -> 'latest' ->> 'followers') = '17700'
     and (j -> 'social' -> 'tiktok' -> 'latest' ->> 'followers') = '9240'
     and (j ->> 'can_manage') = 'true'
    then ok := ok + 1; else fail := fail + 1; log := log || ' [overview ' || left(j::text, 300) || ']'; end if;
  if (j -> 'funnel' ->> 'visitors')::int = 191 and (j -> 'funnel' ? 'enquiries') and (j -> 'funnel' ? 'clients')
    then ok := ok + 1; else fail := fail + 1; log := log || ' [funnel]'; end if;
  -- a longer window reaches the older row, a shorter one does not
  if (public.audience_overview(60) -> 'web' ->> 'visitors')::int = 1190
     and (public.audience_overview(7) -> 'web' ->> 'visitors')::int = 191
    then ok := ok + 1; else fail := fail + 1; log := log || ' [period-window]'; end if;
  -- the config is returned, and it never carries a key or a secret
  if (j -> 'config' ->> 'plausible_site_id') is not null and j::text !~* 'api_key|secret|token|password'
    then ok := ok + 1; else fail := fail + 1; log := log || ' [config-leaks]'; end if;
  execute 'reset role';

  /* ---- 5. analytics:view reads but writes nothing ---- */
  perform set_config('request.jwt.claims', '{"role":"authenticated","sub":"00000000-0000-4000-8000-0000000000a2","email":"anview@test.local"}', true);
  execute 'set local role authenticated';
  j := public.audience_overview(30);
  if (j ->> 'can_manage') = 'false' and (j -> 'web' ->> 'visitors')::int = 191 then ok := ok + 1; else fail := fail + 1; log := log || ' [viewer-read]'; end if;
  begin perform public.audience_snapshot_upsert(jsonb_build_object('platform','instagram','date',current_date::text,'followers',1)); fail := fail + 1; log := log || ' [viewer-wrote-a-snapshot]'; exception when sqlstate '42501' then ok := ok + 1; end;
  begin perform public.audience_snapshots_import('instagram', jsonb_build_array(jsonb_build_object('date',current_date::text,'followers',1))); fail := fail + 1; log := log || ' [viewer-imported]'; exception when sqlstate '42501' then ok := ok + 1; end;
  begin perform public.audience_snapshot_delete(sid); fail := fail + 1; log := log || ' [viewer-deleted]'; exception when sqlstate '42501' then ok := ok + 1; end;
  begin perform public.analytics_config_set(jsonb_build_object('tiktok_handle','@x')); fail := fail + 1; log := log || ' [viewer-set-config]'; exception when sqlstate '42501' then ok := ok + 1; end;
  begin perform public.analytics_sync_now(); fail := fail + 1; log := log || ' [viewer-asked-a-sync]'; exception when sqlstate '42501' then ok := ok + 1; end;
  execute 'reset role';

  /* ---- 6. a signed-in operator without analytics:view sees nothing at all (RLS + RPC) ---- */
  perform set_config('request.jwt.claims', '{"role":"authenticated","sub":"00000000-0000-4000-8000-0000000000a3","email":"anno@test.local"}', true);
  execute 'set local role authenticated';
  select count(*) into n from public.web_daily;        if n = 0 then ok := ok + 1; else fail := fail + 1; log := log || ' [rls-leaks-web]'; end if;
  select count(*) into n from public.social_snapshots; if n = 0 then ok := ok + 1; else fail := fail + 1; log := log || ' [rls-leaks-social]'; end if;
  select count(*) into n from public.analytics_config; if n = 0 then ok := ok + 1; else fail := fail + 1; log := log || ' [rls-leaks-config]'; end if;
  begin perform public.audience_overview(30); fail := fail + 1; log := log || ' [no-perm-read]'; exception when sqlstate '42501' then ok := ok + 1; end;
  execute 'reset role';

  /* ---- 7. the sync path belongs to service_role; anon reaches nothing ---- */
  if not has_function_privilege('authenticated', 'public.web_daily_upsert(jsonb, jsonb, jsonb, jsonb)', 'execute')
     and not has_function_privilege('authenticated', 'public.social_snapshot_api(text, jsonb)', 'execute')
     and not has_function_privilege('authenticated', 'public.analytics_sync_kick()', 'execute')
     and not has_function_privilege('authenticated', 'public.analytics_sync_authorize(text)', 'execute')
    then ok := ok + 1; else fail := fail + 1; log := log || ' [sync-rpcs-exposed-to-operators]'; end if;
  execute 'set local role anon';
  foreach q in array array['select count(*) from public.web_daily', 'select count(*) from public.social_snapshots', 'select count(*) from public.analytics_config',
                           'select public.audience_overview(30)', 'select public.audience_snapshot_upsert(''{}''::jsonb)', 'select public.analytics_sync_now()'] loop
    begin execute q; fail := fail + 1; log := log || ' [anon allowed: ' || q || ']'; exception when insufficient_privilege then ok := ok + 1; end;
  end loop;
  execute 'reset role';

  /* ---- 8. the drain key is hashed, never stored in the clear ---- */
  if exists (select 1 from public.outbox_keys where name = 'analytics' and key_sha256 is not null)
     and public.analytics_sync_authorize(repeat('a', 64)) = false
    then ok := ok + 1; else fail := fail + 1; log := log || ' [analytics-key]'; end if;

  /* ---- 9. delete removes exactly one snapshot, and the API source is marked as such ---- */
  perform public.social_snapshot_api('youtube', jsonb_build_object('followers', 2130, 'views', 98000, 'posts', 41));
  if (select source from public.social_snapshots where platform = 'youtube' and snapshot_date = current_date) = 'api'
     and (select youtube_synced_at is not null from public.analytics_config where id = 1)
    then ok := ok + 1; else fail := fail + 1; log := log || ' [youtube-api-snapshot]'; end if;
  perform set_config('request.jwt.claims', '{"role":"authenticated","sub":"00000000-0000-4000-8000-0000000000a1","email":"anmanage@test.local"}', true);
  execute 'set local role authenticated';
  perform public.audience_snapshot_delete(sid);
  if not exists (select 1 from public.social_snapshots where id = sid)
     and exists (select 1 from public.social_snapshots where platform = 'tiktok') then ok := ok + 1; else fail := fail + 1; log := log || ' [delete]'; end if;
  execute 'reset role';

  /* ---- 9. what counts as audience: the start date, the exclusions, the countries ---- */
  --    a day before the start date is refused by the table, not merely hidden by a query
  update public.analytics_config set web_start_date = current_date - 5 where id = 1;
  n := public.web_daily_upsert(jsonb_build_array(
         jsonb_build_object('day', (current_date - 30)::text, 'visitors', 999, 'pageviews', 999, 'visits', 999),
         jsonb_build_object('day', (current_date - 2)::text,  'visitors', 7,   'pageviews', 9,   'visits', 8)));
  if n = 1 and not exists (select 1 from public.web_daily where day = current_date - 30)
     and exists (select 1 from public.web_daily where day = current_date - 2)
    then ok := ok + 1; else fail := fail + 1; log := log || ' [start-date-not-enforced ' || n || ']'; end if;

  --    countries are stored and read back, and only through the sync path
  perform public.web_daily_upsert('[]'::jsonb, null, null,
    jsonb_build_array(jsonb_build_object('country', 'AE', 'visitors', 12), jsonb_build_object('country', 'ZW', 'visitors', 5)));
  perform set_config('request.jwt.claims', '{"role":"authenticated","email":"anview@test.local"}', true);
  execute 'set local role authenticated';
  j := public.audience_overview(30);
  if (j -> 'web' -> 'countries' -> 0 ->> 'country') = 'AE' and (j -> 'web' -> 'countries' -> 0 ->> 'visitors') = '12'
    then ok := ok + 1; else fail := fail + 1; log := log || ' [countries-missing]'; end if;
  --    the window is visible to the operator, so the screen can say what it is counting
  if (j -> 'config' ->> 'web_start_date') is not null and (j -> 'config' -> 'web_exclude_paths') ? '/admin'
    then ok := ok + 1; else fail := fail + 1; log := log || ' [window-not-exposed]'; end if;
  --    a viewer cannot move the window
  begin perform public.analytics_web_config_set('{"web_start_date":"2026-01-01"}'::jsonb); fail := fail + 1; log := log || ' [viewer-moved-window]';
  exception when insufficient_privilege then ok := ok + 1; end;
  execute 'reset role';

  --    the manager can, and moving it forward deletes what is now uncountable
  perform public.web_daily_upsert(jsonb_build_array(jsonb_build_object('day', (current_date - 4)::text, 'visitors', 3, 'pageviews', 3, 'visits', 3)));
  perform set_config('request.jwt.claims', '{"role":"authenticated","email":"anmanage@test.local"}', true);
  execute 'set local role authenticated';
  j := public.analytics_web_config_set(jsonb_build_object('web_start_date', (current_date - 3)::text));
  if (j ->> 'web_start_date')::date = current_date - 3
     and not exists (select 1 from public.web_daily where day < current_date - 3)
    then ok := ok + 1; else fail := fail + 1; log := log || ' [window-move]'; end if;
  --    a start date in the future is refused: a site cannot have gone live tomorrow
  begin perform public.analytics_web_config_set(jsonb_build_object('web_start_date', (current_date + 1)::text)); fail := fail + 1; log := log || ' [future-start]';
  exception when sqlstate '22023' then ok := ok + 1; end;
  --    an exclusion that is not a path is refused before it can break a Plausible query
  begin perform public.analytics_web_config_set('{"web_exclude_paths":["admin"]}'::jsonb); fail := fail + 1; log := log || ' [exclusion-not-a-path]';
  exception when sqlstate '22023' then ok := ok + 1; end;
  j := public.analytics_web_config_set('{"web_exclude_paths":["/admin","/c"]}'::jsonb);
  if (j -> 'web_exclude_paths') ? '/admin' and (j -> 'web_exclude_paths') ? '/c' then ok := ok + 1; else fail := fail + 1; log := log || ' [exclusion-save]'; end if;
  execute 'reset role';
  --    every change to what counts is audited: the numbers must never move anonymously.
  --    Read as postgres, not as the operator — the audit trail is not theirs to read.
  if exists (select 1 from public.admin_audit where area = 'analytics' and action = 'config' and changed_by = 'anmanage@test.local')
    then ok := ok + 1; else fail := fail + 1; log := log || ' [window-not-audited]'; end if;

  --    the sync reads the rule from the database, and only as service_role
  if (public.analytics_sync_config() ->> 'start_date')::date = current_date - 3 then ok := ok + 1; else fail := fail + 1; log := log || ' [sync-config]'; end if;
  perform set_config('request.jwt.claims', '{"role":"authenticated","email":"anmanage@test.local"}', true);
  execute 'set local role authenticated';
  begin perform public.analytics_sync_config(); fail := fail + 1; log := log || ' [sync-config-open]';
  exception when insufficient_privilege then ok := ok + 1; end;
  execute 'reset role';

  raise exception 'CG018_TESTS ok=% fail=% %', ok, fail, log;
end $$;

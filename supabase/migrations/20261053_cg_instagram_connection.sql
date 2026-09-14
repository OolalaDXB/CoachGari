-- =====================================================================
-- Instagram — the connection, and why the token lives in the Vault
--
-- WHAT META ACTUALLY REQUIRES. Instagram's counters are only readable for a
-- PROFESSIONAL account (Business or Creator) through an authorised token. There
-- is no key-only path like YouTube's. Two things make it workable here anyway:
--
--   * "Instagram API with Instagram Login" no longer needs a linked Facebook
--     Page, which used to be the expensive part of the setup;
--   * Standard Access covers accounts that hold a ROLE on the app, so a single
--     creator connecting their own account needs no App Review and no Business
--     Verification. That is exactly our case, and it is the boundary Meta
--     documents — not a trick.
--
-- WHY THE VAULT AND NOT A DEPLOYMENT SECRET. A long-lived token lasts 60 days
-- and is refreshed by exchanging it for a new one. The new value has to be
-- STORED, and a Deno environment variable cannot be written at runtime. So the
-- token lives in the Vault, like every other secret here, and the sync rotates
-- it in place.
--
-- THE 60-DAY RULE IS A TRAP, AND IT IS HANDLED. Meta refreshes a token only if
-- it is at least 24 hours old and NOT yet expired: a token left unrefreshed for
-- 60 days dies permanently and the whole connection must be re-authorised by
-- hand. So the expiry is stored, the sync refreshes at 30 days — halfway, which
-- leaves a month of missed runs before anything is lost — and the back-office
-- says how long is left rather than waiting to say it is too late.
--
-- WHAT IS COLLECTED. Followers, following and post count from the user node.
-- Nothing about anybody else: no follower list, no names, no messages. The same
-- aggregate shape every other platform in this table already has.
-- =====================================================================

-- ---------- 1. what we remember about the connection ----------
alter table public.analytics_config add column if not exists instagram_user_id    text;
alter table public.analytics_config add column if not exists instagram_username   text;
alter table public.analytics_config add column if not exists instagram_expires_at timestamptz;
alter table public.analytics_config add column if not exists instagram_synced_at  timestamptz;
alter table public.analytics_config add column if not exists instagram_error      text;

comment on column public.analytics_config.instagram_expires_at is
  'When the stored long-lived token dies. Meta refuses to refresh an expired token, so passing this date means re-authorising by hand.';

-- ---------- 2. connecting (from the back-office, once) ----------
/* The operator pastes the long-lived token Meta issued them. It goes straight
   into the Vault and is never returned by anything a browser can call — not by
   this function, not by the overview. What comes back is the connection's
   shape: which account, until when. */
create or replace function public.instagram_connect(p_token text, p_user_id text, p_username text default null,
                                                    p_expires_in int default 5184000)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare e text := public.current_email(); sid uuid; v_exp timestamptz;
begin
  if not public.has_permission('analytics:manage') then raise exception 'forbidden' using errcode = '42501'; end if;
  if coalesce(btrim(p_token), '') = '' then raise exception 'a token is required' using errcode = '22023'; end if;
  /* Meta's long-lived tokens are long and opaque. The only thing worth checking
     is that this is not a short-lived token or a pasted URL — both are common
     mistakes and both fail hours later, far from the paste. */
  if length(btrim(p_token)) < 40 or btrim(p_token) like 'http%' then
    raise exception 'that does not look like a long-lived access token' using errcode = '22023';
  end if;
  if coalesce(btrim(p_user_id), '') !~ '^[0-9]{5,}$' then raise exception 'the Instagram user id is a number' using errcode = '22023'; end if;

  v_exp := now() + make_interval(secs => greatest(3600, least(coalesce(p_expires_in, 5184000), 5184000)));

  select id into sid from vault.secrets where name = 'instagram_token';
  if sid is null then
    perform vault.create_secret(btrim(p_token), 'instagram_token', 'Instagram long-lived access token (rotated by analytics-sync)');
  else
    perform vault.update_secret(sid, btrim(p_token));
  end if;

  update public.analytics_config
     set instagram_user_id = btrim(p_user_id),
         instagram_username = nullif(btrim(coalesce(p_username, '')), ''),
         instagram_handle = coalesce(nullif(btrim(coalesce(p_username, '')), ''), instagram_handle),
         instagram_expires_at = v_exp, instagram_error = null, updated_at = now()
   where id = 1;

  insert into public.admin_audit (area, entity_id, action, changed_by, summary)
  values ('analytics', 'instagram', 'connect', e, jsonb_build_object('user_id', btrim(p_user_id), 'expires_at', v_exp));

  return jsonb_build_object('ok', true, 'user_id', btrim(p_user_id), 'expires_at', v_exp);
end $$;
revoke execute on function public.instagram_connect(text, text, text, int) from public, anon;
grant  execute on function public.instagram_connect(text, text, text, int) to authenticated, service_role;

create or replace function public.instagram_disconnect()
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare e text := public.current_email(); sid uuid;
begin
  if not public.has_permission('analytics:manage') then raise exception 'forbidden' using errcode = '42501'; end if;
  select id into sid from vault.secrets where name = 'instagram_token';
  if sid is not null then delete from vault.secrets where id = sid; end if;
  update public.analytics_config
     set instagram_user_id = null, instagram_expires_at = null, instagram_error = null, updated_at = now()
   where id = 1;
  insert into public.admin_audit (area, entity_id, action, changed_by, summary)
  values ('analytics', 'instagram', 'disconnect', e, '{}'::jsonb);
  return jsonb_build_object('ok', true);
end $$;
revoke execute on function public.instagram_disconnect() from public, anon;
grant  execute on function public.instagram_disconnect() to authenticated, service_role;

-- ---------- 3. what the sync may read and write ----------
/* service_role only. The token leaves the database exactly once per run, to the
   function that calls Meta with it, and never towards a browser. */
create or replace function public.instagram_token_get()
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare c public.analytics_config%rowtype; t text;
begin
  select * into c from public.analytics_config where id = 1;
  if c.instagram_user_id is null then return jsonb_build_object('connected', false); end if;
  select decrypted_secret into t from vault.decrypted_secrets where name = 'instagram_token' limit 1;
  if t is null then return jsonb_build_object('connected', false, 'reason', 'no token stored'); end if;
  return jsonb_build_object(
    'connected', true, 'token', t, 'user_id', c.instagram_user_id,
    'expires_at', c.instagram_expires_at,
    -- refresh at the halfway mark, not at the edge: Meta refuses to refresh an
    -- expired token, and a month of missed runs must not cost the connection
    'should_refresh', c.instagram_expires_at is null or c.instagram_expires_at < now() + interval '30 days',
    'expired', c.instagram_expires_at is not null and c.instagram_expires_at <= now());
end $$;
revoke execute on function public.instagram_token_get() from public, anon, authenticated;
grant  execute on function public.instagram_token_get() to service_role;

create or replace function public.instagram_token_rotate(p_token text, p_expires_in int default 5184000)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare sid uuid; v_exp timestamptz;
begin
  if coalesce(btrim(p_token), '') = '' then raise exception 'a token is required' using errcode = '22023'; end if;
  v_exp := now() + make_interval(secs => greatest(3600, least(coalesce(p_expires_in, 5184000), 5184000)));
  select id into sid from vault.secrets where name = 'instagram_token';
  if sid is null then
    perform vault.create_secret(btrim(p_token), 'instagram_token', 'Instagram long-lived access token (rotated by analytics-sync)');
  else
    perform vault.update_secret(sid, btrim(p_token));
  end if;
  update public.analytics_config set instagram_expires_at = v_exp, instagram_error = null, updated_at = now() where id = 1;
  /* Audited without the token: what matters on the trail is that the connection
     was kept alive and until when, never the value that keeps it alive. */
  insert into public.admin_audit (area, entity_id, action, changed_by, summary)
  values ('analytics', 'instagram', 'token_rotated', 'system:analytics-sync', jsonb_build_object('expires_at', v_exp));
  return jsonb_build_object('ok', true, 'expires_at', v_exp);
end $$;
revoke execute on function public.instagram_token_rotate(text, int) from public, anon, authenticated;
grant  execute on function public.instagram_token_rotate(text, int) to service_role;

create or replace function public.instagram_sync_done(p_error text default null)
returns void language plpgsql volatile security definer set search_path = '' as $$
begin
  update public.analytics_config
     set instagram_synced_at = case when p_error is null then now() else instagram_synced_at end,
         instagram_error = left(p_error, 300), updated_at = now()
   where id = 1;
end $$;
revoke execute on function public.instagram_sync_done(text) from public, anon, authenticated;
grant  execute on function public.instagram_sync_done(text) to service_role;

-- ---------- 4. the sync's view of the configuration ----------
create or replace function public.analytics_sync_config()
returns jsonb language sql stable security definer set search_path = '' as $$
  select jsonb_build_object(
    'site_id', c.plausible_site_id,
    'start_date', coalesce(c.web_start_date, date '2026-09-15'),
    'exclude_paths', to_jsonb(c.web_exclude_paths),
    'youtube_channel_id', c.youtube_channel_id,
    'instagram_user_id', c.instagram_user_id)
  from public.analytics_config c where c.id = 1;
$$;
revoke execute on function public.analytics_sync_config() from public, anon, authenticated;
grant  execute on function public.analytics_sync_config() to service_role;

-- ---------- 5. the operator sees the connection, never the token ----------
grant select (id, plausible_site_id, youtube_channel_id, instagram_handle, tiktok_handle,
              web_sources, web_goals, web_countries, web_start_date, web_exclude_paths,
              web_synced_at, youtube_synced_at, last_sync_error,
              instagram_user_id, instagram_username, instagram_expires_at, instagram_synced_at, instagram_error,
              updated_at)
  on public.analytics_config to authenticated;

create or replace function public.instagram_status()
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare c public.analytics_config%rowtype;
begin
  if not public.has_permission('analytics:view') then raise exception 'forbidden' using errcode = '42501'; end if;
  select * into c from public.analytics_config where id = 1;
  return jsonb_build_object(
    'connected', c.instagram_user_id is not null,
    'username', c.instagram_username,
    'expires_at', c.instagram_expires_at,
    'days_left', case when c.instagram_expires_at is null then null
                      else greatest(0, (c.instagram_expires_at::date - current_date)) end,
    'synced_at', c.instagram_synced_at,
    'error', c.instagram_error);
end $$;
revoke execute on function public.instagram_status() from public, anon;
grant  execute on function public.instagram_status() to authenticated, service_role;

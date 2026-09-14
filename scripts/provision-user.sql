-- =====================================================================
-- Provision a person's access — an operational act, run against the project.
--
-- WHY THIS IS NOT A MIGRATION. Migrations describe the schema, and they are
-- permanent. Who holds which permission is neither: people join, leave and
-- change roles, and writing an address into a migration puts a real person into
-- every database ever built from this repository — including a CI replay and
-- anyone's checkout — with no way to take it back. Two migrations used to do
-- exactly that; they no longer do.
--
-- HOW TO RUN IT. Pass the address on the command line; nothing here names
-- anyone, so this file is safe to read and to commit.
--
--   psql "$DATABASE_URL" -v email=someone@example.com -v name='Their name' \
--        -v party=gari -v set=coach -f scripts/provision-user.sql
--
--   party : 'gari' (the coach's side) | 'oolala' or 'studio' (the platform side)
--   set   : 'coach'   — the full launch set the coach holds
--           'finance'  — finance only (view + manage)
--           'admin'    — access administration only (platform:admin)
--
-- The grant is recorded in admin_audit with an actor, exactly like one made
-- from the back-office, and it is idempotent: running it twice changes nothing
-- the second time.
--
-- To take access away, use the back-office, or public.admin_revoke(email,
-- permission). Never delete rows by hand: the audit trail is the point.
-- =====================================================================
\set ON_ERROR_STOP on

-- psql substitutes :variables in ordinary SQL but not inside a dollar-quoted
-- body, so the four arguments are put into settings here and read back below.
-- The 'false' makes them session-scoped, and the session ends with this script.
select set_config('provision.email', :'email', false),
       set_config('provision.name',  :'name',  false),
       set_config('provision.party', :'party', false),
       set_config('provision.set',   :'set',   false) \g /dev/null

do $$
declare
  v_email  text := lower(btrim(current_setting('provision.email')));
  v_name   text := btrim(current_setting('provision.name'));
  v_party  text := current_setting('provision.party');
  v_set    text := current_setting('provision.set');
  v_perms  text[];
  p        text;
begin
  if v_email !~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$' then
    raise exception 'that does not look like an email address: %', v_email;
  end if;
  if v_party not in ('gari','oolala','studio') then
    raise exception 'party must be gari, oolala or studio (got %)', v_party;
  end if;

  v_perms := case v_set
    when 'coach' then array['coach:operations','client_profile:view','client_profile:manage',
                            'health_metrics:view','health_metrics:manage',
                            'coaching_sensitive:view','coaching_sensitive:manage',
                            'finance:view','finance:manage','analytics:view',
                            'catalog:view','catalog:manage','collab:view','collab:manage']
    when 'finance' then array['finance:view','finance:manage']
    when 'admin'   then array['platform:admin']
    else null end;
  if v_perms is null then raise exception 'set must be coach, finance or admin (got %)', v_set; end if;

  insert into public.app_users (email, display_name, party, active)
  values (v_email, coalesce(nullif(v_name, ''), v_email), v_party, true)
  on conflict (email) do update set active = true, display_name = excluded.display_name, party = excluded.party;

  foreach p in array v_perms loop
    insert into public.app_permissions (email, permission) values (v_email, p) on conflict do nothing;
  end loop;

  insert into public.admin_audit (area, entity_id, action, changed_by, summary)
  values ('permission', v_email, 'provision', coalesce(public.current_email(), 'script:provision-user'),
          jsonb_build_object('set', v_set, 'party', v_party, 'permissions', to_jsonb(v_perms)));

  raise notice 'provisioned % (% set, party %): % permissions', v_email, v_set, v_party, array_length(v_perms, 1);
end $$;

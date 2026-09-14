-- =====================================================================
-- Is the live project provisioned? — an operational check, not a test.
--
-- The database suites used to assert this by naming two real people and reading
-- their rows, which made them unrunnable anywhere but production and put a
-- personal address in the repository. What the suites owe us is that the schema
-- ENFORCES permissions; whether a particular person currently holds one is a
-- fact about the project, and it belongs here.
--
--   psql "$DATABASE_URL" -f scripts/check-provisioning.sql
--
-- Prints one row per signed-in person with what they can reach, then a verdict.
-- Reads only; changes nothing. It never prints anything but addresses that are
-- already in the database being queried.
-- =====================================================================
\pset pager off

select u.email,
       u.party,
       u.active,
       count(p.permission)                                                    as permissions,
       bool_or(p.permission = 'finance:view')  and
       bool_or(p.permission = 'finance:manage')                               as finance_pair,
       bool_or(p.permission = 'coach:operations')                             as coach,
       bool_or(p.permission = 'platform:admin')                               as access_admin
  from public.app_users u
  left join public.app_permissions p on p.email = u.email
 group by u.email, u.party, u.active
 order by u.active desc, u.email;

do $$
declare n_finance int; n_coach int; n_admin int; n_inactive_with_perms int;
begin
  select count(*) into n_finance from (
    select u.email from public.app_users u join public.app_permissions p on p.email = u.email
     where u.active group by u.email
    having bool_or(p.permission = 'finance:view') and bool_or(p.permission = 'finance:manage')) q;
  select count(*) into n_coach from public.app_permissions p join public.app_users u on u.email = p.email
   where u.active and p.permission = 'coach:operations';
  select count(*) into n_admin from public.app_permissions p join public.app_users u on u.email = p.email
   where u.active and p.permission = 'platform:admin';
  select count(distinct p.email) into n_inactive_with_perms
    from public.app_permissions p join public.app_users u on u.email = p.email where not u.active;

  raise notice '% active people hold the finance pair, % hold coach:operations, % hold platform:admin', n_finance, n_coach, n_admin;
  if n_finance < 2 then
    raise warning 'fewer than two people can reach Finance. One illness or one lost password and the money side is unreachable.';
  end if;
  if n_admin = 0 then
    raise warning 'nobody holds platform:admin: no one can grant or revoke access from the back-office.';
  end if;
  if n_inactive_with_perms > 0 then
    raise warning '% deactivated %s still carry permission rows. Deactivation is enough to lock them out, but the rows should be revoked so the list says what is true.',
      n_inactive_with_perms, case when n_inactive_with_perms = 1 then 'person' else 'people' end;
  end if;
end $$;

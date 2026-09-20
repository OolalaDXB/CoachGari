-- =====================================================================
-- Subscriptions: close the definer grants the advisors found
--
-- Three real breaches of this project's own rule (20261020,
-- "cg_definer_grants_lockdown"): a SECURITY DEFINER function must not be
-- reachable by a role a browser can hold, and every function must pin its
-- search_path. Writing 20261056/57 I applied that rule to the RPCs and
-- forgot it on the small helpers, which is exactly how these things get in.
--
-- 1. `subscription_cycle_on_pack_payment` — the settlement trigger — was
--    executable by ANON over /rest/v1/rpc. Calling it directly raises
--    "trigger functions can only be called as triggers", so nothing could
--    actually be moved with it; it is still a SECURITY DEFINER function on
--    the public internet, which is not a thing this codebase leaves lying
--    around. Revoking EXECUTE does not affect the trigger: PostgreSQL checks
--    that privilege when the trigger is CREATED, never when it fires.
--
-- 2. `subscription_json` / `subscription_cycle_json` were executable by
--    `authenticated`. They are SECURITY DEFINER and take a rowtype, so a
--    signed-in operator without finance:view could pass a hand-made row and
--    read back the cycle counts, the amount paid to date and the client's
--    display name for any subscription id they could name. That needs a UUID
--    they should not have, which is why this is a leak and not a hole — but
--    the permission check belongs in front of the data, not in front of one
--    of the two ways to reach it. They are now owner-only, which changes
--    nothing for the back-office: subscriptions_list, subscription_get and
--    the rest are themselves SECURITY DEFINER, so they keep calling these
--    as the owner after their own has_permission() check.
--
-- 3. `subscription_has_mandate` had a mutable search_path. Its body reads
--    only the fields of its argument, so there is nothing a search_path
--    could redirect and no exploit here — but "this one is fine" is how the
--    rule stops being a rule, and a later edit that adds a table lookup
--    would inherit the hole silently.
--
-- Found by running the advisors after applying, which is the point of doing
-- that. No behaviour changes; every suite passes unchanged.
-- =====================================================================

-- 1. the settlement trigger: owner-only, as every other definer trigger here
revoke all on function public.subscription_cycle_on_pack_payment() from public, anon, authenticated, service_role;

-- 2. the shapes: reached only through the permission-checked RPCs above them
revoke all on function public.subscription_json(public.subscriptions) from public, anon, authenticated, service_role;
revoke all on function public.subscription_cycle_json(public.subscription_cycles) from public, anon, authenticated, service_role;

-- 3. pin the helper's search_path, and close it while we are here
create or replace function public.subscription_has_mandate(s public.subscriptions) returns boolean
language sql immutable set search_path = '' as $$
  select coalesce(s.stripe_customer_id, '') <> '' and coalesce(s.stripe_payment_method_id, '') <> '';
$$;
revoke all on function public.subscription_has_mandate(public.subscriptions) from public, anon, authenticated, service_role;

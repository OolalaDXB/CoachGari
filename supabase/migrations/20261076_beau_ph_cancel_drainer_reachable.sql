-- =====================================================================
-- The provider-cancellation drainer could never reach its own queue.
--
-- beau_ph.cancellations_due() and beau_ph.cancellation_mark() were written in
-- the beau_ph schema, and the ph-cancel Edge Function calls them with
-- supabase-js `rpc()` — which goes through PostgREST, which exposes `public`
-- and nothing else. So every run since 20261049 ended the same way: the first
-- call failed, the function answered 500, and not one cancellation was ever
-- delivered. The queue looked healthy (rows `pending`, attempts 0) precisely
-- because nothing ever picked them up — a failure that is silent by
-- construction, and it was found by watching a payment link's Stripe session
-- stay open after the link had been deleted.
--
-- What that cost: when a request is superseded or a link is withdrawn or
-- deleted, the Checkout Session at Stripe was never expired. The state machine
-- still refuses a second payment, so no double ledger entry was ever possible;
-- but money could still reach Stripe on a closed order and need refunding by
-- hand. The guarantee was written, recorded and never executed.
--
-- The fix is a pair of `public` wrappers carrying the exact names the deployed
-- function already calls, so the repair does not depend on redeploying it.
-- They are SECURITY DEFINER, granted to service_role only, and do nothing of
-- their own: the logic stays in beau_ph, which is where the hub's rules live.
-- =====================================================================

create or replace function public.cancellations_due(p_limit int default 20)
returns jsonb language sql volatile security definer set search_path = '' as $$
  select beau_ph.cancellations_due(p_limit)
$$;
revoke execute on function public.cancellations_due(int) from public, anon, authenticated;
grant  execute on function public.cancellations_due(int) to service_role;

create or replace function public.cancellation_mark(p_id uuid, p_ok boolean, p_error text default null, p_skip boolean default false)
returns jsonb language sql volatile security definer set search_path = '' as $$
  select beau_ph.cancellation_mark(p_id, p_ok, p_error, p_skip)
$$;
revoke execute on function public.cancellation_mark(uuid, boolean, text, boolean) from public, anon, authenticated;
grant  execute on function public.cancellation_mark(uuid, boolean, text, boolean) to service_role;

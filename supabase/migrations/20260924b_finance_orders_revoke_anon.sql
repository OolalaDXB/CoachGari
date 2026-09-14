-- finance_orders() is a SECURITY DEFINER function: the grant, not only the
-- permission check inside it, has to stop at signed-in users.
revoke all on function public.finance_orders() from public;
revoke all on function public.finance_orders() from anon;
grant execute on function public.finance_orders() to authenticated, service_role;

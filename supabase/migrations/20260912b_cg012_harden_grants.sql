-- CG-012 hardening: trigger functions are never RPCs, and the two pack helpers
-- are called only by other definer functions — nothing signed in needs them.
revoke all on function public.coaching_sessions_pack_guard() from public, anon, authenticated;
revoke all on function public.sync_session_from_booking() from public, anon, authenticated;
revoke execute on function public.pack_recap_data(uuid, boolean) from authenticated;
revoke execute on function public.project_pack_payment(uuid) from authenticated;

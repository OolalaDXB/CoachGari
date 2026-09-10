-- =====================================================================
-- Coach Gari — P0: close the default PUBLIC grant on internal SECURITY DEFINER helpers
--
-- CREATE OR REPLACE FUNCTION does not reset privileges, so these four kept an ACL
-- that let anon / authenticated call them directly over PostgREST. A live scan of
-- schema public (pg_proc.prosecdef, checking has_function_privilege('anon', …))
-- confirmed these are the ONLY anon-reachable SECURITY DEFINER functions:
--
--   collab_deal_json(uuid, boolean)        — deal serializer (admin/public shapes)
--   collab_deal_by_token(text)             — token → deal id resolver
--   collab_new_ref()                       — public reference generator
--   email_payload_booking(public.bookings) — email render payload builder
--
-- Each is invoked only from other SECURITY DEFINER functions (collab_room,
-- collab_admin_get, collab_intake, the email_on_* producers), which execute as the
-- function owner — so removing PUBLIC / anon / authenticated changes no working path.
-- Every other SECURITY DEFINER function in public already carries an explicit ACL
-- that excludes anon; the RPCs the back-office calls keep their authenticated grant
-- and gate themselves with has_permission().
-- =====================================================================

revoke all on function public.collab_deal_json(uuid, boolean)          from public, anon, authenticated;
revoke all on function public.collab_deal_by_token(text)               from public, anon, authenticated;
revoke all on function public.collab_new_ref()                         from public, anon, authenticated;
revoke all on function public.email_payload_booking(public.bookings)   from public, anon, authenticated;

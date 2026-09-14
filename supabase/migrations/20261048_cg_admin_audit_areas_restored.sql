-- =====================================================================
-- admin_audit: restore the two areas that were lost when the CHECK was
-- re-issued.
--
-- A CHECK constraint cannot grow in place: adding one value means dropping the
-- constraint and writing the whole enumeration again. Migration 20261041 did
-- that to add 'whatsapp', and retyped the list from an older copy — so
-- 'commission' (20261030) and 'enquiry' (20261035) silently disappeared.
--
-- The consequence was not cosmetic. Both are written by code that runs today:
--   * public.lead_delete()                 audits area 'enquiry'
--   * public.commission_exemption_request() audits area 'commission'
-- Each ends with an INSERT into admin_audit, so deleting a lead and asking for
-- a commission exemption both failed with a constraint violation, and the work
-- they had already done was rolled back with them.
--
-- Found by replaying every migration into an empty database in CI and running
-- the suites against it, which is the point of doing that.
--
-- The list below is the union of every area any migration has ever declared.
-- Anything added from here on must be added to THIS list, not to an older one.
-- =====================================================================
alter table public.admin_audit drop constraint if exists admin_audit_area_check;
alter table public.admin_audit add constraint admin_audit_area_check check (area = any (array[
  'crm_contact', 'crm_note', 'body_measurement', 'permission', 'consent', 'merge',
  'coaching_session', 'session_pack', 'block', 'report', 'payment', 'payment_method',
  'beau_ph_rail', 'beau_ph_fx', 'settlement_destination', 'collaboration', 'email',
  'commission', 'enquiry', 'analytics', 'whatsapp', 'agreement']));

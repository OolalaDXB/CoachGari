-- =====================================================================
-- Coach Gari — Collaborations: align the operator SELECT grant with the
-- house secret-column pattern.
--
-- 20261013 granted `select` on the whole `collaboration_deals` table to
-- `authenticated`, so any `collab:view` operator could read the token columns.
-- The house rule (see 20260905_cg0025_backoffice.sql) is a column-scoped grant
-- that never includes token/hash/idempotency columns; secrets are reachable
-- only through SECURITY DEFINER functions that run as the owner.
--
-- The recoverable token is already encrypted at rest (20261016: `room_token_enc`
-- under a Vault key, decryptor revoked from every non-owner role), so the
-- ciphertext is not exploitable even if read. This closes the gap the other way
-- too: an operator's raw `select *` now returns neither `access_token_hash` nor
-- `room_token_enc`. RLS still gates rows by `collab:view`; the magic-link
-- producers (email queues, `collab_deal_json(_, true)`) keep access because they
-- are SECURITY DEFINER and execute as the function owner, not as the operator.
-- Flow unchanged: `collab_room` stays `p_admin => false`.
-- =====================================================================

-- Drop the table-wide grant, re-grant column by column, excluding the two
-- secret columns: access_token_hash (auth gate) and room_token_enc (ciphertext).
revoke select on public.collaboration_deals from authenticated;
grant select (
  id, public_ref, crm_contact_id, company, contact_name, contact_email,
  contact_phone, contact_url, collaboration_type, title, initial_request,
  proposed_date_from, proposed_date_to, location, intake_budget_amount,
  intake_budget_currency, intake_offer, status, accepted_proposal_id,
  token_revoked_at, source, created_by, created_at, updated_at
) on public.collaboration_deals to authenticated;

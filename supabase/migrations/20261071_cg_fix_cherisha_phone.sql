-- =====================================================================
-- One number corrected by hand, because no rule could have caught it.
--
-- "9551064692" survived every automatic check: it is ten digits, it starts
-- with a digit that is not zero, and 95 is Myanmar's dialling code — so the
-- digits parse as a real country's number and nothing was entitled to call it
-- wrong. CG-043's length rule had nothing to say either: the contact was never
-- normalised by country because it never went through the enquiry form.
--
-- What identified it was the row's own history, not its shape: no enquiry
-- attached, and a single audit line — created in the back-office by the owner.
-- The country and city were typed, not collected. So the typo is the owner's,
-- and the owner is the person who can confirm the real number.
--
--   9551064692    =  9   · 551064692
--   971551064692  =  971 · 551064692     (55 is a valid UAE mobile prefix)
--
-- Confirmed by the owner and applied. The lesson worth keeping: when a value is
-- wrong in a way no rule can detect, the provenance of the row is the evidence —
-- who entered it, and whether anyone else ever touched it.
-- =====================================================================

with before as (
  select id, phone as old_phone, phone_norm as old_norm
    from public.crm_contacts
   where phone_norm = '9551064692'
),
audited as (
  insert into public.admin_audit (area, entity_id, action, changed_by, summary)
  select 'crm_contact', id::text, 'phone:corrected-by-owner', 'migration:20261071',
         jsonb_build_object('from', old_norm, 'to', '971551064692',
                            'reason', 'back-office typo: 971 typed as 9, confirmed by the owner')
    from before
  returning 1
)
update public.crm_contacts c
   set phone = '+971551064692'
  from before b
 where c.id = b.id;

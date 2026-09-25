-- =====================================================================
-- Two numbers WhatsApp cannot reach, flagged where the coach will see them.
--
-- Rhitu (05028225655) and Sameer (050659577) are both a digit off a UAE mobile,
-- and CG-043 deliberately left them alone: a number that is merely unusable
-- must not be turned into one that looks usable, because the second kind
-- reaches a stranger and nobody finds out. Eight or nine missing digits cannot
-- be reconstructed — only asked for.
--
-- So the flag goes on the contact's own record, pinned, where Coach Gari
-- already looks before writing to someone. Not a report, not a list elsewhere
-- in the back-office: a warning is only useful in the place where the mistake
-- would otherwise be made.
--
-- The note states the correct shape (0 + nine digits, i.e. +971 + nine) so the
-- check takes a glance, and guesses nothing.
--
-- Idempotent on the author, so replaying this never leaves two.
-- =====================================================================

insert into public.crm_notes (crm_contact_id, body, category, pinned, scope, author)
select k.id,
       'Phone to check — WhatsApp cannot reach this number. It is on file as ' || k.phone ||
       ', one digit short of a UAE mobile. A UAE mobile is 0 followed by nine digits ' ||
       '(05X XXX XXXX), which is +971 followed by nine. Please confirm the full number with ' ||
       coalesce(k.display_name, 'this person') || ' and correct it here.',
       'admin', true, 'operational', 'system:phone-check'
  from public.crm_contacts k
 where k.phone is not null
   and not (coalesce(k.phone_norm, '') ~ '^[1-9][0-9]{9,14}$')
   and not exists (
     select 1 from public.crm_notes n
      where n.crm_contact_id = k.id and n.author = 'system:phone-check');

-- =====================================================================
-- +971 in front of both, at the owner's instruction.
--
-- The trunk zero is replaced by the country code. The digit count is left
-- exactly as found, because that is the part nobody can reconstruct:
--
--   Rhitu   +9715028225655   ten digits after 971  (one more than a UAE mobile)
--   Sameer  +97150659577     eight                 (one fewer)
--
-- Both are recorded in admin_audit with their old value, so this is reversible.
--
-- One consequence to know rather than discover: these now pass the shape test
-- the WhatsApp button uses, so the button is live again and may open on a
-- number that does not exist. The pinned note on each record is what remains,
-- and it now names each one's actual defect instead of describing both as too
-- short, which was wrong for Rhitu.
-- =====================================================================

with before as (
  select id, display_name, phone as old_phone, phone_norm as old_norm,
         '+971' || substr(phone_norm, 2) as new_phone
    from public.crm_contacts
   where phone is not null
     and phone_norm ~ '^0'
     and not (phone_norm ~ '^[1-9][0-9]{9,14}$')
),
audited as (
  insert into public.admin_audit (area, entity_id, action, changed_by, summary)
  select 'crm_contact', id::text, 'phone:prefixed-971-by-owner', 'migration:20261073',
         jsonb_build_object('from', old_norm, 'to', substr(new_phone, 2),
                            'note', 'digit count unchanged and still non-standard for a UAE mobile')
    from before
  returning 1
)
update public.crm_contacts c
   set phone = b.new_phone
  from before b
 where c.id = b.id;

update public.crm_notes n
   set body = 'Phone to check. Now stored as ' || k.phone || ' at the owner''s instruction. '
              || case when length(k.phone_norm) - 3 > 9
                      then 'It still has one digit MORE than a UAE mobile, which is +971 followed by nine.'
                      else 'It still has one digit FEWER than a UAE mobile, which is +971 followed by nine.' end
              || ' WhatsApp will now accept the link, so it may open on a number that does not exist — '
              || 'please confirm the real number with ' || coalesce(k.display_name, 'this person') || '.',
       updated_at = now()
  from public.crm_contacts k
 where n.crm_contact_id = k.id and n.author = 'system:phone-check';

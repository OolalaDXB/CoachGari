-- =====================================================================
-- Keep the readable number in E.164 too, not just the comparison key.
--
-- 20261061 fixed phone_norm and backfilled the rows that existed. It did
-- not fix the next number someone types. The writers store `phone` exactly
-- as it arrived and `phone_norm` normalised, so an enquiry or an edit
-- carrying 0561234567 puts a working key in phone_norm and a broken number
-- on the screen — and the screen is what the WhatsApp and Call buttons are
-- built from. wa.me strips the punctuation and dials 056…, which is nobody.
--
-- WHY A TRIGGER AND NOT A FIX IN EACH FUNCTION.
-- Three functions write this column today — crm_link_contact from an
-- enquiry or booking, crm_save_contact from the form, crm_merge_contacts
-- when it fills a gap from the other record — and the fourth will be the
-- client import. Patching them one at a time means the invariant holds
-- until someone adds a writer, which is not an invariant. Here it is one:
-- whenever phone_norm is plainly a full number, phone is the same number
-- with a plus in front.
--
-- 10 to 15 digits is E.164's own range. Anything shorter or stranger — a
-- landline fragment, the row whose owner typed a letter o for a zero — is
-- left exactly as it was typed, because a number we cannot read is worth
-- more on the screen than a number we guessed at.
-- =====================================================================

create or replace function public.crm_contacts_phone_display()
returns trigger language plpgsql set search_path = '' as $$
begin
  if new.phone_norm ~ '^[0-9]{10,15}$' then
    new.phone := '+' || new.phone_norm;
  end if;
  return new;
end $$;

drop trigger if exists crm_contacts_phone_display on public.crm_contacts;
create trigger crm_contacts_phone_display
  before insert or update of phone, phone_norm on public.crm_contacts
  for each row execute function public.crm_contacts_phone_display();

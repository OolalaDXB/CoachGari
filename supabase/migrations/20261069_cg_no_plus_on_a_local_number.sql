-- =====================================================================
-- A '+' in front of a zero is not a phone number.
--
-- 20261062 made the E.164 display an invariant: whenever phone_norm held 10 to
-- 15 digits, phone became '+' || phone_norm. The first international leads
-- showed what that rule does to a number it could not normalise. Zimbabwe's
-- 0788784495 is exactly ten digits, so it matched, and the contact was stored
-- and displayed as "+0788784495".
--
-- No country code begins with zero, so that string is a phone number in no
-- country at all. It reads as international to a person and wa.me refuses it —
-- which is worse than the raw local number it came from, because the raw one
-- at least looks local and invites the question.
--
-- The guard now requires a leading 1-9. A number that cannot be E.164 keeps
-- its own spelling instead of being dressed as something it is not.
--
-- The lesson: an invariant enforced by a pattern is only as true as the
-- pattern. '[0-9]{10,15}' describes the LENGTH of an E.164 number, and length
-- was never what made it one.
-- =====================================================================

create or replace function public.crm_contacts_phone_display()
returns trigger language plpgsql set search_path = '' as $$
begin
  if new.phone_norm ~ '^[1-9][0-9]{9,14}$' then new.phone := '+' || new.phone_norm; end if;
  return new;
end $$;

update public.crm_contacts
   set phone = phone_norm
 where phone like '+0%' and phone_norm ~ '^0';

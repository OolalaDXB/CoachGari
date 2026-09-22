-- =====================================================================
-- Phone numbers in one shape: E.164.
--
-- `0563497457` and `+971563497457` are the same person's mobile, and the
-- normaliser treated them as two, because it only stripped punctuation.
-- That is not cosmetic — it is three faults wearing one hat:
--
--   1. DEDUPLICATION. Two people who wrote their number differently on two
--      enquiries became two records. The matcher compares phone_norm, so a
--      leading zero against a country code never matched.
--   2. WHATSAPP. session_reminders_run passes phone_norm straight to
--      whatsapp_queue, and WhatsApp addresses in E.164. A local `05…`
--      number does not reach anyone.
--   3. READING IT. `https://wa.me/0563497457` goes nowhere, and a number
--      with no country code cannot be dialled from outside the country.
--
-- WHAT IS CONVERTED, AND WHAT IS DELIBERATELY NOT.
-- Only what is unambiguously a UAE mobile in local form: ten digits
-- matching 0(50|52|54|55|56|58) + seven. Those are the six UAE mobile
-- prefixes, and every local-format number in this table matches one.
--
-- NOT by the contact's country field, which is where the person is, not
-- where their number is: this table holds numbers filed under Portugal and
-- the United Kingdom that carry UAE mobile prefixes, because that is what a
-- resident of Dubai has. Prefixing by country would have corrupted them.
--
-- Anything already international is left exactly as it is — +39, +91, +31,
-- +380, +44 all appear here and are correct. Anything that matches neither
-- shape is left alone and stays visible rather than being guessed at; there
-- is one in the data whose owner typed a letter o for a zero.
--
-- Applied against 67 contacts: 52 converted, 1 already E.164, 10 untouched.
-- =====================================================================

create or replace function public.crm_normalize_phone(t text)
returns text language sql immutable set search_path = '' as $$
  with d as (select regexp_replace(coalesce(t, ''), '\D', '', 'g') as n)
  select case
    -- 00 is the international prefix in written form; drop it and judge what is left
    when (select n from d) ~ '^00[0-9]{8,}$'                     then substr((select n from d), 3)
    -- a UAE mobile written locally: 0 + one of the six mobile prefixes + seven digits
    when (select n from d) ~ '^0(50|52|54|55|56|58)[0-9]{7}$'    then '971' || substr((select n from d), 2)
    -- everything else keeps the old rule: digits only, and long enough to be a number
    when length((select n from d)) >= 7                          then (select n from d)
    else null
  end
$$;
revoke execute on function public.crm_normalize_phone(text) from public, anon;

-- ---------- backfill ----------
/* phone keeps the readable + form, phone_norm the digits, so a tel: link, a wa.me
   link and a comparison all read the same number. Only rows the pattern recognises
   are touched; the update is a no-op on everything else. */
update public.crm_contacts
   set phone_norm = '971' || substr(phone_norm, 2),
       phone      = '+971' || substr(phone_norm, 2)
 where phone_norm ~ '^0(50|52|54|55|56|58)[0-9]{7}$';

update public.crm_contacts
   set phone = '+' || phone_norm
 where phone_norm is not null
   and phone_norm ~ '^[0-9]{10,15}$'
   and coalesce(phone, '') !~ '^\+';

/* Putting two spellings into one shape reveals pairs that were never comparable
   before. Re-run the flag so those rows carry the Merge button too. */
update public.crm_contacts c
   set needs_review = true
 where not c.needs_review
   and exists (
     select 1 from public.crm_contacts o
      where o.id <> c.id
        and ((o.email_norm is not null and o.email_norm = c.email_norm)
          or (o.phone_norm is not null and o.phone_norm = c.phone_norm)));

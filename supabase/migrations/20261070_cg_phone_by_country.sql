-- =====================================================================
-- A local number is only local to somewhere. Normalise it with the country.
--
-- 20261061 taught the database one country's habits: 0 followed by a UAE
-- mobile prefix became 971…. That was true of the contacts it had. The first
-- international leads arrived from Zimbabwe and South Africa, and the rule had
-- nothing to say about them — so 0788784495 stayed local, un-dialable, and
-- (until 20261069) wore a '+' it had no right to.
--
-- The country was in the row the whole time: the enquiry form asks for it and
-- crm_link_contact already receives it. What was missing was using it.
--
-- Two things make this safe to apply to real people's numbers:
--
--   * every country here carries the LENGTH of its national numbers, not just
--     its dialling code. A conversion only happens when the digits left after
--     the trunk zero are a length that country actually uses. Sameer's nine
--     digits (050659577) are one short for the UAE, so nothing is done to them:
--     a number that was merely unusable is not turned into one that looks
--     usable and reaches a stranger.
--
--   * every backfilled row is written to admin_audit with its old and new
--     value, so any conversion can be read back and undone.
--
-- The normalisation now lives in a trigger as well as in crm_link_contact.
-- The trigger covers every writer at once; crm_link_contact still needs its
-- own call because it LOOKS UP by phone_norm before inserting, and a lookup
-- that normalises differently from the write would stop recognising the
-- person and quietly create a second contact for them.
-- =====================================================================

-- ---------- 1. what each country dials, and how long its numbers are ----------
create table if not exists public.phone_dial_codes (
  country  text primary key,              -- lower-case, as the enquiry form spells it
  dial     text not null check (dial ~ '^[1-9][0-9]{0,3}$'),
  nsn_len  int[] not null                 -- national significant number lengths, trunk zero removed
);
alter table public.phone_dial_codes enable row level security;
-- readable by the back-office, written by migrations only
drop policy if exists phone_dial_codes_read on public.phone_dial_codes;
create policy phone_dial_codes_read on public.phone_dial_codes for select to authenticated using (true);

insert into public.phone_dial_codes (country, dial, nsn_len) values
  ('united arab emirates','971','{9}'), ('zimbabwe','263','{9}'), ('south africa','27','{9}'),
  ('united kingdom','44','{10}'), ('united states','1','{10}'), ('canada','1','{10}'),
  ('france','33','{9}'), ('germany','49','{10,11}'), ('spain','34','{9}'), ('italy','39','{9,10}'),
  ('netherlands','31','{9}'), ('portugal','351','{9}'), ('switzerland','41','{9}'),
  ('ireland','353','{9}'), ('belgium','32','{9}'), ('australia','61','{9}'),
  ('new zealand','64','{8,9}'), ('india','91','{10}'), ('pakistan','92','{10}'),
  ('philippines','63','{10}'), ('kenya','254','{9}'), ('nigeria','234','{10}'),
  ('ghana','233','{9}'), ('botswana','267','{8}'), ('zambia','260','{9}'),
  ('namibia','264','{9}'), ('mozambique','258','{9}'), ('tanzania','255','{9}'),
  ('uganda','256','{9}'), ('malawi','265','{9}'), ('egypt','20','{10}'),
  ('saudi arabia','966','{9}'), ('qatar','974','{8}'), ('kuwait','965','{8}'),
  ('oman','968','{8}'), ('bahrain','973','{8}'), ('ukraine','380','{9}'),
  ('brazil','55','{10,11}'), ('mauritius','230','{8}')
on conflict (country) do update set dial = excluded.dial, nsn_len = excluded.nsn_len;

-- ---------- 2. normalisation, with the country in hand ----------
create or replace function public.crm_normalize_phone(t text, p_country text)
returns text language plpgsql stable set search_path = '' as $$
declare n text; dial text; lens int[]; rest text;
begin
  n := regexp_replace(coalesce(t, ''), '\D', '', 'g');
  if n = '' then return null; end if;
  if n ~ '^00[0-9]{8,}$' then n := substr(n, 3); end if;   -- 00 is the written international prefix

  select d.dial, d.nsn_len into dial, lens
    from public.phone_dial_codes d
   where d.country = lower(btrim(coalesce(p_country, '')));

  if dial is not null then
    -- already international for that country: the code, then a national number of the right length
    if left(n, length(dial)) = dial and (length(n) - length(dial)) = any (lens) then
      return n;
    end if;
    -- written locally: trunk zero, then a national number of the right length
    if left(n, 1) = '0' then
      rest := substr(n, 2);
      if length(rest) = any (lens) then return dial || rest; end if;
      return n;            -- wrong length for this country: leave it alone, do not invent digits
    end if;
    -- written without the trunk zero, which is how the Gulf states write theirs
    if length(n) = any (lens) then return dial || n; end if;
  end if;

  -- no country, or a country we do not know: the rule from 20261061, unchanged
  if n ~ '^0(50|52|54|55|56|58)[0-9]{7}$' then return '971' || substr(n, 2); end if;
  if length(n) >= 7 then return n; end if;
  return null;
end $$;
revoke execute on function public.crm_normalize_phone(text, text) from public, anon;
grant  execute on function public.crm_normalize_phone(text, text) to authenticated, service_role;

-- ---------- 3. the trigger: one place, every writer ----------
create or replace function public.crm_contacts_phone_display()
returns trigger language plpgsql set search_path = '' as $$
begin
  if new.phone is not null then
    new.phone_norm := public.crm_normalize_phone(new.phone, new.country);
  end if;
  -- E.164 for display only when it can be one: no country code begins with zero (20261069)
  if new.phone_norm ~ '^[1-9][0-9]{9,14}$' then new.phone := '+' || new.phone_norm; end if;
  return new;
end $$;

drop trigger if exists crm_contacts_phone_display on public.crm_contacts;
create trigger crm_contacts_phone_display
  before insert or update of phone, phone_norm, country on public.crm_contacts
  for each row execute function public.crm_contacts_phone_display();

-- ---------- 4. the lookup has to normalise the same way as the write ----------
create or replace function public.crm_link_contact(p_name text, p_contact text, p_city text default null,
                                                   p_country text default null, p_at timestamptz default now(),
                                                   p_created_by text default null)
returns uuid language plpgsql security definer set search_path = '' as $$
declare em text; ph text; ids uuid[]; cid uuid; review boolean := false;
begin
  em := public.crm_normalize_email(p_contact);
  ph := case when em is null then public.crm_normalize_phone(p_contact, p_country) else null end;

  if em is not null then
    select array_agg(id order by first_seen_at nulls last, id) into ids
      from public.crm_contacts where email_norm = em;
    if coalesce(array_length(ids, 1), 0) > 0 then
      cid := ids[1];
      review := array_length(ids, 1) > 1;
    end if;
  end if;

  if cid is null and ph is not null then
    select array_agg(id order by first_seen_at nulls last, id) into ids
      from public.crm_contacts where phone_norm = ph;
    if coalesce(array_length(ids, 1), 0) > 0 then
      cid := ids[1];
      review := array_length(ids, 1) > 1;
    end if;
  end if;

  if cid is null then
    insert into public.crm_contacts (display_name, email, email_norm, phone, phone_norm, city, country, needs_review, first_seen_at, last_activity_at, created_by)
    values (nullif(btrim(coalesce(p_name, '')), ''),
            case when em is not null then btrim(p_contact) end, em,
            case when ph is not null then btrim(p_contact) end, ph,
            nullif(btrim(coalesce(p_city, '')), ''), nullif(btrim(coalesce(p_country, '')), ''),
            false, p_at, p_at, p_created_by)
    returning id into cid;
  else
    update public.crm_contacts set
      last_activity_at = greatest(last_activity_at, p_at),
      first_seen_at    = least(first_seen_at, p_at),
      display_name     = coalesce(display_name, nullif(btrim(coalesce(p_name, '')), '')),
      city             = coalesce(city, nullif(btrim(coalesce(p_city, '')), '')),
      country          = coalesce(country, nullif(btrim(coalesce(p_country, '')), '')),
      phone            = case when phone is null and ph is not null then btrim(p_contact) else phone end,
      phone_norm       = coalesce(phone_norm, ph),
      email            = case when email is null and em is not null then btrim(p_contact) else email end,
      email_norm       = coalesce(email_norm, em),
      needs_review     = needs_review or review
    where id = cid;
  end if;
  return cid;
end $$;
revoke execute on function public.crm_link_contact(text, text, text, text, timestamptz, text) from public, anon, authenticated;
grant  execute on function public.crm_link_contact(text, text, text, text, timestamptz, text) to service_role;

-- ---------- 5. backfill, with every change written down ----------
with candidates as (
  select id, phone, phone_norm, country,
         public.crm_normalize_phone(phone, country) as fixed
    from public.crm_contacts
   where phone is not null and country is not null
),
changed as (
  select * from candidates
   where fixed is not null and fixed <> phone_norm and fixed ~ '^[1-9][0-9]{9,14}$'
),
audited as (
  insert into public.admin_audit (area, entity_id, action, changed_by, summary)
  select 'crm_contact', id::text, 'phone:normalised-by-country', 'migration:20261070',
         jsonb_build_object('country', country, 'from', phone_norm, 'to', fixed)
    from changed
  returning 1
)
update public.crm_contacts c
   set phone_norm = ch.fixed
  from changed ch
 where c.id = ch.id;

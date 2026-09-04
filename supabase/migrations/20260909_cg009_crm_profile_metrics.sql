-- =============================================================
-- CG-009 — CRM canonical model, client profile, notes, body metrics
--
-- An enquiry (public.contacts) is a submission, not a person. This adds a
-- canonical person model (crm_contacts) that many enquiries and many
-- bookings link to, plus internal notes, longitudinal body measurements
-- (with a DERIVED BMI), and an admin audit trail.
--
-- Principles honoured:
--  * Enquiry history stays immutable: contacts rows are never rewritten;
--    a crm_contact_id link is added and back-filled.
--  * Conservative matching: exact normalised email, then exact normalised
--    phone, each only when a SINGLE unambiguous contact exists; never a
--    fuzzy name merge. Ambiguity creates a new contact flagged for review.
--  * Sensitive data is independently permissionable: client_profile:* for
--    the profile/notes, health_metrics:* for measurements. finance:* /
--    analytics:* never imply access to either.
--  * BMI is derived, never typed: a generated column from the weight and
--    the height snapshot taken at measurement time (historical BMI stays
--    reproducible). No medical interpretation.
--  * Writes go through permission-checked SECURITY DEFINER RPCs; the tables
--    have no direct insert/update/delete grant for authenticated; anon has
--    nothing. Meaningful changes are audited (who / what / when).
-- =============================================================

-- ---------- 1. permissions ----------
alter table public.app_permissions drop constraint if exists app_permissions_permission_check;
alter table public.app_permissions add constraint app_permissions_permission_check
  check (permission in ('coach:operations','finance:view','finance:manage','analytics:view','platform:admin',
                        'catalog:view','catalog:manage',
                        'client_profile:view','client_profile:manage','health_metrics:view','health_metrics:manage'));

-- ---------- 2. normalisation helpers ----------
create or replace function public.crm_normalize_email(t text)
returns text language sql immutable set search_path = '' as $$
  select case when lower(btrim(coalesce(t,''))) ~ '^[^@\s]+@[^@\s]+\.[^@\s]{2,}$' then lower(btrim(t)) else null end
$$;
create or replace function public.crm_normalize_phone(t text)
returns text language sql immutable set search_path = '' as $$
  select case when length(regexp_replace(coalesce(t,''), '\D', '', 'g')) >= 7 then regexp_replace(t, '\D', '', 'g') else null end
$$;
revoke execute on function public.crm_normalize_email(text), public.crm_normalize_phone(text) from public, anon;

-- ---------- 3. canonical person ----------
create table if not exists public.crm_contacts (
  id                 uuid primary key default gen_random_uuid(),
  display_name       text,
  email              text,
  email_norm         text,
  phone              text,
  phone_norm         text,
  city               text,
  country            text,
  preferred_timezone text,
  preferred_language text,
  goals              text,
  height_cm          numeric(5,1) check (height_cm is null or height_cm between 50 and 260),
  status             text not null default 'lead' check (status in ('lead','active','past','archived')),
  needs_review       boolean not null default false,   -- ambiguous match: a human can merge later
  first_seen_at      timestamptz not null default now(),
  last_activity_at   timestamptz not null default now(),
  created_by         text,
  updated_by         text,
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now()
);
create index if not exists crm_contacts_email_idx on public.crm_contacts (email_norm) where email_norm is not null;
create index if not exists crm_contacts_phone_idx on public.crm_contacts (phone_norm) where phone_norm is not null;
create index if not exists crm_contacts_activity_idx on public.crm_contacts (last_activity_at desc);
drop trigger if exists crm_contacts_updated_at on public.crm_contacts;
create trigger crm_contacts_updated_at before update on public.crm_contacts for each row execute function public.set_updated_at();

-- Conservative link/create. Runs as owner (definer) so triggers and the
-- service role can maintain the CRM regardless of the caller's RLS.
create or replace function public.crm_link_contact(
  p_name text, p_contact text, p_city text default null, p_country text default null,
  p_at timestamptz default now(), p_created_by text default null)
returns uuid language plpgsql security definer set search_path = '' as $$
declare em text; ph text; ids uuid[]; cid uuid; review boolean := false;
begin
  em := public.crm_normalize_email(p_contact);
  ph := case when em is null then public.crm_normalize_phone(p_contact) else null end;
  if em is not null then
    select array_agg(id) into ids from public.crm_contacts where email_norm = em;
    if array_length(ids,1) = 1 then cid := ids[1];
    elsif coalesce(array_length(ids,1),0) > 1 then review := true; end if;
  end if;
  if cid is null and ph is not null then
    select array_agg(id) into ids from public.crm_contacts where phone_norm = ph;
    if array_length(ids,1) = 1 then cid := ids[1];
    elsif coalesce(array_length(ids,1),0) > 1 then review := true; end if;
  end if;
  if cid is null then
    insert into public.crm_contacts (display_name, email, email_norm, phone, phone_norm, city, country, needs_review, first_seen_at, last_activity_at, created_by)
    values (nullif(btrim(coalesce(p_name,'')),''),
            case when em is not null then btrim(p_contact) end, em,
            case when ph is not null then btrim(p_contact) end, ph,
            nullif(btrim(coalesce(p_city,'')),''), nullif(btrim(coalesce(p_country,'')),''),
            review, p_at, p_at, p_created_by)
    returning id into cid;
  else
    update public.crm_contacts set
      last_activity_at = greatest(last_activity_at, p_at),
      first_seen_at    = least(first_seen_at, p_at),
      display_name     = coalesce(display_name, nullif(btrim(coalesce(p_name,'')),'')),
      city             = coalesce(city, nullif(btrim(coalesce(p_city,'')),'')),
      country          = coalesce(country, nullif(btrim(coalesce(p_country,'')),'')),
      phone            = case when phone is null and ph is not null then btrim(p_contact) else phone end,
      phone_norm       = coalesce(phone_norm, ph),
      email            = case when email is null and em is not null then btrim(p_contact) else email end,
      email_norm       = coalesce(email_norm, em)
    where id = cid;
  end if;
  return cid;
end $$;
revoke execute on function public.crm_link_contact(text, text, text, text, timestamptz, text) from public, anon, authenticated;
grant  execute on function public.crm_link_contact(text, text, text, text, timestamptz, text) to service_role;

-- ---------- 4. link enquiries + bookings to the canonical person ----------
alter table public.contacts add column if not exists crm_contact_id uuid references public.crm_contacts(id);
alter table public.bookings add column if not exists crm_contact_id uuid references public.crm_contacts(id);
grant select (crm_contact_id) on public.contacts to authenticated;
grant select (crm_contact_id) on public.bookings to authenticated;

create or replace function public.contacts_link_crm() returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if new.crm_contact_id is null then
    new.crm_contact_id := public.crm_link_contact(new.name, new.contact, new.city, new.country, coalesce(new.created_at, now()));
  end if;
  return new;
end $$;
drop trigger if exists contacts_link_crm on public.contacts;
create trigger contacts_link_crm before insert on public.contacts for each row execute function public.contacts_link_crm();

create or replace function public.bookings_link_crm() returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if new.crm_contact_id is null then
    new.crm_contact_id := public.crm_link_contact(new.customer_name, new.customer_contact, null, null, coalesce(new.created_at, now()));
  end if;
  return new;
end $$;
drop trigger if exists bookings_link_crm on public.bookings;
create trigger bookings_link_crm before insert on public.bookings for each row execute function public.bookings_link_crm();

-- back-fill existing history in chronological order (first source creates, later ones match)
do $$ declare r record; cid uuid; begin
  for r in select id, name, contact, city, country, created_at from public.contacts order by created_at, id loop
    cid := public.crm_link_contact(r.name, r.contact, r.city, r.country, r.created_at);
    update public.contacts set crm_contact_id = cid where id = r.id;
  end loop;
  for r in select id, customer_name, customer_contact, created_at from public.bookings order by created_at, id loop
    cid := public.crm_link_contact(r.customer_name, r.customer_contact, null, null, r.created_at);
    update public.bookings set crm_contact_id = cid where id = r.id;
  end loop;
end $$;

-- ---------- 5. internal notes (history, not one overwriteable field) ----------
create table if not exists public.crm_notes (
  id             uuid primary key default gen_random_uuid(),
  crm_contact_id uuid not null references public.crm_contacts(id) on delete cascade,
  body           text not null check (btrim(body) <> ''),
  category       text check (category is null or category in ('general','session','goal','admin')),
  pinned         boolean not null default false,
  author         text not null,
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now()
);
create index if not exists crm_notes_contact_idx on public.crm_notes (crm_contact_id, pinned desc, created_at desc);
drop trigger if exists crm_notes_updated_at on public.crm_notes;
create trigger crm_notes_updated_at before update on public.crm_notes for each row execute function public.set_updated_at();

-- ---------- 6. longitudinal body measurements (derived BMI) ----------
create table if not exists public.body_measurements (
  id                 uuid primary key default gen_random_uuid(),
  crm_contact_id     uuid not null references public.crm_contacts(id) on delete cascade,
  measured_at        date not null default current_date,
  height_cm_snapshot numeric(5,1) check (height_cm_snapshot is null or height_cm_snapshot between 50 and 260),
  weight_kg          numeric(5,1) check (weight_kg is null or weight_kg between 20 and 500),
  body_fat_pct       numeric(4,1) check (body_fat_pct is null or body_fat_pct between 1 and 75),
  muscle_pct         numeric(4,1) check (muscle_pct is null or muscle_pct between 1 and 80),
  bmi                numeric(5,1) generated always as (
                       case when weight_kg is not null and height_cm_snapshot is not null and height_cm_snapshot > 0
                            then round(weight_kg / power(height_cm_snapshot / 100.0, 2), 1) else null end) stored,
  source             text,
  note               text,
  created_by         text,
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now(),
  constraint body_measurements_has_metric check (weight_kg is not null or body_fat_pct is not null or muscle_pct is not null)
);
create index if not exists body_measurements_contact_idx on public.body_measurements (crm_contact_id, measured_at desc, created_at desc);
drop trigger if exists body_measurements_updated_at on public.body_measurements;
create trigger body_measurements_updated_at before update on public.body_measurements for each row execute function public.set_updated_at();

-- ---------- 7. admin audit ----------
create table if not exists public.admin_audit (
  id          uuid primary key default gen_random_uuid(),
  area        text not null check (area in ('crm_contact','crm_note','body_measurement','permission')),
  entity_id   text,
  action      text not null,
  changed_by  text not null,
  changed_at  timestamptz not null default now(),
  summary     jsonb not null default '{}'::jsonb
);
create index if not exists admin_audit_area_idx on public.admin_audit (area, changed_at desc);

-- ---------- 8. RLS + read grants (writes are RPC-only) ----------
alter table public.crm_contacts       enable row level security;
alter table public.crm_notes          enable row level security;
alter table public.body_measurements  enable row level security;
alter table public.admin_audit        enable row level security;
revoke all on public.crm_contacts, public.crm_notes, public.body_measurements, public.admin_audit from anon, authenticated;

grant select on public.crm_contacts to authenticated;
drop policy if exists crm_contacts_view on public.crm_contacts;
create policy crm_contacts_view on public.crm_contacts for select to authenticated using (public.has_permission('client_profile:view'));

grant select on public.crm_notes to authenticated;
drop policy if exists crm_notes_view on public.crm_notes;
create policy crm_notes_view on public.crm_notes for select to authenticated using (public.has_permission('client_profile:view'));

grant select on public.body_measurements to authenticated;
drop policy if exists body_measurements_view on public.body_measurements;
create policy body_measurements_view on public.body_measurements for select to authenticated using (public.has_permission('health_metrics:view'));

grant select on public.admin_audit to authenticated;
drop policy if exists admin_audit_view on public.admin_audit;
create policy admin_audit_view on public.admin_audit for select to authenticated
  using (public.has_permission('platform:admin') or (area <> 'permission' and public.has_permission('client_profile:view')));

-- ---------- 9. write RPCs (permission-checked, audited) ----------
create or replace function public.crm_save_contact(p jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare e text := public.current_email(); id uuid := nullif(p ->> 'id','')::uuid; before jsonb; row public.crm_contacts%rowtype; changed text[];
begin
  if not public.has_permission('client_profile:manage') then raise exception 'forbidden' using errcode = '42501'; end if;
  if coalesce(btrim(p ->> 'display_name'),'') = '' then raise exception 'display name is required' using errcode = '22023'; end if;
  if p ? 'status' and (p ->> 'status') not in ('lead','active','past','archived') then raise exception 'invalid status' using errcode = '22023'; end if;
  if id is not null then
    select * into row from public.crm_contacts where id = id for update;
    if not found then raise exception 'contact not found' using errcode = 'P0002'; end if;
    before := to_jsonb(row);
    update public.crm_contacts set
      display_name = btrim(p ->> 'display_name'),
      email = nullif(btrim(coalesce(p ->> 'email','')),''), email_norm = public.crm_normalize_email(p ->> 'email'),
      phone = nullif(btrim(coalesce(p ->> 'phone','')),''), phone_norm = public.crm_normalize_phone(p ->> 'phone'),
      city = nullif(btrim(coalesce(p ->> 'city','')),''), country = nullif(btrim(coalesce(p ->> 'country','')),''),
      preferred_timezone = nullif(btrim(coalesce(p ->> 'preferred_timezone','')),''),
      preferred_language = nullif(btrim(coalesce(p ->> 'preferred_language','')),''),
      goals = nullif(btrim(coalesce(p ->> 'goals','')),''),
      height_cm = nullif(p ->> 'height_cm','')::numeric,
      status = coalesce(nullif(p ->> 'status',''), status),
      needs_review = coalesce((p ->> 'needs_review')::boolean, needs_review),
      updated_by = e
    where id = row.id returning * into row;
    changed := array(select k from jsonb_object_keys(to_jsonb(row)) k where to_jsonb(row) -> k is distinct from before -> k and k not in ('updated_at'));
  else
    insert into public.crm_contacts (display_name, email, email_norm, phone, phone_norm, city, country,
                                     preferred_timezone, preferred_language, goals, height_cm, status, created_by, updated_by)
    values (btrim(p ->> 'display_name'),
            nullif(btrim(coalesce(p ->> 'email','')),''), public.crm_normalize_email(p ->> 'email'),
            nullif(btrim(coalesce(p ->> 'phone','')),''), public.crm_normalize_phone(p ->> 'phone'),
            nullif(btrim(coalesce(p ->> 'city','')),''), nullif(btrim(coalesce(p ->> 'country','')),''),
            nullif(btrim(coalesce(p ->> 'preferred_timezone','')),''), nullif(btrim(coalesce(p ->> 'preferred_language','')),''),
            nullif(btrim(coalesce(p ->> 'goals','')),''), nullif(p ->> 'height_cm','')::numeric,
            coalesce(nullif(p ->> 'status',''),'lead'), e, e)
    returning * into row;
    changed := array['created'];
  end if;
  insert into public.admin_audit (area, entity_id, action, changed_by, summary)
  values ('crm_contact', row.id::text, case when id is null then 'create' else 'update' end, e,
          jsonb_build_object('changed', to_jsonb(changed)));
  return to_jsonb(row);
end $$;

create or replace function public.crm_add_note(p_contact_id uuid, p_body text, p_category text default null, p_pinned boolean default false)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare e text := public.current_email(); row public.crm_notes%rowtype;
begin
  if not public.has_permission('client_profile:manage') then raise exception 'forbidden' using errcode = '42501'; end if;
  if coalesce(btrim(p_body),'') = '' then raise exception 'note body is required' using errcode = '22023'; end if;
  insert into public.crm_notes (crm_contact_id, body, category, pinned, author)
  values (p_contact_id, btrim(p_body), nullif(p_category,''), coalesce(p_pinned,false), e) returning * into row;
  insert into public.admin_audit (area, entity_id, action, changed_by, summary)
  values ('crm_note', row.id::text, 'create', e, jsonb_build_object('contact', p_contact_id));
  return to_jsonb(row);
end $$;

create or replace function public.crm_edit_note(p_note_id uuid, p_body text, p_pinned boolean default null, p_category text default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare e text := public.current_email(); before public.crm_notes%rowtype; row public.crm_notes%rowtype;
begin
  if not public.has_permission('client_profile:manage') then raise exception 'forbidden' using errcode = '42501'; end if;
  select * into before from public.crm_notes where id = p_note_id for update;
  if not found then raise exception 'note not found' using errcode = 'P0002'; end if;
  if coalesce(btrim(p_body),'') = '' then raise exception 'note body is required' using errcode = '22023'; end if;
  update public.crm_notes set body = btrim(p_body),
         pinned = coalesce(p_pinned, pinned),
         category = coalesce(nullif(p_category,''), category)
   where id = p_note_id returning * into row;
  insert into public.admin_audit (area, entity_id, action, changed_by, summary)
  values ('crm_note', row.id::text, 'update', e, jsonb_build_object('before_body', before.body, 'after_body', row.body));
  return to_jsonb(row);
end $$;

create or replace function public.metrics_add(
  p_contact_id uuid, p_measured_at date default current_date, p_weight numeric default null,
  p_body_fat numeric default null, p_muscle numeric default null, p_height numeric default null,
  p_source text default null, p_note text default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare e text := public.current_email(); snap numeric; row public.body_measurements%rowtype;
begin
  if not public.has_permission('health_metrics:manage') then raise exception 'forbidden' using errcode = '42501'; end if;
  if p_weight is null and p_body_fat is null and p_muscle is null then raise exception 'record at least one of weight, body fat or muscle' using errcode = '22023'; end if;
  snap := coalesce(p_height, (select height_cm from public.crm_contacts where id = p_contact_id));
  insert into public.body_measurements (crm_contact_id, measured_at, height_cm_snapshot, weight_kg, body_fat_pct, muscle_pct, source, note, created_by)
  values (p_contact_id, coalesce(p_measured_at, current_date), snap, p_weight, p_body_fat, p_muscle, nullif(p_source,''), nullif(p_note,''), e)
  returning * into row;
  -- a supplied height updates the current profile height only for a profile manager
  if p_height is not null and public.has_permission('client_profile:manage') then
    update public.crm_contacts set height_cm = p_height, updated_by = e where id = p_contact_id;
  end if;
  insert into public.admin_audit (area, entity_id, action, changed_by, summary)
  values ('body_measurement', row.id::text, 'create', e, jsonb_build_object('contact', p_contact_id, 'bmi', row.bmi));
  return to_jsonb(row);
end $$;

create or replace function public.metrics_edit(
  p_id uuid, p_measured_at date default null, p_weight numeric default null, p_body_fat numeric default null,
  p_muscle numeric default null, p_height numeric default null, p_source text default null, p_note text default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare e text := public.current_email(); before public.body_measurements%rowtype; row public.body_measurements%rowtype;
begin
  if not public.has_permission('health_metrics:manage') then raise exception 'forbidden' using errcode = '42501'; end if;
  select * into before from public.body_measurements where id = p_id for update;
  if not found then raise exception 'measurement not found' using errcode = 'P0002'; end if;
  update public.body_measurements set
    measured_at = coalesce(p_measured_at, measured_at),
    weight_kg = coalesce(p_weight, weight_kg),
    body_fat_pct = coalesce(p_body_fat, body_fat_pct),
    muscle_pct = coalesce(p_muscle, muscle_pct),
    height_cm_snapshot = coalesce(p_height, height_cm_snapshot),
    source = coalesce(nullif(p_source,''), source),
    note = coalesce(nullif(p_note,''), note)
  where id = p_id returning * into row;
  insert into public.admin_audit (area, entity_id, action, changed_by, summary)
  values ('body_measurement', row.id::text, 'update', e,
          jsonb_build_object('before', jsonb_build_object('weight', before.weight_kg, 'bmi', before.bmi),
                             'after',  jsonb_build_object('weight', row.weight_kg,   'bmi', row.bmi)));
  return to_jsonb(row);
end $$;

revoke execute on function public.crm_save_contact(jsonb), public.crm_add_note(uuid, text, text, boolean),
  public.crm_edit_note(uuid, text, boolean, text),
  public.metrics_add(uuid, date, numeric, numeric, numeric, numeric, text, text),
  public.metrics_edit(uuid, date, numeric, numeric, numeric, numeric, text, text) from public, anon;
grant execute on function public.crm_save_contact(jsonb), public.crm_add_note(uuid, text, text, boolean),
  public.crm_edit_note(uuid, text, boolean, text),
  public.metrics_add(uuid, date, numeric, numeric, numeric, numeric, text, text),
  public.metrics_edit(uuid, date, numeric, numeric, numeric, numeric, text, text) to authenticated, service_role;

-- ---------- 10. CRM contacts list with counts (client_profile:view) ----------
create or replace function public.crm_list_contacts(p_search text default null)
returns table (
  id uuid, display_name text, email text, phone text, city text, country text, status text,
  needs_review boolean, main_interest text, enquiry_count bigint, booking_count bigint,
  first_seen_at timestamptz, last_activity_at timestamptz)
language plpgsql stable security definer set search_path = '' as $$
begin
  if not public.has_permission('client_profile:view') then raise exception 'forbidden' using errcode = '42501'; end if;
  return query
    select c.id, c.display_name, c.email, c.phone, c.city, c.country, c.status, c.needs_review,
           (select ct.interest from public.contacts ct where ct.crm_contact_id = c.id and ct.interest is not null
              order by ct.created_at desc limit 1) as main_interest,
           (select count(*) from public.contacts ct where ct.crm_contact_id = c.id) as enquiry_count,
           (select count(*) from public.bookings b where b.crm_contact_id = c.id) as booking_count,
           c.first_seen_at, c.last_activity_at
    from public.crm_contacts c
    where p_search is null or btrim(p_search) = ''
       or c.display_name ilike '%' || p_search || '%'
       or c.email ilike '%' || p_search || '%'
       or c.phone ilike '%' || p_search || '%'
       or c.city ilike '%' || p_search || '%'
       or c.country ilike '%' || p_search || '%'
    order by c.last_activity_at desc
    limit 500;
end $$;
revoke execute on function public.crm_list_contacts(text) from public, anon;
grant  execute on function public.crm_list_contacts(text) to authenticated, service_role;

-- ---------- 11. lightweight overview (authorised cards only) ----------
create or replace function public.admin_overview()
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare out jsonb := '{}'::jsonb;
begin
  if public.has_permission('coach:operations') then
    out := out || jsonb_build_object('operations', jsonb_build_object(
      'new_leads_7d', (select count(*) from public.contacts where created_at >= now() - interval '7 days'),
      'today_sessions', (select count(*) from public.bookings where status = 'confirmed' and start_at::date = current_date),
      'upcoming_bookings', (select count(*) from public.bookings where status in ('confirmed','pending_payment') and start_at >= now())));
  end if;
  if public.has_permission('finance:view') then
    out := out || jsonb_build_object('finance', jsonb_build_object(
      'pending_payment_orders', (select count(*) from public.orders where status = 'pending_payment'),
      'unsettled_payable', (select coalesce(sum(pe.gari_payable),0) from public.partner_earnings pe where pe.status = 'open')));
  end if;
  if public.has_permission('client_profile:view') then
    out := out || jsonb_build_object('crm', jsonb_build_object(
      'total_contacts', (select count(*) from public.crm_contacts),
      'needs_review', (select count(*) from public.crm_contacts where needs_review)));
  end if;
  return out || jsonb_build_object('generated_at', now());
end $$;
revoke execute on function public.admin_overview() from public, anon;
grant  execute on function public.admin_overview() to authenticated, service_role;

-- ---------- 12. lock the trigger functions (advisor 0028): triggers only ----------
revoke execute on function public.contacts_link_crm() from public, anon, authenticated;
revoke execute on function public.bookings_link_crm() from public, anon, authenticated;

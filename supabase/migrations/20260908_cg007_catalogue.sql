-- =============================================================
-- CG-007 — admin-editable commercial catalogue
--
-- Scope: the service catalogue only (no CMS, no site_content).
-- 1. catalog:view / catalog:manage permissions.
-- 2. services gains the presentation fields Route C needs so the cards
--    and the booking picker render from the database, not from HTML.
--    booking_mode: 'slot' = bookable in the picker, 'enquiry' = card with
--    an enquiry CTA. Historical rows keep working (defaults).
-- 3. Historical integrity: bookings snapshot slug / title / duration at
--    hold time (price was already snapshotted); orders snapshot the title.
--    finance_orders, booking_to_json and order_to_json read the snapshot.
-- 4. Auditability: every catalogue write goes through
--    catalog_save_service() (catalog:manage) which records who changed
--    which fields, before / after, in catalog_audit. No direct writes:
--    authenticated has no insert / update / delete grant on services;
--    anon has nothing. Services are never deleted — deactivate instead.
-- =============================================================

-- ---------- 1. permissions ----------
alter table public.app_permissions drop constraint if exists app_permissions_permission_check;
alter table public.app_permissions add constraint app_permissions_permission_check
  check (permission in ('coach:operations','finance:view','finance:manage','analytics:view','platform:admin','catalog:view','catalog:manage'));

-- ---------- 2. catalogue fields ----------
alter table public.services
  add column if not exists tagline          text,
  add column if not exists long_description text,
  add column if not exists price_unit       text not null default 'per session',
  add column if not exists features         text[] not null default '{}',
  add column if not exists featured         boolean not null default false,
  add column if not exists cta_label        text,
  add column if not exists updated_by       text;
alter table public.services drop constraint if exists services_category_check;
alter table public.services add constraint services_category_check
  check (category in ('coaching','mentoring','onsite','programme','group'));
alter table public.services drop constraint if exists services_booking_mode_check;
alter table public.services add constraint services_booking_mode_check
  check (booking_mode in ('slot','enquiry'));
alter table public.services drop constraint if exists services_price_unit_check;
alter table public.services add constraint services_price_unit_check
  check (price_unit in ('per session','per month','one-off','per person'));
alter table public.services drop constraint if exists services_features_check;
alter table public.services add constraint services_features_check
  check (coalesce(array_length(features, 1), 0) <= 8);

-- readable in full (listed or not) by the catalogue permission; other parties keep their label-only read
drop policy if exists services_catalog_view on public.services;
create policy services_catalog_view on public.services for select to authenticated
  using (public.has_permission('catalog:view'));

-- ---------- 3. commercial snapshots ----------
alter table public.bookings
  add column if not exists service_slug             text,
  add column if not exists service_title            text,
  add column if not exists service_duration_minutes int;
update public.bookings b
   set service_slug = s.slug, service_title = s.title, service_duration_minutes = s.duration_minutes
  from public.services s
 where s.id = b.service_id and b.service_title is null;
grant select (service_slug, service_title, service_duration_minutes) on public.bookings to authenticated;

alter table public.orders add column if not exists service_title text;
update public.orders o set service_title = b.service_title
  from public.bookings b where b.id = o.booking_id and o.service_title is null;

create or replace function public.create_hold(
  p_service_slug text, p_start_at timestamptz, p_participants int, p_idempotency_key uuid,
  p_customer_name text, p_customer_contact text,
  p_tour_stop_slug text default null, p_notes text default null, p_ip_hash text default null
) returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare
  s     public.services%rowtype;
  ts    public.tour_stops%rowtype;
  b     public.bookings%rowtype;
  slot  record;
  v_ref text; v_token text; v_end timestamptz; v_mode text; v_day date;
begin
  if p_idempotency_key is null then
    raise exception 'idempotency_key required' using errcode = '22023';
  end if;

  select * into b from public.bookings where idempotency_key = p_idempotency_key;
  if found then return public.booking_to_json(b); end if;

  if p_participants is null or p_participants < 1 or p_participants > 100 then
    raise exception 'invalid participant count' using errcode = '22023';
  end if;
  if coalesce(btrim(p_customer_name), '') = '' or coalesce(btrim(p_customer_contact), '') = '' then
    raise exception 'name and contact are required' using errcode = '22023';
  end if;
  if p_start_at is null then raise exception 'start_at required' using errcode = '22023'; end if;

  -- only a bookable, active service; enquiry-only products never reach a hold
  select * into s from public.services where slug = p_service_slug and active and booking_mode = 'slot';
  if not found then raise exception 'unknown or inactive service' using errcode = 'P0002'; end if;

  if p_tour_stop_slug is not null then
    select * into ts from public.tour_stops where slug = p_tour_stop_slug and status = 'open';
    if not found then raise exception 'tour stop not open' using errcode = 'P0002'; end if;
  end if;

  perform pg_advisory_xact_lock(hashtext('booking:' || s.id::text));

  v_day := (p_start_at at time zone 'UTC')::date;
  select * into slot
  from public.available_slots(s.slug, v_day - 1, v_day + 1, 'UTC') a
  where a.start_at = p_start_at
    and a.tour_stop_id is not distinct from ts.id
  limit 1;
  if not found then raise exception 'slot not available' using errcode = 'P0003'; end if;
  if slot.remaining < p_participants then raise exception 'insufficient capacity' using errcode = 'P0003'; end if;

  v_end   := p_start_at + make_interval(mins => s.duration_minutes);
  v_mode  := case when ts.id is not null then 'tour' else s.delivery_mode end;
  v_token := encode(extensions.gen_random_bytes(24), 'hex');
  loop
    v_ref := 'CG-' || upper(substr(encode(extensions.gen_random_bytes(4), 'hex'), 1, 6));
    exit when not exists (select 1 from public.bookings where reference = v_ref);
  end loop;

  -- commercial snapshot: what was sold, at the moment it was sold
  insert into public.bookings (
    reference, service_id, contact_id, customer_name, customer_contact,
    start_at, end_at, session_timezone, tour_stop_id, delivery_mode, participant_count,
    status, hold_expires_at, idempotency_key, manage_token, price_amount, currency, notes, ip_hash,
    service_slug, service_title, service_duration_minutes
  ) values (
    v_ref, s.id,
    (select c.id from public.contacts c where c.contact = btrim(p_customer_contact) order by c.created_at desc limit 1),
    btrim(p_customer_name), btrim(p_customer_contact),
    p_start_at, v_end, slot.session_timezone, ts.id, v_mode, p_participants,
    'hold', now() + interval '10 minutes', p_idempotency_key, v_token,
    case when s.price_amount is null then null else s.price_amount * p_participants end,
    s.currency, nullif(btrim(coalesce(p_notes, '')), ''), p_ip_hash,
    s.slug, s.title, s.duration_minutes
  ) returning * into b;

  return public.booking_to_json(b);
exception when unique_violation then
  select * into b from public.bookings where idempotency_key = p_idempotency_key;
  if found then return public.booking_to_json(b); end if;
  raise;
end $$;

create or replace function public.booking_to_json(b public.bookings)
returns jsonb language sql stable set search_path = '' as $$
  select jsonb_build_object(
    'reference', b.reference,
    'manage_token', b.manage_token,
    'status', b.status,
    'start_at', b.start_at,
    'end_at', b.end_at,
    'session_timezone', b.session_timezone,
    'local_start', to_char(b.start_at at time zone b.session_timezone, 'YYYY-MM-DD"T"HH24:MI'),
    'delivery_mode', b.delivery_mode,
    'participant_count', b.participant_count,
    'hold_expires_at', b.hold_expires_at,
    'price_amount', b.price_amount,
    'currency', b.currency,
    'customer_name', b.customer_name,
    'created_at', b.created_at,
    'service', (select jsonb_build_object('slug', coalesce(b.service_slug, s.slug), 'title', coalesce(b.service_title, s.title),
                                          'duration_minutes', coalesce(b.service_duration_minutes, s.duration_minutes),
                                          'delivery_mode', s.delivery_mode)
                from public.services s where s.id = b.service_id),
    'tour_stop', (select jsonb_build_object('slug', t.slug, 'city', t.city, 'country', t.country,
                                            'timezone', t.timezone, 'venue', t.venue, 'address', t.address,
                                            'location_notes', t.location_notes)
                  from public.tour_stops t where t.id = b.tour_stop_id),
    'order', (select jsonb_build_object('reference', o.reference, 'status', o.status, 'gross_amount', o.gross_amount,
                                        'currency', o.currency, 'paid_at', o.paid_at,
                                        'checkout_expires_at', o.checkout_expires_at)
              from public.orders o where o.booking_id = b.id
              order by (o.status in ('pending_payment','paid','partially_refunded','refunded')) desc, o.created_at desc
              limit 1)
  )
$$;

create or replace function public.order_to_json(o public.orders)
returns jsonb language sql stable set search_path = '' as $$
  select jsonb_build_object(
    'reference', o.reference, 'status', o.status, 'gross_amount', o.gross_amount, 'currency', o.currency,
    'checkout_url', o.checkout_url, 'checkout_expires_at', o.checkout_expires_at, 'checkout_attempts', o.checkout_attempts,
    'paid_at', o.paid_at, 'customer_name', o.customer_name, 'customer_contact', o.customer_contact,
    'booking', (select jsonb_build_object('reference', b.reference, 'start_at', b.start_at, 'session_timezone', b.session_timezone,
                                          'hold_expires_at', b.hold_expires_at, 'status', b.status,
                                          'service_title', coalesce(o.service_title, b.service_title,
                                                                    (select s.title from public.services s where s.id = b.service_id)))
                from public.bookings b where b.id = o.booking_id)
  )
$$;

create or replace function public.create_order_for_booking(p_reference text, p_manage_token text)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare b public.bookings%rowtype; o public.orders%rowtype; v_ref text;
begin
  select * into b from public.bookings where reference = upper(p_reference) and manage_token = p_manage_token for update;
  if not found then raise exception 'booking not found' using errcode = 'P0002'; end if;
  if b.status in ('hold','pending_payment') and b.hold_expires_at < now() then
    update public.bookings set status = 'expired' where id = b.id;
    raise exception 'hold expired' using errcode = 'P0003';
  end if;
  if b.status not in ('hold','pending_payment') then
    raise exception 'booking not payable in status %', b.status using errcode = 'P0003';
  end if;
  if b.price_amount is null then raise exception 'priced on request' using errcode = 'P0003'; end if;

  select * into o from public.orders where booking_id = b.id and status = 'pending_payment';
  if found then return public.order_to_json(o); end if;

  loop
    v_ref := 'OR-' || upper(substr(encode(extensions.gen_random_bytes(4), 'hex'), 1, 6));
    exit when not exists (select 1 from public.orders where reference = v_ref);
  end loop;
  -- amount, currency and title come from the booking's snapshot, never from the caller or the live catalogue
  insert into public.orders (reference, booking_id, customer_name, customer_contact, currency, gross_amount, status, service_title)
  values (v_ref, b.id, b.customer_name, b.customer_contact, b.currency, b.price_amount, 'pending_payment',
          coalesce(b.service_title, (select s.title from public.services s where s.id = b.service_id)))
  returning * into o;
  return public.order_to_json(o);
end $$;

drop function if exists public.finance_orders();
create function public.finance_orders()
returns table (
  id uuid, reference text, status text, currency text, gross_amount int, paid_at timestamptz, created_at timestamptz, stripe_checkout_session_id text,
  booking_reference text, session_start_at timestamptz, session_timezone text, booking_status text, delivery_mode text,
  service_slug text, service_title text, customer_hint text,
  stripe_fee int, refund_amount int, chargeback_amount int, net_collected int, oolala_commission int, gari_payable int,
  earning_status text, settlement_id uuid, adjusted_at timestamptz)
language plpgsql stable security definer set search_path = '' as $$
begin
  if not public.has_permission('finance:view') then raise exception 'forbidden' using errcode = '42501'; end if;
  return query
    select o.id, o.reference, o.status, o.currency, o.gross_amount, o.paid_at, o.created_at, o.stripe_checkout_session_id,
           b.reference, b.start_at, b.session_timezone, b.status, b.delivery_mode,
           coalesce(b.service_slug, s.slug), coalesce(o.service_title, b.service_title, s.title),
           public.mask_contact(b.customer_contact),
           pe.stripe_fee, pe.refund_amount, pe.chargeback_amount, pe.net_collected, pe.oolala_commission, pe.gari_payable,
           pe.status, pe.settlement_id, pe.adjusted_at
    from public.orders o
    join public.bookings b on b.id = o.booking_id
    left join public.services s on s.id = b.service_id
    left join public.partner_earnings pe on pe.order_id = o.id
    order by o.created_at desc;
end $$;
revoke execute on function public.finance_orders() from public, anon;
grant  execute on function public.finance_orders() to authenticated, service_role;

-- ---------- 4. audit + write RPC ----------
create table if not exists public.catalog_audit (
  id             uuid primary key default gen_random_uuid(),
  service_id     uuid not null references public.services(id),
  slug           text not null,
  action         text not null check (action in ('create','update')),
  changed_by     text not null,
  changed_at     timestamptz not null default now(),
  changed_fields text[] not null,
  before         jsonb,
  after          jsonb not null
);
create index if not exists catalog_audit_service_idx on public.catalog_audit (service_id, changed_at desc);
alter table public.catalog_audit enable row level security;
revoke all on public.catalog_audit from anon, authenticated;
grant select on public.catalog_audit to authenticated;
drop policy if exists catalog_audit_view on public.catalog_audit;
create policy catalog_audit_view on public.catalog_audit for select to authenticated
  using (public.has_permission('catalog:view'));

create or replace function public.service_commercial_json(s public.services)
returns jsonb language sql immutable set search_path = '' as $$
  select jsonb_build_object(
    'slug', s.slug, 'title', s.title, 'category', s.category, 'tagline', s.tagline,
    'description', s.description, 'long_description', s.long_description,
    'duration_minutes', s.duration_minutes, 'price_amount', s.price_amount, 'currency', s.currency, 'price_unit', s.price_unit,
    'delivery_mode', s.delivery_mode, 'default_capacity', s.default_capacity, 'booking_mode', s.booking_mode,
    'features', to_jsonb(s.features), 'featured', s.featured, 'cta_label', s.cta_label,
    'active', s.active, 'listed', s.listed, 'sort_order', s.sort_order)
$$;

-- The only write path. Creates (new slug) or updates (existing slug, immutable
-- identity). Table constraints validate values; unchanged saves write no audit row.
create or replace function public.catalog_save_service(p jsonb)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare
  e text := public.current_email();
  v_slug text := lower(btrim(coalesce(p ->> 'slug', '')));
  old_row public.services%rowtype; new_row public.services%rowtype;
  v_before jsonb; v_after jsonb; v_changed text[]; k text;
  v_features text[];
begin
  if not public.has_permission('catalog:manage') then raise exception 'forbidden' using errcode = '42501'; end if;
  if v_slug !~ '^[a-z0-9-]{2,60}$' then raise exception 'slug: lowercase letters, digits and dashes only' using errcode = '22023'; end if;
  if coalesce(btrim(p ->> 'title'), '') = '' then raise exception 'title is required' using errcode = '22023'; end if;
  if p ? 'features' and jsonb_typeof(p -> 'features') = 'array' then
    select coalesce(array_agg(btrim(x) order by ord), '{}') into v_features
      from jsonb_array_elements_text(p -> 'features') with ordinality t(x, ord) where btrim(x) <> '';
  else v_features := '{}';
  end if;

  select * into old_row from public.services where slug = v_slug for update;
  if found then
    v_before := public.service_commercial_json(old_row);
    update public.services set
      title            = btrim(p ->> 'title'),
      category         = coalesce(p ->> 'category', category),
      tagline          = nullif(btrim(coalesce(p ->> 'tagline', '')), ''),
      description      = nullif(btrim(coalesce(p ->> 'description', '')), ''),
      long_description = nullif(btrim(coalesce(p ->> 'long_description', '')), ''),
      duration_minutes = coalesce((p ->> 'duration_minutes')::int, duration_minutes),
      price_amount     = case when p ? 'price_amount' then nullif(p ->> 'price_amount', '')::int else price_amount end,
      currency         = upper(coalesce(nullif(p ->> 'currency', ''), currency)),
      price_unit       = coalesce(nullif(p ->> 'price_unit', ''), price_unit),
      delivery_mode    = coalesce(p ->> 'delivery_mode', delivery_mode),
      default_capacity = coalesce((p ->> 'default_capacity')::int, default_capacity),
      booking_mode     = coalesce(p ->> 'booking_mode', booking_mode),
      features         = case when p ? 'features' then v_features else features end,
      featured         = coalesce((p ->> 'featured')::boolean, featured),
      cta_label        = nullif(btrim(coalesce(p ->> 'cta_label', '')), ''),
      active           = coalesce((p ->> 'active')::boolean, active),
      listed           = coalesce((p ->> 'listed')::boolean, listed),
      sort_order       = coalesce((p ->> 'sort_order')::int, sort_order),
      updated_by       = e
    where id = old_row.id returning * into new_row;
  else
    insert into public.services (slug, title, category, tagline, description, long_description, duration_minutes, price_amount, currency, price_unit,
                                 delivery_mode, default_capacity, booking_mode, features, featured, cta_label, active, listed, sort_order, updated_by)
    values (v_slug, btrim(p ->> 'title'), coalesce(p ->> 'category', 'coaching'),
            nullif(btrim(coalesce(p ->> 'tagline', '')), ''), nullif(btrim(coalesce(p ->> 'description', '')), ''), nullif(btrim(coalesce(p ->> 'long_description', '')), ''),
            coalesce((p ->> 'duration_minutes')::int, 60), nullif(p ->> 'price_amount', '')::int, upper(coalesce(nullif(p ->> 'currency', ''), 'USD')),
            coalesce(nullif(p ->> 'price_unit', ''), 'per session'),
            coalesce(p ->> 'delivery_mode', 'online'), coalesce((p ->> 'default_capacity')::int, 1), coalesce(p ->> 'booking_mode', 'enquiry'),
            v_features, coalesce((p ->> 'featured')::boolean, false), nullif(btrim(coalesce(p ->> 'cta_label', '')), ''),
            coalesce((p ->> 'active')::boolean, false), coalesce((p ->> 'listed')::boolean, false), coalesce((p ->> 'sort_order')::int, 100), e)
    returning * into new_row;
  end if;

  v_after := public.service_commercial_json(new_row);
  select coalesce(array_agg(key order by key), '{}') into v_changed
    from jsonb_each(v_after) a(key, value)
   where v_before is null or (v_before -> key) is distinct from value;
  if v_before is not null and coalesce(array_length(v_changed, 1), 0) = 0 then
    return jsonb_build_object('slug', v_slug, 'changed', '[]'::jsonb, 'service', v_after);
  end if;
  insert into public.catalog_audit (service_id, slug, action, changed_by, changed_fields, before, after)
  values (new_row.id, v_slug, case when v_before is null then 'create' else 'update' end, e, v_changed, v_before, v_after);
  return jsonb_build_object('slug', v_slug, 'changed', to_jsonb(v_changed), 'service', v_after);
end $$;

revoke execute on function public.catalog_save_service(jsonb), public.service_commercial_json(public.services) from public, anon;
grant  execute on function public.catalog_save_service(jsonb) to authenticated, service_role;
grant  execute on function public.service_commercial_json(public.services) to authenticated, service_role;

-- ---------- 5. Route C cards move into the catalogue ----------
-- The three non-bookable offers previously hard-coded in index.html (same
-- copy and figures as the page), as enquiry products. Prices of enquiry
-- products stay hidden on the site while CONFIG.COMMERCE is false.
insert into public.services (slug, title, category, tagline, description, duration_minutes, price_amount, currency, price_unit,
                             delivery_mode, default_capacity, booking_mode, features, featured, active, listed, sort_order)
values
  ('programme-12w', 'The Programme', 'programme', 'Self-guided',
   'Twelve weeks of training and eating, on video. Yours to keep, run at your own pace.',
   60, 2900, 'USD', 'one-off', 'online', 1, 'enquiry',
   array['12-week training plan', 'Video demo for every move', 'Eating habits built in', 'Home version, no equipment'], false, true, true, 1),
  ('online-coaching', 'Online Coaching', 'coaching', 'Most popular',
   'One to one with me, live on video. A plan that changes as you do, and someone who notices when you stop.',
   60, 7900, 'USD', 'per month', 'online', 1, 'enquiry',
   array['2 live video sessions a month', 'Plan rewritten every month', 'Food sorted alongside training', 'WhatsApp check-ins between'], true, true, true, 2),
  ('live-group', 'Live Group Sessions', 'group', 'Together',
   'Train live with me and everyone else, twice a week. Camera on or off — nobody''s watching but me.',
   60, 1200, 'USD', 'per month', 'online', 20, 'enquiry',
   array['2 live classes a week', 'Replays if you miss one', 'No equipment needed', 'Cancel whenever'], false, true, true, 3)
on conflict (slug) do nothing;

-- The Conversation: presentation fields only; price (100 USD) and duration are untouched
update public.services
   set tagline    = coalesce(tagline, 'Mindset'),
       price_unit = 'per session',
       features   = case when coalesce(array_length(features, 1), 0) = 0
                         then array['60 minutes, one to one', 'Goals, habits, getting unstuck', 'One-off or monthly', 'No training plan required']
                         else features end
 where slug = 'conversation';

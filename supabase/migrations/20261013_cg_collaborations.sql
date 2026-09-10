-- =====================================================================
-- Coach Gari — Collaborations (brand / partnership deal room), V1
--
-- Public intake → private deal room (secure token) → immutable, versioned
-- proposals and counter-offers → explicit acceptance → optional monetary
-- payment through the EXISTING BEAU PH rails (no new rails) → Finance
-- visibility. Monetary and non-cash consideration are kept separate; non-cash
-- is never turned into a payment.
--
-- Reuse, not reinvention:
--   * secure token = 32 random bytes, only the sha256 hex is stored (report/consent pattern)
--   * CRM person via crm_link_contact (dedupe by email/phone; a collaboration never forces a coaching client)
--   * payment = a target-less order (order_reason 'collaboration', both FKs null) exactly like 'support',
--     driven through cg_ph_request_for_order → beau_ph.create_request (intent 'other'); the Stripe webhook
--     marks it paid. project_pack_payment is a no-op for a null pack; recompute_earning is kind-agnostic.
--   * emails go through the existing outbox (public.email_queue) and are sent by the pg_cron drain.
--
-- Additive, forward-only. Nothing here changes booking, pack, support or
-- commission logic.
-- =====================================================================

-- ---------- permissions + audit ----------
alter table public.app_permissions drop constraint if exists app_permissions_permission_check;
alter table public.app_permissions add constraint app_permissions_permission_check check (permission in (
  'coach:operations','finance:view','finance:manage','analytics:view','platform:admin',
  'catalog:view','catalog:manage','client_profile:view','client_profile:manage',
  'health_metrics:view','health_metrics:manage','coaching_sensitive:view','coaching_sensitive:manage',
  'collab:view','collab:manage'));

alter table public.admin_audit drop constraint if exists admin_audit_area_check;
alter table public.admin_audit add constraint admin_audit_area_check check (area in (
  'crm_contact','crm_note','body_measurement','permission','consent','merge','coaching_session',
  'session_pack','block','report','payment','payment_method','beau_ph_rail','beau_ph_fx',
  'settlement_destination','collaboration'));

-- Grant the launch coach the new permissions (Mickaël is provisioned operationally, see README).
insert into public.app_permissions (email, permission)
select 'grej28roux@gmail.com', p from unnest(array['collab:view','collab:manage']) p
on conflict do nothing;
insert into public.admin_audit (area, entity_id, action, changed_by, summary)
values ('permission', 'grej28roux@gmail.com', 'provision', 'migration:20261013', '{"collab":true}'::jsonb);

-- ---------- the Stripe rail opts in to the 'other' intent (collaboration payments map to it) ----------
do $$
begin
  perform beau_ph.merchant_method_configure('coach_gari', 'stripe',
    '{"intents":["service","package","support","other"]}'::jsonb, 'migration:20261013');
end $$;

-- ---------- order kind: collaboration is a target-less order, like support ----------
alter table public.orders drop constraint if exists orders_order_reason_check;
alter table public.orders add constraint orders_order_reason_check check (order_reason in ('booking','session_pack','support','collaboration'));
alter table public.orders drop constraint if exists orders_target_ck;
alter table public.orders add constraint orders_target_ck check (
  (order_reason = 'booking'       and booking_id is not null) or
  (order_reason = 'session_pack'  and session_pack_id is not null) or
  (order_reason = 'support'       and booking_id is null and session_pack_id is null) or
  (order_reason = 'collaboration' and booking_id is null and session_pack_id is null));

-- ---------- email kinds ----------
alter table public.email_events drop constraint if exists email_events_kind_check;
alter table public.email_events add constraint email_events_kind_check
  check (kind in ('booking_confirmed','payment_received','booking_cancelled','reminder','reschedule','session_link',
                  'payment_confirmed','support_thanks','enquiry_received','lead_notification',
                  'collab_received','collab_ack','collab_proposal','collab_counter','collab_accepted','collab_payment_ready'));

-- =====================================================================
--  Tables
-- =====================================================================
create table if not exists public.collaboration_deals (
  id                  uuid primary key default gen_random_uuid(),
  public_ref          text not null unique,
  crm_contact_id      uuid references public.crm_contacts(id),
  company             text,
  contact_name        text not null,
  contact_email       text,
  contact_phone       text,
  contact_url         text,
  collaboration_type  text not null check (collaboration_type in
                        ('brand_partnership','sponsored_content','event_appearance','corporate_activation',
                         'padel_sport','affiliate_ambassador','product_collaboration','other')),
  title               text,
  initial_request     text,
  proposed_date_from  date,
  proposed_date_to    date,
  location            text,
  intake_budget_amount   int check (intake_budget_amount is null or intake_budget_amount >= 0),
  intake_budget_currency text check (intake_budget_currency is null or intake_budget_currency ~ '^[A-Z]{3}$'),
  intake_offer        text,
  status              text not null default 'new' check (status in ('new','reviewing','negotiating','agreed','declined','closed')),
  accepted_proposal_id uuid,
  access_token_hash   text unique,
  token_revoked_at    timestamptz,
  source              text not null default 'public',
  created_by          text,
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now()
);
create index if not exists collaboration_deals_status_idx on public.collaboration_deals (status, updated_at desc);
create index if not exists collaboration_deals_crm_idx on public.collaboration_deals (crm_contact_id);

create table if not exists public.collaboration_proposals (
  id               uuid primary key default gen_random_uuid(),
  collaboration_id uuid not null references public.collaboration_deals(id) on delete cascade,
  version_number   int not null,
  proposed_by      text not null check (proposed_by in ('coach','counterparty')),
  intro            text,
  monetary_amount  int check (monetary_amount is null or monetary_amount >= 0),
  currency         text check (currency is null or currency ~ '^[A-Z]{3}$'),
  considerations   jsonb not null default '[]'::jsonb,   -- [{type:'monetary'|'non_cash', description, amount?, currency?, estimated_value?, estimated_value_currency?}]
  terms            jsonb not null default '{}'::jsonb,    -- {deliverables, timing, usage_rights, exclusivity, territory, payment_terms, additional}
  expires_at       timestamptz,
  accepted_evidence jsonb,
  created_by       text,
  created_at       timestamptz not null default now(),
  accepted_at      timestamptz,
  declined_at      timestamptz,
  superseded_at    timestamptz,
  unique (collaboration_id, version_number)
);
create index if not exists collaboration_proposals_deal_idx on public.collaboration_proposals (collaboration_id, version_number desc);

alter table public.collaboration_deals drop constraint if exists collaboration_deals_accepted_fk;
alter table public.collaboration_deals add constraint collaboration_deals_accepted_fk
  foreign key (accepted_proposal_id) references public.collaboration_proposals(id) on delete set null;

create table if not exists public.collaboration_payments (
  id               uuid primary key default gen_random_uuid(),
  collaboration_id uuid not null references public.collaboration_deals(id) on delete cascade,
  proposal_id      uuid references public.collaboration_proposals(id),
  label            text,
  amount           int not null check (amount > 0),
  currency         text not null check (currency ~ '^[A-Z]{3}$'),
  order_reference  text,
  public_reference text,
  status           text not null default 'requested' check (status in ('requested','checkout','paid','cancelled')),
  created_by       text,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now()
);
create index if not exists collaboration_payments_deal_idx on public.collaboration_payments (collaboration_id, created_at desc);
create index if not exists collaboration_payments_order_idx on public.collaboration_payments (order_reference);

create trigger collaboration_deals_updated_at before update on public.collaboration_deals for each row execute function public.set_updated_at();
create trigger collaboration_payments_updated_at before update on public.collaboration_payments for each row execute function public.set_updated_at();

-- ---------- RLS: read for collab:view; every write goes through a definer RPC ----------
alter table public.collaboration_deals     enable row level security;
alter table public.collaboration_proposals enable row level security;
alter table public.collaboration_payments  enable row level security;
revoke all on public.collaboration_deals, public.collaboration_proposals, public.collaboration_payments from anon, authenticated;
grant select on public.collaboration_deals, public.collaboration_proposals, public.collaboration_payments to authenticated;
drop policy if exists collaboration_deals_view on public.collaboration_deals;
create policy collaboration_deals_view on public.collaboration_deals for select to authenticated using (public.has_permission('collab:view'));
drop policy if exists collaboration_proposals_view on public.collaboration_proposals;
create policy collaboration_proposals_view on public.collaboration_proposals for select to authenticated using (public.has_permission('collab:view'));
drop policy if exists collaboration_payments_view on public.collaboration_payments;
create policy collaboration_payments_view on public.collaboration_payments for select to authenticated using (public.has_permission('collab:view'));

-- =====================================================================
--  Helpers
-- =====================================================================
create or replace function public.collab_new_ref() returns text language plpgsql volatile security definer set search_path = '' as $$
declare r text;
begin
  loop r := 'CL-' || upper(substr(encode(extensions.gen_random_bytes(4), 'hex'), 1, 6));
       exit when not exists (select 1 from public.collaboration_deals where public_ref = r); end loop;
  return r;
end $$;

-- Serialise one deal + latest proposal + history + payments for a viewer. p_admin=true exposes admin-only fields.
create or replace function public.collab_deal_json(p_id uuid, p_admin boolean default false)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare d public.collaboration_deals; latest public.collaboration_proposals; hist jsonb; pays jsonb; can_counter boolean;
begin
  select * into d from public.collaboration_deals where id = p_id;
  if not found then return null; end if;
  select * into latest from public.collaboration_proposals where collaboration_id = d.id order by version_number desc limit 1;
  select coalesce(jsonb_agg(jsonb_build_object(
           'version', pr.version_number, 'proposed_by', pr.proposed_by, 'intro', pr.intro,
           'monetary_amount', pr.monetary_amount, 'currency', pr.currency,
           'considerations', pr.considerations, 'terms', pr.terms, 'expires_at', pr.expires_at,
           'created_at', pr.created_at, 'accepted_at', pr.accepted_at, 'declined_at', pr.declined_at, 'superseded_at', pr.superseded_at
         ) order by pr.version_number desc), '[]'::jsonb)
    into hist from public.collaboration_proposals pr where pr.collaboration_id = d.id;
  select coalesce(jsonb_agg(jsonb_build_object(
           'id', cp.id, 'label', cp.label, 'amount', cp.amount, 'currency', cp.currency, 'status', cp.status,
           'public_reference', cp.public_reference,
           'order_status', (select o.status from public.orders o where o.reference = cp.order_reference),
           'created_at', cp.created_at
         ) order by cp.created_at desc), '[]'::jsonb)
    into pays from public.collaboration_payments cp where cp.collaboration_id = d.id;
  -- the counterparty may act when the latest proposal is the coach's, still live, and the deal is open
  can_counter := latest.id is not null and latest.proposed_by = 'coach'
                 and latest.accepted_at is null and latest.declined_at is null
                 and (latest.expires_at is null or latest.expires_at > now())
                 and d.status in ('new','reviewing','negotiating');
  return jsonb_strip_nulls(jsonb_build_object(
    'public_ref', d.public_ref, 'company', d.company, 'contact_name', d.contact_name,
    'collaboration_type', d.collaboration_type, 'title', d.title, 'initial_request', d.initial_request,
    'proposed_date_from', d.proposed_date_from, 'proposed_date_to', d.proposed_date_to, 'location', d.location,
    'status', d.status,
    'latest', case when latest.id is null then null else jsonb_build_object(
       'version', latest.version_number, 'proposed_by', latest.proposed_by, 'intro', latest.intro,
       'monetary_amount', latest.monetary_amount, 'currency', latest.currency,
       'considerations', latest.considerations, 'terms', latest.terms, 'expires_at', latest.expires_at,
       'accepted_at', latest.accepted_at, 'declined_at', latest.declined_at) end,
    'accepted_version', (select version_number from public.collaboration_proposals where id = d.accepted_proposal_id),
    'history', hist, 'payments', pays, 'can_counter', can_counter,
    -- admin-only extras (never exposed to the room)
    'id', case when p_admin then d.id::text else null end,
    'crm_contact_id', case when p_admin then d.crm_contact_id::text else null end,
    'contact_email', case when p_admin then d.contact_email else null end,
    'contact_phone', case when p_admin then d.contact_phone else null end,
    'contact_url', case when p_admin then d.contact_url else null end,
    'intake_budget_amount', case when p_admin then d.intake_budget_amount else null end,
    'intake_budget_currency', case when p_admin then d.intake_budget_currency else null end,
    'intake_offer', case when p_admin then d.intake_offer else null end,
    'token_revoked_at', case when p_admin then d.token_revoked_at else null end,
    'created_at', case when p_admin then d.created_at else null end));
end $$;

-- resolve a room token to a deal id, or raise (P0002 invalid, P0003 revoked)
create or replace function public.collab_deal_by_token(p_token text) returns uuid language plpgsql stable security definer set search_path = '' as $$
declare d public.collaboration_deals;
begin
  if p_token is null or p_token !~ '^[0-9a-f]{64}$' then raise exception 'invalid token' using errcode = 'P0002'; end if;
  select * into d from public.collaboration_deals where access_token_hash = encode(extensions.digest(p_token, 'sha256'), 'hex');
  if not found then raise exception 'invalid token' using errcode = 'P0002'; end if;
  if d.token_revoked_at is not null then raise exception 'this link is no longer active' using errcode = 'P0003'; end if;
  return d.id;
end $$;

-- =====================================================================
--  Public / edge RPCs (service_role only)
-- =====================================================================

-- Intake: create a deal + a private room. Returns the raw token ONCE.
create or replace function public.collab_intake(p jsonb)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare d public.collaboration_deals; tok text; cid uuid;
  v_name text := nullif(btrim(coalesce(p ->> 'name','')),'');
  v_email text := nullif(btrim(coalesce(p ->> 'email','')),'');
  v_phone text := nullif(btrim(coalesce(p ->> 'phone','')),'');
  v_type text := coalesce(p ->> 'type','other');
  v_amt int := nullif(p ->> 'budget_amount','')::int;
  v_ccy text := nullif(upper(coalesce(p ->> 'budget_currency','')),'');
begin
  if v_name is null then raise exception 'name is required' using errcode = '22023'; end if;
  if v_email is null and v_phone is null then raise exception 'an email or phone is required' using errcode = '22023'; end if;
  if v_type not in ('brand_partnership','sponsored_content','event_appearance','corporate_activation','padel_sport','affiliate_ambassador','product_collaboration','other') then v_type := 'other'; end if;
  if v_ccy is not null and v_ccy !~ '^[A-Z]{3}$' then v_ccy := null; end if;
  -- link (or create) the CRM person; a collaboration never forces a coaching client
  cid := public.crm_link_contact(v_name, coalesce(v_email, v_phone), nullif(btrim(coalesce(p ->> 'location','')),''), null, now(), 'collab');
  tok := encode(extensions.gen_random_bytes(32), 'hex');
  insert into public.collaboration_deals (public_ref, crm_contact_id, company, contact_name, contact_email, contact_phone, contact_url,
      collaboration_type, title, initial_request, proposed_date_from, proposed_date_to, location,
      intake_budget_amount, intake_budget_currency, intake_offer, status, access_token_hash, source, created_by)
  values (public.collab_new_ref(), cid, nullif(btrim(coalesce(p ->> 'company','')),''), v_name, v_email, v_phone,
      nullif(btrim(coalesce(p ->> 'url','')),''), v_type,
      nullif(left(btrim(coalesce(p ->> 'title','')), 200),''), nullif(left(btrim(coalesce(p ->> 'initial_request','')), 4000),''),
      nullif(p ->> 'date_from','')::date, nullif(p ->> 'date_to','')::date, nullif(left(btrim(coalesce(p ->> 'location','')),200),''),
      v_amt, v_ccy, nullif(left(btrim(coalesce(p ->> 'offer','')), 2000),''),
      'new', encode(extensions.digest(tok, 'sha256'), 'hex'), 'public', 'public')
  returning * into d;
  -- notify the owner + acknowledge the requester (sent by the outbox)
  perform public.email_queue('collab_received', public.email_owner_address(),
    jsonb_build_object('public_ref', d.public_ref, 'name', d.contact_name, 'company', d.company, 'type', d.collaboration_type, 'title', d.title, 'reply_to', d.contact_email),
    'collab:' || d.id || ':received', null, null, null);
  if d.contact_email is not null then
    perform public.email_queue('collab_ack', d.contact_email,
      jsonb_build_object('public_ref', d.public_ref, 'name', d.contact_name, 'title', d.title),
      'collab:' || d.id || ':ack', null, null, null);
  end if;
  insert into public.admin_audit (area, entity_id, action, changed_by, summary)
  values ('collaboration', d.id::text, 'intake', 'public', jsonb_build_object('public_ref', d.public_ref, 'type', d.collaboration_type));
  return jsonb_build_object('public_ref', d.public_ref, 'token', tok);
end $$;

-- Room view (counterparty). No admin internals, no private notes.
create or replace function public.collab_room(p_token text)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare did uuid;
begin
  did := public.collab_deal_by_token(p_token);
  return jsonb_build_object('ok', true) || public.collab_deal_json(did, false);
end $$;

-- Counter-offer from the room: a NEW immutable version, proposed_by 'counterparty'.
create or replace function public.collab_counter(p_token text, p jsonb)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare did uuid; d public.collaboration_deals; nextv int; pr public.collaboration_proposals;
  v_amt int := nullif(p ->> 'monetary_amount','')::int; v_ccy text := nullif(upper(coalesce(p ->> 'currency','')),'');
begin
  did := public.collab_deal_by_token(p_token);
  select * into d from public.collaboration_deals where id = did for update;
  if d.status not in ('new','reviewing','negotiating') then raise exception 'this collaboration is no longer open to changes' using errcode = 'P0003'; end if;
  if v_ccy is not null and v_ccy !~ '^[A-Z]{3}$' then raise exception 'invalid currency' using errcode = '22023'; end if;
  update public.collaboration_proposals set superseded_at = now()
   where collaboration_id = d.id and accepted_at is null and declined_at is null and superseded_at is null;
  select coalesce(max(version_number),0) + 1 into nextv from public.collaboration_proposals where collaboration_id = d.id;
  insert into public.collaboration_proposals (collaboration_id, version_number, proposed_by, intro, monetary_amount, currency, considerations, terms, created_by)
  values (d.id, nextv, 'counterparty', nullif(left(btrim(coalesce(p ->> 'intro','')),4000),''), v_amt, v_ccy,
          coalesce(p -> 'considerations', '[]'::jsonb), coalesce(p -> 'terms', '{}'::jsonb), 'counterparty')
  returning * into pr;
  update public.collaboration_deals set status = 'negotiating' where id = d.id;
  perform public.email_queue('collab_counter', public.email_owner_address(),
    jsonb_build_object('public_ref', d.public_ref, 'name', d.contact_name, 'version', nextv, 'monetary_amount', v_amt, 'currency', v_ccy),
    'collab:' || d.id || ':counter:' || nextv, null, null, null);
  insert into public.admin_audit (area, entity_id, action, changed_by, summary)
  values ('collaboration', d.id::text, 'counter', 'counterparty', jsonb_build_object('version', nextv));
  return jsonb_build_object('ok', true, 'version', nextv);
end $$;

-- Explicit acceptance from the room: freeze a specific coach proposal version. Idempotent.
create or replace function public.collab_accept(p_token text, p_version int, p_evidence jsonb default '{}'::jsonb)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare did uuid; d public.collaboration_deals; pr public.collaboration_proposals;
begin
  did := public.collab_deal_by_token(p_token);
  select * into d from public.collaboration_deals where id = did for update;
  select * into pr from public.collaboration_proposals where collaboration_id = d.id and version_number = p_version;
  if not found then raise exception 'proposal not found' using errcode = 'P0002'; end if;
  if d.status = 'agreed' and d.accepted_proposal_id = pr.id then return jsonb_build_object('ok', true, 'version', pr.version_number, 'already', true); end if;
  if d.status in ('agreed','declined','closed') then raise exception 'this collaboration is already settled' using errcode = 'P0003'; end if;
  if pr.proposed_by <> 'coach' then raise exception 'only Coach Gari''s proposal can be accepted here' using errcode = '22023'; end if;
  if pr.superseded_at is not null then raise exception 'a newer version exists' using errcode = 'P0003'; end if;
  if pr.expires_at is not null and pr.expires_at < now() then raise exception 'this proposal has expired' using errcode = 'P0003'; end if;
  update public.collaboration_proposals set accepted_at = now(),
         accepted_evidence = jsonb_strip_nulls(coalesce(p_evidence,'{}'::jsonb) || jsonb_build_object('by','counterparty','at', now()))
   where id = pr.id;
  update public.collaboration_deals set status = 'agreed', accepted_proposal_id = pr.id where id = d.id;
  perform public.email_queue('collab_accepted', public.email_owner_address(),
    jsonb_build_object('public_ref', d.public_ref, 'name', d.contact_name, 'version', pr.version_number, 'by', 'counterparty'),
    'collab:' || d.id || ':accepted', null, null, null);
  if d.contact_email is not null then
    perform public.email_queue('collab_accepted', d.contact_email,
      jsonb_build_object('public_ref', d.public_ref, 'name', d.contact_name, 'version', pr.version_number, 'by', 'you'),
      'collab:' || d.id || ':accepted:party', null, null, null);
  end if;
  insert into public.admin_audit (area, entity_id, action, changed_by, summary)
  values ('collaboration', d.id::text, 'accept', 'counterparty', jsonb_build_object('version', pr.version_number));
  return jsonb_build_object('ok', true, 'version', pr.version_number);
end $$;

-- Decline from the room.
create or replace function public.collab_decline(p_token text, p_reason text default null)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare did uuid; d public.collaboration_deals; pr public.collaboration_proposals;
begin
  did := public.collab_deal_by_token(p_token);
  select * into d from public.collaboration_deals where id = did for update;
  if d.status in ('agreed','declined','closed') then raise exception 'this collaboration is already settled' using errcode = 'P0003'; end if;
  select * into pr from public.collaboration_proposals where collaboration_id = d.id order by version_number desc limit 1;
  if found then update public.collaboration_proposals set declined_at = now() where id = pr.id; end if;
  update public.collaboration_deals set status = 'declined' where id = d.id;
  insert into public.admin_audit (area, entity_id, action, changed_by, summary)
  values ('collaboration', d.id::text, 'decline', 'counterparty', jsonb_strip_nulls(jsonb_build_object('reason', nullif(left(btrim(coalesce(p_reason,'')),300),''))));
  return jsonb_build_object('ok', true, 'status', 'declined');
end $$;

revoke all on function public.collab_intake(jsonb) from public, anon, authenticated;
revoke all on function public.collab_room(text) from public, anon, authenticated;
revoke all on function public.collab_counter(text, jsonb) from public, anon, authenticated;
revoke all on function public.collab_accept(text, int, jsonb) from public, anon, authenticated;
revoke all on function public.collab_decline(text, text) from public, anon, authenticated;
grant execute on function public.collab_intake(jsonb), public.collab_room(text), public.collab_counter(text, jsonb),
  public.collab_accept(text, int, jsonb), public.collab_decline(text, text) to service_role;

-- =====================================================================
--  Admin RPCs (collab:manage)
-- =====================================================================
create or replace function public.collab_admin_list(p_status text default null, p_search text default null)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare out jsonb; s text := nullif(btrim(coalesce(p_search,'')),'');
begin
  if not public.has_permission('collab:view') then raise exception 'forbidden' using errcode = '42501'; end if;
  select coalesce(jsonb_agg(row order by (row ->> 'updated_at') desc), '[]'::jsonb) into out from (
    select jsonb_build_object(
      'id', d.id, 'public_ref', d.public_ref, 'contact_name', d.contact_name, 'company', d.company,
      'collaboration_type', d.collaboration_type, 'title', d.title, 'status', d.status,
      'latest_amount', lp.monetary_amount, 'latest_currency', lp.currency,
      'updated_at', d.updated_at) as row
    from public.collaboration_deals d
    left join lateral (select monetary_amount, currency from public.collaboration_proposals p
                       where p.collaboration_id = d.id order by version_number desc limit 1) lp on true
    where (p_status is null or d.status = p_status)
      and (s is null or d.contact_name ilike '%'||s||'%' or d.company ilike '%'||s||'%' or d.public_ref ilike '%'||s||'%' or d.title ilike '%'||s||'%')
    order by d.updated_at desc limit 300) t;
  return out;
end $$;

create or replace function public.collab_admin_get(p_id uuid)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
begin
  if not public.has_permission('collab:view') then raise exception 'forbidden' using errcode = '42501'; end if;
  return public.collab_deal_json(p_id, true);
end $$;

-- Coach creates a new proposal / counter version (proposed_by 'coach').
create or replace function public.collab_propose(p_id uuid, p jsonb)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare e text := public.current_email(); d public.collaboration_deals; nextv int; pr public.collaboration_proposals;
  v_amt int := nullif(p ->> 'monetary_amount','')::int; v_ccy text := nullif(upper(coalesce(p ->> 'currency','')),'');
  v_exp timestamptz := nullif(p ->> 'expires_at','')::timestamptz;
begin
  if not public.has_permission('collab:manage') then raise exception 'forbidden' using errcode = '42501'; end if;
  select * into d from public.collaboration_deals where id = p_id for update;
  if not found then raise exception 'collaboration not found' using errcode = 'P0002'; end if;
  if d.status in ('agreed','declined','closed') then raise exception 'this collaboration is settled; reopen it first' using errcode = 'P0003'; end if;
  if v_ccy is not null and v_ccy !~ '^[A-Z]{3}$' then raise exception 'invalid currency' using errcode = '22023'; end if;
  update public.collaboration_proposals set superseded_at = now()
   where collaboration_id = d.id and accepted_at is null and declined_at is null and superseded_at is null;
  select coalesce(max(version_number),0) + 1 into nextv from public.collaboration_proposals where collaboration_id = d.id;
  insert into public.collaboration_proposals (collaboration_id, version_number, proposed_by, intro, monetary_amount, currency, considerations, terms, expires_at, created_by)
  values (d.id, nextv, 'coach', nullif(left(btrim(coalesce(p ->> 'intro','')),4000),''), v_amt, v_ccy,
          coalesce(p -> 'considerations', '[]'::jsonb), coalesce(p -> 'terms', '{}'::jsonb), v_exp, e)
  returning * into pr;
  update public.collaboration_deals set status = 'negotiating' where id = d.id;
  if d.contact_email is not null then
    perform public.email_queue('collab_proposal', d.contact_email,
      jsonb_build_object('public_ref', d.public_ref, 'name', d.contact_name, 'version', nextv, 'monetary_amount', v_amt, 'currency', v_ccy),
      'collab:' || d.id || ':proposal:' || nextv, null, null, null);
  end if;
  insert into public.admin_audit (area, entity_id, action, changed_by, summary)
  values ('collaboration', d.id::text, 'propose', e, jsonb_build_object('version', nextv));
  return jsonb_build_object('ok', true, 'version', nextv);
end $$;

-- Coach accepts the counterparty's latest counter-offer (symmetric to collab_accept). Idempotent.
create or replace function public.collab_admin_accept(p_id uuid, p_version int)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare e text := public.current_email(); d public.collaboration_deals; pr public.collaboration_proposals;
begin
  if not public.has_permission('collab:manage') then raise exception 'forbidden' using errcode = '42501'; end if;
  select * into d from public.collaboration_deals where id = p_id for update;
  if not found then raise exception 'collaboration not found' using errcode = 'P0002'; end if;
  select * into pr from public.collaboration_proposals where collaboration_id = d.id and version_number = p_version;
  if not found then raise exception 'proposal not found' using errcode = 'P0002'; end if;
  if d.status = 'agreed' and d.accepted_proposal_id = pr.id then return jsonb_build_object('ok', true, 'version', pr.version_number, 'already', true); end if;
  if d.status in ('agreed','declined','closed') then raise exception 'already settled' using errcode = 'P0003'; end if;
  if pr.superseded_at is not null then raise exception 'a newer version exists' using errcode = 'P0003'; end if;
  update public.collaboration_proposals set accepted_at = now(), accepted_evidence = jsonb_build_object('by','coach','actor',e,'at', now()) where id = pr.id;
  update public.collaboration_deals set status = 'agreed', accepted_proposal_id = pr.id where id = d.id;
  if d.contact_email is not null then
    perform public.email_queue('collab_accepted', d.contact_email,
      jsonb_build_object('public_ref', d.public_ref, 'name', d.contact_name, 'version', pr.version_number, 'by', 'Coach Gari'),
      'collab:' || d.id || ':accepted:coach', null, null, null);
  end if;
  insert into public.admin_audit (area, entity_id, action, changed_by, summary)
  values ('collaboration', d.id::text, 'accept', e, jsonb_build_object('version', pr.version_number));
  return jsonb_build_object('ok', true, 'version', pr.version_number);
end $$;

create or replace function public.collab_set_status(p_id uuid, p_status text)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare e text := public.current_email(); d public.collaboration_deals;
begin
  if not public.has_permission('collab:manage') then raise exception 'forbidden' using errcode = '42501'; end if;
  if p_status not in ('new','reviewing','negotiating','declined','closed') then raise exception 'invalid status' using errcode = '22023'; end if;
  update public.collaboration_deals set status = p_status where id = p_id returning * into d;
  if not found then raise exception 'collaboration not found' using errcode = 'P0002'; end if;
  insert into public.admin_audit (area, entity_id, action, changed_by, summary)
  values ('collaboration', d.id::text, 'status', e, jsonb_build_object('to', p_status));
  return jsonb_build_object('ok', true, 'status', d.status);
end $$;

-- Revoke / regenerate the room token. Regenerate returns a fresh raw token once.
create or replace function public.collab_revoke_token(p_id uuid)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare e text := public.current_email(); d public.collaboration_deals;
begin
  if not public.has_permission('collab:manage') then raise exception 'forbidden' using errcode = '42501'; end if;
  update public.collaboration_deals set token_revoked_at = now() where id = p_id returning * into d;
  if not found then raise exception 'collaboration not found' using errcode = 'P0002'; end if;
  insert into public.admin_audit (area, entity_id, action, changed_by, summary) values ('collaboration', d.id::text, 'revoke_token', e, '{}'::jsonb);
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.collab_regenerate_token(p_id uuid)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare e text := public.current_email(); d public.collaboration_deals; tok text;
begin
  if not public.has_permission('collab:manage') then raise exception 'forbidden' using errcode = '42501'; end if;
  tok := encode(extensions.gen_random_bytes(32), 'hex');
  update public.collaboration_deals set access_token_hash = encode(extensions.digest(tok,'sha256'),'hex'), token_revoked_at = null where id = p_id returning * into d;
  if not found then raise exception 'collaboration not found' using errcode = 'P0002'; end if;
  insert into public.admin_audit (area, entity_id, action, changed_by, summary) values ('collaboration', d.id::text, 'regenerate_token', e, '{}'::jsonb);
  return jsonb_build_object('ok', true, 'public_ref', d.public_ref, 'token', tok);
end $$;

-- Coach records a payment request for an AGREED deal. Monetary only; non-cash is never a payment.
create or replace function public.collab_payment_request(p_id uuid, p_amount int, p_currency text, p_label text default null)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare e text := public.current_email(); d public.collaboration_deals; cp public.collaboration_payments; cur text := upper(coalesce(p_currency,''));
begin
  if not public.has_permission('collab:manage') then raise exception 'forbidden' using errcode = '42501'; end if;
  select * into d from public.collaboration_deals where id = p_id;
  if not found then raise exception 'collaboration not found' using errcode = 'P0002'; end if;
  if d.status <> 'agreed' or d.accepted_proposal_id is null then raise exception 'agree the terms before requesting a payment' using errcode = 'P0003'; end if;
  if cur !~ '^[A-Z]{3}$' then raise exception 'currency required (ISO 4217)' using errcode = '22023'; end if;
  if p_amount is null or p_amount <= 0 then raise exception 'amount required' using errcode = '22023'; end if;
  insert into public.collaboration_payments (collaboration_id, proposal_id, label, amount, currency, status, created_by)
  values (d.id, d.accepted_proposal_id, nullif(left(btrim(coalesce(p_label,'')),120),''), p_amount, cur, 'requested', e)
  returning * into cp;
  if d.contact_email is not null then
    perform public.email_queue('collab_payment_ready', d.contact_email,
      jsonb_build_object('public_ref', d.public_ref, 'name', d.contact_name, 'amount', cp.amount, 'currency', cp.currency, 'label', cp.label),
      'collab:' || cp.id || ':payment_ready', null, null, null);
  end if;
  insert into public.admin_audit (area, entity_id, action, changed_by, summary)
  values ('collaboration', d.id::text, 'payment_request', e, jsonb_build_object('amount', cp.amount, 'currency', cp.currency, 'label', cp.label));
  return jsonb_build_object('ok', true, 'id', cp.id, 'amount', cp.amount, 'currency', cp.currency);
end $$;

revoke all on function public.collab_admin_list(text, text), public.collab_admin_get(uuid), public.collab_propose(uuid, jsonb),
  public.collab_admin_accept(uuid, int), public.collab_set_status(uuid, text), public.collab_revoke_token(uuid),
  public.collab_regenerate_token(uuid), public.collab_payment_request(uuid, int, text, text) from public, anon;
grant execute on function public.collab_admin_list(text, text), public.collab_admin_get(uuid), public.collab_propose(uuid, jsonb),
  public.collab_admin_accept(uuid, int), public.collab_set_status(uuid, text), public.collab_revoke_token(uuid),
  public.collab_regenerate_token(uuid), public.collab_payment_request(uuid, int, text, text) to authenticated, service_role;

-- =====================================================================
--  Payer RPCs (service_role): start checkout for a requested collaboration payment
-- =====================================================================
-- Mirrors support_create: a target-less collaboration order → BEAU PH request (intent 'other') → returns the
-- request for the edge function to build the Stripe embedded session. The amount is authoritative from the
-- coach's payment request; the payer only supplies their country for rail eligibility.
create or replace function public.collab_pay_start(p_token text, p_country text, p_runtime jsonb default '{}'::jsonb)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare did uuid; d public.collaboration_deals; cp public.collaboration_payments; o public.orders%rowtype; req jsonb; v_ref text; pub text;
  ctry text := upper(coalesce(p_country,'')); offered jsonb;
begin
  did := public.collab_deal_by_token(p_token);
  select * into d from public.collaboration_deals where id = did;
  select * into cp from public.collaboration_payments where collaboration_id = d.id and status in ('requested','checkout') order by created_at desc limit 1;
  if not found then raise exception 'no payment is awaiting' using errcode = 'P0002'; end if;
  if ctry !~ '^[A-Z]{2}$' then raise exception 'country required (ISO 3166-1 alpha-2)' using errcode = '22023'; end if;
  offered := beau_ph.eligible_currencies('coach_gari', ctry, p_runtime, null, 'customer', 'other');
  if not exists (select 1 from jsonb_array_elements(offered) c where c ->> 'currency' = cp.currency) then
    raise exception 'no payment method is available for % in %', cp.currency, ctry using errcode = '22023';
  end if;
  loop v_ref := 'OR-' || upper(substr(encode(extensions.gen_random_bytes(4), 'hex'), 1, 6)); exit when not exists (select 1 from public.orders where reference = v_ref); end loop;
  loop pub := 'CLP-' || upper(substr(encode(extensions.gen_random_bytes(4), 'hex'), 1, 6)); exit when not exists (select 1 from beau_ph.payment_requests where public_reference = pub); end loop;
  insert into public.orders (reference, booking_id, session_pack_id, order_reason, customer_name, customer_contact, currency, gross_amount, status, service_title)
  values (v_ref, null, null, 'collaboration', d.contact_name, coalesce(d.contact_email, 'n/a'), cp.currency, cp.amount, 'pending_payment', 'Collaboration ' || d.public_ref)
  returning * into o;
  req := public.cg_ph_request_for_order(o, 'stripe', p_runtime, false, null, null, null, ctry);
  if req is null or (req ->> 'id') is null then raise exception 'payment unavailable' using errcode = 'P0003'; end if;
  update beau_ph.payment_requests
     set public_reference = pub,
         metadata = metadata || jsonb_build_object('collaboration_ref', d.public_ref, 'collaboration_id', d.id,
                      'proposal_version', (select version_number from public.collaboration_proposals where id = cp.proposal_id),
                      'message', coalesce(cp.label, 'Collaboration ' || d.public_ref))
   where id = (req ->> 'id')::uuid;
  update public.collaboration_payments set order_reference = o.reference, public_reference = pub, status = 'checkout' where id = cp.id;
  req := beau_ph.request_json((select r from beau_ph.payment_requests r where r.id = (req ->> 'id')::uuid));
  return jsonb_build_object('request', req, 'order', jsonb_build_object('reference', o.reference, 'gross_amount', o.gross_amount, 'currency', o.currency));
end $$;

-- Keep the collaboration payment row in step with its order (paid / cancelled), called after a state change.
create or replace function public.collab_payment_sync(p_order_reference text)
returns void language plpgsql volatile security definer set search_path = '' as $$
declare o public.orders%rowtype;
begin
  select * into o from public.orders where reference = p_order_reference;
  if not found then return; end if;
  update public.collaboration_payments
     set status = case when o.status = 'paid' then 'paid' when o.status in ('cancelled','failed') then 'cancelled' else status end
   where order_reference = o.reference;
end $$;

revoke all on function public.collab_pay_start(text, text, jsonb), public.collab_payment_sync(text) from public, anon, authenticated;
grant execute on function public.collab_pay_start(text, text, jsonb), public.collab_payment_sync(text) to service_role;

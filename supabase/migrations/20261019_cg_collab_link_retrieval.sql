-- =====================================================================
-- Coach Gari — Collaborations: gate room-link retrieval, stop persisting links
--
-- The room token is encrypted at rest (20261016) and the operator SELECT grant
-- excludes the ciphertext (20261017), but a working room link still reached an
-- operator by two paths a column grant cannot cover:
--   * collab_deal_json(_, admin) returned room_url, so a collab:VIEW operator got
--     a live link through collab_admin_get;
--   * the outbox payload stored room_url in the clear in email_events, so the row
--     at rest carried an exploitable link.
-- On a surface where accept freezes a deal and pay charges a card, those links
-- are sensitive. This:
--   1. adds collab_copy_room_link(id) — collab:MANAGE only, SECURITY DEFINER,
--      decrypts the token, returns the URL and AUDITS the access. It is the only
--      way an operator obtains a link; collab:view can never reconstruct one.
--   2. removes room_url from collab_deal_json entirely.
--   3. stops persisting room_url in email_events: producers store the deal id
--      (collab_id) instead, and email_outbox_claim builds the URL at send time by
--      decrypting definer-side, so the outbox row at rest holds no link.
-- The room/counter/accept/pay flow and the existing encryption are untouched. The
-- intake still returns the raw token to the submitter (their own room); it is
-- never logged and only the hash + ciphertext are stored.
-- =====================================================================

-- 1. definer-only URL builder (owner-executable; reached only by the RPCs / claim below)
create or replace function public.collab_room_url(p_id uuid) returns text language sql stable security definer set search_path = '' as $$
  select case when d.room_token_enc is not null and d.token_revoked_at is null
              then 'https://coachgari28.com/c/' || public.collab_room_token(d) else null end
    from public.collaboration_deals d where d.id = p_id;
$$;
revoke all on function public.collab_room_url(uuid) from public, anon, authenticated, service_role;

-- 2. the ONE audited path an operator uses to obtain a link — collab:manage only
create or replace function public.collab_copy_room_link(p_id uuid)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare e text := public.current_email(); d public.collaboration_deals; url text;
begin
  if not public.has_permission('collab:manage') then raise exception 'forbidden' using errcode = '42501'; end if;
  select * into d from public.collaboration_deals where id = p_id;
  if not found then raise exception 'collaboration not found' using errcode = 'P0002'; end if;
  if d.token_revoked_at is not null or d.room_token_enc is null then
    raise exception 'no active room link; reset it first' using errcode = 'P0003';
  end if;
  url := public.collab_room_url(p_id);
  insert into public.admin_audit (area, entity_id, action, changed_by, summary)
  values ('collaboration', d.id::text, 'room_link_access', e, jsonb_build_object('public_ref', d.public_ref));
  return jsonb_build_object('ok', true, 'public_ref', d.public_ref, 'url', url);
end $$;
revoke all on function public.collab_copy_room_link(uuid) from public, anon;
grant execute on function public.collab_copy_room_link(uuid) to authenticated, service_role;

-- 3. collab_deal_json no longer exposes room_url on any path (admin or public).
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
    'id', case when p_admin then d.id::text else null end,
    'crm_contact_id', case when p_admin then d.crm_contact_id::text else null end,
    'contact_email', case when p_admin then d.contact_email else null end,
    'contact_phone', case when p_admin then d.contact_phone else null end,
    'contact_url', case when p_admin then d.contact_url else null end,
    'intake_budget_amount', case when p_admin then d.intake_budget_amount else null end,
    'intake_budget_currency', case when p_admin then d.intake_budget_currency else null end,
    'intake_offer', case when p_admin then d.intake_offer else null end,
    -- room_url removed: an operator obtains a link only through collab_copy_room_link (audited).
    -- room_active tells the admin UI whether a link exists, without ever exposing it.
    'room_active', case when p_admin then (d.room_token_enc is not null and d.token_revoked_at is null) else null end,
    'token_revoked_at', case when p_admin then d.token_revoked_at else null end,
    'created_at', case when p_admin then d.created_at else null end));
end $$;

-- 4. producers store the deal id, not a link. The URL is built at send time (step 5).
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
  cid := public.crm_link_contact(v_name, coalesce(v_email, v_phone), nullif(btrim(coalesce(p ->> 'location','')),''), null, now(), 'collab');
  tok := encode(extensions.gen_random_bytes(32), 'hex');
  insert into public.collaboration_deals (public_ref, crm_contact_id, company, contact_name, contact_email, contact_phone, contact_url,
      collaboration_type, title, initial_request, proposed_date_from, proposed_date_to, location,
      intake_budget_amount, intake_budget_currency, intake_offer, status, access_token_hash, room_token_enc, source, created_by)
  values (public.collab_new_ref(), cid, nullif(btrim(coalesce(p ->> 'company','')),''), v_name, v_email, v_phone,
      nullif(btrim(coalesce(p ->> 'url','')),''), v_type,
      nullif(left(btrim(coalesce(p ->> 'title','')), 200),''), nullif(left(btrim(coalesce(p ->> 'initial_request','')), 4000),''),
      nullif(p ->> 'date_from','')::date, nullif(p ->> 'date_to','')::date, nullif(left(btrim(coalesce(p ->> 'location','')),200),''),
      v_amt, v_ccy, nullif(left(btrim(coalesce(p ->> 'offer','')), 2000),''),
      'new', encode(extensions.digest(tok, 'sha256'), 'hex'), extensions.pgp_sym_encrypt(tok, public.collab_room_key()), 'public', 'public')
  returning * into d;
  perform public.email_queue('collab_received', public.email_owner_address(),
    jsonb_build_object('public_ref', d.public_ref, 'name', d.contact_name, 'company', d.company, 'type', d.collaboration_type, 'title', d.title, 'reply_to', d.contact_email),
    'collab:' || d.id || ':received', null, null, null);
  if d.contact_email is not null then
    perform public.email_queue('collab_ack', d.contact_email,
      jsonb_build_object('public_ref', d.public_ref, 'name', d.contact_name, 'title', d.title, 'collab_id', d.id),
      'collab:' || d.id || ':ack', null, null, null);
  end if;
  insert into public.admin_audit (area, entity_id, action, changed_by, summary)
  values ('collaboration', d.id::text, 'intake', 'public', jsonb_build_object('public_ref', d.public_ref, 'type', d.collaboration_type));
  return jsonb_build_object('public_ref', d.public_ref, 'token', tok);
end $$;

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
      jsonb_build_object('public_ref', d.public_ref, 'name', d.contact_name, 'version', nextv, 'monetary_amount', v_amt, 'currency', v_ccy, 'collab_id', d.id),
      'collab:' || d.id || ':proposal:' || nextv, null, null, null);
  end if;
  insert into public.admin_audit (area, entity_id, action, changed_by, summary)
  values ('collaboration', d.id::text, 'propose', e, jsonb_build_object('version', nextv));
  return jsonb_build_object('ok', true, 'version', nextv);
end $$;

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
      jsonb_build_object('public_ref', d.public_ref, 'name', d.contact_name, 'version', pr.version_number, 'by', 'you', 'collab_id', d.id),
      'collab:' || d.id || ':accepted:party', null, null, null);
  end if;
  insert into public.admin_audit (area, entity_id, action, changed_by, summary)
  values ('collaboration', d.id::text, 'accept', 'counterparty', jsonb_build_object('version', pr.version_number));
  return jsonb_build_object('ok', true, 'version', pr.version_number);
end $$;

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
      jsonb_build_object('public_ref', d.public_ref, 'name', d.contact_name, 'version', pr.version_number, 'by', 'Coach Gari', 'collab_id', d.id),
      'collab:' || d.id || ':accepted:coach', null, null, null);
  end if;
  insert into public.admin_audit (area, entity_id, action, changed_by, summary)
  values ('collaboration', d.id::text, 'accept', e, jsonb_build_object('version', pr.version_number));
  return jsonb_build_object('ok', true, 'version', pr.version_number);
end $$;

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
      jsonb_build_object('public_ref', d.public_ref, 'name', d.contact_name, 'amount', cp.amount, 'currency', cp.currency, 'label', cp.label, 'collab_id', d.id),
      'collab:' || cp.id || ':payment_ready', null, null, null);
  end if;
  insert into public.admin_audit (area, entity_id, action, changed_by, summary)
  values ('collaboration', d.id::text, 'payment_request', e, jsonb_build_object('amount', cp.amount, 'currency', cp.currency, 'label', cp.label));
  return jsonb_build_object('ok', true, 'id', cp.id, 'amount', cp.amount, 'currency', cp.currency);
end $$;

-- 5. the drain builds the room URL at send time, from collab_id, decrypting definer-side.
--    The stored outbox row never holds a link; a revoked link resolves to nothing.
drop function if exists public.email_outbox_claim(int, uuid, uuid, uuid);
create or replace function public.email_outbox_claim(p_limit int default 20, p_order_id uuid default null, p_booking_id uuid default null, p_contact_id uuid default null)
returns table (id uuid, kind text, to_address text, payload jsonb, dedupe_key text, attempts int)
language plpgsql volatile security definer set search_path = '' as $$
begin
  return query
  with due as (
    select e.id from public.email_events e
     where e.status = 'pending' and e.next_attempt_at <= now()
       and (p_order_id is null or e.order_id = p_order_id)
       and (p_booking_id is null or e.booking_id = p_booking_id)
       and (p_contact_id is null or e.contact_id = p_contact_id)
     order by e.created_at
     limit greatest(1, least(coalesce(p_limit, 20), 100))
     for update skip locked),
  leased as (
    update public.email_events e
       set attempts = e.attempts + 1, last_attempt_at = now(), next_attempt_at = now() + interval '2 minutes'
      from due where e.id = due.id
    returning e.id, e.kind, e.to_address, e.payload, e.dedupe_key, e.attempts)
  select l.id, l.kind, l.to_address,
         case when l.payload ? 'collab_id'
              then (l.payload - 'collab_id') || jsonb_strip_nulls(jsonb_build_object('room_url', public.collab_room_url((l.payload ->> 'collab_id')::uuid)))
              else l.payload end,
         l.dedupe_key, l.attempts
    from leased l;
end $$;
revoke execute on function public.email_outbox_claim(int, uuid, uuid, uuid) from public, anon, authenticated;
grant  execute on function public.email_outbox_claim(int, uuid, uuid, uuid) to service_role;

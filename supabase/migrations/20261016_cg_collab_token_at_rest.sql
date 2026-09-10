-- =====================================================================
-- Coach Gari — Collaborations: encrypt the room bearer token at rest
--
-- The room token was stored in plaintext (room_token) so producers could build
-- the room URL. Public access already validates against the SHA-256 hash
-- (access_token_hash) — that is unchanged. This removes the recoverable
-- plaintext at rest: the token is encrypted with pgcrypto (pgp_sym) under a key
-- held in Supabase Vault (project-managed, not in any table), and recovered
-- server-side only, by SECURITY DEFINER producers, to build the authorised room
-- URL. The key reader and the decryptor are executable by the function owner
-- only (no grant to anon / authenticated / service_role), so the token is never
-- reachable through a generic serializer, a client RPC, logs or analytics —
-- only the room URL it produces. Reset re-hashes and re-encrypts, so the
-- previous token stops working immediately. Minimal; the room design is unchanged.
-- =====================================================================

-- 1. a random encryption key in Vault (generated at apply time, never in the committed SQL)
do $$
begin
  if not exists (select 1 from vault.decrypted_secrets where name = 'collab_room_key') then
    perform vault.create_secret(encode(extensions.gen_random_bytes(32), 'hex'),
                                'collab_room_key', 'Collaboration room token encryption key (pgcrypto pgp_sym)');
  end if;
end $$;

-- 2. server-side-only key reader and token decryptor
create or replace function public.collab_room_key() returns text language sql stable security definer set search_path = '' as $$
  select decrypted_secret from vault.decrypted_secrets where name = 'collab_room_key' limit 1;
$$;
revoke all on function public.collab_room_key() from public, anon, authenticated, service_role;

alter table public.collaboration_deals add column if not exists room_token_enc bytea;

create or replace function public.collab_room_token(d public.collaboration_deals) returns text language sql stable security definer set search_path = '' as $$
  select case when d.room_token_enc is null then null
              else extensions.pgp_sym_decrypt(d.room_token_enc, public.collab_room_key()) end;
$$;
revoke all on function public.collab_room_token(public.collaboration_deals) from public, anon, authenticated, service_role;

-- 3. move any existing plaintext token into ciphertext, then drop the plaintext column
update public.collaboration_deals set room_token_enc = extensions.pgp_sym_encrypt(room_token, public.collab_room_key())
 where room_token is not null and room_token_enc is null;
alter table public.collaboration_deals drop column if exists room_token;

-- 4. producers encrypt on write and decrypt server-side for the URL only
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
      jsonb_build_object('public_ref', d.public_ref, 'name', d.contact_name, 'title', d.title, 'room_url', 'https://coachgari28.com/c/' || tok),
      'collab:' || d.id || ':ack', null, null, null);
  end if;
  insert into public.admin_audit (area, entity_id, action, changed_by, summary)
  values ('collaboration', d.id::text, 'intake', 'public', jsonb_build_object('public_ref', d.public_ref, 'type', d.collaboration_type));
  return jsonb_build_object('public_ref', d.public_ref, 'token', tok);
end $$;

create or replace function public.collab_regenerate_token(p_id uuid)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare e text := public.current_email(); d public.collaboration_deals; tok text;
begin
  if not public.has_permission('collab:manage') then raise exception 'forbidden' using errcode = '42501'; end if;
  tok := encode(extensions.gen_random_bytes(32), 'hex');
  update public.collaboration_deals set access_token_hash = encode(extensions.digest(tok,'sha256'),'hex'),
         room_token_enc = extensions.pgp_sym_encrypt(tok, public.collab_room_key()), token_revoked_at = null
   where id = p_id returning * into d;
  if not found then raise exception 'collaboration not found' using errcode = 'P0002'; end if;
  insert into public.admin_audit (area, entity_id, action, changed_by, summary) values ('collaboration', d.id::text, 'regenerate_token', e, '{}'::jsonb);
  return jsonb_build_object('ok', true, 'public_ref', d.public_ref, 'token', tok);
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
      jsonb_build_object('public_ref', d.public_ref, 'name', d.contact_name, 'version', nextv, 'monetary_amount', v_amt, 'currency', v_ccy,
                         'room_url', 'https://coachgari28.com/c/' || public.collab_room_token(d)),
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
      jsonb_build_object('public_ref', d.public_ref, 'name', d.contact_name, 'version', pr.version_number, 'by', 'you', 'room_url', 'https://coachgari28.com/c/' || public.collab_room_token(d)),
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
      jsonb_build_object('public_ref', d.public_ref, 'name', d.contact_name, 'version', pr.version_number, 'by', 'Coach Gari', 'room_url', 'https://coachgari28.com/c/' || public.collab_room_token(d)),
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
      jsonb_build_object('public_ref', d.public_ref, 'name', d.contact_name, 'amount', cp.amount, 'currency', cp.currency, 'label', cp.label,
                         'room_url', 'https://coachgari28.com/c/' || public.collab_room_token(d)),
      'collab:' || cp.id || ':payment_ready', null, null, null);
  end if;
  insert into public.admin_audit (area, entity_id, action, changed_by, summary)
  values ('collaboration', d.id::text, 'payment_request', e, jsonb_build_object('amount', cp.amount, 'currency', cp.currency, 'label', cp.label));
  return jsonb_build_object('ok', true, 'id', cp.id, 'amount', cp.amount, 'currency', cp.currency);
end $$;

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
    'room_url', case when p_admin and d.room_token_enc is not null and d.token_revoked_at is null then 'https://coachgari28.com/c/' || public.collab_room_token(d) else null end,
    'token_revoked_at', case when p_admin then d.token_revoked_at else null end,
    'created_at', case when p_admin then d.created_at else null end));
end $$;

-- =====================================================================
-- Coach Gari — P2: per-IP intake identity, and DB-side throttle / size caps
--
-- The collaboration intake had only an identity-independent back-stop, so a single
-- caller could fill the window on its own; and a counter-offer could carry an
-- unbounded considerations array / terms object straight into the room.
--
--  * collaboration_deals.ip_hash — the salted hash the edge computes (fail-closed:
--    no IP_HASH_SALT -> no identity -> the global back-stop alone). It is deliberately
--    NOT added to the column-scoped operator grant (20261017), so it stays invisible
--    to a collab:view operator exactly like the token columns. A value that is not a
--    64-hex digest is dropped rather than stored, so a raw address can never land here.
--  * collab_counter — caps (20 considerations, 8 KB of considerations/terms) and a
--    per-room throttle (10 counterparty versions per 10 minutes). Enforced in the
--    database so it holds even if a caller reaches the RPC another way.
-- =====================================================================

alter table public.collaboration_deals add column if not exists ip_hash text;
create index if not exists collaboration_deals_ip_hash_idx on public.collaboration_deals (ip_hash, created_at desc);

create or replace function public.collab_intake(p jsonb)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare d public.collaboration_deals; tok text; cid uuid;
  v_name text := nullif(btrim(coalesce(p ->> 'name','')),'');
  v_email text := nullif(btrim(coalesce(p ->> 'email','')),'');
  v_phone text := nullif(btrim(coalesce(p ->> 'phone','')),'');
  v_type text := coalesce(p ->> 'type','other');
  v_amt int := nullif(p ->> 'budget_amount','')::int;
  v_ccy text := nullif(upper(coalesce(p ->> 'budget_currency','')),'');
  v_ip text := nullif(btrim(coalesce(p ->> 'ip_hash','')),'');
begin
  if v_name is null then raise exception 'name is required' using errcode = '22023'; end if;
  if v_email is null and v_phone is null then raise exception 'an email or phone is required' using errcode = '22023'; end if;
  if v_type not in ('brand_partnership','sponsored_content','event_appearance','corporate_activation','padel_sport','affiliate_ambassador','product_collaboration','other') then v_type := 'other'; end if;
  if v_ccy is not null and v_ccy !~ '^[A-Z]{3}$' then v_ccy := null; end if;
  if v_ip is not null and v_ip !~ '^[0-9a-f]{64}$' then v_ip := null; end if;
  cid := public.crm_link_contact(v_name, coalesce(v_email, v_phone), nullif(btrim(coalesce(p ->> 'location','')),''), null, now(), 'collab');
  tok := encode(extensions.gen_random_bytes(32), 'hex');
  insert into public.collaboration_deals (public_ref, crm_contact_id, company, contact_name, contact_email, contact_phone, contact_url,
      collaboration_type, title, initial_request, proposed_date_from, proposed_date_to, location,
      intake_budget_amount, intake_budget_currency, intake_offer, status, access_token_hash, room_token_enc, ip_hash, source, created_by)
  values (public.collab_new_ref(), cid, nullif(btrim(coalesce(p ->> 'company','')),''), v_name, v_email, v_phone,
      nullif(btrim(coalesce(p ->> 'url','')),''), v_type,
      nullif(left(btrim(coalesce(p ->> 'title','')), 200),''), nullif(left(btrim(coalesce(p ->> 'initial_request','')), 4000),''),
      nullif(p ->> 'date_from','')::date, nullif(p ->> 'date_to','')::date, nullif(left(btrim(coalesce(p ->> 'location','')),200),''),
      v_amt, v_ccy, nullif(left(btrim(coalesce(p ->> 'offer','')), 2000),''),
      'new', encode(extensions.digest(tok, 'sha256'), 'hex'), extensions.pgp_sym_encrypt(tok, public.collab_room_key()), v_ip, 'public', 'public')
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

create or replace function public.collab_counter(p_token text, p jsonb)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare did uuid; d public.collaboration_deals; nextv int; pr public.collaboration_proposals; recent int;
  v_amt int := nullif(p ->> 'monetary_amount','')::int; v_ccy text := nullif(upper(coalesce(p ->> 'currency','')),'');
begin
  did := public.collab_deal_by_token(p_token);
  select * into d from public.collaboration_deals where id = did for update;
  if d.status not in ('new','reviewing','negotiating') then raise exception 'this collaboration is no longer open to changes' using errcode = 'P0003'; end if;
  if v_ccy is not null and v_ccy !~ '^[A-Z]{3}$' then raise exception 'invalid currency' using errcode = '22023'; end if;
  -- size caps: a room holds a negotiation, not a payload store
  if jsonb_typeof(coalesce(p -> 'considerations', '[]'::jsonb)) <> 'array'
     or jsonb_array_length(coalesce(p -> 'considerations', '[]'::jsonb)) > 20 then
    raise exception 'too many considerations (20 maximum)' using errcode = '22023';
  end if;
  if length(coalesce(p ->> 'considerations', '')) > 8000 or length(coalesce(p ->> 'terms', '')) > 8000 then
    raise exception 'the counter-offer is too large' using errcode = '22023';
  end if;
  -- throttle per room: a counterparty cannot spin versions in a loop
  select count(*) into recent from public.collaboration_proposals
   where collaboration_id = d.id and proposed_by = 'counterparty' and created_at > now() - interval '10 minutes';
  if recent >= 10 then raise exception 'too many changes just now; please try again shortly' using errcode = 'P0003'; end if;

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

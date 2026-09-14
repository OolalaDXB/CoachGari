-- =====================================================================
-- Coach Gari — Collaborations: the workflow, second pass
--
-- Four things the owner asked for, and nothing else:
--   1. Decline politely from the back-office. collab_admin_decline(id, note)
--      settles the deal as 'declined' and sends the requester one courteous
--      email (collab_declined) carrying an optional personal line. Until now
--      the admin could only Close, silently. A decline from the room now also
--      tells the owner (same kind, internal flavour).
--   2. Reminders. collab_reminders() runs once a day (pg_cron, 06:00 UTC =
--      10:00 Dubai) and queues ONE reminder per waiting thing, deduped by the
--      outbox key so a second run never re-sends:
--        · requester: a coach proposal awaiting their answer (3 days)
--        · requester: a requested payment still unpaid (3 days)
--        · owner:     a counter-offer, or a new enquiry, waiting on him (3 days)
--      Owner mails ride the existing push hook, so the phone buzzes too.
--   3. Intake fields are optional. Only a way to reply stays required: an
--      email or a phone. contact_name becomes nullable; the CRM link and the
--      emails fall back to the company, then to the email.
--   4. The admin list says whose move it is (waiting_on: you | them | payment)
--      and since when, so the colour of a row tells the story at a glance.
-- No new tables, no new rails. Two email kinds are added to the constraint.
-- =====================================================================

-- ---------- email kinds ----------
alter table public.email_events drop constraint if exists email_events_kind_check;
alter table public.email_events add constraint email_events_kind_check
  check (kind in ('booking_confirmed','payment_received','booking_cancelled','reminder','reschedule','session_link',
                  'payment_confirmed','support_thanks','enquiry_received','lead_notification',
                  'collab_received','collab_ack','collab_proposal','collab_counter','collab_accepted','collab_payment_ready',
                  'collab_declined','collab_reminder'));

-- ---------- 3. intake: everything optional but a reply channel ----------
alter table public.collaboration_deals alter column contact_name drop not null;

create or replace function public.collab_intake(p jsonb)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare d public.collaboration_deals; tok text; cid uuid;
  v_name text := nullif(left(btrim(coalesce(p ->> 'name','')),120),'');
  v_company text := nullif(left(btrim(coalesce(p ->> 'company','')),160),'');
  v_email text := nullif(btrim(coalesce(p ->> 'email','')),'');
  v_phone text := nullif(btrim(coalesce(p ->> 'phone','')),'');
  v_type text := coalesce(p ->> 'type','other');
  v_amt int := nullif(p ->> 'budget_amount','')::int;
  v_ccy text := nullif(upper(coalesce(p ->> 'budget_currency','')),'');
  v_ip text := nullif(btrim(coalesce(p ->> 'ip_hash','')),'');
  v_who text;   -- what we call them when no name was given: the company, else the email's local part
begin
  if v_email is null and v_phone is null then raise exception 'an email or phone is required' using errcode = '22023'; end if;
  if v_type not in ('brand_partnership','sponsored_content','event_appearance','corporate_activation','padel_sport','affiliate_ambassador','product_collaboration','other') then v_type := 'other'; end if;
  if v_ccy is not null and v_ccy !~ '^[A-Z]{3}$' then v_ccy := null; end if;
  if v_ip is not null and v_ip !~ '^[0-9a-f]{64}$' then v_ip := null; end if;
  v_who := coalesce(v_name, v_company, split_part(v_email, '@', 1), v_phone);
  cid := public.crm_link_contact(v_who, coalesce(v_email, v_phone), nullif(btrim(coalesce(p ->> 'location','')),''), null, now(), 'collab');
  tok := encode(extensions.gen_random_bytes(32), 'hex');
  insert into public.collaboration_deals (public_ref, crm_contact_id, company, contact_name, contact_email, contact_phone, contact_url,
      collaboration_type, title, initial_request, proposed_date_from, proposed_date_to, location,
      intake_budget_amount, intake_budget_currency, intake_offer, status, access_token_hash, room_token_enc, ip_hash, source, created_by)
  values (public.collab_new_ref(), cid, v_company, v_name, v_email, v_phone,
      nullif(btrim(coalesce(p ->> 'url','')),''), v_type,
      nullif(left(btrim(coalesce(p ->> 'title','')), 200),''), nullif(left(btrim(coalesce(p ->> 'initial_request','')), 4000),''),
      nullif(p ->> 'date_from','')::date, nullif(p ->> 'date_to','')::date, nullif(left(btrim(coalesce(p ->> 'location','')),200),''),
      v_amt, v_ccy, nullif(left(btrim(coalesce(p ->> 'offer','')), 2000),''),
      'new', encode(extensions.digest(tok, 'sha256'), 'hex'), extensions.pgp_sym_encrypt(tok, public.collab_room_key()), v_ip, 'public', 'public')
  returning * into d;
  perform public.email_queue('collab_received', public.email_owner_address(),
    jsonb_build_object('public_ref', d.public_ref, 'name', v_who, 'company', d.company, 'type', d.collaboration_type, 'title', d.title, 'reply_to', d.contact_email),
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

-- ---------- 1. decline, politely ----------
-- From the back-office: settle as declined and send the requester one courteous email.
-- p_note is an optional personal line from Coach Gari, shown inside the email.
create or replace function public.collab_admin_decline(p_id uuid, p_note text default null)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare e text := public.current_email(); d public.collaboration_deals; pr public.collaboration_proposals;
  v_note text := nullif(left(btrim(coalesce(p_note,'')),600),'');
begin
  if not public.has_permission('collab:manage') then raise exception 'forbidden' using errcode = '42501'; end if;
  select * into d from public.collaboration_deals where id = p_id for update;
  if not found then raise exception 'collaboration not found' using errcode = 'P0002'; end if;
  if d.status = 'declined' then return jsonb_build_object('ok', true, 'status', 'declined', 'already', true); end if;
  if d.status = 'agreed' then raise exception 'an agreed collaboration is closed, not declined' using errcode = 'P0003'; end if;
  select * into pr from public.collaboration_proposals where collaboration_id = d.id
    and accepted_at is null and declined_at is null and superseded_at is null order by version_number desc limit 1;
  if found then update public.collaboration_proposals set declined_at = now() where id = pr.id; end if;
  update public.collaboration_deals set status = 'declined' where id = d.id;
  if d.contact_email is not null then
    perform public.email_queue('collab_declined', d.contact_email,
      jsonb_build_object('public_ref', d.public_ref, 'name', d.contact_name, 'title', d.title, 'by', 'Coach Gari', 'note', v_note),
      'collab:' || d.id || ':declined:coach', null, null, null);
  end if;
  insert into public.admin_audit (area, entity_id, action, changed_by, summary)
  values ('collaboration', d.id::text, 'decline', e, jsonb_strip_nulls(jsonb_build_object('note', v_note)));
  return jsonb_build_object('ok', true, 'status', 'declined');
end $$;
revoke all on function public.collab_admin_decline(uuid, text) from public, anon;
grant execute on function public.collab_admin_decline(uuid, text) to authenticated, service_role;

-- From the room: unchanged behaviour, plus the owner is now told.
create or replace function public.collab_decline(p_token text, p_reason text default null)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare did uuid; d public.collaboration_deals; pr public.collaboration_proposals;
  v_reason text := nullif(left(btrim(coalesce(p_reason,'')),300),'');
begin
  did := public.collab_deal_by_token(p_token);
  select * into d from public.collaboration_deals where id = did for update;
  if d.status in ('agreed','declined','closed') then raise exception 'this collaboration is already settled' using errcode = 'P0003'; end if;
  select * into pr from public.collaboration_proposals where collaboration_id = d.id order by version_number desc limit 1;
  if found then update public.collaboration_proposals set declined_at = now() where id = pr.id; end if;
  update public.collaboration_deals set status = 'declined' where id = d.id;
  perform public.email_queue('collab_declined', public.email_owner_address(),
    jsonb_build_object('public_ref', d.public_ref, 'name', coalesce(d.contact_name, d.company), 'title', d.title, 'by', 'counterparty', 'note', v_reason),
    'collab:' || d.id || ':declined:party', null, null, null);
  insert into public.admin_audit (area, entity_id, action, changed_by, summary)
  values ('collaboration', d.id::text, 'decline', 'counterparty', jsonb_strip_nulls(jsonb_build_object('reason', v_reason)));
  return jsonb_build_object('ok', true, 'status', 'declined');
end $$;

-- ---------- 2. reminders: one per waiting thing, never twice ----------
-- Returns how many reminders were queued this run. Idempotent through the outbox
-- dedupe key (email_queue returns null on a duplicate), so a daily cron is enough
-- and a manual call is harmless. Owner mails go through email_owner_address(), which
-- the push hook already watches.
create or replace function public.collab_reminders(p_after interval default interval '3 days')
returns int language plpgsql volatile security definer set search_path = '' as $$
declare n int := 0; r record; owner text := public.email_owner_address();
begin
  -- a) requester: Coach Gari's proposal is waiting for their answer
  for r in
    select d.id, d.public_ref, d.contact_name, d.contact_email, p.version_number, p.monetary_amount, p.currency, p.expires_at
      from public.collaboration_deals d
      join lateral (select * from public.collaboration_proposals p where p.collaboration_id = d.id order by version_number desc limit 1) p on true
     where d.status in ('new','reviewing','negotiating') and d.contact_email is not null and d.token_revoked_at is null
       and p.proposed_by = 'coach' and p.accepted_at is null and p.declined_at is null and p.superseded_at is null
       and (p.expires_at is null or p.expires_at > now()) and p.created_at < now() - p_after
  loop
    if public.email_queue('collab_reminder', r.contact_email,
         jsonb_build_object('about', 'proposal', 'public_ref', r.public_ref, 'name', r.contact_name, 'version', r.version_number,
                            'monetary_amount', r.monetary_amount, 'currency', r.currency, 'expires_at', r.expires_at, 'collab_id', r.id),
         'collab:' || r.id || ':reminder:proposal:' || r.version_number, null, null, null) is not null then n := n + 1; end if;
  end loop;

  -- b) requester: a requested payment is still unpaid
  for r in
    select d.id, d.public_ref, d.contact_name, d.contact_email, cp.id as pid, cp.amount, cp.currency, cp.label
      from public.collaboration_payments cp join public.collaboration_deals d on d.id = cp.collaboration_id
     where cp.status in ('requested','checkout') and cp.created_at < now() - p_after
       and not exists (select 1 from public.orders o where o.reference = cp.order_reference and o.status = 'paid')   -- paid, sync pending: no nudge
       and d.status = 'agreed' and d.contact_email is not null and d.token_revoked_at is null
  loop
    if public.email_queue('collab_reminder', r.contact_email,
         jsonb_build_object('about', 'payment', 'public_ref', r.public_ref, 'name', r.contact_name,
                            'amount', r.amount, 'currency', r.currency, 'label', r.label, 'collab_id', r.id),
         'collab:' || r.pid || ':reminder:payment', null, null, null) is not null then n := n + 1; end if;
  end loop;

  -- c) owner: a counter-offer is waiting for his reply
  for r in
    select d.id, d.public_ref, coalesce(d.contact_name, d.company) as name, p.version_number, p.monetary_amount, p.currency
      from public.collaboration_deals d
      join lateral (select * from public.collaboration_proposals p where p.collaboration_id = d.id order by version_number desc limit 1) p on true
     where d.status in ('new','reviewing','negotiating')
       and p.proposed_by = 'counterparty' and p.accepted_at is null and p.declined_at is null and p.superseded_at is null
       and p.created_at < now() - p_after
  loop
    if public.email_queue('collab_reminder', owner,
         jsonb_build_object('about', 'counter', 'public_ref', r.public_ref, 'name', r.name, 'version', r.version_number,
                            'monetary_amount', r.monetary_amount, 'currency', r.currency),
         'collab:' || r.id || ':reminder:owner:' || r.version_number, null, null, null) is not null then n := n + 1; end if;
  end loop;

  -- d) owner: a new enquiry nobody has answered yet
  for r in
    select d.id, d.public_ref, coalesce(d.contact_name, d.company) as name, d.title
      from public.collaboration_deals d
     where d.status = 'new' and d.created_at < now() - p_after
       and not exists (select 1 from public.collaboration_proposals p where p.collaboration_id = d.id)
  loop
    if public.email_queue('collab_reminder', owner,
         jsonb_build_object('about', 'new', 'public_ref', r.public_ref, 'name', r.name, 'title', r.title),
         'collab:' || r.id || ':reminder:owner:new', null, null, null) is not null then n := n + 1; end if;
  end loop;
  return n;
end $$;
revoke all on function public.collab_reminders(interval) from public, anon, authenticated;
grant execute on function public.collab_reminders(interval) to service_role;

do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.unschedule(jobid) from cron.job where jobname = 'cg-collab-reminders';
    perform cron.schedule('cg-collab-reminders', '0 6 * * *', $cron$select public.collab_reminders()$cron$);
  end if;
end $$;

-- ---------- 4. the list says whose move it is ----------
create or replace function public.collab_admin_list(p_status text default null, p_search text default null)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare out jsonb; s text := nullif(btrim(coalesce(p_search,'')),'');
begin
  if not public.has_permission('collab:view') then raise exception 'forbidden' using errcode = '42501'; end if;
  select coalesce(jsonb_agg(row order by (row ->> 'updated_at') desc), '[]'::jsonb) into out from (
    select jsonb_strip_nulls(jsonb_build_object(
      'id', d.id, 'public_ref', d.public_ref, 'contact_name', d.contact_name, 'company', d.company,
      'collaboration_type', d.collaboration_type, 'title', d.title, 'status', d.status,
      'latest_amount', lp.monetary_amount, 'latest_currency', lp.currency,
      'waiting_on', case
        when d.status = 'agreed' and exists (select 1 from public.collaboration_payments cp
                                              where cp.collaboration_id = d.id and cp.status in ('requested','checkout')) then 'payment'
        when d.status not in ('new','reviewing','negotiating') then null
        when lp.proposed_by = 'coach' and lp.accepted_at is null and lp.declined_at is null and lp.superseded_at is null
             and (lp.expires_at is null or lp.expires_at > now()) then 'them'
        else 'you' end,
      'waiting_since', coalesce(lp.created_at, d.created_at),
      'updated_at', d.updated_at)) as row
    from public.collaboration_deals d
    left join lateral (select monetary_amount, currency, proposed_by, accepted_at, declined_at, superseded_at, expires_at, created_at
                         from public.collaboration_proposals p
                        where p.collaboration_id = d.id order by version_number desc limit 1) lp on true
    where (p_status is null or d.status = p_status)
      and (s is null or d.contact_name ilike '%'||s||'%' or d.company ilike '%'||s||'%' or d.public_ref ilike '%'||s||'%' or d.title ilike '%'||s||'%')
    order by d.updated_at desc limit 300) t;
  return out;
end $$;

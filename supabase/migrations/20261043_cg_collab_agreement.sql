-- =====================================================================
-- Coach Gari — the agreement as a document (CG-020)
--
-- An agreed collaboration lived only as rows. That is enough to run a deal and
-- not enough to sell one: a brand's finance team files a document, not a
-- database. On acceptance the frozen proposal is rendered to a PDF and kept,
-- with the evidence of how it was signed.
--
-- WHY THE FILE LIVES IN THE DATABASE. The integrity claim is "these bytes have
-- not changed", which only means something if the bytes are the ones we hashed.
-- Regenerating on demand would re-render with whatever the code says that day.
-- Storage would work, but it brings a bucket, policies, signed URLs and a
-- delete path that this project has already been bitten by. A one-page
-- agreement is some twenty kilobytes; a bytea column is the smaller, more
-- honest answer, and it is covered by the same RLS as the deal it belongs to.
--
-- ONE AGREEMENT PER ACCEPTED VERSION. The unique key is (deal, proposal), so
-- re-running the generation after a retry or a redeploy writes nothing. A
-- counter-offer accepted later is a different proposal and gets its own
-- document; neither replaces the other.
--
-- On the signature itself, see supabase/functions/_shared/agreement.ts: this is
-- an electronic signature under Federal Decree-Law No. 46 of 2021, and
-- deliberately not claimed to be a Qualified Electronic Signature.
-- =====================================================================

-- ---------- 1. who the coach is, on paper ----------
-- A contract needs a party, and a party needs a legal name, a licence and an
-- address. None of that can be invented here: the owner fills it in, and until
-- then the document falls back to the trading name and says nothing it cannot
-- support.
create table if not exists public.org_profile (
  id           int primary key default 1 check (id = 1),
  legal_name   text,
  trading_name text not null default 'Coach Gari',
  licence_no   text,
  jurisdiction text,
  address      text,
  email        text,
  website      text,
  updated_by   text,
  updated_at   timestamptz not null default now()
);
insert into public.org_profile (id) values (1) on conflict (id) do nothing;

alter table public.org_profile enable row level security;
revoke all on public.org_profile from anon, authenticated;
-- The letterhead is not client data: it is printed on every agreement the
-- counterparty receives. Anyone who can sign in may read it; only an
-- administrator may change it.
grant select on public.org_profile to authenticated;
drop policy if exists org_profile_view on public.org_profile;
create policy org_profile_view on public.org_profile for select to authenticated using (true);

create or replace function public.org_profile_set(p jsonb)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare e text := coalesce(public.current_email(), 'system');
begin
  if not public.has_permission('platform:admin') then raise exception 'forbidden' using errcode = '42501'; end if;
  update public.org_profile set
    legal_name   = nullif(btrim(coalesce(p ->> 'legal_name',   legal_name)),   ''),
    trading_name = coalesce(nullif(btrim(coalesce(p ->> 'trading_name', trading_name)), ''), 'Coach Gari'),
    licence_no   = nullif(btrim(coalesce(p ->> 'licence_no',   licence_no)),   ''),
    jurisdiction = nullif(btrim(coalesce(p ->> 'jurisdiction', jurisdiction)), ''),
    address      = nullif(btrim(coalesce(p ->> 'address',      address)),      ''),
    email        = nullif(btrim(coalesce(p ->> 'email',        email)),        ''),
    website      = nullif(btrim(coalesce(p ->> 'website',      website)),      ''),
    updated_by   = e,
    updated_at   = now()
  where id = 1;
  insert into public.admin_audit (area, entity_id, action, changed_by, summary)
  values ('agreement', 'org_profile', 'update', e, jsonb_build_object('keys', (select jsonb_agg(k) from jsonb_object_keys(p) k)));
  return jsonb_build_object('ok', true);
end $$;
revoke execute on function public.org_profile_set(jsonb) from public, anon;
grant  execute on function public.org_profile_set(jsonb) to authenticated, service_role;

-- ---------- 2. audit area ----------
alter table public.admin_audit drop constraint if exists admin_audit_area_check;
alter table public.admin_audit add constraint admin_audit_area_check check (area = any (array[
  'crm_contact','crm_note','body_measurement','permission','consent','merge','coaching_session',
  'session_pack','block','report','payment','payment_method','beau_ph_rail','beau_ph_fx',
  'settlement_destination','collaboration','email','analytics','whatsapp','agreement']));

-- ---------- 3. the signed document ----------
create table if not exists public.collaboration_agreements (
  id               uuid primary key default gen_random_uuid(),
  collaboration_id uuid not null references public.collaboration_deals(id) on delete cascade,
  proposal_id      uuid not null references public.collaboration_proposals(id) on delete cascade,
  version_number   int  not null,
  pdf              bytea not null,
  pdf_sha256       bytea not null,          -- of the bytes above: detects a changed file
  record_sha256    text  not null,          -- of the terms and the moment: detects changed data
  byte_size        int   not null check (byte_size > 0 and byte_size <= 2097152),
  signed_at        timestamptz not null,
  evidence         jsonb not null default '{}'::jsonb,
  org_snapshot     jsonb not null default '{}'::jsonb,   -- the letterhead as it was, not as it is now
  created_at       timestamptz not null default now(),
  unique (collaboration_id, proposal_id)
);
create index if not exists collaboration_agreements_deal_idx on public.collaboration_agreements (collaboration_id, created_at desc);

alter table public.collaboration_agreements enable row level security;
revoke all on public.collaboration_agreements from anon, authenticated;
-- The bytes are never handed out by a plain select: the column list stops at the
-- metadata, and the file itself comes back through the RPC below, which audits.
grant select (id, collaboration_id, proposal_id, version_number, record_sha256, byte_size, signed_at, created_at)
  on public.collaboration_agreements to authenticated;
drop policy if exists collaboration_agreements_view on public.collaboration_agreements;
create policy collaboration_agreements_view on public.collaboration_agreements for select to authenticated
  using (public.has_permission('collab:view'));

-- ---------- 4. what the renderer needs ----------
/* Everything the document prints, in one read: the deal, the proposal that was
   accepted, and the letterhead. service_role only — it carries the
   counterparty's contact details. */
create or replace function public.collab_agreement_snapshot(p_collab uuid)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare d public.collaboration_deals%rowtype; pr public.collaboration_proposals%rowtype; o public.org_profile%rowtype;
begin
  select * into d from public.collaboration_deals where id = p_collab;
  if not found then raise exception 'no such collaboration' using errcode = 'P0002'; end if;
  if d.accepted_proposal_id is null then raise exception 'nothing has been accepted' using errcode = 'P0003'; end if;
  select * into pr from public.collaboration_proposals where id = d.accepted_proposal_id;
  select * into o  from public.org_profile where id = 1;
  return jsonb_build_object(
    'deal', jsonb_build_object(
      'id', d.id, 'public_ref', d.public_ref, 'company', d.company, 'contact_name', d.contact_name,
      'contact_email', d.contact_email, 'contact_phone', d.contact_phone,
      'collaboration_type', d.collaboration_type, 'title', d.title, 'location', d.location,
      'proposed_date_from', d.proposed_date_from, 'proposed_date_to', d.proposed_date_to,
      'created_at', d.created_at),
    'proposal', jsonb_build_object(
      'id', pr.id, 'version_number', pr.version_number, 'intro', pr.intro,
      'monetary_amount', pr.monetary_amount, 'currency', pr.currency,
      'considerations', pr.considerations, 'terms', pr.terms,
      'accepted_at', pr.accepted_at, 'accepted_evidence', pr.accepted_evidence),
    'org', to_jsonb(o) - 'id' - 'updated_by' - 'updated_at');
end $$;
revoke execute on function public.collab_agreement_snapshot(uuid) from public, anon, authenticated;
grant  execute on function public.collab_agreement_snapshot(uuid) to service_role;

/* Store the rendered file. Idempotent on (deal, proposal): a retry or a
   redeploy writes nothing and reports the agreement that already exists, so a
   second render can never replace a signed document. */
create or replace function public.collab_agreement_record(p_collab uuid, p_proposal uuid, p_pdf_b64 text,
                                                          p_record_hash text, p_evidence jsonb default '{}'::jsonb,
                                                          p_org jsonb default '{}'::jsonb)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare v_bytes bytea; v_id uuid; pr public.collaboration_proposals%rowtype; v_new boolean := false;
begin
  select * into pr from public.collaboration_proposals where id = p_proposal and collaboration_id = p_collab;
  if not found then raise exception 'no such proposal' using errcode = 'P0002'; end if;
  if pr.accepted_at is null then raise exception 'that version was never accepted' using errcode = 'P0003'; end if;
  if p_record_hash !~ '^[0-9a-f]{64}$' then raise exception 'bad record hash' using errcode = '22023'; end if;

  v_bytes := decode(coalesce(p_pdf_b64, ''), 'base64');
  if length(v_bytes) = 0 or length(v_bytes) > 2097152 then raise exception 'bad document size' using errcode = '22023'; end if;
  -- %PDF- : refuse to store anything else under the name of a signed agreement
  if substring(v_bytes from 1 for 5) <> '\x255044462d'::bytea then
    raise exception 'that is not a PDF' using errcode = '22023';
  end if;

  insert into public.collaboration_agreements
    (collaboration_id, proposal_id, version_number, pdf, pdf_sha256, record_sha256, byte_size, signed_at, evidence, org_snapshot)
  values (p_collab, p_proposal, pr.version_number, v_bytes, extensions.digest(v_bytes, 'sha256'), p_record_hash,
          length(v_bytes), pr.accepted_at, coalesce(p_evidence, '{}'::jsonb), coalesce(p_org, '{}'::jsonb))
  on conflict (collaboration_id, proposal_id) do nothing
  returning id into v_id;
  v_new := v_id is not null;
  if v_id is null then select id into v_id from public.collaboration_agreements where collaboration_id = p_collab and proposal_id = p_proposal; end if;

  if v_new then
    insert into public.admin_audit (area, entity_id, action, changed_by, summary)
    values ('agreement', p_collab::text, 'issue', 'system',
            jsonb_build_object('agreement_id', v_id, 'version', pr.version_number, 'bytes', length(v_bytes), 'record', p_record_hash));
  end if;
  return jsonb_build_object('ok', true, 'id', v_id, 'created', v_new);
end $$;
revoke execute on function public.collab_agreement_record(uuid, uuid, text, text, jsonb, jsonb) from public, anon, authenticated;
grant  execute on function public.collab_agreement_record(uuid, uuid, text, text, jsonb, jsonb) to service_role;

-- ---------- 5. handing the file over ----------
/* To an operator. Audited, because downloading a signed contract is an act, not
   a page view. Returns base64: the back-office builds the file in the browser,
   so the bytes never become a URL that can be forwarded or logged. */
create or replace function public.collab_agreement_get(p_collab uuid)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare a public.collaboration_agreements%rowtype; d public.collaboration_deals%rowtype;
begin
  if not public.has_permission('collab:view') then raise exception 'forbidden' using errcode = '42501'; end if;
  select * into d from public.collaboration_deals where id = p_collab;
  if not found then raise exception 'no such collaboration' using errcode = 'P0002'; end if;
  select * into a from public.collaboration_agreements
   where collaboration_id = p_collab order by created_at desc limit 1;
  if not found then raise exception 'no agreement yet' using errcode = 'P0002'; end if;

  insert into public.admin_audit (area, entity_id, action, changed_by, summary)
  values ('agreement', p_collab::text, 'download', coalesce(public.current_email(), 'system'),
          jsonb_build_object('agreement_id', a.id, 'version', a.version_number));

  return jsonb_build_object('ok', true, 'id', a.id, 'version', a.version_number,
    'filename', 'Collaboration-Agreement-' || d.public_ref || '-v' || a.version_number || '.pdf',
    'signed_at', a.signed_at, 'bytes', a.byte_size,
    'record_sha256', a.record_sha256, 'file_sha256', encode(a.pdf_sha256, 'hex'),
    'pdf_b64', encode(a.pdf, 'base64'));
end $$;
revoke execute on function public.collab_agreement_get(uuid) from public, anon;
grant  execute on function public.collab_agreement_get(uuid) to authenticated, service_role;

/* To the counterparty, through the room link they already hold. service_role:
   the Edge Function calls it after the token has resolved to a live deal. */
create or replace function public.collab_agreement_for_token(p_token text)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare did uuid; a public.collaboration_agreements%rowtype; d public.collaboration_deals%rowtype;
begin
  did := public.collab_deal_by_token(p_token);
  select * into d from public.collaboration_deals where id = did;
  select * into a from public.collaboration_agreements
   where collaboration_id = did order by created_at desc limit 1;
  if not found then raise exception 'no agreement yet' using errcode = 'P0002'; end if;
  return jsonb_build_object('ok', true, 'version', a.version_number,
    'filename', 'Collaboration-Agreement-' || d.public_ref || '-v' || a.version_number || '.pdf',
    'signed_at', a.signed_at, 'record_sha256', a.record_sha256, 'file_sha256', encode(a.pdf_sha256, 'hex'),
    'pdf_b64', encode(a.pdf, 'base64'));
end $$;
revoke execute on function public.collab_agreement_for_token(text) from public, anon, authenticated;
grant  execute on function public.collab_agreement_for_token(text) to service_role;

/* Which deals have a document, for the list — metadata only, no bytes. */
create or replace function public.collab_agreement_status(p_collab uuid)
returns jsonb language sql stable security definer set search_path = '' as $$
  select case when not public.has_permission('collab:view') then null else
    coalesce((select jsonb_build_object('has', true, 'version', a.version_number, 'signed_at', a.signed_at,
                                        'bytes', a.byte_size, 'record_sha256', a.record_sha256)
                from public.collaboration_agreements a
               where a.collaboration_id = p_collab order by a.created_at desc limit 1),
             jsonb_build_object('has', false)) end
$$;
revoke execute on function public.collab_agreement_status(uuid) from public, anon;
grant  execute on function public.collab_agreement_status(uuid) to authenticated, service_role;

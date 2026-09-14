-- =====================================================================
-- Coach Gari — issuing the agreement, from whichever side accepts (CG-020)
--
-- A collaboration can be agreed in two places: the counterparty accepts in the
-- room (collab_accept, through the public Edge Function) or the coach accepts a
-- counter-offer in the back-office (collab_admin_accept, straight from the
-- browser). Hooking the document generation into one of them would quietly
-- leave the other without a contract.
--
-- So the hook is on the fact, not on the caller: a trigger fires the moment a
-- deal acquires an accepted proposal, and asks the renderer to produce the
-- document. Rendering needs a PDF writer, which lives in an Edge Function, so
-- the trigger goes out through pg_net with the same hashed-key discipline as
-- the email and WhatsApp outboxes.
--
-- Nothing here is load-bearing for the deal itself. If the renderer is down the
-- acceptance still stands, the email still goes, and the document can be issued
-- later by hand — collab_agreement_record is idempotent on (deal, proposal), so
-- a retry never produces a second, differing contract.
-- =====================================================================

-- ---------- the key: clear in Vault, hashed here ----------
do $$
declare k text;
begin
  if not exists (select 1 from public.outbox_keys where name = 'agreement') then
    if exists (select 1 from vault.decrypted_secrets where name = 'outbox_agreement_key') then
      select decrypted_secret into k from vault.decrypted_secrets where name = 'outbox_agreement_key' limit 1;
    else
      k := encode(extensions.gen_random_bytes(32), 'hex');
      perform vault.create_secret(k, 'outbox_agreement_key',
        'Agreement renderer key (clear; only its SHA-256 hash is stored in public.outbox_keys)');
    end if;
    insert into public.outbox_keys (name, key_sha256) values ('agreement', extensions.digest(k, 'sha256'));
  end if;
end $$;

create or replace function public.agreement_authorize(p_key text)
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from public.outbox_keys k
     where k.name = 'agreement'
       and length(coalesce(p_key, '')) = 64
       and public.ct_bytea_eq(k.key_sha256, extensions.digest(p_key, 'sha256'))
  )
$$;
revoke execute on function public.agreement_authorize(text) from public, anon, authenticated;
grant  execute on function public.agreement_authorize(text) to service_role;

-- ---------- ask the renderer for one document ----------
create or replace function public.agreement_kick(p_collab uuid)
returns bigint language plpgsql volatile security definer set search_path = '' as $$
declare k text; rid bigint;
begin
  if exists (select 1 from public.collaboration_agreements where collaboration_id = p_collab) then return null; end if;
  select decrypted_secret into k from vault.decrypted_secrets where name = 'outbox_agreement_key' limit 1;
  if k is null then return null; end if;
  select net.http_post(url := 'https://acrjrlgeeyseyolmofuq.supabase.co/functions/v1/agreement',
                       headers := jsonb_build_object('Content-Type', 'application/json', 'x-outbox-key', k),
                       body := jsonb_build_object('action', 'issue', 'collab_id', p_collab),
                       timeout_milliseconds := 20000) into rid;
  return rid;
end $$;
revoke execute on function public.agreement_kick(uuid) from public, anon, authenticated;
grant  execute on function public.agreement_kick(uuid) to service_role;

-- ---------- the trigger: the fact, not the caller ----------
create or replace function public.collab_agreement_on_accept()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if new.accepted_proposal_id is not null
     and (old.accepted_proposal_id is null or old.accepted_proposal_id <> new.accepted_proposal_id) then
    perform public.agreement_kick(new.id);
  end if;
  return new;
end $$;
revoke execute on function public.collab_agreement_on_accept() from public, anon, authenticated;

drop trigger if exists collaboration_deals_agreement on public.collaboration_deals;
create trigger collaboration_deals_agreement
  after update of accepted_proposal_id on public.collaboration_deals
  for each row execute function public.collab_agreement_on_accept();

-- ---------- and by hand, when it did not happen ----------
/* The back-office button. Refuses to run when a document already exists: a
   signed contract is never regenerated, only retrieved. */
create or replace function public.agreement_issue_now(p_collab uuid)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare rid bigint;
begin
  if not public.has_permission('collab:manage') then raise exception 'forbidden' using errcode = '42501'; end if;
  if exists (select 1 from public.collaboration_agreements where collaboration_id = p_collab) then
    raise exception 'this collaboration already has a signed agreement' using errcode = 'P0003';
  end if;
  if not exists (select 1 from public.collaboration_deals where id = p_collab and accepted_proposal_id is not null) then
    raise exception 'nothing has been accepted yet' using errcode = 'P0003';
  end if;
  rid := public.agreement_kick(p_collab);
  insert into public.admin_audit (area, entity_id, action, changed_by, summary)
  values ('agreement', p_collab::text, 'issue_requested', coalesce(public.current_email(), 'system'), '{}'::jsonb);
  return jsonb_build_object('ok', true, 'requested', rid is not null);
end $$;
revoke execute on function public.agreement_issue_now(uuid) from public, anon;
grant  execute on function public.agreement_issue_now(uuid) to authenticated, service_role;

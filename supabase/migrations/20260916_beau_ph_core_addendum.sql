-- =====================================================================
-- BEAU PH core — addendum: attach_attempt fix + cancel / expire (contract: cancel())
--
-- * attach_attempt: the attempt counter variable shadowed the column `n`
--   (plpgsql ambiguity at runtime). Fixed forward, never by rewriting the
--   applied core migration.
-- * cancel/expire: a host may supersede an open intent (e.g. a card Checkout
--   that was never completed while the client paid by bank transfer for a
--   different amount). Cancelling is a normal normalized event; a paid
--   request is never cancelled.
-- Forward migration only.
-- =====================================================================

create or replace function beau_ph.attach_attempt(p_request_id uuid, p_provider_reference text, p_redirect_url text, p_expires_at timestamptz)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare r beau_ph.payment_requests%rowtype; a beau_ph.payment_attempts%rowtype; v_n int;
begin
  select * into r from beau_ph.payment_requests where id = p_request_id for update;
  if not found then raise exception 'request not found' using errcode = 'P0002'; end if;
  if r.status not in ('created','pending','requires_action') then raise exception 'request not open' using errcode = 'P0003'; end if;
  update beau_ph.payment_attempts set status = 'superseded' where request_id = r.id and status = 'open';
  select coalesce(max(pa.n), 0) + 1 into v_n from beau_ph.payment_attempts pa where pa.request_id = r.id;
  insert into beau_ph.payment_attempts (request_id, n, provider_reference, redirect_url, expires_at)
  values (r.id, v_n, p_provider_reference, p_redirect_url, p_expires_at) returning * into a;
  perform beau_ph.record_event(r.id, 'requires_action', 'system', null, null, null, null, 'attempt_open', p_provider_reference, null,
                               jsonb_build_object('attempt', a.n, 'expires_at', p_expires_at));
  update beau_ph.payment_requests set expires_at = coalesce(p_expires_at, expires_at) where id = r.id;
  select * into r from beau_ph.payment_requests where id = r.id;
  return beau_ph.request_json(r);
end $$;

create or replace function beau_ph.cancel_request(p_request_id uuid, p_actor text default 'system', p_actor_id text default null, p_reason text default null)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare r beau_ph.payment_requests%rowtype;
begin
  select * into r from beau_ph.payment_requests where id = p_request_id for update;
  if not found then raise exception 'request not found' using errcode = 'P0002'; end if;
  if r.status in ('paid','refunded') then raise exception 'already paid' using errcode = 'P0003'; end if;
  if r.status in ('cancelled','expired','failed') then return beau_ph.request_json(r); end if;   -- idempotent
  perform beau_ph.record_event(r.id, 'cancelled', coalesce(p_actor, 'system'), p_actor_id, null, null, null, 'cancelled', null, null,
                               jsonb_build_object('reason', p_reason));
  select * into r from beau_ph.payment_requests where id = r.id;
  return beau_ph.request_json(r);
end $$;

-- cancel every LIVE request of an external order (all rails); returns how many were cancelled
create or replace function beau_ph.cancel_requests_for(p_merchant_key text, p_external_reference text, p_actor text default 'system', p_actor_id text default null, p_reason text default null)
returns int language plpgsql volatile security definer set search_path = '' as $$
declare v_count int := 0; rid uuid;
begin
  for rid in select r.id from beau_ph.payment_requests r join beau_ph.merchants m on m.id = r.merchant_id
              where m.key = p_merchant_key and r.external_reference = p_external_reference and r.status in ('created','pending','requires_action') loop
    perform beau_ph.cancel_request(rid, p_actor, p_actor_id, p_reason);
    v_count := v_count + 1;
  end loop;
  return v_count;
end $$;

create or replace function beau_ph.expire_request(p_request_id uuid, p_reason text default 'expired')
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare r beau_ph.payment_requests%rowtype;
begin
  select * into r from beau_ph.payment_requests where id = p_request_id for update;
  if not found then raise exception 'request not found' using errcode = 'P0002'; end if;
  if r.status in ('paid','refunded') then raise exception 'already paid' using errcode = 'P0003'; end if;
  if r.status in ('cancelled','expired','failed') then return beau_ph.request_json(r); end if;
  perform beau_ph.record_event(r.id, 'expired', 'system', null, null, null, null, 'expired', null, null, jsonb_build_object('reason', p_reason));
  select * into r from beau_ph.payment_requests where id = r.id;
  return beau_ph.request_json(r);
end $$;

do $$
declare f record;
begin
  for f in select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'beau_ph' and p.proname in ('attach_attempt','cancel_request','cancel_requests_for','expire_request') loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;

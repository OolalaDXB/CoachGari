-- =====================================================================
-- BEAU PH — tell the provider when a request stops being payable
--
-- THE HOLE. When a payment request is superseded — the client paid by bank
-- transfer, the coach took cash, a different amount was received — the hub
-- marks the old request 'cancelled' and the ledger is correct. But the PROVIDER
-- was never told. A Stripe Checkout session stays open for 24 hours, and its
-- URL is in an email the client already has. Two people can pay the same thing:
-- the webhook then arrives for a cancelled request, the state machine refuses
-- the illegal transition (which is why no double ledger entry exists — that
-- part was already right), and the money sits with Stripe waiting for someone
-- to notice and refund it. The suites prove the refusal; nothing closed the
-- door in the first place.
--
-- WHY IT IS AN OUTBOX AND NOT A DIRECT CALL. Cancelling at the provider is an
-- HTTP call, and the code that supersedes a request is SQL: payment_record_manual
-- is an RPC the back-office calls straight through PostgREST, with no Edge
-- Function in the path. Postgres could reach out with pg_net, but then the
-- back-office's "record this receipt" would depend on Stripe answering, and a
-- slow provider would hold a transaction that has already done the real work.
--
-- So the fact is recorded here and delivered elsewhere, exactly like the email,
-- push, WhatsApp and analytics rails: a row per request, a key held only in the
-- Vault, an Edge Function that drains it, a cron that nudges. A cancellation
-- that fails is retried; one that cannot succeed is marked and stops, because a
-- queue that retries for ever is a queue nobody reads.
--
-- WHAT IS DELIBERATELY NOT QUEUED. A rail whose adapter has no cancel (every
-- manual rail, and PayPal, whose order simply expires) has nothing to call, and
-- a request with no provider_reference was never created at the provider. Both
-- are recorded as 'skipped' with the reason rather than left pending, so the
-- queue says what happened instead of going quiet.
-- =====================================================================

-- ---------- 1. which rails can be cancelled at the provider ----------
-- This mirrors the adapter's supports.cancel. It lives in the database because
-- the queue is in the database; beau-ph/providers/*/adapter.ts remains the
-- source of truth, and scripts/test-paypal-wise.mjs and the contract suite fail
-- if the two ever disagree.
alter table beau_ph.providers add column if not exists supports_cancel boolean not null default false;
comment on column beau_ph.providers.supports_cancel is
  'True when the adapter can close an open request at the provider (adapter supports.cancel). Only such rails are queued for cancellation.';
update beau_ph.providers set supports_cancel = (key = 'stripe');

-- ---------- 2. the queue ----------
create table if not exists beau_ph.provider_cancellations (
  id                 uuid primary key default gen_random_uuid(),
  request_id         uuid not null unique references beau_ph.payment_requests(id) on delete cascade,
  merchant_key       text not null,
  provider_key       text not null,
  provider_reference text not null,
  reason             text,
  status             text not null default 'pending' check (status in ('pending','done','skipped','failed')),
  attempts           int  not null default 0,
  last_error         text,
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now(),
  settled_at         timestamptz
);
create index if not exists provider_cancellations_pending_idx
  on beau_ph.provider_cancellations (created_at) where status = 'pending';

alter table beau_ph.provider_cancellations enable row level security;
revoke all on beau_ph.provider_cancellations from public, anon, authenticated;

-- ---------- 3. queue on the fact, not on the caller ----------
-- Every path that ends a request — cancel_request, cancel_requests_for,
-- expire_request, and anything added later — lands as an UPDATE of status, so
-- the trigger catches all of them and nothing has to remember to call it.
create or replace function beau_ph.queue_provider_cancellation()
returns trigger language plpgsql security definer set search_path = '' as $$
declare v_merchant text; v_supports boolean;
begin
  if new.status not in ('cancelled','expired') or old.status = new.status then return new; end if;

  select m.key into v_merchant from beau_ph.merchants m where m.id = new.merchant_id;
  select p.supports_cancel into v_supports from beau_ph.providers p where p.key = new.provider_key;

  insert into beau_ph.provider_cancellations (request_id, merchant_key, provider_key, provider_reference, reason, status, last_error, settled_at)
  values (new.id, v_merchant, new.provider_key, coalesce(new.provider_reference, ''), new.status,
          case when coalesce(v_supports, false) and coalesce(new.provider_reference, '') <> '' then 'pending' else 'skipped' end,
          case when not coalesce(v_supports, false)                then 'rail has no cancel'
               when coalesce(new.provider_reference, '') = ''      then 'never created at the provider'
               else null end,
          case when coalesce(v_supports, false) and coalesce(new.provider_reference, '') <> '' then null else now() end)
  on conflict (request_id) do nothing;   -- a request is closed once; a second close is not a second cancellation
  return new;
end $$;

drop trigger if exists payment_requests_queue_cancellation on beau_ph.payment_requests;
create trigger payment_requests_queue_cancellation
  after update of status on beau_ph.payment_requests
  for each row execute function beau_ph.queue_provider_cancellation();
revoke all on function beau_ph.queue_provider_cancellation() from public, anon, authenticated;

-- ---------- 4. what the drainer reads and writes ----------
create or replace function beau_ph.cancellations_due(p_limit int default 20)
returns jsonb language sql volatile security definer set search_path = '' as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'id', c.id, 'merchant', c.merchant_key, 'provider', c.provider_key,
           'provider_reference', c.provider_reference, 'attempts', c.attempts,
           'mode', m.mode) order by c.created_at), '[]'::jsonb)
    from beau_ph.provider_cancellations c
    join beau_ph.merchants m on m.key = c.merchant_key
   where c.status = 'pending' and c.attempts < 5
   limit greatest(1, least(coalesce(p_limit, 20), 100));
$$;
revoke execute on function beau_ph.cancellations_due(int) from public, anon, authenticated;
grant  execute on function beau_ph.cancellations_due(int) to service_role;

/* One row, one outcome. 'done' and 'skipped' are final. A failure counts an
   attempt and stays pending until the fifth, then becomes 'failed' so somebody
   can look at it — an open session at a provider is worth a human glance. */
create or replace function beau_ph.cancellation_mark(p_id uuid, p_ok boolean, p_error text default null, p_skip boolean default false)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare c beau_ph.provider_cancellations%rowtype;
begin
  select * into c from beau_ph.provider_cancellations where id = p_id for update;
  if not found then raise exception 'cancellation not found' using errcode = 'P0002'; end if;
  if c.status <> 'pending' then return to_jsonb(c); end if;

  if p_ok then
    update beau_ph.provider_cancellations
       set status = 'done', attempts = attempts + 1, last_error = null, settled_at = now(), updated_at = now()
     where id = c.id returning * into c;
  elsif p_skip then
    update beau_ph.provider_cancellations
       set status = 'skipped', attempts = attempts + 1, last_error = left(coalesce(p_error, 'skipped'), 300), settled_at = now(), updated_at = now()
     where id = c.id returning * into c;
  else
    update beau_ph.provider_cancellations
       set attempts = attempts + 1, last_error = left(coalesce(p_error, 'unknown error'), 300),
           status = case when attempts + 1 >= 5 then 'failed' else 'pending' end,
           settled_at = case when attempts + 1 >= 5 then now() else null end, updated_at = now()
     where id = c.id returning * into c;
  end if;
  return to_jsonb(c);
end $$;
revoke execute on function beau_ph.cancellation_mark(uuid, boolean, text, boolean) from public, anon, authenticated;
grant  execute on function beau_ph.cancellation_mark(uuid, boolean, text, boolean) to service_role;

-- ---------- 5. the key, the gate and the kick ----------
do $$
declare k text;
begin
  if not exists (select 1 from vault.decrypted_secrets where name = 'outbox_cancel_key') then
    k := encode(extensions.gen_random_bytes(32), 'hex');
    perform vault.create_secret(k, 'outbox_cancel_key',
      'Provider-cancellation drain key (clear; only its SHA-256 hash is stored in public.outbox_keys)');
    insert into public.outbox_keys (name, key_sha256) values ('cancel', extensions.digest(k, 'sha256'))
      on conflict (name) do update set key_sha256 = excluded.key_sha256;
  end if;
end $$;

create or replace function public.ph_cancel_authorize(p_key text)
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.outbox_keys k where k.name = 'cancel' and length(coalesce(p_key, '')) = 64
                   and public.ct_bytea_eq(k.key_sha256, extensions.digest(p_key, 'sha256')))
$$;
revoke execute on function public.ph_cancel_authorize(text) from public, anon, authenticated;
grant  execute on function public.ph_cancel_authorize(text) to service_role;

create or replace function public.ph_cancel_kick()
returns bigint language plpgsql volatile security definer set search_path = '' as $$
declare k text; rid bigint;
begin
  if not exists (select 1 from beau_ph.provider_cancellations where status = 'pending' and attempts < 5) then return null; end if;
  select decrypted_secret into k from vault.decrypted_secrets where name = 'outbox_cancel_key' limit 1;
  if k is null then return null; end if;
  select net.http_post(url := 'https://acrjrlgeeyseyolmofuq.supabase.co/functions/v1/ph-cancel',
                       headers := jsonb_build_object('Content-Type', 'application/json', 'x-outbox-key', k),
                       body := '{"action":"drain"}'::jsonb, timeout_milliseconds := 30000) into rid;
  return rid;
end $$;
revoke execute on function public.ph_cancel_kick() from public, anon, authenticated;
grant  execute on function public.ph_cancel_kick() to service_role;

/* Every two minutes. An open checkout session is a window during which the same
   thing can be paid twice, so the window should be minutes, not hours. The kick
   returns immediately when the queue is empty, so an idle project does nothing. */
do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.unschedule(jobid) from cron.job where jobname = 'beau-ph-cancel-outbox';
    perform cron.schedule('beau-ph-cancel-outbox', '*/2 * * * *', $cron$select public.ph_cancel_kick()$cron$);
  end if;
end $$;

-- ---------- 6. what the operator sees ----------
-- A cancellation that could not be delivered belongs on the Finance side of the
-- back-office, not buried: it means a payment link may still be live.
create or replace function public.ph_cancellations_open()
returns jsonb language plpgsql stable security definer set search_path = '' as $$
begin
  if not public.has_permission('finance:view') then raise exception 'forbidden' using errcode = '42501'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object(
      'id', c.id, 'provider', c.provider_key, 'status', c.status, 'attempts', c.attempts,
      'reason', c.reason, 'last_error', c.last_error, 'created_at', c.created_at,
      'order', r.external_reference, 'amount', r.amount, 'currency', r.currency) order by c.created_at desc)
    from beau_ph.provider_cancellations c
    join beau_ph.payment_requests r on r.id = c.request_id
   where c.status in ('pending','failed')), '[]'::jsonb);
end $$;
revoke execute on function public.ph_cancellations_open() from public, anon;
grant  execute on function public.ph_cancellations_open() to authenticated, service_role;

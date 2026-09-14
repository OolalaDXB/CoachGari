-- Push notifications for the back-office (CG-017)
--
-- Who gets them: the people who already work here. A subscription belongs to an
-- app_users row, and RLS lets each person see and delete only their own. Nobody
-- subscribes a device they are not signed in on.
--
-- What they carry: a kind, never a row. The outbox stores no name, address,
-- reference or amount — a notification lands on a lock screen, which is not a
-- private place, and the service worker deliberately keeps no data on the device.
-- The Edge Function turns the kind into a fixed sentence ("New booking request").
--
-- What triggers one: any email already addressed to the owner. Hooking the push
-- queue to email_events rather than to a dozen call sites means every owner-facing
-- event, present and future, buzzes the phone without a second wiring to forget.
--
-- Sending: the same shape as the email outbox — a keyed Edge Function called by
-- pg_cron through pg_net, retries with backoff, and a row that ends failed rather
-- than vanishing. The VAPID private key and the drain key both live in Vault.

-- ---------- 1. VAPID keys ----------
-- Only the public half and the subject sit in a table. The private key lives in
-- Vault as 'push_vapid_private', the way 20261018 moved the outbox key there: a raw
-- read of an application table must never yield something that can sign.
create table if not exists public.push_config (
  id            smallint primary key default 1 check (id = 1),
  vapid_public  text not null,
  subject       text not null default 'mailto:letsgo@coachgari28.com',
  updated_at    timestamptz not null default now()
);
alter table public.push_config enable row level security;
revoke all on public.push_config from public, anon, authenticated;

-- The public key is public by design: the browser needs it to subscribe. The private
-- half is never selectable by anyone but the sender, which runs as service_role.
create or replace function public.push_vapid_public()
returns text language sql stable security definer set search_path = '' as $$
  select vapid_public from public.push_config where id = 1
$$;
revoke execute on function public.push_vapid_public() from public, anon;
grant  execute on function public.push_vapid_public() to authenticated, service_role;

create or replace function public.push_sender_config()
returns table (vapid_public text, vapid_private text, subject text)
language sql stable security definer set search_path = '' as $$
  select c.vapid_public,
         (select v.decrypted_secret from vault.decrypted_secrets v where v.name = 'push_vapid_private' limit 1),
         c.subject
    from public.push_config c where c.id = 1
$$;
revoke execute on function public.push_sender_config() from public, anon, authenticated;
grant  execute on function public.push_sender_config() to service_role;

-- ---------- 2. subscriptions ----------
create table if not exists public.push_subscriptions (
  id           uuid primary key default gen_random_uuid(),
  email        text not null references public.app_users(email) on delete cascade on update cascade,
  endpoint     text not null unique,
  p256dh       text not null,
  auth         text not null,
  user_agent   text,
  created_at   timestamptz not null default now(),
  last_sent_at timestamptz,
  failures     integer not null default 0,
  disabled_at  timestamptz
);
create index if not exists push_subscriptions_email_idx on public.push_subscriptions (email) where disabled_at is null;
alter table public.push_subscriptions enable row level security;
revoke all on public.push_subscriptions from public, anon;
grant select, delete on public.push_subscriptions to authenticated;

drop policy if exists push_subs_own_select on public.push_subscriptions;
create policy push_subs_own_select on public.push_subscriptions for select to authenticated
  using (email = public.current_email());
drop policy if exists push_subs_own_delete on public.push_subscriptions;
create policy push_subs_own_delete on public.push_subscriptions for delete to authenticated
  using (email = public.current_email());
-- No insert or update policy: a row is only ever created through push_subscribe below,
-- which pins the email to the caller's own identity.

-- ---------- 3. subscribe / unsubscribe ----------
create or replace function public.push_subscribe(p_endpoint text, p_p256dh text, p_auth text, p_user_agent text default null)
returns uuid language plpgsql volatile security definer set search_path = '' as $$
declare me text; sid uuid;
begin
  me := public.current_email();
  if me is null then raise exception 'not signed in' using errcode = '42501'; end if;
  if not exists (select 1 from public.app_users u where u.email = me and u.active) then
    raise exception 'no back-office access' using errcode = '42501';
  end if;
  if coalesce(p_endpoint, '') !~ '^https://' then raise exception 'bad endpoint' using errcode = '22023'; end if;
  if length(coalesce(p_p256dh, '')) < 80 or length(coalesce(p_auth, '')) < 16 then
    raise exception 'bad subscription keys' using errcode = '22023';
  end if;
  insert into public.push_subscriptions (email, endpoint, p256dh, auth, user_agent)
  values (me, p_endpoint, p_p256dh, p_auth, left(coalesce(p_user_agent, ''), 200))
  on conflict (endpoint) do update
    set email = excluded.email, p256dh = excluded.p256dh, auth = excluded.auth,
        user_agent = excluded.user_agent, failures = 0, disabled_at = null
  returning id into sid;
  return sid;
end $$;
revoke execute on function public.push_subscribe(text, text, text, text) from public, anon;
grant  execute on function public.push_subscribe(text, text, text, text) to authenticated;

create or replace function public.push_unsubscribe(p_endpoint text)
returns integer language plpgsql volatile security definer set search_path = '' as $$
declare n integer;
begin
  delete from public.push_subscriptions
   where endpoint = p_endpoint and email = public.current_email();
  get diagnostics n = row_count; return n;
end $$;
revoke execute on function public.push_unsubscribe(text) from public, anon;
grant  execute on function public.push_unsubscribe(text) to authenticated;

-- ---------- 4. the outbox ----------
create table if not exists public.push_events (
  id              bigint generated always as identity primary key,
  kind            text not null,
  dedupe_key      text unique,
  status          text not null default 'pending' check (status in ('pending','sent','failed','skipped')),
  attempts        integer not null default 0,
  next_attempt_at timestamptz not null default now(),
  created_at      timestamptz not null default now(),
  sent_at         timestamptz,
  delivered       integer,
  error           text
);
create index if not exists push_events_pending_idx on public.push_events (next_attempt_at) where status = 'pending';
alter table public.push_events enable row level security;
revoke all on public.push_events from public, anon, authenticated;
-- Deliberately no payload column. The kind is the whole message; anything else would
-- be personal data sitting in a queue and then on a lock screen.

create or replace function public.push_queue(p_kind text, p_dedupe_key text)
returns bigint language plpgsql volatile security definer set search_path = '' as $$
declare rid bigint;
begin
  if not exists (select 1 from public.push_subscriptions where disabled_at is null) then return null; end if;
  insert into public.push_events (kind, dedupe_key) values (p_kind, p_dedupe_key)
  on conflict (dedupe_key) do nothing returning id into rid;
  return rid;
end $$;
revoke execute on function public.push_queue(text, text) from public, anon, authenticated;
grant  execute on function public.push_queue(text, text) to service_role;

-- ---------- 5. one hook: whatever emails the owner, buzzes the phone ----------
create or replace function public.push_from_email_event()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if new.to_address is not null and new.to_address = public.email_owner_address() then
    perform public.push_queue(new.kind, 'email:' || new.id);
  end if;
  return new;
end $$;
drop trigger if exists push_on_owner_email on public.email_events;
create trigger push_on_owner_email after insert on public.email_events
  for each row execute function public.push_from_email_event();

-- ---------- 6. the sender's key, and the cron kick ----------
-- Same shape as the email drain key after 20261018: the clear key only ever exists
-- in Vault, the table keeps its SHA-256, and the comparison is constant time.
do $$
declare k text;
begin
  if not exists (select 1 from vault.decrypted_secrets where name = 'outbox_push_key') then
    k := encode(extensions.gen_random_bytes(32), 'hex');
    perform vault.create_secret(k, 'outbox_push_key',
      'Push outbox drain key (clear; only its SHA-256 hash is stored in public.outbox_keys)');
    insert into public.outbox_keys (name, key_sha256) values ('push', extensions.digest(k, 'sha256'))
      on conflict (name) do update set key_sha256 = excluded.key_sha256;
  end if;
end $$;

create or replace function public.push_outbox_authorize(p_key text)
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from public.outbox_keys k
     where k.name = 'push'
       and length(coalesce(p_key, '')) = 64
       and public.ct_bytea_eq(k.key_sha256, extensions.digest(p_key, 'sha256'))
  )
$$;
revoke execute on function public.push_outbox_authorize(text) from public, anon, authenticated;
grant  execute on function public.push_outbox_authorize(text) to service_role;

create or replace function public.push_outbox_kick()
returns bigint language plpgsql volatile security definer set search_path = '' as $$
declare k text; rid bigint;
begin
  if not exists (select 1 from public.push_events where status = 'pending' and next_attempt_at <= now()) then return null; end if;
  select decrypted_secret into k from vault.decrypted_secrets where name = 'outbox_push_key' limit 1;
  if k is null then return null; end if;
  select net.http_post(url := 'https://acrjrlgeeyseyolmofuq.supabase.co/functions/v1/push',
                       headers := jsonb_build_object('Content-Type', 'application/json', 'x-outbox-key', k),
                       body := '{"action":"drain"}'::jsonb, timeout_milliseconds := 20000) into rid;
  return rid;
end $$;
revoke execute on function public.push_outbox_kick() from public, anon, authenticated;
grant  execute on function public.push_outbox_kick() to service_role;

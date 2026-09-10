-- =====================================================================
-- Coach Gari — email outbox drain key: store a hash, not the clear key.
--
-- 20261009 stored public.outbox_keys.key in the CLEAR and its comment claimed
-- it was "stored hashed"; email_outbox_authorize compared k.key = p_key in the
-- clear. This makes the comment true and hardens the store.
--
-- Chosen path (of the two on the table): HASH AT REST.
--   * outbox_keys keeps only the SHA-256 of the key (key_sha256 bytea). A raw
--     read of the table can no longer reveal a usable key.
--   * email_outbox_authorize hashes the presented token and compares in
--     CONSTANT TIME against the stored hash.
--   * the drain still needs to present the clear key to the function, so the
--     clear key lives in Supabase Vault (project-managed, not in any table);
--     email_outbox_kick reads it from Vault only, at send time. The clear key
--     therefore transits once per kick as the x-outbox-key request header
--     through pg_net's ephemeral request queue — never persisted in the clear
--     in an application table.
--   * rotation is a single SECURITY DEFINER function that regenerates both the
--     Vault secret and the stored hash in sync.
-- Nothing here is anon-reachable; the table stays RLS-locked and revoked.
-- The deployed function is unchanged (it presents the same key value); the
-- comment in supabase/functions/email-outbox/index.ts is corrected to match.
-- =====================================================================

-- 1. move the current clear key into Vault (preserve the live value so the
--    running cron / function keep authorising), generating one only if absent.
do $$
declare k text;
begin
  select key into k from public.outbox_keys where name = 'email';
  if k is null then k := encode(extensions.gen_random_bytes(32), 'hex'); end if;
  if not exists (select 1 from vault.decrypted_secrets where name = 'outbox_email_key') then
    perform vault.create_secret(k, 'outbox_email_key',
      'Email outbox drain key (clear; only its SHA-256 hash is stored in public.outbox_keys)');
  end if;
end $$;

-- 2. store the hash, backfilled from the current clear key, then drop the clear column.
alter table public.outbox_keys add column if not exists key_sha256 bytea;
update public.outbox_keys set key_sha256 = extensions.digest(key, 'sha256')
 where key_sha256 is null and key is not null;
alter table public.outbox_keys drop column if exists key;

-- 3. constant-time bytea comparison (fixed-width digests; no early-out over the bytes).
create or replace function public.ct_bytea_eq(a bytea, b bytea)
returns boolean language plpgsql immutable set search_path = '' as $$
declare diff int := 0;
begin
  if a is null or b is null or length(a) <> length(b) then return false; end if;
  for i in 0 .. length(a) - 1 loop
    diff := diff | (get_byte(a, i) # get_byte(b, i));
  end loop;
  return diff = 0;
end $$;
revoke all on function public.ct_bytea_eq(bytea, bytea) from public, anon, authenticated;

-- 4. authorize by hashing the presented token and comparing the hash in constant time.
create or replace function public.email_outbox_authorize(p_key text)
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from public.outbox_keys k
     where k.name = 'email'
       and length(coalesce(p_key, '')) = 64
       and public.ct_bytea_eq(k.key_sha256, extensions.digest(p_key, 'sha256'))
  )
$$;
revoke execute on function public.email_outbox_authorize(text) from public, anon, authenticated;
grant  execute on function public.email_outbox_authorize(text) to service_role;

-- 5. the drain reads the clear key from Vault (never from an app table) at send time.
create or replace function public.email_outbox_kick()
returns bigint language plpgsql volatile security definer set search_path = '' as $$
declare k text; rid bigint;
begin
  if not exists (select 1 from public.email_events where status = 'pending' and next_attempt_at <= now()) then return null; end if;
  select decrypted_secret into k from vault.decrypted_secrets where name = 'outbox_email_key' limit 1;
  if k is null then return null; end if;
  select net.http_post(url := 'https://acrjrlgeeyseyolmofuq.supabase.co/functions/v1/email-outbox',
                       headers := jsonb_build_object('Content-Type', 'application/json', 'x-outbox-key', k),
                       body := '{"action":"drain"}'::jsonb, timeout_milliseconds := 20000) into rid;
  return rid;
end $$;
revoke execute on function public.email_outbox_kick() from public, anon, authenticated;
grant  execute on function public.email_outbox_kick() to service_role;

-- 6. allow 'email' as an audit area so rotation can record itself (additive).
alter table public.admin_audit drop constraint if exists admin_audit_area_check;
alter table public.admin_audit add constraint admin_audit_area_check check (area = any (array[
  'crm_contact','crm_note','body_measurement','permission','consent','merge','coaching_session',
  'session_pack','block','report','payment','payment_method','beau_ph_rail','beau_ph_fx',
  'settlement_destination','collaboration','email']));

-- 7. rotation: regenerate the Vault secret and the stored hash together. Takes
--    effect on the next kick (the function holds no cached key). service_role only.
create or replace function public.email_outbox_rotate_key()
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare k text; sid uuid;
begin
  k := encode(extensions.gen_random_bytes(32), 'hex');
  select id into sid from vault.secrets where name = 'outbox_email_key';
  if sid is null then
    perform vault.create_secret(k, 'outbox_email_key',
      'Email outbox drain key (clear; only its SHA-256 hash is stored in public.outbox_keys)');
  else
    perform vault.update_secret(sid, k);
  end if;
  update public.outbox_keys set key_sha256 = extensions.digest(k, 'sha256'), created_at = now() where name = 'email';
  if not found then
    insert into public.outbox_keys (name, key_sha256) values ('email', extensions.digest(k, 'sha256'));
  end if;
  insert into public.admin_audit (area, entity_id, action, changed_by, summary)
  values ('email', 'outbox', 'rotate_key', coalesce(public.current_email(), 'system'), '{}'::jsonb);
  return jsonb_build_object('ok', true, 'rotated_at', now());
end $$;
revoke execute on function public.email_outbox_rotate_key() from public, anon, authenticated;
grant  execute on function public.email_outbox_rotate_key() to service_role;

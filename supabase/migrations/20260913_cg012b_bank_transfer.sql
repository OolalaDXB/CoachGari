-- =====================================================================
-- CG-012b — Bank transfer as a second manual payment option
--
-- Adds a config-driven bank-transfer method (account holder / IBAN / BIC /
-- bank name) shown on the client report/payment page in English, alongside
-- Aani. Same rules as Aani: settled MANUALLY (an authorised operator records
-- the received payment), the ledger stays authoritative, viewing/copying the
-- details never marks anything paid, and no amount is converted. Bank details
-- are entered by the owner in the admin — nothing is seeded or committed.
-- Forward migration only.
-- =====================================================================

alter table public.payment_methods drop constraint if exists payment_methods_method_check;
alter table public.payment_methods add constraint payment_methods_method_check
  check (method in ('aani','bank_transfer'));

alter table public.payment_methods add column if not exists account_holder text;
alter table public.payment_methods add column if not exists iban           text;
alter table public.payment_methods add column if not exists bic            text;
alter table public.payment_methods add column if not exists bank_name      text;

-- manage both methods (finance:manage); carries the bank fields too
create or replace function public.payment_method_set(p jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare e text := public.current_email(); row public.payment_methods%rowtype; m text := coalesce(p->>'method','aani');
begin
  if not public.has_permission('finance:manage') then raise exception 'forbidden' using errcode = '42501'; end if;
  if m not in ('aani','bank_transfer') then raise exception 'unknown method' using errcode = '22023'; end if;
  insert into public.payment_methods (method, enabled, proxy_type, proxy_value, display_value, instructions, currency, qr_url,
                                      account_holder, iban, bic, bank_name, updated_by)
  values (m, coalesce((p->>'enabled')::boolean, false), nullif(p->>'proxy_type',''), nullif(p->>'proxy_value',''),
          nullif(p->>'display_value',''), nullif(p->>'instructions',''), coalesce(nullif(p->>'currency',''),'AED'), nullif(p->>'qr_url',''),
          nullif(p->>'account_holder',''), nullif(p->>'iban',''), nullif(p->>'bic',''), nullif(p->>'bank_name',''), e)
  on conflict (method) do update set
    enabled = excluded.enabled, proxy_type = excluded.proxy_type, proxy_value = excluded.proxy_value,
    display_value = excluded.display_value, instructions = excluded.instructions, currency = excluded.currency,
    qr_url = excluded.qr_url, account_holder = excluded.account_holder, iban = excluded.iban, bic = excluded.bic,
    bank_name = excluded.bank_name, updated_by = e, updated_at = now()
  returning * into row;
  insert into public.admin_audit (area, entity_id, action, changed_by, summary)
  values ('payment_method', m, 'set', e, jsonb_build_object('enabled', row.enabled));
  return to_jsonb(row);
end $$;
revoke execute on function public.payment_method_set(jsonb) from public, anon;
grant  execute on function public.payment_method_set(jsonb) to authenticated, service_role;

-- report view now also exposes the bank-transfer block (client-safe fields only)
create or replace function public.report_view(p_token text)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare t public.report_tokens%rowtype; recap jsonb; aani public.payment_methods%rowtype; bank public.payment_methods%rowtype;
  aani_json jsonb; bank_json jsonb; ref text;
begin
  if p_token is null or p_token !~ '^[0-9a-f]{64}$' then raise exception 'invalid token' using errcode = 'P0002'; end if;
  select * into t from public.report_tokens where token_hash = encode(extensions.digest(p_token,'sha256'),'hex');
  if not found then raise exception 'invalid token' using errcode = 'P0002'; end if;
  if t.revoked_at is not null then raise exception 'this link has been revoked' using errcode = 'P0003'; end if;
  if t.expires_at is not null and t.expires_at < now() then raise exception 'this link has expired' using errcode = 'P0003'; end if;
  recap := public.pack_recap_data(t.session_pack_id, true);
  ref := 'PACK-' || upper(substr(t.session_pack_id::text, 1, 8));
  select * into aani from public.payment_methods where method = 'aani' and enabled;
  if found then
    aani_json := jsonb_build_object('enabled', true, 'proxy_type', aani.proxy_type, 'display_value', aani.display_value,
      'instructions', aani.instructions, 'currency', aani.currency, 'qr_url', aani.qr_url, 'reference', ref);
  else aani_json := jsonb_build_object('enabled', false); end if;
  select * into bank from public.payment_methods where method = 'bank_transfer' and enabled;
  if found then
    bank_json := jsonb_build_object('enabled', true, 'account_holder', bank.account_holder, 'iban', bank.iban,
      'bic', bank.bic, 'bank_name', bank.bank_name, 'currency', bank.currency, 'instructions', bank.instructions, 'reference', ref);
  else bank_json := jsonb_build_object('enabled', false); end if;
  return jsonb_build_object('ok', true, 'recap', recap, 'aani', aani_json, 'bank', bank_json, 'pay_ref', ref);
end $$;
revoke execute on function public.report_view(text) from public, anon, authenticated;
grant  execute on function public.report_view(text) to service_role;

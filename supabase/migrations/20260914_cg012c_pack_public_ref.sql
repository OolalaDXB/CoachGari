-- =====================================================================
-- CG-012c — human, order-specific public payment reference (CG-1048)
--
-- The client report/payment page and payment instructions should quote a
-- short, human reference (e.g. CG-1048) rather than a UUID slice, so a
-- manual (Aani / bank transfer) payment can be matched back to the package.
-- Forward migration only.
-- =====================================================================

create sequence if not exists public.pack_ref_seq start 1001;
alter table public.session_packs add column if not exists public_ref text;
alter table public.session_packs alter column public_ref set default ('CG-' || to_char(nextval('public.pack_ref_seq'), 'FM0000'));
update public.session_packs set public_ref = 'CG-' || to_char(nextval('public.pack_ref_seq'), 'FM0000') where public_ref is null;
create unique index if not exists session_packs_public_ref_idx on public.session_packs(public_ref);

-- expose the reference in pack_json (operational; not financial)
create or replace function public.pack_json(p public.session_packs)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare used int := public.pack_used(p.id); j jsonb;
begin
  j := jsonb_build_object(
    'id', p.id, 'crm_contact_id', p.crm_contact_id, 'service_id', p.service_id,
    'title', p.title, 'total_sessions', p.total_sessions,
    'used', used, 'remaining', greatest(p.total_sessions - used, 0),
    'status', p.status, 'agreement_date', p.agreement_date,
    'renewed_from_pack_id', p.renewed_from_pack_id, 'created_at', p.created_at,
    'public_ref', p.public_ref);
  if public.has_permission('finance:view') then
    j := j || jsonb_build_object(
      'price_amount', p.price_amount, 'currency', p.currency,
      'payment_status', p.payment_status, 'payment_source', p.payment_source,
      'order_id', p.order_id, 'paid_at', p.paid_at);
  end if;
  return j;
end $$;
revoke execute on function public.pack_json(public.session_packs) from public, anon;
grant  execute on function public.pack_json(public.session_packs) to authenticated, service_role;

-- the report/payment page quotes the pack's public_ref (never a UUID)
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
  select public_ref into ref from public.session_packs where id = t.session_pack_id;
  ref := coalesce(ref, 'CG-' || upper(substr(t.session_pack_id::text, 1, 6)));
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

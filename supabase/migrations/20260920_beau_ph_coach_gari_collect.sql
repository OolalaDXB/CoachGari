-- =====================================================================
-- BEAU PH — Coach Gari host adapter: COLLECT IN PERSON (SoftPOS handoff, V0)
--
-- Host UX (pack or session → "Collect in person"):
--   operator sees the amount + public reference → opens the PSP's certified
--   Tap to Pay app (N-Genius One / SwipeX) → the customer taps → the app
--   shows the receipt → the operator enters the receipt / transaction
--   reference → BEAU PH confirms the softpos request (operator-attested
--   provider receipt) → Coach Gari ledger + pack projection, exactly once.
-- No card data, no NFC, nothing PSP-proprietary in the PWA.
-- Money collected by the PSP settles to Gari's PSP merchant account: no
-- Oolala earning (same rule as Aani / bank transfer).
-- Forward migration only.
-- =====================================================================

-- ---------- 1. ledger vocabulary ----------
alter table public.session_packs drop constraint if exists session_packs_payment_source_check;
alter table public.session_packs add constraint session_packs_payment_source_check
  check (payment_source in ('stripe','bank_transfer','cash','manual','external','aani','card_present'));
alter table public.payments add column if not exists capability text;   -- how the money was collected (BEAU PH capability)

create or replace function public.project_pack_payment(p_order_id uuid)
returns void language plpgsql volatile security definer set search_path = '' as $$
declare o public.orders%rowtype; p public.payments%rowtype; src text;
begin
  select * into o from public.orders where id = p_order_id;
  if not found or o.session_pack_id is null then return; end if;
  select * into p from public.payments where order_id = o.id and status = 'succeeded' order by paid_at desc nulls last limit 1;
  src := case when p.provider is null then null
              when p.provider = 'stripe' then 'stripe'
              when p.capability in ('softpos','card_present','tap_to_pay') then 'card_present'
              when p.provider in ('aani','bank_transfer','cash','manual','external') then p.provider
              else 'external' end;
  update public.session_packs set
    payment_status = case when o.status = 'paid' then 'paid'
                          when o.status in ('partially_refunded') then 'partial'
                          when o.status in ('refunded','cancelled') then 'unpaid'
                          else payment_status end,
    paid_at = case when o.status = 'paid' then coalesce(p.paid_at, o.paid_at, now()) else paid_at end,
    order_id = o.id,
    payment_source = coalesce(src, payment_source)
  where id = o.session_pack_id;
end $$;

-- ---------- 2. order → request, now capability-aware ----------
drop function if exists public.cg_ph_request_for_order(public.orders, text, jsonb, boolean);
create or replace function public.cg_ph_request_for_order(o public.orders, p_provider text, p_runtime jsonb default '{}'::jsonb, p_use_contact_country boolean default true,
                                                          p_capability text default null, p_platform text default null)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare pub text; ctry text; meta jsonb;
begin
  if o.booking_id is not null then
    select b.reference into pub from public.bookings b where b.id = o.booking_id;
    meta := jsonb_build_object('order_id', o.id, 'booking_id', o.booking_id, 'reason', coalesce(o.order_reason, 'booking'));
  else
    select sp.public_ref, case when p_use_contact_country then public.cg_country_code(c.country) else null end into pub, ctry
      from public.session_packs sp left join public.crm_contacts c on c.id = sp.crm_contact_id where sp.id = o.session_pack_id;
    meta := jsonb_build_object('order_id', o.id, 'session_pack_id', o.session_pack_id, 'reason', coalesce(o.order_reason, 'session_pack'));
  end if;
  return beau_ph.create_request('coach_gari', p_provider, o.reference, coalesce(pub, o.reference), o.gross_amount, o.currency, ctry,
                                o.checkout_expires_at, meta, p_runtime, p_capability, p_platform, null);
end $$;
revoke execute on function public.cg_ph_request_for_order(public.orders, text, jsonb, boolean, text, text) from public, anon, authenticated;
grant  execute on function public.cg_ph_request_for_order(public.orders, text, jsonb, boolean, text, text) to service_role;

-- ---------- 3. what can be collected in person for this pack, on this device ----------
create or replace function public.cg_ph_collect_options(p_pack_id uuid, p_platform text default null)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare sp public.session_packs%rowtype; due int; opts jsonb;
begin
  if not public.has_permission('finance:manage') then raise exception 'forbidden' using errcode = '42501'; end if;
  select * into sp from public.session_packs where id = p_pack_id;
  if not found then raise exception 'pack not found' using errcode = 'P0002'; end if;
  select gross_amount into due from public.orders where session_pack_id = sp.id and status = 'pending_payment' order by created_at desc limit 1;
  due := coalesce(due, sp.price_amount);
  -- in person = the merchant's location: eligibility uses the merchant country, the pack currency, the operator's device, merchant-initiated
  opts := (select coalesce(jsonb_agg(c), '[]'::jsonb)
             from jsonb_array_elements(beau_ph.eligible_capabilities('coach_gari', null, sp.currency, '{}'::jsonb, p_platform, 'merchant')) c
            where (c ->> 'in_person')::boolean);
  return jsonb_build_object('pack_id', sp.id, 'reference', sp.public_ref, 'amount', due, 'currency', sp.currency,
                            'paid', sp.payment_status = 'paid', 'options', opts);
end $$;
revoke execute on function public.cg_ph_collect_options(uuid, text) from public, anon;
grant  execute on function public.cg_ph_collect_options(uuid, text) to authenticated, service_role;

-- ---------- 4. record a receipt — now also through a SoftPOS handoff (PSP receipt reference required) ----------
drop function if exists public.payment_record_manual(uuid, int, text, text, text, timestamptz);
create or replace function public.payment_record_manual(
  p_pack_id uuid, p_amount int, p_currency text, p_source text default 'aani', p_reference text default null, p_paid_at timestamptz default null,
  p_capability text default null, p_platform text default null)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare e text := public.current_email(); sp public.session_packs%rowtype; o public.orders%rowtype; c public.crm_contacts%rowtype;
  v_ref text; pay public.payments%rowtype; req jsonb; conf jsonb; superseded text; psp boolean; v_cap text;
begin
  if not public.has_permission('finance:manage') then raise exception 'forbidden' using errcode = '42501'; end if;
  psp := p_source in ('network_international','magnati','adyen');
  if p_source not in ('aani','bank_transfer','cash','manual','external') and not psp then raise exception 'invalid source' using errcode = '22023'; end if;
  if p_amount is null or p_amount <= 0 then raise exception 'amount required' using errcode = '22023'; end if;
  if coalesce(p_currency,'') !~ '^[A-Z]{3}$' then raise exception 'currency required (ISO 4217)' using errcode = '22023'; end if;
  v_cap := case when psp then coalesce(p_capability, 'softpos') else p_capability end;
  if psp and coalesce(btrim(p_reference), '') = '' then
    raise exception 'the PSP app receipt / transaction reference is required for an in-person payment' using errcode = '22023';
  end if;
  select * into sp from public.session_packs where id = p_pack_id for update;
  if not found then raise exception 'pack not found' using errcode = 'P0002'; end if;
  select * into c from public.crm_contacts where id = sp.crm_contact_id;

  select * into o from public.orders where session_pack_id = sp.id and status in ('pending_payment') limit 1;
  if found and (o.currency <> p_currency or o.gross_amount <> p_amount) then
    perform beau_ph.cancel_requests_for('coach_gari', o.reference, 'operator', e, 'superseded by a manual receipt of a different amount');
    update public.orders set status = 'cancelled' where id = o.id;
    superseded := o.reference; o := null;
  end if;
  if o.id is null then
    loop v_ref := 'OR-' || upper(substr(encode(extensions.gen_random_bytes(4),'hex'),1,6)); exit when not exists (select 1 from public.orders where reference = v_ref); end loop;
    insert into public.orders (reference, booking_id, session_pack_id, order_reason, customer_name, customer_contact, currency, gross_amount, status)
    values (v_ref, null, sp.id, 'session_pack', coalesce(c.display_name,'Client'), coalesce(c.email,c.phone,'n/a'), p_currency, p_amount, 'pending_payment')
    returning * into o;
  end if;

  if p_source in ('aani','bank_transfer') or psp then
    req  := public.cg_ph_request_for_order(o, p_source, '{}'::jsonb, false, v_cap, p_platform);
    conf := beau_ph.confirm_manual((req ->> 'id')::uuid, e, p_amount, p_currency, nullif(btrim(p_reference), ''), p_paid_at, null);
    insert into public.payments (order_id, provider, amount, currency, status, paid_at, note, ph_request_id, ph_event_id, capability)
    values (o.id, p_source, p_amount, p_currency, 'succeeded', coalesce(p_paid_at, now()), nullif(btrim(p_reference), ''),
            (req ->> 'id')::uuid, (conf ->> 'payment_event_id')::uuid, req ->> 'capability')
    returning * into pay;
    perform beau_ph.mark_reconciled((conf ->> 'payment_event_id')::uuid, pay.id::text, 'public.payments');
  else
    insert into public.payments (order_id, provider, amount, currency, status, paid_at, note, capability)
    values (o.id, p_source, p_amount, p_currency, 'succeeded', coalesce(p_paid_at, now()), nullif(p_reference,''), p_capability)
    returning * into pay;
  end if;
  update public.orders set status = 'paid', paid_at = coalesce(paid_at, pay.paid_at) where id = o.id;
  perform public.project_pack_payment(o.id);       -- source recorded on the pack; NO recompute_earning (not Oolala-collected)
  insert into public.admin_audit (area, entity_id, action, changed_by, summary)
  values ('payment', o.reference, 'manual', e, jsonb_build_object('pack', sp.id, 'source', p_source, 'capability', coalesce(req ->> 'capability', p_capability),
                                                                   'amount', p_amount, 'currency', p_currency, 'beau_ph_request', req ->> 'id', 'superseded_order', superseded));
  return jsonb_build_object('ok', true, 'order', o.reference, 'payment_id', pay.id, 'source', p_source, 'capability', coalesce(req ->> 'capability', p_capability),
                            'request_id', req ->> 'id', 'public_reference', req ->> 'public_reference', 'superseded_order', superseded);
end $$;
revoke execute on function public.payment_record_manual(uuid, int, text, text, text, timestamptz, text, text) from public, anon;
grant  execute on function public.payment_record_manual(uuid, int, text, text, text, timestamptz, text, text) to authenticated, service_role;

-- ---------- 5. Finance configuration: PSP handoff app (non-secret) + rails matrix with capabilities ----------
create or replace function public.payment_method_set(p jsonb)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare e text := public.current_email(); m text := coalesce(p ->> 'method', 'aani'); row jsonb; ins jsonb := '{}'::jsonb; cfg jsonb := '{}'::jsonb; url text;
begin
  if not public.has_permission('finance:manage') then raise exception 'forbidden' using errcode = '42501'; end if;
  if m not in ('aani','bank_transfer','stripe','network_international','magnati','adyen') then raise exception 'unknown method' using errcode = '22023'; end if;
  if m = 'aani' and nullif(p ->> 'proxy_type', '') is not null and (p ->> 'proxy_type') not in ('mobile','email','merchant','qr') then
    raise exception 'invalid proxy_type' using errcode = '22023';
  end if;
  if m = 'aani' then
    ins := jsonb_strip_nulls(jsonb_build_object('proxy_type', nullif(p ->> 'proxy_type', ''), 'proxy_value', nullif(p ->> 'proxy_value', ''),
             'display_value', nullif(p ->> 'display_value', ''), 'instructions', nullif(p ->> 'instructions', ''), 'qr_url', nullif(p ->> 'qr_url', '')));
  elsif m = 'bank_transfer' then
    ins := jsonb_strip_nulls(jsonb_build_object('account_holder', nullif(p ->> 'account_holder', ''), 'iban', nullif(p ->> 'iban', ''),
             'bic', nullif(p ->> 'bic', ''), 'bank_name', nullif(p ->> 'bank_name', ''), 'instructions', nullif(p ->> 'instructions', '')));
  elsif m in ('network_international','magnati','adyen') then
    -- SoftPOS handoff: only the name of the PSP app the merchant uses and an optional app link. Never a merchant id, key or credential.
    url := nullif(btrim(p ->> 'handoff_url'), '');
    if url is not null and url !~ '^[a-z][a-z0-9+.-]*:' then raise exception 'handoff_url must be an app link or URL' using errcode = '22023'; end if;
    cfg := jsonb_strip_nulls(jsonb_build_object('handoff_app', nullif(btrim(p ->> 'handoff_app'), ''), 'handoff_url', url));
  end if;
  row := beau_ph.merchant_method_set('coach_gari', m, coalesce((p ->> 'enabled')::boolean, false),
           case when m = 'stripe' then null else coalesce(nullif(p ->> 'currency', ''), 'AED') end, ins, cfg, null, e);
  insert into public.admin_audit (area, entity_id, action, changed_by, summary)
  values ('payment_method', m, 'set', e, jsonb_build_object('enabled', (row ->> 'enabled')::boolean));
  return row;
end $$;

create or replace function public.payment_methods_list()
returns jsonb language plpgsql stable security definer set search_path = '' as $$
begin
  if not public.has_permission('finance:view') then raise exception 'forbidden' using errcode = '42501'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object(
      'method', mm.provider_key, 'enabled', mm.enabled, 'currency', mm.currency, 'updated_by', mm.updated_by, 'updated_at', mm.updated_at,
      'proxy_type', mm.instructions ->> 'proxy_type', 'proxy_value', mm.instructions ->> 'proxy_value', 'display_value', mm.instructions ->> 'display_value',
      'instructions', mm.instructions ->> 'instructions', 'qr_url', mm.instructions ->> 'qr_url',
      'account_holder', mm.instructions ->> 'account_holder', 'iban', mm.instructions ->> 'iban', 'bic', mm.instructions ->> 'bic', 'bank_name', mm.instructions ->> 'bank_name',
      'handoff_app', mm.settings ->> 'handoff_app', 'handoff_url', mm.settings ->> 'handoff_url')
      order by mm.provider_key)
    from beau_ph.merchant_methods mm join beau_ph.merchants m on m.id = mm.merchant_id where m.key = 'coach_gari'), '[]'::jsonb);
end $$;

create or replace function public.payment_rails()
returns jsonb language plpgsql stable security definer set search_path = '' as $$
begin
  if not public.has_permission('finance:view') then raise exception 'forbidden' using errcode = '42501'; end if;
  return (select jsonb_agg(jsonb_build_object(
      'provider', p.key, 'display_name', p.display_name, 'kind', p.kind, 'confirmation', p.confirmation, 'readiness', p.readiness,
      'countries', to_jsonb(coalesce(mm.countries, p.countries)), 'currencies', to_jsonb(p.currencies),
      'enabled', coalesce(mm.enabled, false), 'settlement_currency', mm.currency, 'notes', p.notes, 'updated_at', mm.updated_at,
      'capabilities', beau_ph.capabilities_json(p.key)) order by p.sort)
    from beau_ph.providers p
    left join beau_ph.merchant_methods mm on mm.provider_key = p.key and mm.merchant_id = (select id from beau_ph.merchants where key = 'coach_gari'));
end $$;

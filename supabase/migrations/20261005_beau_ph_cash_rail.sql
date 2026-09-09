-- =====================================================================
-- BEAU PH — Cash is a rail
--
-- Cash was a host-only "source" on payment_record_manual: a receipt was
-- written straight into public.payments with no BEAU PH request, no
-- evidence, no reconciliation, and cash appeared nowhere in Finance ›
-- Payment methods, BEAU PH › Rails, the client's payment options or the
-- "Collect in person" options. It is now a first-class MANUAL, in-person
-- rail, operator-confirmed like Aani and bank transfer:
--   * capability vocabulary gains `cash` (in person);
--   * provider `cash`: manual, operator-confirmed, available, any country /
--     currency (the merchant scopes it), one optional instruction text;
--   * Coach Gari: enabled, listed, AE, AED + USD, with a client note;
--   * payment_record_manual('cash') goes through BEAU PH (request →
--     operator confirmation → host payment → reconciled once). `manual` and
--     `external` stay host-only sources.
-- Forward migration only.
-- =====================================================================

-- 1. vocabulary
create or replace function beau_ph.is_capability(p text)
returns boolean language sql immutable set search_path = '' as $$
  select p in ('online_checkout','payment_link','manual_instructions','wallet','bank_transfer','mobile_money','softpos','card_present','tap_to_pay','qr','crypto','cash')
$$;
create or replace function beau_ph.is_in_person(p text)
returns boolean language sql immutable set search_path = '' as $$
  select p in ('softpos','card_present','tap_to_pay','cash')
$$;

-- 2. the provider
alter table beau_ph.providers drop constraint if exists providers_key_check;
alter table beau_ph.providers add constraint providers_key_check
  check (key in ('stripe','aani','bank_transfer','cash','paynow','mpesa','ozow','payshap','beau_wallet','network_international','magnati','adyen'));

insert into beau_ph.providers (key, display_name, kind, confirmation, countries, currencies, readiness, sort, notes, channel_label, intents, secrets, config_schema, onboarding)
values ('cash', 'Cash', 'manual', 'operator', null, null, 'available', 35,
        'Cash handed over in person; an authorised operator records the receipt (amount, currency, date). The amount is the request amount in the request currency — never converted.',
        'In person · Cash', null, '{}'::text[],
        '[{"key":"instructions","type":"textarea","label":"Instructions shown to the client","store":"instructions","public":true}]'::jsonb,
        'No API. Enable the rail and scope its markets; optionally add a note for the client. An authorised operator records each cash receipt; nothing is ever confirmed automatically.')
on conflict (key) do nothing;

insert into beau_ph.provider_capabilities (provider_key, capability, readiness, confirmation, platforms, initiated_by, handoff, notes)
values ('cash', 'cash', 'available', 'operator', null, 'any', false, 'Cash in person; an authorised operator records the receipt. Offered to the client as an option and to the merchant under Collect in person.')
on conflict do nothing;

-- 3. Coach Gari: on, in the home market, both trading currencies
do $$
begin
  if not exists (select 1 from beau_ph.merchant_methods mm join beau_ph.merchants m on m.id = mm.merchant_id where m.key = 'coach_gari' and mm.provider_key = 'cash') then
    perform beau_ph.merchant_method_configure('coach_gari', 'cash',
      '{"enabled":true,"listed":true,"currency":"AED","countries":["AE"],"currencies":["AED","USD"],
        "instructions":{"instructions":"Pay in cash at your session. Coach Gari confirms receipt and your package is updated."}}'::jsonb,
      'migration:20261005');
    insert into public.admin_audit (area, entity_id, action, changed_by, summary)
    values ('payment_method', 'cash', 'add', 'migration:20261005', '{"enabled":true,"countries":["AE"],"currencies":["AED","USD"]}'::jsonb);
  end if;
end $$;

-- 4. a cash receipt is a BEAU PH manual confirmation, like Aani and bank transfer
create or replace function public.payment_record_manual(
  p_pack_id uuid, p_amount int, p_currency text, p_source text default 'aani', p_reference text default null, p_paid_at timestamptz default null,
  p_capability text default null, p_platform text default null)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare e text := public.current_email(); sp public.session_packs%rowtype; o public.orders%rowtype; c public.crm_contacts%rowtype;
  v_ref text; pay public.payments%rowtype; req jsonb; conf jsonb; superseded text; psp boolean; v_cap text; via_ph boolean;
begin
  if not public.has_permission('finance:manage') then raise exception 'forbidden' using errcode = '42501'; end if;
  psp := p_source in ('network_international','magnati','adyen');
  if p_source not in ('aani','bank_transfer','cash','manual','external') and not psp then raise exception 'invalid source' using errcode = '22023'; end if;
  if p_amount is null or p_amount <= 0 then raise exception 'amount required' using errcode = '22023'; end if;
  if coalesce(p_currency,'') !~ '^[A-Z]{3}$' then raise exception 'currency required (ISO 4217)' using errcode = '22023'; end if;
  via_ph := p_source in ('aani','bank_transfer','cash') or psp;
  v_cap := case when psp then coalesce(p_capability, 'softpos') when p_source = 'cash' then coalesce(p_capability, 'cash') else p_capability end;
  if psp and coalesce(btrim(p_reference), '') = '' then
    raise exception 'the PSP app receipt / transaction reference is required for an in-person payment' using errcode = '22023';
  end if;
  select * into sp from public.session_packs where id = p_pack_id for update;
  if not found then raise exception 'pack not found' using errcode = 'P0002'; end if;
  -- race guard: another rail (e.g. a Stripe webhook) settled this pack first → a receipt must not pay it twice
  if sp.payment_status = 'paid' or exists (select 1 from public.orders oo where oo.session_pack_id = sp.id and oo.status = 'paid') then
    raise exception 'pack % is already paid', coalesce(sp.public_ref, sp.id::text) using errcode = 'P0003';
  end if;
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

  if via_ph then
    req  := public.cg_ph_request_for_order(o, p_source, '{}'::jsonb, false, v_cap, p_platform);
    conf := beau_ph.confirm_manual((req ->> 'id')::uuid, e, p_amount, p_currency, nullif(btrim(p_reference), ''), p_paid_at, null, 'coach_gari');
    insert into public.payments (order_id, provider, amount, currency, status, paid_at, note, ph_request_id, ph_event_id, capability)
    values (o.id, p_source, p_amount, p_currency, 'succeeded', coalesce(p_paid_at, now()), nullif(btrim(p_reference), ''),
            (req ->> 'id')::uuid, (conf ->> 'payment_event_id')::uuid, req ->> 'capability')
    returning * into pay;
    perform beau_ph.mark_reconciled((conf ->> 'payment_event_id')::uuid, pay.id::text, 'public.payments', 'coach_gari');
  else
    insert into public.payments (order_id, provider, amount, currency, status, paid_at, note, capability)
    values (o.id, p_source, p_amount, p_currency, 'succeeded', coalesce(p_paid_at, now()), nullif(p_reference,''), p_capability)
    returning * into pay;
  end if;
  update public.orders set status = 'paid', paid_at = coalesce(paid_at, pay.paid_at) where id = o.id;
  perform public.project_pack_payment(o.id);
  insert into public.admin_audit (area, entity_id, action, changed_by, summary)
  values ('payment', o.reference, 'manual', e, jsonb_build_object('pack', sp.id, 'source', p_source, 'capability', coalesce(req ->> 'capability', p_capability),
                                                                   'amount', p_amount, 'currency', p_currency, 'beau_ph_request', req ->> 'id', 'superseded_order', superseded));
  return jsonb_build_object('ok', true, 'order', o.reference, 'payment_id', pay.id, 'source', p_source, 'capability', coalesce(req ->> 'capability', p_capability),
                            'request_id', req ->> 'id', 'public_reference', req ->> 'public_reference', 'superseded_order', superseded);
end $$;

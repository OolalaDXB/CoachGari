/* =============================================================
   CG — manual rails book an earning too
   process_stripe_event has always called recompute_earning; payment_record_manual
   never did, so every off-platform receipt (cash, Aani, bank transfer, in-person
   PSP) produced a paid order with no partner_earnings row at all — untracked
   money rather than a 0 % commission. It now recomputes like the Stripe path;
   recompute_earning decides the rate and the accounting direction from the origin.
   Nothing else in the manual flow changes.
   ============================================================= */
create or replace function public.payment_record_manual(
  p_pack_id uuid, p_amount int, p_currency text, p_source text default 'aani', p_reference text default null, p_paid_at timestamptz default null,
  p_capability text default null, p_platform text default null)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare e text := public.current_email(); sp public.session_packs%rowtype; o public.orders%rowtype; c public.crm_contacts%rowtype;
  v_ref text; pay public.payments%rowtype; req jsonb; conf jsonb; superseded text; psp boolean; v_cap text; via_ph boolean; earn jsonb;
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
  -- Every origin books an earning. A rail Coach Gari collected himself produces a RECEIVABLE
  -- commission (he holds the cash, Studio is owed its share) — recompute_earning decides the
  -- direction from the origin; this call is what stops off-platform money going untracked.
  earn := public.recompute_earning(o.id);
  perform public.project_pack_payment(o.id);
  perform public.email_on_order_paid(o.id);            -- outbox: pack receipt to the client, notice to the owner
  insert into public.admin_audit (area, entity_id, action, changed_by, summary)
  values ('payment', o.reference, 'manual', e, jsonb_build_object('pack', sp.id, 'source', p_source, 'capability', coalesce(req ->> 'capability', p_capability),
                                                                   'amount', p_amount, 'currency', p_currency, 'beau_ph_request', req ->> 'id', 'superseded_order', superseded,
                                                                   'commission_origin', earn ->> 'collection_origin', 'commission_direction', earn ->> 'direction'));
  return jsonb_build_object('ok', true, 'order', o.reference, 'payment_id', pay.id, 'source', p_source, 'capability', coalesce(req ->> 'capability', p_capability),
                            'request_id', req ->> 'id', 'public_reference', req ->> 'public_reference', 'superseded_order', superseded,
                            'earning', jsonb_strip_nulls(jsonb_build_object('origin', earn ->> 'collection_origin', 'direction', earn ->> 'direction',
                                                                            'rate', earn ->> 'commission_rate', 'commission', earn ->> 'oolala_commission',
                                                                            'studio_receivable', earn ->> 'studio_receivable', 'gari_payable', earn ->> 'gari_payable')));
end $$;

-- =====================================================================
-- Coach Gari host adapter — a verified PayPal event reaching the ledger
--
-- Mirrors process_stripe_event: the same webhook_events dedupe, the same
-- tenant-scope refusal, the same "record the payment, mark the order paid,
-- recompute the earning, confirm the booking or project the pack, queue the
-- emails" sequence. What differs is only how PayPal names things.
--
-- WHAT THIS DELIBERATELY DOES NOT DO. A PayPal refund event is recorded as
-- BEAU PH evidence and then left alone: on a refund the resource is the REFUND,
-- not the capture, and mapping it onto the ledger correctly needs the capture
-- link that PayPal only supplies on some event shapes. Automating that on a
-- guess would silently credit the wrong payment. Until a real refund event has
-- been seen and read, a PayPal refund is applied through the same operator path
-- every other manual correction uses, and the evidence is already stored.
--
-- CONFIRMATION IS THE WEBHOOK, NEVER THE RETURN URL. The payer's browser coming
-- back from PayPal is a navigation, not a receipt. Nothing in the host marks an
-- order paid except this function, reached only after the adapter has had
-- PayPal itself verify the signature.
-- =====================================================================
create or replace function public.process_paypal_event(p_event jsonb)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare
  ev_id text := p_event ->> 'id'; ev_type text := p_event ->> 'event_type';
  res jsonb := p_event -> 'resource';
  existing public.webhook_events%rowtype;
  o public.orders%rowtype; b public.bookings%rowtype; p public.payments%rowtype;
  ph jsonb; ph_event uuid; result jsonb;
  v_amount int; v_currency text; v_capture text; v_order_ref text; v_fee int;
begin
  if ev_id is null or ev_type is null then raise exception 'malformed event' using errcode = '22023'; end if;

  insert into public.webhook_events (event_id, event_type, payload) values (ev_id, ev_type, p_event)
  on conflict (event_id) do nothing;
  if not found then
    select * into existing from public.webhook_events where event_id = ev_id;
    if existing.status in ('processed','ignored') then
      return jsonb_build_object('event_id', ev_id, 'duplicate', true, 'status', existing.status);
    end if;
  end if;

  ph := beau_ph.process_paypal_event(p_event);
  ph_event := (ph ->> 'payment_event_id')::uuid;

  -- this host reconciles its own merchant's requests and no one else's
  if (ph ->> 'request_id') is not null and not beau_ph.owned_by((ph ->> 'request_id')::uuid, 'coach_gari') then
    update public.webhook_events set status = 'ignored', note = 'beau_ph foreign_merchant', processed_at = now() where event_id = ev_id;
    return jsonb_build_object('event_id', ev_id, 'status', 'ignored', 'note', 'foreign_merchant');
  end if;

  if ev_type <> 'PAYMENT.CAPTURE.COMPLETED' then
    -- recorded, normalized into BEAU PH, and not carried into the ledger
    update public.webhook_events set status = 'ignored', note = 'beau_ph ' || coalesce(ph ->> 'outcome', 'none'), processed_at = now() where event_id = ev_id;
    return jsonb_build_object('event_id', ev_id, 'status', 'ignored', 'note', ph ->> 'outcome', 'beau_ph', ph ->> 'outcome');
  end if;

  v_capture   := res ->> 'id';
  v_currency  := upper(res #>> '{amount,currency_code}');
  v_amount    := beau_ph.paypal_minor(res #>> '{amount,value}', v_currency);
  v_fee       := beau_ph.paypal_minor(res #>> '{seller_receivable_breakdown,paypal_fee,value}',
                                      upper(coalesce(res #>> '{seller_receivable_breakdown,paypal_fee,currency_code}', v_currency)));
  -- the invoice id is "<order reference>-<attempt>"; the normalizer already stripped the attempt
  v_order_ref := coalesce(ph ->> 'external_reference', regexp_replace(coalesce(res ->> 'invoice_id', ''), '-[0-9]+$', ''));

  if coalesce(v_order_ref, '') = '' then
    update public.webhook_events set status = 'ignored', note = 'no order reference', processed_at = now() where event_id = ev_id;
    return jsonb_build_object('event_id', ev_id, 'status', 'ignored', 'note', 'no order reference');
  end if;
  select * into o from public.orders where reference = v_order_ref;
  if not found then
    update public.webhook_events set status = 'ignored', note = 'unknown order', processed_at = now() where event_id = ev_id;
    return jsonb_build_object('event_id', ev_id, 'status', 'ignored', 'note', 'unknown order');
  end if;

  -- BEAU PH is the authority on whether this event may move money. When it found
  -- no request at all the host still checks the amount itself, exactly as the
  -- Stripe path does, so a stray capture can never be credited.
  if (ph ->> 'outcome') = 'no_request' then
    if v_amount is null or v_amount <> o.gross_amount or v_currency <> o.currency then
      update public.webhook_events set status = 'ignored',
             note = format('amount mismatch: got %s %s, order %s %s', v_amount, v_currency, o.gross_amount, o.currency),
             processed_at = now() where event_id = ev_id;
      return jsonb_build_object('event_id', ev_id, 'status', 'ignored', 'note', 'amount mismatch');
    end if;
  elsif coalesce((ph ->> 'duplicate')::boolean, false) then
    if ph_event is null or beau_ph.is_reconciled(ph_event) then
      update public.webhook_events set status = 'processed', note = 'beau_ph duplicate', processed_at = now() where event_id = ev_id;
      return jsonb_build_object('event_id', ev_id, 'duplicate', true, 'status', 'processed');
    end if;
  elsif (ph ->> 'outcome') <> 'normalized' or (ph ->> 'to') <> 'paid' then
    update public.webhook_events set status = 'ignored', note = 'beau_ph ' || (ph ->> 'outcome'), processed_at = now() where event_id = ev_id;
    return jsonb_build_object('event_id', ev_id, 'status', 'ignored', 'note', ph ->> 'outcome');
  end if;

  insert into public.payments (order_id, provider, provider_payment_intent_id, provider_charge_id,
                               amount, currency, fee_amount, fee_known, status, paid_at, provider_event_id,
                               ph_request_id, ph_event_id)
  values (o.id, 'paypal', v_capture, res #>> '{supplementary_data,related_ids,order_id}',
          v_amount, v_currency, coalesce(v_fee, 0), v_fee is not null, 'succeeded', now(), ev_id,
          (ph ->> 'request_id')::uuid, ph_event)
  on conflict (provider_payment_intent_id) do update
    set fee_amount = case when public.payments.fee_known then public.payments.fee_amount else excluded.fee_amount end,
        fee_known  = public.payments.fee_known or excluded.fee_known,
        ph_request_id = coalesce(public.payments.ph_request_id, excluded.ph_request_id),
        ph_event_id   = coalesce(public.payments.ph_event_id, excluded.ph_event_id)
  returning * into p;

  update public.orders set status = 'paid', paid_at = coalesce(paid_at, now())
   where id = o.id and status in ('pending_payment','paid');
  perform public.recompute_earning(o.id);
  if ph_event is not null then perform beau_ph.mark_reconciled(ph_event, p.id::text, 'public.payments', 'coach_gari'); end if;

  if o.booking_id is not null then
    update public.bookings set status = 'confirmed', hold_expires_at = null
     where id = o.booking_id and status in ('hold','pending_payment','confirmed');
    select * into b from public.bookings where id = o.booking_id;
    perform public.email_on_order_paid(o.id, res #>> '{payer,email_address}');
    result := jsonb_build_object('order', o.reference, 'payment_id', p.id, 'booking', b.reference, 'booking_status', 'confirmed');
  else
    perform public.project_pack_payment(o.id);
    perform public.email_on_order_paid(o.id, res #>> '{payer,email_address}');
    result := jsonb_build_object('order', o.reference, 'payment_id', p.id, 'session_pack', o.session_pack_id);
  end if;

  update public.webhook_events set status = 'processed', processed_at = now() where event_id = ev_id;
  return jsonb_build_object('event_id', ev_id, 'status', 'processed', 'duplicate', false) || result
         || jsonb_build_object('beau_ph', jsonb_build_object('request_id', ph ->> 'request_id', 'payment_event_id', ph_event, 'outcome', ph ->> 'outcome'));
end $$;
revoke all on function public.process_paypal_event(jsonb) from public, anon, authenticated;
grant execute on function public.process_paypal_event(jsonb) to service_role;

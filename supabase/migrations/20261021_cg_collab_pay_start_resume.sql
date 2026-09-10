-- =====================================================================
-- Coach Gari — P1: make collab_pay_start idempotent (resume, don't duplicate)
--
-- collab_pay_start created a fresh order + BEAU PH request on EVERY call, so a
-- double click, a reload or a second tab produced several live orders and several
-- payment requests for one agreed collaboration payment.
--
-- Same rule as the booking checkout (20260904_cg003_payments: reuse the existing
-- pending_payment order instead of minting another):
--   * an order already in flight for this payment and still usable
--     (pending_payment, checkout not expired) is REUSED —
--     cg_ph_request_for_order is already idempotent per order (it returns the live
--     request matching external_reference), so one order keeps one request;
--   * an order whose checkout has expired is CLOSED explicitly (order -> cancelled,
--     live BEAU PH request -> cancel_request) before a replacement is issued;
--   * an already-paid order is refused rather than re-charged.
-- The Stripe rail, the amounts and the room flow are unchanged.
-- =====================================================================

create or replace function public.collab_pay_start(p_token text, p_country text, p_runtime jsonb default '{}'::jsonb)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare did uuid; d public.collaboration_deals; cp public.collaboration_payments; o public.orders%rowtype; req jsonb; v_ref text; pub text;
  ctry text := upper(coalesce(p_country,'')); offered jsonb; rid uuid;
begin
  did := public.collab_deal_by_token(p_token);
  select * into d from public.collaboration_deals where id = did;
  select * into cp from public.collaboration_payments where collaboration_id = d.id and status in ('requested','checkout') order by created_at desc limit 1;
  if not found then raise exception 'no payment is awaiting' using errcode = 'P0002'; end if;
  if ctry !~ '^[A-Z]{2}$' then raise exception 'country required (ISO 3166-1 alpha-2)' using errcode = '22023'; end if;
  offered := beau_ph.eligible_currencies('coach_gari', ctry, p_runtime, null, 'customer', 'other');
  if not exists (select 1 from jsonb_array_elements(offered) c where c ->> 'currency' = cp.currency) then
    raise exception 'no payment method is available for % in %', cp.currency, ctry using errcode = '22023';
  end if;

  -- ---- resume: this payment may already have an order in flight ----
  if cp.order_reference is not null then
    select * into o from public.orders where reference = cp.order_reference for update;
    if found then
      if o.status = 'paid' then raise exception 'this payment is already settled' using errcode = 'P0003'; end if;
      if o.status = 'pending_payment' and (o.checkout_expires_at is null or o.checkout_expires_at > now()) then
        req := public.cg_ph_request_for_order(o, 'stripe', p_runtime, false, null, null, null, ctry);
        if req is null or (req ->> 'id') is null then raise exception 'payment unavailable' using errcode = 'P0003'; end if;
        return jsonb_build_object(
          'request', beau_ph.request_json((select r from beau_ph.payment_requests r where r.id = (req ->> 'id')::uuid)),
          'order', jsonb_build_object('reference', o.reference, 'gross_amount', o.gross_amount, 'currency', o.currency),
          'resumed', true);
      end if;
      -- unusable (expired checkout, or an order already closed): close it explicitly first
      if o.status = 'pending_payment' then
        update public.orders set status = 'cancelled' where id = o.id;
      end if;
      for rid in select r.id from beau_ph.payment_requests r
                  where r.external_reference = o.reference and r.status in ('created','pending','requires_action') loop
        perform beau_ph.cancel_request(rid, 'system', null, 'collaboration checkout expired; replaced', 'coach_gari');
      end loop;
    end if;
  end if;

  -- ---- no usable order: issue a fresh one ----
  loop v_ref := 'OR-' || upper(substr(encode(extensions.gen_random_bytes(4), 'hex'), 1, 6)); exit when not exists (select 1 from public.orders where reference = v_ref); end loop;
  loop pub := 'CLP-' || upper(substr(encode(extensions.gen_random_bytes(4), 'hex'), 1, 6)); exit when not exists (select 1 from beau_ph.payment_requests where public_reference = pub); end loop;
  insert into public.orders (reference, booking_id, session_pack_id, order_reason, customer_name, customer_contact, currency, gross_amount, status, service_title)
  values (v_ref, null, null, 'collaboration', d.contact_name, coalesce(d.contact_email, 'n/a'), cp.currency, cp.amount, 'pending_payment', 'Collaboration ' || d.public_ref)
  returning * into o;
  req := public.cg_ph_request_for_order(o, 'stripe', p_runtime, false, null, null, null, ctry);
  if req is null or (req ->> 'id') is null then raise exception 'payment unavailable' using errcode = 'P0003'; end if;
  update beau_ph.payment_requests
     set public_reference = pub,
         metadata = metadata || jsonb_build_object('collaboration_ref', d.public_ref, 'collaboration_id', d.id,
                      'proposal_version', (select version_number from public.collaboration_proposals where id = cp.proposal_id),
                      'message', coalesce(cp.label, 'Collaboration ' || d.public_ref))
   where id = (req ->> 'id')::uuid;
  update public.collaboration_payments set order_reference = o.reference, public_reference = pub, status = 'checkout' where id = cp.id;
  req := beau_ph.request_json((select r from beau_ph.payment_requests r where r.id = (req ->> 'id')::uuid));
  return jsonb_build_object('request', req, 'order', jsonb_build_object('reference', o.reference, 'gross_amount', o.gross_amount, 'currency', o.currency));
end $$;

-- =====================================================================
-- Coach Gari host — attaching a Checkout Session keeps the request the
-- session was created for
--
-- attach_checkout() re-derived the BEAU PH request without a payment
-- currency: for a client paying a USD package in AED, that superseded the
-- AED request the Stripe session had just been created for, attached the
-- session to a fresh USD request, and the webhook (AED 367.25) was refused as
-- an amount mismatch. Found by the contract suite before any client did.
-- Now: the session attaches to the order's LIVE Stripe request whatever its
-- currency; only when none exists is one created in the pricing currency.
-- Forward migration only.
-- =====================================================================
create or replace function public.attach_checkout(p_order_reference text, p_session_id text, p_url text, p_expires_at timestamptz)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare o public.orders%rowtype; req jsonb; v_mode text; live beau_ph.payment_requests%rowtype; mid uuid;
begin
  update public.orders
     set stripe_checkout_session_id = p_session_id, checkout_url = p_url, checkout_expires_at = p_expires_at,
         checkout_attempts = checkout_attempts + 1
   where reference = p_order_reference and status = 'pending_payment'
   returning * into o;
  if not found then raise exception 'order not pending' using errcode = 'P0003'; end if;
  update public.bookings set status = 'pending_payment', hold_expires_at = p_expires_at
   where id = o.booking_id and status in ('hold','pending_payment');
  select id, mode into mid, v_mode from beau_ph.merchants where key = 'coach_gari';
  -- the session was created for the order's live Stripe request (in the currency the payer chose); attach to that one
  select * into live from beau_ph.payment_requests
   where merchant_id = mid and provider_key = 'stripe' and external_reference = o.reference and status in ('created','pending','requires_action');
  if found then
    perform beau_ph.attach_attempt(live.id, p_session_id, p_url, p_expires_at, 'coach_gari');
    return public.order_to_json(o);
  end if;
  -- no live request (legacy / direct callers): create one in the pricing currency, after eligibility, as before
  req := public.cg_ph_request_for_order(o, 'stripe', jsonb_build_object('stripe', jsonb_build_object('configured', true, 'mode', coalesce(v_mode, 'test'))), true);
  perform beau_ph.attach_attempt((req ->> 'id')::uuid, p_session_id, p_url, p_expires_at, 'coach_gari');
  return public.order_to_json(o);
end $$;

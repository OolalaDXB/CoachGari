-- =====================================================================
-- Payment links: opening one twice, and removing one for good.
--
-- Two faults, both found on the first real link rather than in the suite,
-- and both of them mine:
--
--   1. RE-OPENING FAILED. The Edge Function asked Stripe for a Checkout
--      Session with `attempt: 1` hard-coded, so the second open re-sent the
--      same Idempotency-Key (`<reference>:1:embedded`) with a different body —
--      `expires_at` is computed from the clock at each call. Stripe answers
--      `400 idempotency_error` to a re-used key with a changed body, and the
--      function turned that into a 502. So: the first person to open a link
--      could pay; everybody else, including the same person reloading, saw an
--      error. The fix is not a fresh key every time — that would mint a new
--      session on every reload. It is to RESUME the session already attached
--      to the order when Stripe still has it open, and only create a new one
--      (with an attempt number that has never been used) when it does not.
--
--   2. THE LINK EXPIRED WITH THE STRIPE SESSION. orders.checkout_expires_at
--      carried two different meanings: for a link it is "valid until", written
--      by the coach in days; attach_checkout then overwrote it with the Stripe
--      session's own expiry, hours away. A 30-day link quietly became a
--      one-session link. Payment links therefore no longer go through
--      attach_checkout: payment_link_attach() records the session and the
--      attempt without touching the link's own lifetime. Stripe's session
--      expiry is not stored at all — it is asked for, when it matters, at
--      resume time, which is the only place it is true.
--
-- And one thing that was missing: a link could be withdrawn (the order goes
-- 'cancelled', the row stays) but never removed. Withdrawal is right for a
-- link that was sent to someone; for one that should never have existed —
-- wrong amount, wrong label, a test — the row is noise in a finance list that
-- is supposed to be readable. payment_link_delete() removes it, after
-- cancelling the request behind it, and leaves the audit line standing: what
-- is deleted is the operational row, not the record that it happened.
-- =====================================================================

-- ---------- 1. the payer opens it (again) ----------
/* Now also returns what the function needs to decide between resume and create:
   the session already attached, and how many attempts have been made. Both are
   the coach's side of the transaction, not the payer's — the Edge Function
   never passes them on to the browser. */
create or replace function public.payment_link_open(p_reference text, p_token text, p_runtime jsonb default '{}'::jsonb)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare o public.orders%rowtype; req jsonb;
begin
  if p_token is null or p_token !~ '^[0-9a-f]{64}$' then raise exception 'invalid link' using errcode = 'P0002'; end if;
  select * into o from public.orders
   where reference = p_reference and order_reason = 'payment_link'
     and access_token_hash = encode(extensions.digest(p_token, 'sha256'), 'hex');
  if not found then raise exception 'invalid link' using errcode = 'P0002'; end if;

  -- a settled or withdrawn link answers honestly instead of offering a payment
  if o.status = 'paid' then
    return jsonb_build_object('state', 'paid', 'label', o.service_title, 'amount', o.gross_amount,
                              'currency', o.currency, 'reference', o.reference, 'paid_at', o.paid_at);
  end if;
  if o.status in ('cancelled','failed','refunded','partially_refunded') then
    return jsonb_build_object('state', 'closed', 'label', o.service_title, 'reference', o.reference);
  end if;
  if o.checkout_expires_at is not null and o.checkout_expires_at < now() then
    return jsonb_build_object('state', 'expired', 'label', o.service_title, 'reference', o.reference);
  end if;

  req := public.cg_ph_request_for_order(o, 'stripe', coalesce(p_runtime, '{}'::jsonb), false, null, null, null, null);
  if req is null or (req ->> 'id') is null then raise exception 'payment unavailable' using errcode = 'P0003'; end if;

  return jsonb_build_object('state', 'payable', 'label', o.service_title, 'amount', o.gross_amount,
                            'currency', o.currency, 'reference', o.reference, 'request', req,
                            'session_id', o.stripe_checkout_session_id,
                            'attempts', coalesce(o.checkout_attempts, 0));
end $$;
revoke execute on function public.payment_link_open(text, text, jsonb) from public, anon, authenticated;
grant  execute on function public.payment_link_open(text, text, jsonb) to service_role;

-- ---------- 2. attaching a session to a link ----------
/* attach_checkout() in miniature, minus the two things a link must not inherit:
   it does not move a booking, and it does not rewrite checkout_expires_at,
   which for a link is the coach's own validity window. The attempt counter is
   the input to the next Idempotency-Key, so it is incremented here and nowhere
   else. */
create or replace function public.payment_link_attach(p_reference text, p_session_id text)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare o public.orders%rowtype; live beau_ph.payment_requests%rowtype; mid uuid;
begin
  if p_session_id is null or btrim(p_session_id) = '' then raise exception 'session id required' using errcode = '22023'; end if;
  update public.orders
     set stripe_checkout_session_id = p_session_id, checkout_attempts = coalesce(checkout_attempts, 0) + 1
   where reference = p_reference and order_reason = 'payment_link' and status = 'pending_payment'
   returning * into o;
  if not found then raise exception 'link not pending' using errcode = 'P0003'; end if;

  select id into mid from beau_ph.merchants where key = 'coach_gari';
  select * into live from beau_ph.payment_requests
   where merchant_id = mid and provider_key = 'stripe' and external_reference = o.reference
     and status in ('created','pending','requires_action');
  if not found then raise exception 'no live request for this link' using errcode = 'P0003'; end if;
  -- null expiry: the session's own lifetime lives at Stripe, and is read back at resume
  perform beau_ph.attach_attempt(live.id, p_session_id, null, null, 'coach_gari');

  return jsonb_build_object('reference', o.reference, 'attempts', o.checkout_attempts);
end $$;
revoke execute on function public.payment_link_attach(text, text) from public, anon, authenticated;
grant  execute on function public.payment_link_attach(text, text) to service_role;

-- ---------- 3. removing a link ----------
/* Deletion is for a link that should not be in the list at all. It is refused
   the moment money is involved — paid, or carrying any payment, refund or
   chargeback row — because at that point the order is an accounting record and
   the right move is a refund, not an erasure.

   The BEAU PH request is cancelled first, which queues the provider
   cancellation that expires the Stripe session: a deleted link whose Checkout
   Session stayed open at Stripe would be payable against an order that no
   longer exists. The request row itself stays — a ledger is not edited — and
   the audit line is written BEFORE the delete, with the label and the amount
   in it, so the finance history still says what was removed and by whom. */
create or replace function public.payment_link_delete(p_reference text)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare e text := public.current_email(); o public.orders%rowtype; r beau_ph.payment_requests%rowtype; mid uuid; n int := 0;
begin
  if not public.has_permission('finance:manage') then raise exception 'forbidden' using errcode = '42501'; end if;
  select * into o from public.orders where reference = p_reference and order_reason = 'payment_link';
  if not found then raise exception 'link not found' using errcode = 'P0002'; end if;
  if o.status = 'paid' or o.paid_at is not null then
    raise exception 'this link has been paid — it cannot be deleted' using errcode = 'P0003';
  end if;
  if exists (select 1 from public.payments    where order_id = o.id)
  or exists (select 1 from public.refunds     where order_id = o.id)
  or exists (select 1 from public.chargebacks where order_id = o.id) then
    raise exception 'this link carries a payment record — withdraw it instead of deleting it' using errcode = 'P0003';
  end if;

  select id into mid from beau_ph.merchants where key = 'coach_gari';
  for r in select * from beau_ph.payment_requests
            where merchant_id = mid and external_reference = o.reference
              and status in ('created','pending','requires_action') loop
    perform beau_ph.cancel_request(r.id, 'operator', e, 'payment link deleted', 'coach_gari');
    n := n + 1;
  end loop;

  insert into public.admin_audit (area, entity_id, action, changed_by, summary)
  values ('order', o.id::text, 'payment_link:delete', e,
          jsonb_build_object('reference', o.reference, 'label', o.service_title, 'amount', o.gross_amount,
                             'currency', o.currency, 'status', o.status, 'requests_cancelled', n,
                             'created_at', o.created_at));

  delete from public.orders where id = o.id;
  return jsonb_build_object('reference', o.reference, 'deleted', true, 'requests_cancelled', n);
end $$;
revoke execute on function public.payment_link_delete(text) from public, anon;
grant  execute on function public.payment_link_delete(text) to authenticated, service_role;

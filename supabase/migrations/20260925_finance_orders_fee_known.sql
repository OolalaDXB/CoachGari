-- =============================================================
-- Finance list: say when the Stripe fee is not known yet
--
-- public.payments already distinguishes "the fee is zero" from "we do not
-- know the fee yet" (`fee_known`), and its upsert lets a later, better
-- reading fill an unknown fee in. Nothing surfaced that flag, so a fee
-- that had not arrived from Stripe was displayed as 0.00 and read as a
-- real zero — which is how the first live payment looked.
--
-- finance_orders() now returns it, so the Finance tab can show "pending"
-- instead of a figure it does not have. Reporting only: no amount, fee,
-- earning or settlement logic changes.
--
-- Forward only. The return type changes, so the function is dropped; DROP
-- clears its grants and CREATE grants EXECUTE to PUBLIC by default, hence
-- the explicit revokes below.
-- =============================================================

drop function if exists public.finance_orders();

create function public.finance_orders()
returns table(
  id uuid, reference text, status text, currency text, gross_amount integer,
  paid_at timestamptz, created_at timestamptz, stripe_checkout_session_id text,
  booking_reference text, session_start_at timestamptz, session_timezone text,
  booking_status text, delivery_mode text, service_slug text, service_title text,
  customer_hint text, stripe_fee integer, refund_amount integer, chargeback_amount integer,
  net_collected integer, oolala_commission integer, gari_payable integer,
  earning_status text, settlement_id uuid, adjusted_at timestamptz,
  order_reason text, pack_reference text, crm_contact_id uuid, fee_known boolean)
language plpgsql
stable security definer
set search_path to ''
as $function$
begin
  if not public.has_permission('finance:view') then raise exception 'forbidden' using errcode = '42501'; end if;
  return query
    select o.id, o.reference, o.status, o.currency, o.gross_amount, o.paid_at, o.created_at, o.stripe_checkout_session_id,
           b.reference, b.start_at, b.session_timezone, b.status, b.delivery_mode,
           coalesce(b.service_slug, s.slug),
           coalesce(o.service_title, b.service_title, s.title, p.title),
           public.mask_contact(coalesce(b.customer_contact, c.email, o.customer_contact)),
           pe.stripe_fee, pe.refund_amount, pe.chargeback_amount, pe.net_collected, pe.oolala_commission, pe.gari_payable,
           pe.status, pe.settlement_id, pe.adjusted_at,
           coalesce(o.order_reason, case when o.booking_id is not null then 'booking' else 'session_pack' end),
           p.public_ref,
           coalesce(b.crm_contact_id, p.crm_contact_id),
           pm.fee_known
    from public.orders o
    left join public.bookings b on b.id = o.booking_id
    left join public.services s on s.id = b.service_id
    left join public.session_packs p on p.id = o.session_pack_id
    left join public.crm_contacts c on c.id = p.crm_contact_id
    left join public.partner_earnings pe on pe.order_id = o.id
    left join public.payments pm on pm.id = pe.payment_id
    order by o.created_at desc;
end $function$;

revoke all on function public.finance_orders() from public;
revoke all on function public.finance_orders() from anon;
grant execute on function public.finance_orders() to authenticated, service_role;

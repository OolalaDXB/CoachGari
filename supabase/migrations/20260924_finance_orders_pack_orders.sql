-- =============================================================
-- Finance list: session-pack orders were invisible
--
-- public.finance_orders() joined orders to bookings with an INNER join,
-- so an order created for a session pack (booking_id null,
-- session_pack_id set) never appeared in the Finance tab. The first live
-- pack payment (CG-1048) exposed it: the money was in the ledger, the
-- earning existed, and nothing showed on screen.
--
-- Settlements were never affected: create_settlement() reads
-- partner_earnings joined to orders and already picked pack orders up.
-- This is a reporting fix only — no amount, earning or settlement logic
-- changes, and no row is written.
--
-- The join becomes a LEFT join, and three columns are added so the UI can
-- label a pack row and the client profile can match a client's payments
-- without a booking reference:
--   order_reason    'booking' | 'session_pack' (as stored on the order)
--   pack_reference  the pack's public CG-#### reference
--   crm_contact_id  the client, from the booking or from the pack
--
-- Forward only. Return type changes, so the function is dropped first.
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
  order_reason text, pack_reference text, crm_contact_id uuid)
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
           -- the client hint is masked exactly as before; a pack order falls back to its CRM contact
           public.mask_contact(coalesce(b.customer_contact, c.email, o.customer_contact)),
           pe.stripe_fee, pe.refund_amount, pe.chargeback_amount, pe.net_collected, pe.oolala_commission, pe.gari_payable,
           pe.status, pe.settlement_id, pe.adjusted_at,
           coalesce(o.order_reason, case when o.booking_id is not null then 'booking' else 'session_pack' end),
           p.public_ref,
           coalesce(b.crm_contact_id, p.crm_contact_id)
    from public.orders o
    left join public.bookings b on b.id = o.booking_id
    left join public.services s on s.id = b.service_id
    left join public.session_packs p on p.id = o.session_pack_id
    left join public.crm_contacts c on c.id = p.crm_contact_id
    left join public.partner_earnings pe on pe.order_id = o.id
    order by o.created_at desc;
end $function$;

-- DROP clears the previous grants and CREATE grants EXECUTE to PUBLIC by
-- default, which includes anon. Re-establish exactly the old surface:
-- signed-in users only, and the function's own finance:view check inside.
revoke all on function public.finance_orders() from public;
revoke all on function public.finance_orders() from anon;
grant execute on function public.finance_orders() to authenticated, service_role;

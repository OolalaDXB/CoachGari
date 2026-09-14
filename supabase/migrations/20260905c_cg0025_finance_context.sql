-- CG-002.5 — minimum customer context for reconciliation.
-- Finance never reads contacts or bookings. Where matching a Stripe receipt
-- needs a hint, finance_orders() exposes a masked contact (first character +
-- domain for an email, last two digits for a phone) — never the name, never
-- the full contact, never a message.
create or replace function public.mask_contact(p text)
returns text language sql immutable set search_path = '' as $$
  select case
    when p is null or p = '' then null
    when p ~ '@' then left(split_part(p, '@', 1), 1) || '***@' || split_part(p, '@', 2)
    else regexp_replace(p, '.(?=.{2})', '•', 'g')
  end
$$;
revoke execute on function public.mask_contact(text) from public, anon, authenticated;

drop function if exists public.finance_orders();
create or replace function public.finance_orders()
returns table (
  id uuid, reference text, status text, currency text, gross_amount int, paid_at timestamptz, created_at timestamptz, stripe_checkout_session_id text,
  booking_reference text, session_start_at timestamptz, session_timezone text, booking_status text, delivery_mode text,
  service_slug text, service_title text, customer_hint text,
  stripe_fee int, refund_amount int, chargeback_amount int, net_collected int, oolala_commission int, gari_payable int,
  earning_status text, settlement_id uuid, adjusted_at timestamptz)
language plpgsql stable security definer set search_path = '' as $$
begin
  if not public.has_permission('finance:view') then raise exception 'forbidden' using errcode = '42501'; end if;
  return query
    select o.id, o.reference, o.status, o.currency, o.gross_amount, o.paid_at, o.created_at, o.stripe_checkout_session_id,
           b.reference, b.start_at, b.session_timezone, b.status, b.delivery_mode,
           s.slug, s.title, public.mask_contact(o.customer_contact),
           pe.stripe_fee, pe.refund_amount, pe.chargeback_amount, pe.net_collected, pe.oolala_commission, pe.gari_payable,
           pe.status, pe.settlement_id, pe.adjusted_at
    from public.orders o
    join public.bookings b on b.id = o.booking_id
    join public.services s on s.id = b.service_id
    left join public.partner_earnings pe on pe.order_id = o.id
    order by o.created_at desc;
end $$;
revoke execute on function public.finance_orders() from public, anon;
grant  execute on function public.finance_orders() to authenticated, service_role;

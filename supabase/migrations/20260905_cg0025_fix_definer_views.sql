-- CG-002.5 fix — the Supabase linter rates SECURITY DEFINER *views* as an
-- error (0010). Same protection, expressed as SECURITY DEFINER *functions*
-- that check the permission themselves (consistent with every other RPC).
drop view if exists public.finance_orders;
drop view if exists public.finance_webhook_log;

create or replace function public.finance_orders()
returns table (
  id uuid, reference text, status text, currency text, gross_amount int, paid_at timestamptz, created_at timestamptz, stripe_checkout_session_id text,
  booking_reference text, session_start_at timestamptz, session_timezone text, booking_status text, delivery_mode text,
  service_slug text, service_title text,
  stripe_fee int, refund_amount int, chargeback_amount int, net_collected int, oolala_commission int, gari_payable int,
  earning_status text, settlement_id uuid, adjusted_at timestamptz)
language plpgsql stable security definer set search_path = '' as $$
begin
  if not public.has_permission('finance:view') then raise exception 'forbidden' using errcode = '42501'; end if;
  return query
    select o.id, o.reference, o.status, o.currency, o.gross_amount, o.paid_at, o.created_at, o.stripe_checkout_session_id,
           b.reference, b.start_at, b.session_timezone, b.status, b.delivery_mode,
           s.slug, s.title,
           pe.stripe_fee, pe.refund_amount, pe.chargeback_amount, pe.net_collected, pe.oolala_commission, pe.gari_payable,
           pe.status, pe.settlement_id, pe.adjusted_at
    from public.orders o
    join public.bookings b on b.id = o.booking_id
    join public.services s on s.id = b.service_id
    left join public.partner_earnings pe on pe.order_id = o.id
    order by o.created_at desc;
end $$;

create or replace function public.finance_webhook_log()
returns table (id uuid, provider text, event_id text, event_type text, status text, note text, received_at timestamptz, processed_at timestamptz)
language plpgsql stable security definer set search_path = '' as $$
begin
  if not public.has_permission('finance:view') then raise exception 'forbidden' using errcode = '42501'; end if;
  return query
    select w.id, w.provider, w.event_id, w.event_type, w.status, w.note, w.received_at, w.processed_at
    from public.webhook_events w order by w.received_at desc limit 200;
end $$;

revoke execute on function public.finance_orders(), public.finance_webhook_log() from public, anon;
grant  execute on function public.finance_orders(), public.finance_webhook_log() to authenticated, service_role;

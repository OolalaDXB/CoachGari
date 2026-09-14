-- =====================================================================
-- Coach Gari — Overview revenue is net of refunds
--
-- A refunded purchase must show zero. 20261036 excluded fully refunded orders
-- by status, which happened to give zero for a full refund but ignored partial
-- refunds and depended on the status label. This nets the succeeded refunds
-- against the gross, per order, in the month the order was paid: a full refund
-- reads 0, a partial one reads what was kept. Same gating, same shape.
-- =====================================================================
create or replace function public.admin_overview_charts(p_months int default 12)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare out jsonb := '{}'::jsonb; n int := greatest(1, least(coalesce(p_months, 12), 36));
begin
  if public.has_permission('finance:view') then
    out := out || jsonb_build_object('revenue', (
      with months as (select date_trunc('month', now()) - (i || ' months')::interval as m from generate_series(n - 1, 0, -1) i),
           paid as (select date_trunc('month', o.paid_at) as m, o.currency,
                           sum(o.gross_amount - coalesce((select sum(r.amount) from public.refunds r where r.order_id = o.id and r.status = 'succeeded'), 0))::bigint as amount
                      from public.orders o
                     where o.paid_at is not null and o.status in ('paid','partially_refunded','refunded')
                       and o.paid_at >= (select min(m) from months)
                     group by 1, 2)
      select coalesce(jsonb_agg(jsonb_build_object(
               'month', to_char(months.m, 'YYYY-MM'),
               'by_currency', coalesce((select jsonb_object_agg(p.currency, greatest(p.amount, 0)) from paid p where p.m = months.m), '{}'::jsonb))
             order by months.m), '[]'::jsonb)
        from months));
  end if;
  if public.has_permission('coach:operations') or public.has_permission('client_profile:view') then
    out := out || jsonb_build_object('pipeline', (
      with months as (select date_trunc('month', now()) - (i || ' months')::interval as m from generate_series(n - 1, 0, -1) i)
      select coalesce(jsonb_agg(jsonb_build_object(
               'month', to_char(months.m, 'YYYY-MM'),
               'enquiries', (select count(*) from public.contacts c where date_trunc('month', c.created_at) = months.m),
               'clients',   (select count(*) from public.crm_contacts k where k.status in ('active','past') and date_trunc('month', k.first_seen_at) = months.m),
               'sessions',  (select count(*) from public.bookings b where b.status in ('confirmed','completed') and date_trunc('month', b.start_at) = months.m))
             order by months.m), '[]'::jsonb)
        from months));
  end if;
  if out = '{}'::jsonb then raise exception 'forbidden' using errcode = '42501'; end if;
  return out;
end $$;
revoke all on function public.admin_overview_charts(int) from public, anon;
grant execute on function public.admin_overview_charts(int) to authenticated, service_role;

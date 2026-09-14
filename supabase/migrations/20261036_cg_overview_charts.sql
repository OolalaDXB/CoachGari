-- =====================================================================
-- Coach Gari — Overview: two charts' worth of numbers, month by month
--
-- The Overview showed counters and nothing over time. admin_overview_charts()
-- returns, per calendar month over the last N months (default 12, capped at 36):
--   revenue  (finance:view)        — paid orders by paid_at month, per currency,
--                                    gross as collected; refunds are not netted
--                                    here (Finance is the ledger, this is the shape)
--   pipeline (coach:operations or client_profile:view)
--            — enquiries received (public.contacts.created_at),
--              clients won (crm_contacts.first_seen_at, status active/past),
--              sessions held (bookings completed/confirmed by start_at)
-- Same gating shape as admin_overview: each block only with its permission,
-- nothing at all without one. Months with no rows still appear (zero), so the
-- x-axis never lies by omission.
-- =====================================================================
create or replace function public.admin_overview_charts(p_months int default 12)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare out jsonb := '{}'::jsonb; n int := greatest(1, least(coalesce(p_months, 12), 36));
begin
  if public.has_permission('finance:view') then
    out := out || jsonb_build_object('revenue', (
      with months as (select date_trunc('month', now()) - (i || ' months')::interval as m from generate_series(n - 1, 0, -1) i),
           paid as (select date_trunc('month', o.paid_at) as m, o.currency, sum(o.gross_amount)::bigint as amount
                      from public.orders o
                     where o.paid_at is not null and o.status in ('paid','partially_refunded')
                       and o.paid_at >= (select min(m) from months)
                     group by 1, 2)
      select coalesce(jsonb_agg(jsonb_build_object(
               'month', to_char(months.m, 'YYYY-MM'),
               'by_currency', coalesce((select jsonb_object_agg(p.currency, p.amount) from paid p where p.m = months.m), '{}'::jsonb))
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

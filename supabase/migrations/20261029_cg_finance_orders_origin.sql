/* =============================================================
   CG — the ledger row carries its origin and direction
   The ledger lists every order, and off-platform orders now carry a commission.
   Without the origin on the row, a receivable would read as a commission with
   "payable 0" — an ambiguity the back office must not have to guess at. The
   return type gains three columns, so the function is dropped and recreated,
   then its grants are restored explicitly (a replace would not reset them, but
   a drop does).
   ============================================================= */
drop function if exists public.finance_orders();
create function public.finance_orders()
returns table(id uuid, reference text, status text, currency text, gross_amount integer, paid_at timestamptz, created_at timestamptz,
              stripe_checkout_session_id text, booking_reference text, session_start_at timestamptz, session_timezone text, booking_status text,
              delivery_mode text, service_slug text, service_title text, customer_hint text, stripe_fee integer, refund_amount integer,
              chargeback_amount integer, net_collected integer, oolala_commission integer, gari_payable integer, earning_status text,
              settlement_id uuid, adjusted_at timestamptz, order_reason text, pack_reference text, crm_contact_id uuid, fee_known boolean,
              ledger_currency text, collection_origin text, direction text, studio_receivable integer)
language plpgsql stable security definer set search_path = '' as $$
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
           pm.fee_known, coalesce(pe.currency, o.currency),
           pe.collection_origin, pe.direction, pe.studio_receivable
    from public.orders o
    left join public.bookings b on b.id = o.booking_id
    left join public.services s on s.id = b.service_id
    left join public.session_packs p on p.id = o.session_pack_id
    left join public.crm_contacts c on c.id = p.crm_contact_id
    left join public.partner_earnings pe on pe.order_id = o.id
    left join public.payments pm on pm.id = pe.payment_id
    order by o.created_at desc;
end $$;
revoke all    on function public.finance_orders() from public, anon;
grant execute on function public.finance_orders() to authenticated, service_role;

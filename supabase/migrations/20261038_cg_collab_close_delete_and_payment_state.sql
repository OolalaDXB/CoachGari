-- =====================================================================
-- Coach Gari — Collaborations: close or delete any deal; a cancelled checkout is not "waiting"
--
-- Seen on CL-0E3014: the deal was agreed, the Stripe checkout was abandoned
-- (order cancelled), yet the list said "Waiting on: Payment" and the admin
-- offered neither Close nor Delete on an agreed deal.
--   1. collab_payment_sync is now driven by a trigger on orders (before, nothing
--      in production called it — only the test suite did). A cancelled or failed
--      checkout puts the payment row back to 'requested': the coach's request
--      still stands and the room can start a fresh checkout (collab_pay_start
--      replaces a closed order). Only a paid order moves it to 'paid'. The rows
--      that drifted are re-synced here once.
--   2. "waiting on payment" (list) and the payment reminder look at the ORDER:
--      a paid order is never "waiting", whatever the row says.
--   3. collab_admin_delete(id): removes a deal for good — proposals and payment
--      rows by cascade, audited by reference only. Refused when a payment was
--      actually collected (the ledger keeps its order; close the deal instead).
-- Close (status 'closed') was already possible on every status through
-- collab_set_status; the back-office simply did not show the button on agreed.
-- =====================================================================

-- ---------- 1. keep the payment row in step with its order ----------
create or replace function public.collab_payment_sync(p_order_reference text)
returns void language plpgsql volatile security definer set search_path = '' as $$
declare o public.orders%rowtype;
begin
  select * into o from public.orders where reference = p_order_reference;
  if not found then return; end if;
  update public.collaboration_payments
     set status = case when o.status in ('paid','partially_refunded','refunded') then 'paid'
                       when o.status in ('cancelled','failed') then 'requested'      -- the request stands; the checkout is retried from the room
                       else status end
   where order_reference = o.reference and status <> 'cancelled';
end $$;

create or replace function public.collab_payment_sync_on_order() returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if new.order_reason = 'collaboration' and new.status is distinct from old.status then perform public.collab_payment_sync(new.reference); end if;
  return new;
end $$;
drop trigger if exists orders_collab_payment_sync on public.orders;
create trigger orders_collab_payment_sync after update of status on public.orders for each row execute function public.collab_payment_sync_on_order();
-- the rows that drifted before the trigger existed
update public.collaboration_payments cp set status = 'requested'
  from public.orders o where o.reference = cp.order_reference and o.status in ('cancelled','failed') and cp.status = 'checkout';
update public.collaboration_payments cp set status = 'paid'
  from public.orders o where o.reference = cp.order_reference and o.status in ('paid','partially_refunded','refunded') and cp.status in ('requested','checkout');

-- ---------- 2. waiting on payment = a request that has not been paid ----------
create or replace function public.collab_admin_list(p_status text default null, p_search text default null)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare out jsonb; s text := nullif(btrim(coalesce(p_search,'')),'');
begin
  if not public.has_permission('collab:view') then raise exception 'forbidden' using errcode = '42501'; end if;
  select coalesce(jsonb_agg(row order by (row ->> 'updated_at') desc), '[]'::jsonb) into out from (
    select jsonb_strip_nulls(jsonb_build_object(
      'id', d.id, 'public_ref', d.public_ref, 'contact_name', d.contact_name, 'company', d.company,
      'collaboration_type', d.collaboration_type, 'title', d.title, 'status', d.status,
      'latest_amount', lp.monetary_amount, 'latest_currency', lp.currency,
      'waiting_on', case
        when d.status = 'agreed' and exists (select 1 from public.collaboration_payments cp
                                              left join public.orders o on o.reference = cp.order_reference
                                              where cp.collaboration_id = d.id and cp.status in ('requested','checkout')
                                                and (o.reference is null or o.status not in ('paid','partially_refunded','refunded'))) then 'payment'
        when d.status not in ('new','reviewing','negotiating') then null
        when lp.proposed_by = 'coach' and lp.accepted_at is null and lp.declined_at is null and lp.superseded_at is null
             and (lp.expires_at is null or lp.expires_at > now()) then 'them'
        else 'you' end,
      'waiting_since', coalesce(lp.created_at, d.created_at),
      'updated_at', d.updated_at)) as row
    from public.collaboration_deals d
    left join lateral (select monetary_amount, currency, proposed_by, accepted_at, declined_at, superseded_at, expires_at, created_at
                         from public.collaboration_proposals p
                        where p.collaboration_id = d.id order by version_number desc limit 1) lp on true
    where (p_status is null or d.status = p_status)
      and (s is null or d.contact_name ilike '%'||s||'%' or d.company ilike '%'||s||'%' or d.public_ref ilike '%'||s||'%' or d.title ilike '%'||s||'%')
    order by d.updated_at desc limit 300) t;
  return out;
end $$;

create or replace function public.collab_reminders(p_after interval default interval '3 days')
returns int language plpgsql volatile security definer set search_path = '' as $$
declare n int := 0; r record; owner text := public.email_owner_address();
begin
  for r in
    select d.id, d.public_ref, d.contact_name, d.contact_email, p.version_number, p.monetary_amount, p.currency, p.expires_at
      from public.collaboration_deals d
      join lateral (select * from public.collaboration_proposals p where p.collaboration_id = d.id order by version_number desc limit 1) p on true
     where d.status in ('new','reviewing','negotiating') and d.contact_email is not null and d.token_revoked_at is null
       and p.proposed_by = 'coach' and p.accepted_at is null and p.declined_at is null and p.superseded_at is null
       and (p.expires_at is null or p.expires_at > now()) and p.created_at < now() - p_after
  loop
    if public.email_queue('collab_reminder', r.contact_email,
         jsonb_build_object('about', 'proposal', 'public_ref', r.public_ref, 'name', r.contact_name, 'version', r.version_number,
                            'monetary_amount', r.monetary_amount, 'currency', r.currency, 'expires_at', r.expires_at, 'collab_id', r.id),
         'collab:' || r.id || ':reminder:proposal:' || r.version_number, null, null, null) is not null then n := n + 1; end if;
  end loop;
  for r in
    select d.id, d.public_ref, d.contact_name, d.contact_email, cp.id as pid, cp.amount, cp.currency, cp.label
      from public.collaboration_payments cp join public.collaboration_deals d on d.id = cp.collaboration_id
      left join public.orders o on o.reference = cp.order_reference
     where cp.status in ('requested','checkout') and cp.created_at < now() - p_after
       and (o.reference is null or o.status not in ('paid','partially_refunded','refunded'))   -- paid (sync pending): nothing to nudge
       and d.status = 'agreed' and d.contact_email is not null and d.token_revoked_at is null
  loop
    if public.email_queue('collab_reminder', r.contact_email,
         jsonb_build_object('about', 'payment', 'public_ref', r.public_ref, 'name', r.contact_name,
                            'amount', r.amount, 'currency', r.currency, 'label', r.label, 'collab_id', r.id),
         'collab:' || r.pid || ':reminder:payment', null, null, null) is not null then n := n + 1; end if;
  end loop;
  for r in
    select d.id, d.public_ref, coalesce(d.contact_name, d.company) as name, p.version_number, p.monetary_amount, p.currency
      from public.collaboration_deals d
      join lateral (select * from public.collaboration_proposals p where p.collaboration_id = d.id order by version_number desc limit 1) p on true
     where d.status in ('new','reviewing','negotiating')
       and p.proposed_by = 'counterparty' and p.accepted_at is null and p.declined_at is null and p.superseded_at is null
       and p.created_at < now() - p_after
  loop
    if public.email_queue('collab_reminder', owner,
         jsonb_build_object('about', 'counter', 'public_ref', r.public_ref, 'name', r.name, 'version', r.version_number,
                            'monetary_amount', r.monetary_amount, 'currency', r.currency),
         'collab:' || r.id || ':reminder:owner:' || r.version_number, null, null, null) is not null then n := n + 1; end if;
  end loop;
  for r in
    select d.id, d.public_ref, coalesce(d.contact_name, d.company) as name, d.title
      from public.collaboration_deals d
     where d.status = 'new' and d.created_at < now() - p_after
       and not exists (select 1 from public.collaboration_proposals p where p.collaboration_id = d.id)
  loop
    if public.email_queue('collab_reminder', owner,
         jsonb_build_object('about', 'new', 'public_ref', r.public_ref, 'name', r.name, 'title', r.title),
         'collab:' || r.id || ':reminder:owner:new', null, null, null) is not null then n := n + 1; end if;
  end loop;
  return n;
end $$;

-- ---------- 3. delete a deal for good (never one that collected money) ----------
create or replace function public.collab_admin_delete(p_id uuid)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare e text := public.current_email(); d public.collaboration_deals;
begin
  if not public.has_permission('collab:manage') then raise exception 'forbidden' using errcode = '42501'; end if;
  select * into d from public.collaboration_deals where id = p_id for update;
  if not found then raise exception 'collaboration not found' using errcode = 'P0002'; end if;
  if exists (select 1 from public.collaboration_payments cp join public.orders o on o.reference = cp.order_reference
              where cp.collaboration_id = d.id and o.status in ('paid','partially_refunded','refunded')) then
    raise exception 'a payment was collected on this collaboration; close it instead of deleting it' using errcode = 'P0003';
  end if;
  delete from public.collaboration_deals where id = d.id;   -- proposals and payment rows by cascade; orders stay in the ledger
  insert into public.admin_audit (area, entity_id, action, changed_by, summary)
  values ('collaboration', d.id::text, 'delete', e, jsonb_build_object('public_ref', d.public_ref, 'status', d.status));
  return jsonb_build_object('ok', true, 'public_ref', d.public_ref);
end $$;
revoke all on function public.collab_admin_delete(uuid) from public, anon;
grant execute on function public.collab_admin_delete(uuid) to authenticated, service_role;

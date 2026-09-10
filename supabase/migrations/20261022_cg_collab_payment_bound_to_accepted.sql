-- =====================================================================
-- Coach Gari — P1: bind a collaboration payment to the ACCEPTED proposal
--
-- collab_payment_request accepted any p_amount / p_currency once the deal was
-- 'agreed', so an operator could charge an amount or a currency the counterparty
-- never agreed to — including on a deal whose accepted terms are non-cash only.
-- collab_payment_request is the single writer of collaboration_payments.
--
-- Rules now enforced against collaboration_deals.accepted_proposal_id:
--   * accepted proposal with monetary_amount NULL (non-cash) → every monetary
--     request is refused (P0003). Non-cash consideration is never charged.
--   * currency must equal the accepted proposal's currency (22023 otherwise).
--   * the cumulative total of this proposal's payment requests (excluding
--     'cancelled') may not exceed the accepted monetary_amount (P0003).
-- The cap is scoped to the CURRENTLY accepted proposal, so accepting a new
-- proposal — the only explicit act that changes the agreed terms — is the only
-- way to raise it. Instalments are still fine under the agreed total.
-- =====================================================================

create or replace function public.collab_payment_request(p_id uuid, p_amount int, p_currency text, p_label text default null)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare e text := public.current_email(); d public.collaboration_deals; cp public.collaboration_payments;
  pr public.collaboration_proposals; already int; cur text := upper(coalesce(p_currency,''));
begin
  if not public.has_permission('collab:manage') then raise exception 'forbidden' using errcode = '42501'; end if;
  select * into d from public.collaboration_deals where id = p_id;
  if not found then raise exception 'collaboration not found' using errcode = 'P0002'; end if;
  if d.status <> 'agreed' or d.accepted_proposal_id is null then raise exception 'agree the terms before requesting a payment' using errcode = 'P0003'; end if;
  if cur !~ '^[A-Z]{3}$' then raise exception 'currency required (ISO 4217)' using errcode = '22023'; end if;
  if p_amount is null or p_amount <= 0 then raise exception 'amount required' using errcode = '22023'; end if;

  -- The money is bound to the ACCEPTED proposal: never to whatever the caller passes.
  select * into pr from public.collaboration_proposals where id = d.accepted_proposal_id;
  if not found then raise exception 'accepted proposal not found' using errcode = 'P0002'; end if;
  if pr.monetary_amount is null then
    raise exception 'the accepted terms carry no cash component; non-cash consideration is never charged' using errcode = 'P0003';
  end if;
  if cur <> upper(coalesce(pr.currency, '')) then
    raise exception 'payment currency must match the accepted proposal (%)', pr.currency using errcode = '22023';
  end if;
  -- cumulative cap, scoped to the currently accepted proposal: accepting a NEW proposal
  -- is the only way to raise it (payments carry the proposal they were agreed under).
  select coalesce(sum(amount), 0) into already from public.collaboration_payments
   where collaboration_id = d.id and proposal_id = d.accepted_proposal_id and status <> 'cancelled';
  if already + p_amount > pr.monetary_amount then
    raise exception 'requested payments (%) would exceed the agreed amount (%)', already + p_amount, pr.monetary_amount using errcode = 'P0003';
  end if;

  insert into public.collaboration_payments (collaboration_id, proposal_id, label, amount, currency, status, created_by)
  values (d.id, d.accepted_proposal_id, nullif(left(btrim(coalesce(p_label,'')),120),''), p_amount, cur, 'requested', e)
  returning * into cp;
  if d.contact_email is not null then
    perform public.email_queue('collab_payment_ready', d.contact_email,
      jsonb_build_object('public_ref', d.public_ref, 'name', d.contact_name, 'amount', cp.amount, 'currency', cp.currency, 'label', cp.label, 'collab_id', d.id),
      'collab:' || cp.id || ':payment_ready', null, null, null);
  end if;
  insert into public.admin_audit (area, entity_id, action, changed_by, summary)
  values ('collaboration', d.id::text, 'payment_request', e, jsonb_build_object('amount', cp.amount, 'currency', cp.currency, 'label', cp.label));
  return jsonb_build_object('ok', true, 'id', cp.id, 'amount', cp.amount, 'currency', cp.currency);
end $$;

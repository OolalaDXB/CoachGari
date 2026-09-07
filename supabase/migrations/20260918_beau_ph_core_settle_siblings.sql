-- =====================================================================
-- BEAU PH core — a paid request settles its siblings
--
-- An external order can be offered on several rails at once (card + Aani +
-- bank transfer). The moment ONE request is paid, the other live requests
-- for the same order can never be paid (one paid request per order — the
-- unique index already forbids it); they are now cancelled explicitly by
-- the core with the reason "settled via <rail>", so the state of every
-- request is honest and a late provider event on a sibling is refused as an
-- illegal transition (evidence kept). Note for online rails: the provider-
-- side session (e.g. a Stripe Checkout) is not expired here — the DB cannot
-- call the provider; the adapter's cancel() is the V1 follow-up.
-- Forward migration only.
-- =====================================================================

create or replace function beau_ph.record_event(p_request_id uuid, p_to text, p_actor text, p_actor_id text, p_provider_event_id uuid,
                                                p_amount int, p_currency text, p_provider_status text, p_provider_reference text,
                                                p_payment_reference text, p_evidence jsonb)
returns beau_ph.payment_events language plpgsql volatile security definer set search_path = '' as $$
declare r beau_ph.payment_requests%rowtype; ev beau_ph.payment_events%rowtype; sib uuid;
begin
  select * into r from beau_ph.payment_requests where id = p_request_id for update;
  if not found then raise exception 'request not found' using errcode = 'P0002'; end if;
  if not beau_ph.transition_allowed(r.status, p_to) then
    raise exception 'illegal transition % -> %', r.status, p_to using errcode = 'P0003';
  end if;
  insert into beau_ph.payment_events (request_id, provider_event_id, from_status, to_status, amount, currency, provider_status,
                                      provider_reference, actor, actor_id, evidence)
  values (r.id, p_provider_event_id, r.status, p_to, p_amount, p_currency, p_provider_status,
          coalesce(p_payment_reference, p_provider_reference), p_actor, p_actor_id, coalesce(p_evidence, '{}'::jsonb))
  returning * into ev;
  update beau_ph.payment_requests set
    status = p_to,
    paid_at = case when p_to = 'paid' then coalesce(paid_at, now()) else paid_at end,
    provider_reference = coalesce(p_provider_reference, provider_reference),
    payment_reference  = coalesce(p_payment_reference, payment_reference),
    updated_at = now()
  where id = r.id;
  if p_to in ('paid','expired','cancelled','failed') then
    update beau_ph.payment_attempts set status = case when p_to = 'paid' then 'completed' else p_to end
     where request_id = r.id and status = 'open';
  end if;
  if p_to = 'paid' then
    -- the order is settled: other live requests (other rails) for the same external order can no longer be paid
    for sib in select pr.id from beau_ph.payment_requests pr
                where pr.merchant_id = r.merchant_id and pr.external_reference = r.external_reference and pr.id <> r.id
                  and pr.status in ('created','pending','requires_action') loop
      perform beau_ph.cancel_request(sib, 'system', null, 'settled via ' || r.provider_key);
    end loop;
  end if;
  return ev;
end $$;
revoke all on function beau_ph.record_event(uuid, text, text, text, uuid, int, text, text, text, text, jsonb) from public, anon, authenticated;
grant execute on function beau_ph.record_event(uuid, text, text, text, uuid, int, text, text, text, text, jsonb) to service_role;

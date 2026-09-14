-- =====================================================================
-- The commission is never charged on the gross because the fee is late
--
-- THE DEFECT. recompute_earning computes
--     net = gross − fee − refunds − chargebacks − tax
-- and takes the fee from public.payments.fee_amount. That column is 0 until
-- Stripe tells us the real figure, and `fee_known` is the flag that says
-- whether 0 means "no fee" or "we do not know yet". Nothing read the flag.
--
-- On the one live order the fee is still unknown (the balance transaction had
-- not landed when the webhook ran), so net = gross, and 10 % of gross is more
-- than 10 % of net. That order was refunded, so the error is worth nothing
-- there — but on a real sale it would over-charge the coach on every card
-- payment, quietly, in his favour never.
--
-- WHY THE FEE WAS MISSING. Stripe creates the balance transaction
-- asynchronously; the adapter retries three times over about 1.6 seconds
-- inside the webhook and then gives up, because a webhook that waits minutes is
-- a webhook that times out. The charge id arrived, the fee did not, and nothing
-- ever went back for it. Giving up was right; never returning was the bug.
--
-- THE TWO HALVES OF THE FIX.
--   1. An earning whose fee is EXPECTED but unknown is marked 'fee_pending'.
--      create_settlement sweeps status = 'open' only, so such a row cannot be
--      paid out on a figure we know to be wrong. The numbers are still written
--      and still shown — the back-office needs to see the sale — they are just
--      not payable yet.
--   2. public.payment_fee_record() lets the fee land later, from a sweep that
--      asks Stripe again (the stripe-fees function), and recomputes the earning
--      on the true net. The status then returns to 'open' by itself.
--
-- WHAT COUNTS AS "EXPECTED". Only a rail that goes through a payment service
-- provider takes a cut, and those are exactly the rails whose origin is
-- 'platform'. On a manual rail — cash, a bank transfer, Aani — fee_known is
-- false and always will be, because there is no fee to know; blocking those
-- would freeze the ledger for ever over a fee that does not exist.
-- =====================================================================

-- ---------- 1. does this rail take a provider fee at all? ----------
create or replace function public.fee_is_expected(p_provider text)
returns boolean language sql stable security definer set search_path = '' as $$
  select coalesce((select cr.origin = 'platform' from public.collection_rails cr where cr.rail = p_provider), false)
$$;
comment on function public.fee_is_expected(text) is
  'True when the rail settles through a PSP that takes a cut, so fee_known = false means "not yet" rather than "none".';
revoke execute on function public.fee_is_expected(text) from public, anon;
grant  execute on function public.fee_is_expected(text) to authenticated, service_role;

-- ---------- 2. a fourth state: computed, shown, not payable ----------
alter table public.partner_earnings drop constraint if exists partner_earnings_status_check;
alter table public.partner_earnings add constraint partner_earnings_status_check
  check (status = any (array['open', 'fee_pending', 'settled', 'cancelled']));
comment on column public.partner_earnings.status is
  'open = payable / collectable · fee_pending = the provider fee has not landed, so the net is provisional and the row must not be settled · settled · cancelled.';

-- ---------- 3. recompute reads the flag ----------
create or replace function public.recompute_earning(p_order_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  o public.orders%rowtype; p public.payments%rowtype;
  v_refunds int; v_chargebacks int; v_tax int := 0; v_net int; v_comm int; v_pay int; v_recv int;
  v_origin text; v_rate numeric(6,4); v_exempt_rate numeric; v_exempt_id uuid;
  v_prev_rate numeric(6,4); v_prev_exempt uuid; v_had_row boolean;
  v_pending boolean; v_status text;
  e public.partner_earnings%rowtype;
begin
  select * into o from public.orders where id = p_order_id;
  if not found then raise exception 'order not found' using errcode = 'P0002'; end if;
  select * into p from public.payments where order_id = o.id and status = 'succeeded' order by paid_at desc nulls last limit 1;
  if not found then return null; end if;

  -- ORIGIN first: who actually collected the money. The rail only maps to an origin. An
  -- unmapped rail counts as collected by Coach Gari, the conservative side, because it never
  -- claims Studio is holding funds it does not hold.
  select cr.origin into v_origin from public.collection_rails cr where cr.rail = p.provider;
  v_origin := coalesce(v_origin, 'direct');
  select co.rate into v_rate from public.commission_origins co where co.origin = v_origin;

  select commission_rate, exemption_id into v_prev_rate, v_prev_exempt
    from public.partner_earnings where order_id = o.id;
  v_had_row := found;
  -- an explicit per-order override still wins over the standard rate, exactly as before —
  -- but only a hand-set one, never a rate an exemption put there
  if v_had_row and v_prev_exempt is null then v_rate := v_prev_rate; end if;
  -- ... and a doubly signed exemption wins over both: it is the decision Gari and Studio took together
  select rate, exemption_id into v_exempt_rate, v_exempt_id from public.commission_exempt_rate(o.id);
  if v_exempt_id is not null then v_rate := v_exempt_rate; end if;

  select coalesce(sum(amount), 0) into v_refunds from public.refunds where order_id = o.id and status = 'succeeded';
  select coalesce(sum(amount), 0) into v_chargebacks from public.chargebacks where order_id = o.id and status = 'lost';
  v_net  := p.amount - p.fee_amount - v_refunds - v_chargebacks - v_tax;
  v_comm := greatest(0, round(v_net * v_rate))::int;
  if v_origin = 'platform' then
    v_pay := v_net - v_comm; v_recv := 0;      -- Oolala holds the cash and owes Gari the net
  else
    v_pay := 0; v_recv := v_comm;              -- Gari holds the cash and owes Studio the commission
  end if;

  /* The fee is expected on this rail and has not arrived: the net above is the
     gross, so the commission above is too big. Compute it anyway — the sale is
     real and the back-office has to show it — but say plainly that it cannot be
     paid out yet. A refunded order is the one exception worth making: the net is
     zero whatever the fee turns out to be, so nothing is waiting on it. */
  v_pending := public.fee_is_expected(p.provider) and not p.fee_known and v_refunds < p.amount;
  v_status  := case when v_pending then 'fee_pending' else 'open' end;

  insert into public.partner_earnings (order_id, payment_id, currency, gross_amount, stripe_fee, refund_amount, chargeback_amount,
                                       tax_amount, net_collected, commission_rate, oolala_commission, gari_payable,
                                       collection_origin, studio_receivable, exemption_id, status)
  values (o.id, p.id, coalesce(p.currency, o.currency), p.amount, p.fee_amount, v_refunds, v_chargebacks, v_tax, v_net, v_rate, v_comm, v_pay,
          v_origin, v_recv, v_exempt_id, v_status)
  on conflict (order_id) do update
    set payment_id = excluded.payment_id, currency = excluded.currency, gross_amount = excluded.gross_amount, stripe_fee = excluded.stripe_fee,
        refund_amount = excluded.refund_amount, chargeback_amount = excluded.chargeback_amount, tax_amount = excluded.tax_amount,
        net_collected = excluded.net_collected, oolala_commission = excluded.oolala_commission, gari_payable = excluded.gari_payable,
        collection_origin = excluded.collection_origin, studio_receivable = excluded.studio_receivable,
        -- an exemption is the one thing allowed to move a rate that was already set
        commission_rate = excluded.commission_rate, exemption_id = excluded.exemption_id,
        /* Only the two live states move. A settled row stays settled — the payout
           happened, and rewriting its status would hide that; it gets adjusted_at
           instead, exactly as before. A cancelled row stays cancelled. */
        status = case when public.partner_earnings.status in ('open', 'fee_pending') then excluded.status
                      else public.partner_earnings.status end,
        adjusted_at = case when public.partner_earnings.status = 'settled'
                            and (public.partner_earnings.net_collected <> excluded.net_collected
                                 or public.partner_earnings.oolala_commission <> excluded.oolala_commission) then now()
                           else public.partner_earnings.adjusted_at end
  returning * into e;
  return to_jsonb(e);
end $$;
revoke all on function public.recompute_earning(uuid) from public, anon, authenticated;
grant execute on function public.recompute_earning(uuid) to service_role;

-- ---------- 4. the fee, when it finally lands ----------
/* Idempotent and one-way: a fee that is already known is never overwritten by a
   later sweep, exactly like the webhook's own upsert. The fee must be in the
   currency the payment was taken in — a figure in the settlement currency of a
   Stripe account is a different number, and putting it here would understate or
   overstate the net without anyone being able to see why. */
create or replace function public.payment_fee_record(p_payment_id uuid, p_fee_amount int, p_fee_currency text,
                                                     p_charge_id text default null, p_balance_transaction_id text default null)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare pm public.payments%rowtype;
begin
  select * into pm from public.payments where id = p_payment_id for update;
  if not found then raise exception 'payment not found' using errcode = 'P0002'; end if;
  if pm.fee_known then return jsonb_build_object('ok', true, 'already_known', true, 'fee_amount', pm.fee_amount); end if;
  if p_fee_amount is null or p_fee_amount < 0 then raise exception 'a fee cannot be negative' using errcode = '22023'; end if;
  if upper(coalesce(p_fee_currency, '')) <> upper(pm.currency) then
    raise exception 'the fee is in % but the payment was taken in %', upper(coalesce(p_fee_currency, '?')), upper(pm.currency) using errcode = '22023';
  end if;
  if p_fee_amount > pm.amount then raise exception 'a fee larger than the payment is not a fee' using errcode = '22023'; end if;

  /* The two provider references are filled in if they were missing — the webhook
     had the charge but not the balance transaction, which is the whole reason
     this row is here — and never overwritten if they were already there. */
  update public.payments
     set fee_amount = p_fee_amount, fee_known = true, updated_at = now(),
         provider_charge_id = coalesce(provider_charge_id, nullif(p_charge_id, '')),
         provider_balance_transaction_id = coalesce(provider_balance_transaction_id, nullif(p_balance_transaction_id, ''))
   where id = pm.id;

  insert into public.admin_audit (area, entity_id, action, changed_by, summary)
  values ('payment', pm.id::text, 'fee_recorded', 'system:stripe-fees',
          jsonb_build_object('fee_amount', p_fee_amount, 'currency', upper(pm.currency)));

  return jsonb_build_object('ok', true, 'fee_amount', p_fee_amount, 'earning', public.recompute_earning(pm.order_id));
end $$;
revoke execute on function public.payment_fee_record(uuid, int, text, text, text) from public, anon, authenticated;
grant  execute on function public.payment_fee_record(uuid, int, text, text, text) to service_role;

-- ---------- 5. what the sweep asks for ----------
/* Only what it can act on: a succeeded payment, on a rail that charges a fee,
   whose fee is still unknown, with a provider reference to ask about. Ordered
   oldest first, and capped — a sweep that walks the whole history on every run
   is a sweep that will one day time out. */
create or replace function public.payments_awaiting_fee(p_limit int default 20)
returns jsonb language sql stable security definer set search_path = '' as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'payment_id', p.id, 'provider', p.provider, 'currency', p.currency, 'amount', p.amount,
           'payment_intent', p.provider_payment_intent_id, 'paid_at', p.paid_at) order by p.paid_at), '[]'::jsonb)
    from public.payments p
   where p.status = 'succeeded' and not p.fee_known
     and public.fee_is_expected(p.provider)
     and coalesce(p.provider_payment_intent_id, '') <> ''
   limit greatest(1, least(coalesce(p_limit, 20), 100));
$$;
revoke execute on function public.payments_awaiting_fee(int) from public, anon, authenticated;
grant  execute on function public.payments_awaiting_fee(int) to service_role;

-- ---------- 6. the key, the gate, the kick ----------
do $$
declare k text;
begin
  if not exists (select 1 from vault.decrypted_secrets where name = 'outbox_fees_key') then
    k := encode(extensions.gen_random_bytes(32), 'hex');
    perform vault.create_secret(k, 'outbox_fees_key',
      'Stripe fee sweep key (clear; only its SHA-256 hash is stored in public.outbox_keys)');
    insert into public.outbox_keys (name, key_sha256) values ('fees', extensions.digest(k, 'sha256'))
      on conflict (name) do update set key_sha256 = excluded.key_sha256;
  end if;
end $$;

create or replace function public.stripe_fees_authorize(p_key text)
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.outbox_keys k where k.name = 'fees' and length(coalesce(p_key, '')) = 64
                   and public.ct_bytea_eq(k.key_sha256, extensions.digest(p_key, 'sha256')))
$$;
revoke execute on function public.stripe_fees_authorize(text) from public, anon, authenticated;
grant  execute on function public.stripe_fees_authorize(text) to service_role;

create or replace function public.stripe_fees_kick()
returns bigint language plpgsql volatile security definer set search_path = '' as $$
declare k text; rid bigint;
begin
  if public.payments_awaiting_fee(1) = '[]'::jsonb then return null; end if;   -- an idle project does nothing
  select decrypted_secret into k from vault.decrypted_secrets where name = 'outbox_fees_key' limit 1;
  if k is null then return null; end if;
  select net.http_post(url := 'https://acrjrlgeeyseyolmofuq.supabase.co/functions/v1/stripe-fees',
                       headers := jsonb_build_object('Content-Type', 'application/json', 'x-outbox-key', k),
                       body := '{"action":"sweep"}'::jsonb, timeout_milliseconds := 30000) into rid;
  return rid;
end $$;
revoke execute on function public.stripe_fees_kick() from public, anon, authenticated;
grant  execute on function public.stripe_fees_kick() to service_role;

/* Every ten minutes. A balance transaction usually lands within seconds and
   occasionally takes hours; nothing is urgent here — the money is already in,
   and the only thing waiting is a payout that must not go out wrong. */
do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.unschedule(jobid) from cron.job where jobname = 'cg-stripe-fees';
    perform cron.schedule('cg-stripe-fees', '*/10 * * * *', $cron$select public.stripe_fees_kick()$cron$);
  end if;
end $$;

-- ---------- 7. put the existing rows into the right state ----------
/* One pass over what is already there, so the ledger stops claiming a net it
   does not have. Refunded orders keep their 'open' status: their net is zero
   whatever the fee turns out to be. */
do $$
declare r record;
begin
  for r in select order_id from public.partner_earnings where status = 'open' loop
    perform public.recompute_earning(r.order_id);
  end loop;
end $$;

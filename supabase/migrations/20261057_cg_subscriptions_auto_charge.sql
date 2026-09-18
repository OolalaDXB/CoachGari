-- =====================================================================
-- Recurring billing, part 2 of 2 — charging the card by itself
--
-- 20261056 made recurring billing real on every rail: a cycle is a pack, an
-- invoice goes out, the client pays by card, PayPal, Wise, transfer, Aani or
-- cash. This adds the one thing that only a card can do — collect without
-- anybody clicking anything — WITHOUT moving the schedule, the entitlement or
-- the ledger anywhere. A subscription on `auto` is the same subscription; only
-- the collection method differs.
--
-- WHY NOT STRIPE SUBSCRIPTIONS. Stripe can own a billing schedule, issue its
-- own invoices and dun its own failures, and doing it that way would have been
-- less code. It would also have created a SECOND schedule. Our cycles already
-- exist, are already tested, already mint the entitlement, and already work
-- for the clients who will never pay by card — the ones in Zimbabwe paying by
-- transfer, the one who pays cash after a session. Handing the calendar to
-- Stripe would mean two systems that both believe they know when October is
-- due, and every disagreement between them would surface as a client charged
-- twice or not at all. So the schedule stays here and Stripe is asked to do
-- one thing: charge this card, this much, now.
--
-- HOW THE CARD GETS THERE, AND WHY THERE IS NO "ADD A CARD" PAGE. The client
-- consents once, in Stripe's own UI, at the moment they are already paying —
-- the first invoice's checkout is created with `setup_future_usage=off_session`
-- when the subscription is set to auto, so the card they just used is kept for
-- next month. Nothing new to build, nothing new to explain, and no separate
-- flow for somebody to abandon. It also fails in the right direction: a client
-- who never pays the first invoice never grants a mandate, and there was
-- nothing to charge them for anyway.
--
-- A FAILED CHARGE IS NOT AN EMERGENCY. Cards expire, banks decline, limits
-- bite. When an off-session charge fails, the invoice simply stays open and
-- the ordinary chase takes over — the client gets the pay link they would have
-- got anyway and can pay by any rail. Three consecutive failures drop the
-- subscription back to `invoice` and clear the mandate, because a card that
-- has failed three times is not a card, and retrying it forever is how a
-- client ends up with a row of declines on their statement.
--
-- WHAT IS NEVER STORED HERE. No card number, no CVC, no token that can move
-- money on its own. A Stripe customer id and a payment-method id, which are
-- useless without the secret key, plus the brand and last four digits so a
-- human can tell which card it is. The secret key is a deployment secret and
-- never reaches the database.
--
-- ONE MORE THING THE HOST MUST NOT FORGET: the charge is a real Stripe
-- payment and arrives back as a real webhook. It is reconciled by a function
-- of its own rather than by editing the four-branch Checkout handler, exactly
-- as the PayPal rail was in 20261046 — same shape, same guards, same ledger.
-- =====================================================================

-- ---------- 1. the mandate ----------
alter table public.subscriptions add column if not exists stripe_customer_id       text;
alter table public.subscriptions add column if not exists stripe_payment_method_id text;
alter table public.subscriptions add column if not exists card_brand               text;
alter table public.subscriptions add column if not exists card_last4               text;
alter table public.subscriptions add column if not exists card_exp_month           int;
alter table public.subscriptions add column if not exists card_exp_year            int;
alter table public.subscriptions add column if not exists mandate_at               timestamptz;
alter table public.subscriptions add column if not exists charge_failures          int not null default 0;
alter table public.subscriptions add column if not exists last_charge_error        text;

comment on column public.subscriptions.stripe_payment_method_id is
  'A reference, not a credential: useless without the secret key, which never reaches this database. No card number is stored anywhere here.';

/* `auto` without a mandate is not a bug, it is the normal first state: the
   operator says "collect this one automatically", and the mandate arrives
   when the client pays the first invoice. */
create or replace function public.subscription_has_mandate(s public.subscriptions) returns boolean
language sql immutable as $$
  select coalesce(s.stripe_customer_id, '') <> '' and coalesce(s.stripe_payment_method_id, '') <> '';
$$;

-- ---------- 2. the charge queue ----------
/* A queue rather than a direct call, for the same reason every other outward
   call here is queued: the database must not block on Stripe, a failure must
   be retryable, and a run that dies halfway must not lose or repeat a charge.
   One row per cycle, ever — the unique index is the anti-double-charge. */
create table if not exists public.subscription_charges (
  id                uuid primary key default gen_random_uuid(),
  cycle_id          uuid not null references public.subscription_cycles(id) on delete cascade,
  subscription_id   uuid not null references public.subscriptions(id) on delete cascade,
  amount            int  not null check (amount > 0),
  currency          text not null check (currency ~ '^[A-Z]{3}$'),
  status            text not null default 'pending'
                    check (status in ('pending','sent','succeeded','failed','abandoned')),
  attempts          int  not null default 0,
  next_attempt_at   timestamptz not null default now(),
  provider_reference text,                       -- the PaymentIntent, once Stripe has one
  decline_code      text,
  error             text,
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now()
);
create unique index if not exists subscription_charges_one_per_cycle on public.subscription_charges (cycle_id);
create index if not exists subscription_charges_due_idx on public.subscription_charges (next_attempt_at) where status = 'pending';
drop trigger if exists subscription_charges_updated_at on public.subscription_charges;
create trigger subscription_charges_updated_at before update on public.subscription_charges
  for each row execute function public.set_updated_at();
alter table public.subscription_charges enable row level security;
revoke all on public.subscription_charges from anon, authenticated;

-- ---------- 3. does this pack's checkout need to keep the card? ----------
/* Asked by the checkout path before it builds the Stripe session. True only
   when this pack is a cycle of a subscription set to auto that has no mandate
   yet — so the card is kept exactly once, on the invoice that needs to do it,
   and never on an ordinary pack or a booking. */
create or replace function public.pack_wants_card_on_file(p_pack_id uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from public.subscription_cycles k
      join public.subscriptions s on s.id = k.subscription_id
     where k.session_pack_id = p_pack_id
       and s.billing_mode = 'auto'
       and s.status in ('active','past_due')
       and not public.subscription_has_mandate(s));
$$;
revoke execute on function public.pack_wants_card_on_file(uuid) from public, anon, authenticated;
grant  execute on function public.pack_wants_card_on_file(uuid) to service_role;

/* Recorded by the webhook after a Checkout session that saved the card. Keyed
   on the ORDER, because that is what the session carries and what the host
   already resolved. Idempotent: a replayed webhook records the same mandate. */
create or replace function public.subscription_mandate_record(p_order_reference text, p jsonb)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare o public.orders%rowtype; s public.subscriptions%rowtype; cust text; pm text;
begin
  cust := nullif(btrim(coalesce(p ->> 'customer_id', '')), '');
  pm   := nullif(btrim(coalesce(p ->> 'payment_method_id', '')), '');
  if cust is null or pm is null then return jsonb_build_object('ok', false, 'reason', 'incomplete'); end if;

  select * into o from public.orders where reference = p_order_reference;
  if not found or o.session_pack_id is null then return jsonb_build_object('ok', false, 'reason', 'no order'); end if;

  select s2.* into s from public.subscriptions s2
    join public.subscription_cycles k on k.subscription_id = s2.id
   where k.session_pack_id = o.session_pack_id;
  if not found then return jsonb_build_object('ok', false, 'reason', 'not a subscription'); end if;

  update public.subscriptions
     set stripe_customer_id = cust, stripe_payment_method_id = pm,
         card_brand = nullif(btrim(coalesce(p ->> 'brand', '')), ''),
         card_last4 = nullif(btrim(coalesce(p ->> 'last4', '')), ''),
         card_exp_month = nullif(p ->> 'exp_month', '')::int,
         card_exp_year  = nullif(p ->> 'exp_year', '')::int,
         mandate_at = coalesce(mandate_at, now()),
         charge_failures = 0, last_charge_error = null
   where id = s.id;

  /* Audited without anything that identifies the card beyond its last four —
     enough for a human to say "that one", useless to anybody else. */
  insert into public.admin_audit (area, entity_id, action, changed_by, summary)
  values ('subscription', s.id::text, 'mandate_recorded', 'system:stripe-webhook',
          jsonb_build_object('brand', p ->> 'brand', 'last4', p ->> 'last4', 'order', p_order_reference));
  return jsonb_build_object('ok', true, 'subscription_id', s.id);
end $$;
revoke execute on function public.subscription_mandate_record(text, jsonb) from public, anon, authenticated;
grant  execute on function public.subscription_mandate_record(text, jsonb) to service_role;

-- ---------- 4. what the sweep may charge ----------
/* Deliberately narrow. A cycle is chargeable only when ALL of this holds:
   the subscription is on auto and holds a mandate; the cycle is still open;
   its pack is genuinely unpaid (the fact every rail writes — so a client who
   paid by transfer yesterday is not charged today); the period has actually
   started, because charging for a month before it begins is indefensible;
   and no charge row exists yet, because the unique index is the last line of
   defence and should never be the first. */
create or replace function public.subscription_charges_enqueue()
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare r record; n int := 0; revived int := 0;
begin
  /* First, the ones that went out and never came back. A runner that died
     between claiming a row and recording its answer leaves the row 'sent' with
     a lease, and 'sent' is not claimable — so without this, a single crashed
     invocation would silently stop collecting that invoice for ever. Reviving
     it is safe precisely because the charge is idempotent on the row id: if
     Stripe did take the money, the retry returns the same PaymentIntent rather
     than a second one. After three attempts it is abandoned to a human instead
     of being tried for ever. */
  update public.subscription_charges
     set status = case when attempts >= 3 then 'abandoned' else 'pending' end,
         next_attempt_at = now(),
         error = coalesce(error, 'no answer from the charge run')
   where status = 'sent' and next_attempt_at <= now();
  get diagnostics revived = row_count;

  for r in
    select k.id as cycle_id, k.subscription_id, k.amount, k.currency
      from public.subscription_cycles k
      join public.subscriptions s on s.id = k.subscription_id
      join public.session_packs sp on sp.id = k.session_pack_id
     where s.billing_mode = 'auto' and s.status in ('active','past_due')
       and public.subscription_has_mandate(s)
       and k.status = 'issued' and sp.payment_status <> 'paid'
       and k.period_start <= current_date
       and not exists (select 1 from public.subscription_charges c where c.cycle_id = k.id)
     order by k.period_start
     limit 50
  loop
    insert into public.subscription_charges (cycle_id, subscription_id, amount, currency)
    values (r.cycle_id, r.subscription_id, r.amount, r.currency)
    on conflict (cycle_id) do nothing;
    n := n + 1;
  end loop;
  return jsonb_build_object('queued', n, 'revived', revived);
end $$;
revoke execute on function public.subscription_charges_enqueue() from public, anon, authenticated;
grant  execute on function public.subscription_charges_enqueue() to service_role;

/* Claimed one at a time with a lease, like every other outbox here: a second
   runner picks up nothing, and a runner that dies mid-flight leaves a row that
   comes back after the lease rather than a charge nobody knows about. */
create or replace function public.subscription_charge_claim(p_limit int default 5)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare out jsonb;
begin
  with due as (
    select c.id from public.subscription_charges c
     where c.status = 'pending' and c.next_attempt_at <= now()
     order by c.created_at
     limit greatest(1, least(coalesce(p_limit, 5), 20))
     for update skip locked),
  leased as (
    update public.subscription_charges c
       set status = 'sent', attempts = c.attempts + 1, next_attempt_at = now() + interval '15 minutes'
      from due where c.id = due.id
    returning c.*)
  select coalesce(jsonb_agg(jsonb_build_object(
           'charge_id', l.id, 'cycle_id', l.cycle_id, 'amount', l.amount, 'currency', l.currency,
           'attempt', l.attempts,
           'customer_id', s.stripe_customer_id, 'payment_method_id', s.stripe_payment_method_id,
           'order_reference', o.reference, 'description', sp.title,
           'customer_email', ct.email)), '[]'::jsonb) into out
    from leased l
    join public.subscriptions s on s.id = l.subscription_id
    join public.subscription_cycles k on k.id = l.cycle_id
    join public.session_packs sp on sp.id = k.session_pack_id
    left join public.crm_contacts ct on ct.id = s.crm_contact_id
    left join public.orders o on o.session_pack_id = sp.id and o.status = 'pending_payment';
  return out;
end $$;
revoke execute on function public.subscription_charge_claim(int) from public, anon, authenticated;
grant  execute on function public.subscription_charge_claim(int) to service_role;

/* The order a charge is made against. Created on demand through the ordinary
   RPC, so an auto charge and a client clicking "pay" land on the same row and
   the same guards — there is no second way to make an order here. */
create or replace function public.subscription_charge_order(p_cycle_id uuid)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare k public.subscription_cycles%rowtype;
begin
  select * into k from public.subscription_cycles where id = p_cycle_id;
  if not found or k.session_pack_id is null then raise exception 'cycle not found' using errcode = 'P0002'; end if;
  if k.status <> 'issued' then raise exception 'cycle is %', k.status using errcode = 'P0003'; end if;
  return public.create_order_for_pack(k.session_pack_id);
end $$;
revoke execute on function public.subscription_charge_order(uuid) from public, anon, authenticated;
grant  execute on function public.subscription_charge_order(uuid) to service_role;

/* The outcome. A success is NOT settled here — the webhook does that, exactly
   as it does for a card paid by hand, so there is one reconciliation path and
   one place a payment can be created. This only records what the API said. */
create or replace function public.subscription_charge_result(p_charge_id uuid, p_ok boolean,
                                                             p_provider_reference text default null,
                                                             p_error text default null,
                                                             p_decline_code text default null,
                                                             p_retryable boolean default false)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare c public.subscription_charges%rowtype; s public.subscriptions%rowtype; ct public.crm_contacts%rowtype; fails int;
  /* Two failures that are ours, not the card's: the mandate went between the
     enqueue and the run, or no order could be made. They must be recorded —
     the invoice did not get collected and somebody should see why — but they
     must NOT count towards dropping the card, because the card never said no.
     Counting them would have a working card thrown away after three
     deployment hiccups. */
  internal boolean := coalesce(p_decline_code, '') in ('no_mandate', 'no_order');
begin
  select * into c from public.subscription_charges where id = p_charge_id for update;
  if not found then raise exception 'charge not found' using errcode = 'P0002'; end if;

  if coalesce(p_ok, false) then
    update public.subscription_charges
       set status = 'succeeded', provider_reference = nullif(btrim(coalesce(p_provider_reference, '')), ''), error = null, decline_code = null
     where id = c.id;
    update public.subscriptions set charge_failures = 0, last_charge_error = null where id = c.subscription_id;
    insert into public.admin_audit (area, entity_id, action, changed_by, summary)
    values ('subscription', c.subscription_id::text, 'charged', 'system:subscription-charge',
            jsonb_build_object('amount', c.amount, 'currency', c.currency, 'payment_intent', p_provider_reference));
    return jsonb_build_object('ok', true);
  end if;

  /* A failure. The invoice stays open and the ordinary chase carries on — the
     client can still pay it on any rail, which is why nothing is cancelled and
     nobody is locked out.

     Something that failed because of the network or a 5xx goes back in the
     queue: the card was never asked, so asking again is not a second charge.
     A DECLINE is never retried automatically — a card that said no at seven
     will say no at eight, and the only thing repetition adds is a row of
     declines on the client's statement. */
  if coalesce(p_retryable, false) and c.attempts < 3 then
    update public.subscription_charges
       set status = 'pending', next_attempt_at = now() + (c.attempts * interval '10 minutes'),
           error = left(coalesce(p_error, 'retrying'), 300), decline_code = nullif(btrim(coalesce(p_decline_code, '')), '')
     where id = c.id;
    return jsonb_build_object('ok', false, 'retrying', true, 'attempts', c.attempts);
  end if;

  update public.subscription_charges
     set status = 'failed', provider_reference = nullif(btrim(coalesce(p_provider_reference, '')), ''),
         error = left(coalesce(p_error, 'declined'), 300), decline_code = nullif(btrim(coalesce(p_decline_code, '')), '')
   where id = c.id;

  if internal then
    insert into public.admin_audit (area, entity_id, action, changed_by, summary)
    values ('subscription', c.subscription_id::text, 'charge_skipped', 'system:subscription-charge',
            jsonb_build_object('reason', p_decline_code, 'error', left(coalesce(p_error, ''), 200)));
    return jsonb_build_object('ok', false, 'internal', true);
  end if;

  update public.subscriptions
     set charge_failures = charge_failures + 1, last_charge_error = left(coalesce(p_error, 'declined'), 300)
   where id = c.subscription_id
  returning charge_failures into fails;

  insert into public.admin_audit (area, entity_id, action, changed_by, summary)
  values ('subscription', c.subscription_id::text, 'charge_failed', 'system:subscription-charge',
          jsonb_build_object('amount', c.amount, 'currency', c.currency, 'decline_code', p_decline_code,
                             'error', left(coalesce(p_error, ''), 200), 'consecutive', fails));

  /* Three strikes. A card that has declined three times is not a card, and the
     honest thing is to stop pretending it is one: back to invoicing, mandate
     cleared, and Gari can see why. */
  if coalesce(fails, 0) >= 3 then
    update public.subscriptions
       set billing_mode = 'invoice', stripe_payment_method_id = null, stripe_customer_id = null,
           card_brand = null, card_last4 = null, card_exp_month = null, card_exp_year = null, mandate_at = null
     where id = c.subscription_id;
    select * into s from public.subscriptions where id = c.subscription_id;
    select * into ct from public.crm_contacts where id = s.crm_contact_id;
    if ct.email is not null then
      perform public.email_queue('subscription_card_failed', ct.email,
        jsonb_build_object('name', ct.display_name, 'title', s.title, 'amount', c.amount, 'currency', c.currency,
                           'pay_pack_id', (select k.session_pack_id from public.subscription_cycles k where k.id = c.cycle_id)),
        'sub:' || s.id || ':card_failed:' || c.id, null, null, null);
    end if;
    insert into public.admin_audit (area, entity_id, action, changed_by, summary)
    values ('subscription', c.subscription_id::text, 'mandate_dropped', 'system:subscription-charge',
            jsonb_build_object('after_failures', fails));
  end if;
  return jsonb_build_object('ok', false, 'consecutive_failures', fails);
end $$;
revoke execute on function public.subscription_charge_result(uuid, boolean, text, text, text, boolean) from public, anon, authenticated;
grant  execute on function public.subscription_charge_result(uuid, boolean, text, text, text, boolean) to service_role;

-- ---------- 5. the webhook path for an off-session charge ----------
/* Same shape and the same guards as process_paypal_event (20261046): a rail
   that is not Checkout gets its own reconciler rather than a fifth branch
   grafted onto the Checkout one. The order is found through the PaymentIntent
   metadata the charge set, and the amount is checked against the order before
   anything is credited — a PaymentIntent that names an order it does not match
   is recorded and ignored, never paid. */
create or replace function public.process_stripe_charge_event(p_event jsonb)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare
  ev_id text := p_event ->> 'id'; ev_type text := p_event ->> 'type'; obj jsonb := p_event -> 'data' -> 'object';
  enrich jsonb := coalesce(p_event -> '_enrich', '{}'::jsonb);
  o public.orders%rowtype; p public.payments%rowtype;
  v_ref text; v_amount int; v_currency text; v_pi text; v_fee int; v_fee_known boolean;
begin
  if ev_id is null or ev_type is null then raise exception 'malformed event' using errcode = '22023'; end if;
  insert into public.webhook_events (event_id, event_type, payload, status) values (ev_id, ev_type, p_event, 'received')
    on conflict (event_id) do nothing;
  if not found then
    return jsonb_build_object('event_id', ev_id, 'status', 'processed', 'duplicate', true);
  end if;

  v_pi := obj ->> 'id';
  v_ref := obj #>> '{metadata,order_reference}';
  /* Only OUR off-session charges are handled here. A PaymentIntent from the
     ordinary Checkout flow reaches its own handler and must not be touched
     twice, so the marker the charge sets is what admits it. */
  if coalesce(obj #>> '{metadata,cg_source}', '') <> 'subscription_auto' or coalesce(v_ref, '') = '' then
    update public.webhook_events set status = 'ignored', note = 'not an auto charge', processed_at = now() where event_id = ev_id;
    return jsonb_build_object('event_id', ev_id, 'status', 'ignored', 'note', 'not an auto charge');
  end if;

  select * into o from public.orders where reference = v_ref;
  if not found then
    update public.webhook_events set status = 'ignored', note = 'unknown order', processed_at = now() where event_id = ev_id;
    return jsonb_build_object('event_id', ev_id, 'status', 'ignored', 'note', 'unknown order');
  end if;

  if ev_type = 'payment_intent.payment_failed' then
    /* Recorded and left alone. The invoice stays open, the chase continues,
       and subscription_charge_result has already told the operator why. */
    update public.webhook_events set status = 'processed', note = 'charge failed', processed_at = now() where event_id = ev_id;
    return jsonb_build_object('event_id', ev_id, 'status', 'processed', 'order', o.reference, 'outcome', 'failed');
  end if;

  if ev_type <> 'payment_intent.succeeded' then
    update public.webhook_events set status = 'ignored', note = 'unhandled type', processed_at = now() where event_id = ev_id;
    return jsonb_build_object('event_id', ev_id, 'status', 'ignored', 'note', 'unhandled type');
  end if;

  v_amount := (obj ->> 'amount_received')::int;
  v_currency := upper(coalesce(obj ->> 'currency', ''));
  if v_amount is null or v_amount <> o.gross_amount or v_currency <> o.currency then
    update public.webhook_events set status = 'ignored',
           note = format('amount mismatch: got %s %s, order %s %s', v_amount, v_currency, o.gross_amount, o.currency),
           processed_at = now() where event_id = ev_id;
    return jsonb_build_object('event_id', ev_id, 'status', 'ignored', 'note', 'amount mismatch');
  end if;

  v_fee := nullif(enrich ->> 'fee_amount', '')::int;
  v_fee_known := v_fee is not null;

  insert into public.payments (order_id, provider, provider_payment_intent_id, provider_charge_id,
                               provider_balance_transaction_id, amount, currency, fee_amount, fee_known,
                               status, paid_at, provider_event_id, capability)
  values (o.id, 'stripe', v_pi, nullif(enrich ->> 'charge_id', ''), nullif(enrich ->> 'balance_transaction_id', ''),
          v_amount, v_currency, coalesce(v_fee, 0), v_fee_known, 'succeeded', now(), ev_id, 'online_checkout')
  on conflict (provider_payment_intent_id) do update
    set fee_amount = case when public.payments.fee_known then public.payments.fee_amount else excluded.fee_amount end,
        fee_known  = public.payments.fee_known or excluded.fee_known,
        provider_charge_id = coalesce(public.payments.provider_charge_id, excluded.provider_charge_id),
        provider_balance_transaction_id = coalesce(public.payments.provider_balance_transaction_id, excluded.provider_balance_transaction_id)
  returning * into p;

  update public.orders set status = 'paid', paid_at = coalesce(paid_at, now())
   where id = o.id and status in ('pending_payment','paid');
  perform public.recompute_earning(o.id);
  -- the pack becoming paid is what settles the cycle (20261056's trigger)
  perform public.project_pack_payment(o.id);
  perform public.email_on_order_paid(o.id);

  update public.webhook_events set status = 'processed', processed_at = now() where event_id = ev_id;
  return jsonb_build_object('event_id', ev_id, 'status', 'processed', 'duplicate', false,
                            'order', o.reference, 'payment_id', p.id, 'session_pack', o.session_pack_id);
end $$;
revoke all on function public.process_stripe_charge_event(jsonb) from public, anon, authenticated;
grant execute on function public.process_stripe_charge_event(jsonb) to service_role;

-- ---------- 6. the operator's switch ----------
create or replace function public.subscription_set_billing_mode(p_id uuid, p_mode text)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare e text := public.current_email(); s public.subscriptions%rowtype;
begin
  if not public.has_permission('finance:manage') then raise exception 'forbidden' using errcode = '42501'; end if;
  if coalesce(p_mode, '') not in ('invoice', 'auto') then raise exception 'billing mode is invoice or auto' using errcode = '22023'; end if;
  update public.subscriptions set billing_mode = p_mode, charge_failures = 0, last_charge_error = null
   where id = p_id returning * into s;
  if not found then raise exception 'subscription not found' using errcode = 'P0002'; end if;
  insert into public.admin_audit (area, entity_id, action, changed_by, summary)
  values ('subscription', s.id::text, 'billing_mode', e,
          jsonb_build_object('mode', p_mode, 'has_mandate', public.subscription_has_mandate(s)));
  return public.subscription_json(s);
end $$;
revoke all on function public.subscription_set_billing_mode(uuid, text) from public, anon;
grant execute on function public.subscription_set_billing_mode(uuid, text) to authenticated, service_role;

/* Forgetting the card. The client asked, or Gari did; either way the mandate
   goes and the plan falls back to being invoiced. Detaching it at Stripe is
   the Edge function's job — this is the record. */
create or replace function public.subscription_forget_card(p_id uuid)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare e text := public.current_email(); s public.subscriptions%rowtype; pm text;
begin
  if not public.has_permission('finance:manage') then raise exception 'forbidden' using errcode = '42501'; end if;
  select stripe_payment_method_id into pm from public.subscriptions where id = p_id;
  update public.subscriptions
     set billing_mode = 'invoice', stripe_customer_id = null, stripe_payment_method_id = null,
         card_brand = null, card_last4 = null, card_exp_month = null, card_exp_year = null,
         mandate_at = null, charge_failures = 0, last_charge_error = null
   where id = p_id returning * into s;
  if not found then raise exception 'subscription not found' using errcode = 'P0002'; end if;
  insert into public.admin_audit (area, entity_id, action, changed_by, summary)
  values ('subscription', s.id::text, 'card_forgotten', e, jsonb_build_object('had_card', pm is not null));
  return jsonb_build_object('ok', true, 'detach_payment_method', pm);
end $$;
revoke all on function public.subscription_forget_card(uuid) from public, anon;
grant execute on function public.subscription_forget_card(uuid) to authenticated, service_role;

-- ---------- 7. the card shows up where a human looks ----------
create or replace function public.subscription_json(s public.subscriptions)
returns jsonb language sql stable security definer set search_path = '' as $$
  select jsonb_build_object(
    'id', s.id, 'crm_contact_id', s.crm_contact_id, 'service_id', s.service_id,
    'client_name', (select c.display_name from public.crm_contacts c where c.id = s.crm_contact_id),
    'title', s.title, 'price_amount', s.price_amount, 'currency', s.currency,
    'interval_unit', s.interval_unit, 'interval_count', s.interval_count,
    'sessions_per_cycle', s.sessions_per_cycle, 'billing_mode', s.billing_mode,
    'status', s.status, 'start_date', s.start_date, 'next_billing_date', s.next_billing_date,
    'due_days', s.due_days, 'grace_days', s.grace_days,
    'cycles_issued', s.cycles_issued, 'cancel_at_period_end', s.cancel_at_period_end,
    'cancelled_at', s.cancelled_at, 'ended_at', s.ended_at, 'end_reason', s.end_reason,
    'note', s.note, 'created_at', s.created_at,
    -- the card: what it is, never anything that could be used
    'has_mandate', public.subscription_has_mandate(s),
    'card_brand', s.card_brand, 'card_last4', s.card_last4,
    'card_expiry', case when s.card_exp_month is not null and s.card_exp_year is not null
                        then lpad(s.card_exp_month::text, 2, '0') || '/' || right(s.card_exp_year::text, 2) end,
    'card_expired', s.card_exp_year is not null and
                    make_date(s.card_exp_year, coalesce(s.card_exp_month, 12), 1) + interval '1 month' <= current_date,
    'mandate_at', s.mandate_at, 'charge_failures', s.charge_failures, 'last_charge_error', s.last_charge_error,
    'awaiting_card', s.billing_mode = 'auto' and not public.subscription_has_mandate(s),
    'open_cycles',   (select count(*) from public.subscription_cycles k where k.subscription_id = s.id and k.status = 'issued'),
    'overdue_cycles',(select count(*) from public.subscription_cycles k where k.subscription_id = s.id and k.status = 'issued' and k.due_date < current_date),
    'paid_to_date',  (select coalesce(sum(k.amount), 0) from public.subscription_cycles k where k.subscription_id = s.id and k.status = 'paid'));
$$;
revoke all on function public.subscription_json(public.subscriptions) from public, anon;
grant execute on function public.subscription_json(public.subscriptions) to authenticated, service_role;

-- `subscription_start` gains the mode, so a plan can be born on auto
create or replace function public.subscription_start(p jsonb)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare e text := public.current_email(); s public.subscriptions%rowtype; sv public.services%rowtype;
  v_start date; v_price int; v_cur text; v_sessions int; v_title text; v_immediate boolean; v_mode text;
begin
  if not public.has_permission('finance:manage') then raise exception 'forbidden' using errcode = '42501'; end if;
  if coalesce(nullif(p ->> 'crm_contact_id', ''), '') = '' then raise exception 'crm_contact_id required' using errcode = '22023'; end if;
  if not exists (select 1 from public.crm_contacts where id = (p ->> 'crm_contact_id')::uuid) then
    raise exception 'client not found' using errcode = 'P0002';
  end if;

  if nullif(p ->> 'service_id', '') is not null then
    select * into sv from public.services where id = (p ->> 'service_id')::uuid;
    if not found then raise exception 'service not found' using errcode = 'P0002'; end if;
  end if;

  v_price    := coalesce(nullif(p ->> 'price_amount', '')::int, sv.price_amount);
  v_cur      := upper(coalesce(nullif(p ->> 'currency', ''), sv.currency, 'USD'));
  v_title    := coalesce(nullif(btrim(p ->> 'title'), ''), sv.title);
  v_sessions := coalesce(nullif(p ->> 'sessions_per_cycle', '')::int, 1);
  v_start    := coalesce(nullif(p ->> 'start_date', '')::date, current_date);
  v_immediate := coalesce((p ->> 'issue_now')::boolean, true);
  v_mode     := coalesce(nullif(p ->> 'billing_mode', ''), 'invoice');

  if v_price is null or v_price <= 0 then raise exception 'a price is required' using errcode = '22023'; end if;
  if v_cur !~ '^[A-Z]{3}$' then raise exception 'currency must be ISO 4217' using errcode = '22023'; end if;
  if v_title is null or btrim(v_title) = '' then raise exception 'a title is required' using errcode = '22023'; end if;
  if v_sessions < 1 or v_sessions > 100 then raise exception 'sessions_per_cycle must be between 1 and 100' using errcode = '22023'; end if;
  if v_mode not in ('invoice', 'auto') then raise exception 'billing mode is invoice or auto' using errcode = '22023'; end if;

  insert into public.subscriptions (crm_contact_id, service_id, title, price_amount, currency,
                                    interval_unit, interval_count, sessions_per_cycle, billing_mode,
                                    start_date, next_billing_date, due_days, grace_days, note, created_by)
  values ((p ->> 'crm_contact_id')::uuid, nullif(p ->> 'service_id', '')::uuid, btrim(v_title), v_price, v_cur,
          coalesce(nullif(p ->> 'interval_unit', ''), 'month'),
          coalesce(nullif(p ->> 'interval_count', '')::int, 1), v_sessions, v_mode,
          v_start, v_start,
          coalesce(nullif(p ->> 'due_days', '')::int, 7),
          coalesce(nullif(p ->> 'grace_days', '')::int, 7),
          nullif(btrim(coalesce(p ->> 'note', '')), ''), e)
  returning * into s;

  insert into public.admin_audit (area, entity_id, action, changed_by, summary)
  values ('subscription', s.id::text, 'start', e,
          jsonb_build_object('contact', s.crm_contact_id, 'title', s.title, 'amount', s.price_amount,
                             'currency', s.currency, 'every', s.interval_count || ' ' || s.interval_unit,
                             'sessions_per_cycle', s.sessions_per_cycle, 'start_date', s.start_date,
                             'billing_mode', s.billing_mode));

  if v_immediate and v_start <= current_date then
    perform public.subscription_issue_cycle(s.id, e);
    select * into s from public.subscriptions where id = s.id;
  end if;
  return public.subscription_json(s);
end $$;
revoke all on function public.subscription_start(jsonb) from public, anon;
grant execute on function public.subscription_start(jsonb) to authenticated, service_role;

-- ---------- 8. the key, the gate, the kick ----------
do $$
declare k text;
begin
  if not exists (select 1 from vault.decrypted_secrets where name = 'outbox_subscription_key') then
    k := encode(extensions.gen_random_bytes(32), 'hex');
    perform vault.create_secret(k, 'outbox_subscription_key',
      'Subscription auto-charge key (clear; only its SHA-256 hash is stored in public.outbox_keys)');
    insert into public.outbox_keys (name, key_sha256) values ('subscription', extensions.digest(k, 'sha256'))
      on conflict (name) do update set key_sha256 = excluded.key_sha256;
  end if;
end $$;

create or replace function public.subscription_charge_authorize(p_key text)
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.outbox_keys k where k.name = 'subscription' and length(coalesce(p_key, '')) = 64
                   and public.ct_bytea_eq(k.key_sha256, extensions.digest(p_key, 'sha256')))
$$;
revoke execute on function public.subscription_charge_authorize(text) from public, anon, authenticated;
grant  execute on function public.subscription_charge_authorize(text) to service_role;

create or replace function public.subscription_charge_kick()
returns bigint language plpgsql volatile security definer set search_path = '' as $$
declare k text; rid bigint;
begin
  perform public.subscription_charges_enqueue();
  if not exists (select 1 from public.subscription_charges where status = 'pending' and next_attempt_at <= now()) then
    return null;                                                   -- an idle project does nothing
  end if;
  select decrypted_secret into k from vault.decrypted_secrets where name = 'outbox_subscription_key' limit 1;
  if k is null then return null; end if;
  select net.http_post(url := 'https://acrjrlgeeyseyolmofuq.supabase.co/functions/v1/subscription-charge',
                       headers := jsonb_build_object('Content-Type', 'application/json', 'x-outbox-key', k),
                       body := '{"action":"charge"}'::jsonb, timeout_milliseconds := 30000) into rid;
  return rid;
end $$;
revoke execute on function public.subscription_charge_kick() from public, anon, authenticated;
grant  execute on function public.subscription_charge_kick() to service_role;

/* 07:00 UTC, twenty minutes after the day's invoices are issued, so a cycle
   minted this morning is charged this morning. Hourly retries are pointless —
   a declined card is not going to work at nine that did not work at eight. */
do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.unschedule(jobid) from cron.job where jobname = 'cg-subscription-charge';
    perform cron.schedule('cg-subscription-charge', '0 7 * * *', $cron$select public.subscription_charge_kick()$cron$);
  end if;
end $$;

-- ---------- 9. the email that tells a client their card stopped working ----------
alter table public.email_events drop constraint if exists email_events_kind_check;
alter table public.email_events add constraint email_events_kind_check
  check (kind in ('booking_confirmed','payment_received','booking_cancelled','reminder','reschedule','session_link',
                  'payment_confirmed','support_thanks','enquiry_received','lead_notification',
                  'collab_received','collab_ack','collab_proposal','collab_counter','collab_accepted','collab_payment_ready',
                  'collab_declined','collab_reminder','session_reminder',
                  'subscription_invoice','subscription_reminder','subscription_overdue','subscription_ended',
                  'subscription_card_failed'));

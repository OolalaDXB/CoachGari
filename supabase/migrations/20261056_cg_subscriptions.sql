-- =====================================================================
-- Recurring billing, part 1 of 2 — the spine
--
-- THE PROBLEM THIS CLOSES. Two catalogue products are priced "per month"
-- (Online Coaching $79, Live Group Sessions $12) and neither has any
-- recurring machinery behind it. They are sold by enquiry and paid once. So
-- month two never gets invoiced unless somebody remembers, and "Cancel
-- whenever" had to be deleted from the page because there was nothing to
-- cancel. This makes the promise true.
--
-- THE ONE DECISION EVERYTHING ELSE FOLLOWS FROM:
--
--   *** A BILLING CYCLE IS A SESSION PACK. ***
--
-- Not a parallel money path. Each cycle mints an ordinary `session_packs`
-- row — one month of entitlement, its own price snapshot, its own public
-- reference — and from that point the EXISTING machinery does all the work,
-- untouched:
--     create_order_for_pack → cg_ph_request_for_order → BEAU PH → the /r
--     page on every eligible rail → the ledger → recompute_earning → the
--     receipt → the Finance transaction list → the client's pack history.
-- `session_packs.renewed_from_pack_id` already exists and already means
-- "this one follows that one"; the renewal chain was built for this and has
-- simply never been driven by a schedule. Nothing about Stripe, PayPal,
-- Wise, bank transfer, Aani or cash needed to learn a new concept, and a
-- rail added later inherits recurring billing for free.
--
-- The cost of the decision, stated plainly: a subscription must grant a
-- COUNTABLE entitlement (sessions_per_cycle >= 1), because a pack has
-- total_sessions > 0. Both live products do (2 video sessions a month; 2
-- classes a week ≈ 8). A subscription to something uncountable — a meal
-- plan on its own, say — would need a different entitlement type, and that
-- is a real limit rather than an oversight.
--
-- SETTLEMENT IS A TRIGGER, NOT A FIFTH EDIT TO FOUR FUNCTIONS. An order
-- becomes paid in four different places today (process_stripe_event,
-- process_paypal_event, payment_record_manual, the collect-in-person path),
-- and every one of them lands on the same observable fact: the pack's
-- payment_status becomes 'paid'. Hooking the cycle to that fact with a
-- trigger on session_packs means no rail can settle a subscription without
-- the cycle noticing, including a rail written next year by someone who has
-- never read this file. Editing four function bodies would have worked
-- today and rotted on the fifth rail.
--
-- ISSUING RUNS ENTIRELY IN SQL. Minting a pack, an invoice and an email row
-- needs no network, so pg_cron calls a plain function — no Edge Function, no
-- outbox key, no pg_net. The only thing that leaves the database is the
-- email, and the existing outbox already does that.
--
-- AN UNPAID SUBSCRIPTION IS NOT INVOICED AGAIN. When a cycle goes past its
-- grace period the subscription moves to `past_due` and the issuer STOPS.
-- It does not keep stacking invoices on someone who has not paid; it waits
-- for the money or for Gari to cancel. Debt that accumulates while nobody is
-- looking is how a coaching business ends up chasing four months at once.
--
-- THE PAY LINK IS THE EXISTING REPORT LINK. A cycle's invoice is paid on the
-- /r page that packs already use. report_tokens stores only a SHA-256, which
-- is right for a link a human pastes once but means a link cannot be rebuilt
-- for a reminder email. So a subscription-issued token also stores the value
-- encrypted (pgcrypto pgp_sym under a Vault key) — the same shape, and for
-- the same reason, as the collaboration room token in 20261016/20261019: the
-- outbox row at rest holds a pack id, never a link, and the URL is built
-- definer-side at send time. An operator gets one only through an audited
-- call.
--
-- NOT IN THIS MIGRATION, deliberately: automatic card charging. That is
-- 20261057, it applies to the Stripe rail only, and it is built on top of
-- this — the subscription, the cycle and the entitlement stay exactly as
-- they are; only the collection method changes.
-- =====================================================================

-- ---------- 1. the agreement ----------
create table if not exists public.subscriptions (
  id                   uuid primary key default gen_random_uuid(),
  crm_contact_id       uuid not null references public.crm_contacts(id) on delete cascade,
  service_id           uuid references public.services(id),
  title                text not null,                                   -- snapshot: the catalogue may be re-priced or renamed later
  price_amount         int  not null check (price_amount > 0),           -- minor units, PER CYCLE
  currency             text not null default 'USD' check (currency ~ '^[A-Z]{3}$'),
  interval_unit        text not null default 'month' check (interval_unit in ('week','month')),
  interval_count       int  not null default 1 check (interval_count between 1 and 12),
  sessions_per_cycle   int  not null check (sessions_per_cycle between 1 and 100),
  billing_mode         text not null default 'invoice' check (billing_mode in ('invoice','auto')),
  status               text not null default 'active'
                       check (status in ('active','past_due','paused','cancelled','ended')),
  start_date           date not null,
  next_billing_date    date,                                            -- null once cancelled or ended: nothing more will be issued
  due_days             int  not null default 7  check (due_days between 0 and 60),    -- invoice due this long after it is issued
  grace_days           int  not null default 7  check (grace_days between 0 and 60),  -- and past_due this long after that
  cycles_issued        int  not null default 0,
  cancel_at_period_end boolean not null default false,
  cancelled_at         timestamptz,
  ended_at             timestamptz,
  end_reason           text,
  note                 text,
  created_by           text,
  created_at           timestamptz not null default now(),
  updated_at           timestamptz not null default now()
);
comment on table public.subscriptions is
  'A recurring agreement. Each cycle mints a session_packs row, which is what actually gets invoiced and paid.';
comment on column public.subscriptions.next_billing_date is
  'The period_start of the NEXT cycle to issue. Null means nothing more will be issued.';

create index if not exists subscriptions_contact_idx on public.subscriptions (crm_contact_id, created_at desc);
create index if not exists subscriptions_due_idx on public.subscriptions (next_billing_date) where status = 'active';
/* One live subscription per client per product. Without this, two operators
   (or one operator twice) can put the same person on the same plan twice and
   both invoices go out looking legitimate. */
create unique index if not exists subscriptions_one_live_per_service
  on public.subscriptions (crm_contact_id, service_id)
  where status in ('active','past_due','paused') and service_id is not null;
create trigger subscriptions_updated_at before update on public.subscriptions
  for each row execute function public.set_updated_at();

-- ---------- 2. the invoice for one period ----------
create table if not exists public.subscription_cycles (
  id                  uuid primary key default gen_random_uuid(),
  subscription_id     uuid not null references public.subscriptions(id) on delete cascade,
  seq                 int  not null check (seq > 0),
  period_start        date not null,
  period_end          date not null,
  amount              int  not null check (amount > 0),                  -- snapshot: a later price change never rewrites an issued cycle
  currency            text not null check (currency ~ '^[A-Z]{3}$'),
  session_pack_id     uuid references public.session_packs(id) on delete set null,
  status              text not null default 'issued'
                      check (status in ('issued','paid','skipped','cancelled','written_off')),
  due_date            date not null,
  issued_at           timestamptz not null default now(),
  paid_at             timestamptz,
  reminded_at         timestamptz,
  overdue_notified_at timestamptz,
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now(),
  constraint subscription_cycles_period check (period_end >= period_start),
  constraint subscription_cycles_seq_unique    unique (subscription_id, seq),
  constraint subscription_cycles_period_unique unique (subscription_id, period_start)
);
create index if not exists subscription_cycles_open_idx on public.subscription_cycles (due_date) where status = 'issued';
create index if not exists subscription_cycles_pack_idx on public.subscription_cycles (session_pack_id);
create trigger subscription_cycles_updated_at before update on public.subscription_cycles
  for each row execute function public.set_updated_at();

alter table public.subscriptions       enable row level security;
alter table public.subscription_cycles enable row level security;
revoke all on public.subscriptions, public.subscription_cycles from anon, authenticated;

-- ---------- 3. the pay link, readable again for a reminder ----------
/* report_tokens keeps only a SHA-256, which cannot be reversed to build a
   second email. A subscription-issued token therefore also stores the value
   encrypted under a Vault key, exactly as the collaboration room token does.
   The key is generated at apply time and is never in this file. */
do $$
begin
  if not exists (select 1 from vault.decrypted_secrets where name = 'report_link_key') then
    perform vault.create_secret(encode(extensions.gen_random_bytes(32), 'hex'),
                                'report_link_key', 'Subscription pay-link token encryption key (pgcrypto pgp_sym)');
  end if;
end $$;

create or replace function public.report_link_key() returns text language sql stable security definer set search_path = '' as $$
  select decrypted_secret from vault.decrypted_secrets where name = 'report_link_key' limit 1;
$$;
revoke all on function public.report_link_key() from public, anon, authenticated, service_role;

alter table public.report_tokens add column if not exists token_enc bytea;
comment on column public.report_tokens.token_enc is
  'Set only for tokens minted for a subscription cycle, so a reminder can rebuild the link. Never selectable by a browser role.';

/* The live pay link for a pack, built definer-side. Newest first: a token
   minted by a later reminder wins, and every earlier one stays valid until it
   expires — a link Gari copied by hand yesterday does not die because the
   system sent a reminder today. */
create or replace function public.pack_pay_url(p_pack_id uuid) returns text language sql stable security definer set search_path = '' as $$
  select 'https://coachgari28.com/r/' || extensions.pgp_sym_decrypt(t.token_enc, public.report_link_key())
    from public.report_tokens t
   where t.session_pack_id = p_pack_id and t.token_enc is not null
     and t.revoked_at is null and (t.expires_at is null or t.expires_at > now())
   order by t.created_at desc limit 1;
$$;
revoke all on function public.pack_pay_url(uuid) from public, anon, authenticated, service_role;

-- ---------- 4. new email kinds and audit area (both CHECKs re-issued in full) ----------
-- A CHECK cannot grow in place. Anything added from here on goes in THESE
-- lists, never in an older copy — see 20261048 for what happens otherwise.
alter table public.email_events drop constraint if exists email_events_kind_check;
alter table public.email_events add constraint email_events_kind_check
  check (kind in ('booking_confirmed','payment_received','booking_cancelled','reminder','reschedule','session_link',
                  'payment_confirmed','support_thanks','enquiry_received','lead_notification',
                  'collab_received','collab_ack','collab_proposal','collab_counter','collab_accepted','collab_payment_ready',
                  'collab_declined','collab_reminder','session_reminder',
                  'subscription_invoice','subscription_reminder','subscription_overdue','subscription_ended'));

alter table public.admin_audit drop constraint if exists admin_audit_area_check;
alter table public.admin_audit add constraint admin_audit_area_check check (area = any (array[
  'crm_contact', 'crm_note', 'body_measurement', 'permission', 'consent', 'merge',
  'coaching_session', 'session_pack', 'block', 'report', 'payment', 'payment_method',
  'beau_ph_rail', 'beau_ph_fx', 'settlement_destination', 'collaboration', 'email',
  'commission', 'enquiry', 'analytics', 'whatsapp', 'agreement', 'subscription']));

-- ---------- 5. the outbox builds the link at send time ----------
/* Same contract as the collab branch above it: the stored payload carries an
   id, the claim swaps it for a URL, and the row at rest never holds a link. */
drop function if exists public.email_outbox_claim(int, uuid, uuid, uuid);
create or replace function public.email_outbox_claim(p_limit int default 20, p_order_id uuid default null, p_booking_id uuid default null, p_contact_id uuid default null)
returns table (id uuid, kind text, to_address text, payload jsonb, dedupe_key text, attempts int)
language plpgsql volatile security definer set search_path = '' as $$
begin
  return query
  with due as (
    select e.id from public.email_events e
     where e.status = 'pending' and e.next_attempt_at <= now()
       and (p_order_id is null or e.order_id = p_order_id)
       and (p_booking_id is null or e.booking_id = p_booking_id)
       and (p_contact_id is null or e.contact_id = p_contact_id)
     order by e.created_at
     limit greatest(1, least(coalesce(p_limit, 20), 100))
     for update skip locked),
  leased as (
    update public.email_events e
       set attempts = e.attempts + 1, last_attempt_at = now(), next_attempt_at = now() + interval '2 minutes'
      from due where e.id = due.id
    returning e.id, e.kind, e.to_address, e.payload, e.dedupe_key, e.attempts)
  select l.id, l.kind, l.to_address,
         case when l.payload ? 'collab_id'
              then (l.payload - 'collab_id') || jsonb_strip_nulls(jsonb_build_object('room_url', public.collab_room_url((l.payload ->> 'collab_id')::uuid)))
              when l.payload ? 'pay_pack_id'
              then (l.payload - 'pay_pack_id') || jsonb_strip_nulls(jsonb_build_object('pay_url', public.pack_pay_url((l.payload ->> 'pay_pack_id')::uuid)))
              else l.payload end,
         l.dedupe_key, l.attempts
    from leased l;
end $$;
revoke execute on function public.email_outbox_claim(int, uuid, uuid, uuid) from public, anon, authenticated;
grant  execute on function public.email_outbox_claim(int, uuid, uuid, uuid) to service_role;

-- ---------- 6. shapes ----------
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
    'open_cycles',   (select count(*) from public.subscription_cycles k where k.subscription_id = s.id and k.status = 'issued'),
    'overdue_cycles',(select count(*) from public.subscription_cycles k where k.subscription_id = s.id and k.status = 'issued' and k.due_date < current_date),
    'paid_to_date',  (select coalesce(sum(k.amount), 0) from public.subscription_cycles k where k.subscription_id = s.id and k.status = 'paid'));
$$;
revoke all on function public.subscription_json(public.subscriptions) from public, anon;
grant execute on function public.subscription_json(public.subscriptions) to authenticated, service_role;

create or replace function public.subscription_cycle_json(k public.subscription_cycles)
returns jsonb language sql stable security definer set search_path = '' as $$
  select jsonb_build_object(
    'id', k.id, 'seq', k.seq, 'period_start', k.period_start, 'period_end', k.period_end,
    'amount', k.amount, 'currency', k.currency, 'status', k.status, 'due_date', k.due_date,
    'issued_at', k.issued_at, 'paid_at', k.paid_at, 'reminded_at', k.reminded_at,
    'overdue', k.status = 'issued' and k.due_date < current_date,
    'session_pack_id', k.session_pack_id,
    'pack_ref', (select sp.public_ref from public.session_packs sp where sp.id = k.session_pack_id),
    'order_reference', (select o.reference from public.orders o where o.session_pack_id = k.session_pack_id order by o.created_at desc limit 1));
$$;
revoke all on function public.subscription_cycle_json(public.subscription_cycles) from public, anon;
grant execute on function public.subscription_cycle_json(public.subscription_cycles) to authenticated, service_role;

-- ---------- 7. issue one cycle ----------
/* Internal. Idempotent on (subscription, period_start): a cron that runs
   twice, or an operator who presses "invoice now" while the cron is running,
   produces one invoice, not two. */
create or replace function public.subscription_issue_cycle(p_subscription_id uuid, p_by text default 'system:subscriptions')
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare
  s public.subscriptions%rowtype; k public.subscription_cycles%rowtype;
  c public.crm_contacts%rowtype; sp public.session_packs%rowtype; prev_pack uuid;
  p_start date; p_end date; v_seq int; tok text; v_title text;
begin
  select * into s from public.subscriptions where id = p_subscription_id for update;
  if not found then raise exception 'subscription not found' using errcode = 'P0002'; end if;
  if s.status <> 'active' then raise exception 'subscription is % — nothing to issue', s.status using errcode = 'P0003'; end if;
  if s.next_billing_date is null then raise exception 'subscription has no next billing date' using errcode = 'P0003'; end if;

  p_start := s.next_billing_date;
  p_end   := (p_start + make_interval(months => case when s.interval_unit = 'month' then s.interval_count else 0 end,
                                      weeks  => case when s.interval_unit = 'week'  then s.interval_count else 0 end))::date - 1;

  select * into k from public.subscription_cycles where subscription_id = s.id and period_start = p_start;
  if found then return public.subscription_cycle_json(k); end if;              -- already issued; say so quietly

  select * into c from public.crm_contacts where id = s.crm_contact_id;
  select k2.session_pack_id into prev_pack from public.subscription_cycles k2
   where k2.subscription_id = s.id and k2.session_pack_id is not null
   order by k2.seq desc limit 1;

  v_title := s.title || ' — ' || to_char(p_start, 'FMMonth YYYY');
  insert into public.session_packs (crm_contact_id, service_id, title, total_sessions, price_amount, currency,
                                    payment_status, agreement_date, renewed_from_pack_id, note, created_by)
  values (s.crm_contact_id, s.service_id, v_title, s.sessions_per_cycle, s.price_amount, s.currency,
          'unpaid', p_start, prev_pack,
          'Subscription cycle ' || (s.cycles_issued + 1) || ' · ' || p_start || ' → ' || p_end, p_by)
  returning * into sp;

  v_seq := s.cycles_issued + 1;
  insert into public.subscription_cycles (subscription_id, seq, period_start, period_end, amount, currency,
                                          session_pack_id, status, due_date)
  values (s.id, v_seq, p_start, p_end, s.price_amount, s.currency, sp.id, 'issued', p_start + s.due_days)
  returning * into k;

  /* The pay link: hashed for report_view to resolve, encrypted so a reminder
     can send the same link again.
     The expiry must outlive the chase. A link that dies at due + 30 would be
     dead in the overdue email of a subscription with a long grace period —
     the one message whose entire purpose is to be clicked. 60 days past the
     due date clears the longest grace (60) plus the notice, and still lets a
     forgotten invoice's link die rather than sit open for ever. */
  tok := encode(extensions.gen_random_bytes(32), 'hex');
  insert into public.report_tokens (token_hash, token_enc, crm_contact_id, session_pack_id, expires_at, created_by)
  values (encode(extensions.digest(tok, 'sha256'), 'hex'),
          extensions.pgp_sym_encrypt(tok, public.report_link_key()),
          s.crm_contact_id, sp.id, (k.due_date + 60)::timestamptz, p_by);

  update public.subscriptions
     set cycles_issued = v_seq,
         next_billing_date = (p_end + 1),
         updated_at = now()
   where id = s.id;

  if c.email is not null then
    perform public.email_queue('subscription_invoice', c.email,
      jsonb_build_object('name', c.display_name, 'title', s.title, 'period_label', to_char(p_start, 'FMMonth YYYY'),
                         'period_start', p_start, 'period_end', p_end, 'amount', k.amount, 'currency', k.currency,
                         'due_date', k.due_date, 'sessions', s.sessions_per_cycle,
                         'reference', sp.public_ref, 'pay_pack_id', sp.id),
      'subcycle:' || k.id || ':invoice', null, null, null);
  end if;

  insert into public.admin_audit (area, entity_id, action, changed_by, summary)
  values ('subscription', s.id::text, 'issue_cycle', p_by,
          jsonb_build_object('seq', v_seq, 'period_start', p_start, 'period_end', p_end,
                             'amount', k.amount, 'currency', k.currency, 'pack', sp.public_ref));

  return public.subscription_cycle_json(k);
end $$;
revoke all on function public.subscription_issue_cycle(uuid, text) from public, anon, authenticated;
grant execute on function public.subscription_issue_cycle(uuid, text) to service_role;

-- ---------- 8. the scheduler ----------
/* Runs daily. Issues what is due, and ends what asked to end. It deliberately
   skips `past_due`: see the header — an unpaid subscription is not invoiced
   again until the money arrives or Gari decides. */
create or replace function public.subscriptions_issue_due()
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare r record; c public.crm_contacts%rowtype; n_issued int := 0; n_ended int := 0; n_failed int := 0;
begin
  for r in select * from public.subscriptions
            where status = 'active' and next_billing_date is not null and next_billing_date <= current_date
            order by next_billing_date
  loop
    begin
      if r.cancel_at_period_end then
        update public.subscriptions
           set status = 'ended', ended_at = now(), next_billing_date = null,
               end_reason = coalesce(end_reason, 'cancelled at period end')
         where id = r.id;
        select * into c from public.crm_contacts where id = r.crm_contact_id;
        if c.email is not null then
          perform public.email_queue('subscription_ended', c.email,
            jsonb_build_object('name', c.display_name, 'title', r.title, 'last_day', r.next_billing_date - 1),
            'sub:' || r.id || ':ended', null, null, null);
        end if;
        insert into public.admin_audit (area, entity_id, action, changed_by, summary)
        values ('subscription', r.id::text, 'ended', 'system:subscriptions', jsonb_build_object('reason', 'cancel_at_period_end'));
        n_ended := n_ended + 1;
      else
        perform public.subscription_issue_cycle(r.id);
        n_issued := n_issued + 1;
      end if;
    exception when others then
      /* One broken subscription must not stop the others from being invoiced. */
      n_failed := n_failed + 1;
      insert into public.admin_audit (area, entity_id, action, changed_by, summary)
      values ('subscription', r.id::text, 'issue_failed', 'system:subscriptions', jsonb_build_object('error', left(sqlerrm, 200)));
    end;
  end loop;
  return jsonb_build_object('issued', n_issued, 'ended', n_ended, 'failed', n_failed);
end $$;
revoke all on function public.subscriptions_issue_due() from public, anon, authenticated;
grant execute on function public.subscriptions_issue_due() to service_role;

/* Chasing, also daily. Two nudges and then a state change — never a stream of
   identical emails: `reminded_at` and `overdue_notified_at` make each one
   happen once per cycle, whatever the cron does. */
create or replace function public.subscriptions_chase()
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare r record; n_rem int := 0; n_over int := 0;
begin
  -- two days before it is due, once
  for r in select k.*, s.title, s.crm_contact_id, sp.public_ref
             from public.subscription_cycles k
             join public.subscriptions s on s.id = k.subscription_id
             left join public.session_packs sp on sp.id = k.session_pack_id
            where k.status = 'issued' and k.reminded_at is null
              and k.due_date - 2 <= current_date and k.due_date >= current_date
              and s.status in ('active','past_due')
  loop
    perform public.email_queue('subscription_reminder',
      (select c.email from public.crm_contacts c where c.id = r.crm_contact_id),
      jsonb_build_object('name', (select c.display_name from public.crm_contacts c where c.id = r.crm_contact_id),
                         'title', r.title, 'amount', r.amount, 'currency', r.currency,
                         'due_date', r.due_date, 'reference', r.public_ref, 'pay_pack_id', r.session_pack_id),
      'subcycle:' || r.id || ':reminder', null, null, null);
    update public.subscription_cycles set reminded_at = now() where id = r.id;
    n_rem := n_rem + 1;
  end loop;

  -- past the grace period: tell them once, and stop issuing
  for r in select k.*, s.title, s.crm_contact_id, s.grace_days, s.status as sub_status, sp.public_ref
             from public.subscription_cycles k
             join public.subscriptions s on s.id = k.subscription_id
             left join public.session_packs sp on sp.id = k.session_pack_id
            where k.status = 'issued' and k.overdue_notified_at is null
              and current_date > k.due_date + s.grace_days
              and s.status in ('active','past_due')
  loop
    perform public.email_queue('subscription_overdue',
      (select c.email from public.crm_contacts c where c.id = r.crm_contact_id),
      jsonb_build_object('name', (select c.display_name from public.crm_contacts c where c.id = r.crm_contact_id),
                         'title', r.title, 'amount', r.amount, 'currency', r.currency,
                         'due_date', r.due_date, 'reference', r.public_ref, 'pay_pack_id', r.session_pack_id),
      'subcycle:' || r.id || ':overdue', null, null, null);
    update public.subscription_cycles set overdue_notified_at = now() where id = r.id;
    update public.subscriptions set status = 'past_due' where id = r.subscription_id and status = 'active';
    insert into public.admin_audit (area, entity_id, action, changed_by, summary)
    values ('subscription', r.subscription_id::text, 'past_due', 'system:subscriptions',
            jsonb_build_object('cycle', r.seq, 'due_date', r.due_date, 'amount', r.amount, 'currency', r.currency));
    n_over := n_over + 1;
  end loop;

  return jsonb_build_object('reminded', n_rem, 'overdue', n_over);
end $$;
revoke all on function public.subscriptions_chase() from public, anon, authenticated;
grant execute on function public.subscriptions_chase() to service_role;

-- ---------- 9. settlement: every rail, one trigger ----------
/* The pack's payment_status is the single fact every rail produces. Reacting
   to it means Stripe, PayPal, Wise, bank transfer, Aani, cash, an in-person
   terminal and anything added later all settle a subscription correctly
   without knowing subscriptions exist. A refund runs it backwards. */
create or replace function public.subscription_cycle_on_pack_payment()
returns trigger language plpgsql security definer set search_path = '' as $$
declare k public.subscription_cycles%rowtype;
begin
  if new.payment_status is not distinct from old.payment_status then return new; end if;
  select * into k from public.subscription_cycles where session_pack_id = new.id;
  if not found then return new; end if;

  if new.payment_status = 'paid' and k.status = 'issued' then
    update public.subscription_cycles set status = 'paid', paid_at = coalesce(new.paid_at, now()) where id = k.id;
    /* Back to active only when NOTHING else is outstanding: paying October
       while September is still open must not clear the flag. */
    update public.subscriptions s set status = 'active'
     where s.id = k.subscription_id and s.status = 'past_due'
       and not exists (select 1 from public.subscription_cycles k2
                        where k2.subscription_id = s.id and k2.status = 'issued' and k2.id <> k.id);
    insert into public.admin_audit (area, entity_id, action, changed_by, summary)
    values ('subscription', k.subscription_id::text, 'cycle_paid', 'system:subscriptions',
            jsonb_build_object('cycle', k.seq, 'amount', k.amount, 'currency', k.currency, 'pack', new.public_ref));

  elsif new.payment_status <> 'paid' and k.status = 'paid' then
    update public.subscription_cycles set status = 'issued', paid_at = null where id = k.id;
    insert into public.admin_audit (area, entity_id, action, changed_by, summary)
    values ('subscription', k.subscription_id::text, 'cycle_unpaid', 'system:subscriptions',
            jsonb_build_object('cycle', k.seq, 'pack_status', new.payment_status, 'pack', new.public_ref));
  end if;
  return new;
end $$;

drop trigger if exists session_packs_subscription_settle on public.session_packs;
create trigger session_packs_subscription_settle
  after update of payment_status on public.session_packs
  for each row execute function public.subscription_cycle_on_pack_payment();

-- ---------- 10. what an operator can do ----------
create or replace function public.subscription_start(p jsonb)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare e text := public.current_email(); s public.subscriptions%rowtype; sv public.services%rowtype;
  v_start date; v_price int; v_cur text; v_sessions int; v_title text; v_immediate boolean;
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

  /* Price, title and entitlement default from the catalogue and may be
     overridden per client — a negotiated rate is normal and must not require
     editing the public price list. */
  v_price    := coalesce(nullif(p ->> 'price_amount', '')::int, sv.price_amount);
  v_cur      := upper(coalesce(nullif(p ->> 'currency', ''), sv.currency, 'USD'));
  v_title    := coalesce(nullif(btrim(p ->> 'title'), ''), sv.title);
  v_sessions := coalesce(nullif(p ->> 'sessions_per_cycle', '')::int, 1);
  v_start    := coalesce(nullif(p ->> 'start_date', '')::date, current_date);
  v_immediate := coalesce((p ->> 'issue_now')::boolean, true);

  if v_price is null or v_price <= 0 then raise exception 'a price is required' using errcode = '22023'; end if;
  if v_cur !~ '^[A-Z]{3}$' then raise exception 'currency must be ISO 4217' using errcode = '22023'; end if;
  if v_title is null or btrim(v_title) = '' then raise exception 'a title is required' using errcode = '22023'; end if;
  if v_sessions < 1 or v_sessions > 100 then raise exception 'sessions_per_cycle must be between 1 and 100' using errcode = '22023'; end if;

  insert into public.subscriptions (crm_contact_id, service_id, title, price_amount, currency,
                                    interval_unit, interval_count, sessions_per_cycle, billing_mode,
                                    start_date, next_billing_date, due_days, grace_days, note, created_by)
  values ((p ->> 'crm_contact_id')::uuid, nullif(p ->> 'service_id', '')::uuid, btrim(v_title), v_price, v_cur,
          coalesce(nullif(p ->> 'interval_unit', ''), 'month'),
          coalesce(nullif(p ->> 'interval_count', '')::int, 1), v_sessions, 'invoice',
          v_start, v_start,
          coalesce(nullif(p ->> 'due_days', '')::int, 7),
          coalesce(nullif(p ->> 'grace_days', '')::int, 7),
          nullif(btrim(coalesce(p ->> 'note', '')), ''), e)
  returning * into s;

  insert into public.admin_audit (area, entity_id, action, changed_by, summary)
  values ('subscription', s.id::text, 'start', e,
          jsonb_build_object('contact', s.crm_contact_id, 'title', s.title, 'amount', s.price_amount,
                             'currency', s.currency, 'every', s.interval_count || ' ' || s.interval_unit,
                             'sessions_per_cycle', s.sessions_per_cycle, 'start_date', s.start_date));

  /* Issue the first invoice straight away unless the start date is in the
     future — otherwise nothing happens until the cron wakes up and the
     operator is left wondering whether it worked. */
  if v_immediate and v_start <= current_date then
    perform public.subscription_issue_cycle(s.id, e);
    select * into s from public.subscriptions where id = s.id;
  end if;
  return public.subscription_json(s);
end $$;
revoke all on function public.subscription_start(jsonb) from public, anon;
grant execute on function public.subscription_start(jsonb) to authenticated, service_role;

create or replace function public.subscription_issue_now(p_id uuid)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare e text := public.current_email();
begin
  if not public.has_permission('finance:manage') then raise exception 'forbidden' using errcode = '42501'; end if;
  return public.subscription_issue_cycle(p_id, e);
end $$;
revoke all on function public.subscription_issue_now(uuid) from public, anon;
grant execute on function public.subscription_issue_now(uuid) to authenticated, service_role;

create or replace function public.subscription_pause(p_id uuid, p_reason text default null)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare e text := public.current_email(); s public.subscriptions%rowtype;
begin
  if not public.has_permission('finance:manage') then raise exception 'forbidden' using errcode = '42501'; end if;
  update public.subscriptions set status = 'paused', note = coalesce(nullif(btrim(coalesce(p_reason,'')),''), note)
   where id = p_id and status in ('active','past_due') returning * into s;
  if not found then raise exception 'no active subscription to pause' using errcode = 'P0003'; end if;
  insert into public.admin_audit (area, entity_id, action, changed_by, summary)
  values ('subscription', s.id::text, 'pause', e, jsonb_build_object('reason', p_reason));
  return public.subscription_json(s);
end $$;
revoke all on function public.subscription_pause(uuid, text) from public, anon;
grant execute on function public.subscription_pause(uuid, text) to authenticated, service_role;

/* Resuming never back-bills. A pause is a gap in the service, and charging
   for months nobody was coached is the fastest way to lose the client. The
   next period starts today unless the operator names a date. */
create or replace function public.subscription_resume(p_id uuid, p_next_billing_date date default null)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare e text := public.current_email(); s public.subscriptions%rowtype; d date;
begin
  if not public.has_permission('finance:manage') then raise exception 'forbidden' using errcode = '42501'; end if;
  d := greatest(coalesce(p_next_billing_date, current_date), current_date);
  update public.subscriptions set status = 'active', next_billing_date = d, cancel_at_period_end = false
   where id = p_id and status = 'paused' returning * into s;
  if not found then raise exception 'no paused subscription to resume' using errcode = 'P0003'; end if;
  insert into public.admin_audit (area, entity_id, action, changed_by, summary)
  values ('subscription', s.id::text, 'resume', e, jsonb_build_object('next_billing_date', d));
  return public.subscription_json(s);
end $$;
revoke all on function public.subscription_resume(uuid, date) from public, anon;
grant execute on function public.subscription_resume(uuid, date) to authenticated, service_role;

/* Two kinds of stop, and the difference matters to the client. At period end
   is the honest default: they have paid for this month and they keep it.
   Immediate is for a client who has left; any unpaid invoice is cancelled
   with it, because chasing someone you have already let go is indefensible. */
create or replace function public.subscription_cancel(p_id uuid, p_at_period_end boolean default true, p_reason text default null)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare e text := public.current_email(); s public.subscriptions%rowtype; n int := 0;
begin
  if not public.has_permission('finance:manage') then raise exception 'forbidden' using errcode = '42501'; end if;
  select * into s from public.subscriptions where id = p_id for update;
  if not found then raise exception 'subscription not found' using errcode = 'P0002'; end if;
  if s.status in ('cancelled','ended') then raise exception 'already stopped' using errcode = 'P0003'; end if;

  if coalesce(p_at_period_end, true) then
    update public.subscriptions
       set cancel_at_period_end = true, cancelled_at = now(),
           end_reason = nullif(btrim(coalesce(p_reason, '')), '')
     where id = s.id returning * into s;
  else
    update public.subscription_cycles set status = 'cancelled'
     where subscription_id = s.id and status = 'issued';
    get diagnostics n = row_count;
    update public.subscriptions
       set status = 'cancelled', cancelled_at = now(), ended_at = now(), next_billing_date = null,
           cancel_at_period_end = false, end_reason = nullif(btrim(coalesce(p_reason, '')), '')
     where id = s.id returning * into s;
  end if;

  insert into public.admin_audit (area, entity_id, action, changed_by, summary)
  values ('subscription', s.id::text, 'cancel', e,
          jsonb_build_object('at_period_end', coalesce(p_at_period_end, true), 'reason', p_reason, 'cycles_cancelled', n));
  return public.subscription_json(s);
end $$;
revoke all on function public.subscription_cancel(uuid, boolean, text) from public, anon;
grant execute on function public.subscription_cancel(uuid, boolean, text) to authenticated, service_role;

/* A price change applies to the NEXT cycle. Issued invoices are snapshots and
   are never rewritten — the client was told a figure and that figure stands. */
create or replace function public.subscription_set_price(p_id uuid, p_price_amount int, p_reason text default null)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare e text := public.current_email(); s public.subscriptions%rowtype; old int;
begin
  if not public.has_permission('finance:manage') then raise exception 'forbidden' using errcode = '42501'; end if;
  if p_price_amount is null or p_price_amount <= 0 then raise exception 'a positive price is required' using errcode = '22023'; end if;
  select price_amount into old from public.subscriptions where id = p_id;
  if old is null then raise exception 'subscription not found' using errcode = 'P0002'; end if;
  update public.subscriptions set price_amount = p_price_amount where id = p_id returning * into s;
  insert into public.admin_audit (area, entity_id, action, changed_by, summary)
  values ('subscription', s.id::text, 'price_change', e,
          jsonb_build_object('from', old, 'to', p_price_amount, 'currency', s.currency, 'reason', p_reason));
  return public.subscription_json(s);
end $$;
revoke all on function public.subscription_set_price(uuid, int, text) from public, anon;
grant execute on function public.subscription_set_price(uuid, int, text) to authenticated, service_role;

/* Writing a cycle off: the month is not going to be paid and everyone has
   accepted that. It leaves the pack alone — the sessions happened or they did
   not, and that is a coaching record, not an accounting one. */
create or replace function public.subscription_write_off_cycle(p_cycle_id uuid, p_reason text default null)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare e text := public.current_email(); k public.subscription_cycles%rowtype;
begin
  if not public.has_permission('finance:manage') then raise exception 'forbidden' using errcode = '42501'; end if;
  update public.subscription_cycles set status = 'written_off' where id = p_cycle_id and status = 'issued' returning * into k;
  if not found then raise exception 'no open cycle to write off' using errcode = 'P0003'; end if;
  update public.subscriptions s set status = 'active'
   where s.id = k.subscription_id and s.status = 'past_due'
     and not exists (select 1 from public.subscription_cycles k2 where k2.subscription_id = s.id and k2.status = 'issued');
  insert into public.admin_audit (area, entity_id, action, changed_by, summary)
  values ('subscription', k.subscription_id::text, 'write_off', e, jsonb_build_object('cycle', k.seq, 'amount', k.amount, 'reason', p_reason));
  return public.subscription_cycle_json(k);
end $$;
revoke all on function public.subscription_write_off_cycle(uuid, text) from public, anon;
grant execute on function public.subscription_write_off_cycle(uuid, text) to authenticated, service_role;

-- ---------- 11. reading ----------
create or replace function public.subscriptions_list(p_status text default null, p_contact_id uuid default null, p_limit int default 100)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
begin
  if not (public.has_permission('finance:view') or public.has_permission('coach:operations')) then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  return (select coalesce(jsonb_agg(public.subscription_json(s) order by
                            case s.status when 'past_due' then 0 when 'active' then 1 when 'paused' then 2 else 3 end,
                            s.next_billing_date nulls last, s.created_at desc), '[]'::jsonb)
            from (select * from public.subscriptions s2
                   where (p_status is null or s2.status = p_status)
                     and (p_contact_id is null or s2.crm_contact_id = p_contact_id)
                   order by s2.created_at desc
                   limit greatest(1, least(coalesce(p_limit, 100), 500))) s);
end $$;
revoke all on function public.subscriptions_list(text, uuid, int) from public, anon;
grant execute on function public.subscriptions_list(text, uuid, int) to authenticated, service_role;

create or replace function public.subscription_get(p_id uuid)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare s public.subscriptions%rowtype;
begin
  if not (public.has_permission('finance:view') or public.has_permission('coach:operations')) then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  select * into s from public.subscriptions where id = p_id;
  if not found then raise exception 'subscription not found' using errcode = 'P0002'; end if;
  return public.subscription_json(s) || jsonb_build_object(
    'can_manage', public.has_permission('finance:manage'),
    'cycles', (select coalesce(jsonb_agg(public.subscription_cycle_json(k) order by k.seq desc), '[]'::jsonb)
                 from public.subscription_cycles k where k.subscription_id = s.id));
end $$;
revoke all on function public.subscription_get(uuid) from public, anon;
grant execute on function public.subscription_get(uuid) to authenticated, service_role;

/* The only way an operator obtains a working pay link, and it is audited —
   same rule as the collaboration room link, for the same reason: the link
   settles money without asking who is holding it. */
create or replace function public.subscription_copy_pay_link(p_cycle_id uuid)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare e text := public.current_email(); k public.subscription_cycles%rowtype; url text;
begin
  if not public.has_permission('finance:manage') then raise exception 'forbidden' using errcode = '42501'; end if;
  select * into k from public.subscription_cycles where id = p_cycle_id;
  if not found then raise exception 'cycle not found' using errcode = 'P0002'; end if;
  url := public.pack_pay_url(k.session_pack_id);
  if url is null then raise exception 'no live pay link for this cycle' using errcode = 'P0003'; end if;
  insert into public.admin_audit (area, entity_id, action, changed_by, summary)
  values ('subscription', k.subscription_id::text, 'pay_link_access', e, jsonb_build_object('cycle', k.seq));
  return jsonb_build_object('ok', true, 'url', url, 'cycle', k.seq, 'amount', k.amount, 'currency', k.currency);
end $$;
revoke all on function public.subscription_copy_pay_link(uuid) from public, anon;
grant execute on function public.subscription_copy_pay_link(uuid) to authenticated, service_role;

-- ---------- 12. schedule ----------
/* 06:20 and 06:40 UTC: after the day has turned everywhere Gari's clients
   are, and before the email outbox's own two-minute cadence matters. */
do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.unschedule(jobid) from cron.job where jobname = 'cg-subscriptions-issue';
    perform cron.unschedule(jobid) from cron.job where jobname = 'cg-subscriptions-chase';
    perform cron.schedule('cg-subscriptions-issue', '20 6 * * *', $cron$select public.subscriptions_issue_due()$cron$);
    perform cron.schedule('cg-subscriptions-chase', '40 6 * * *', $cron$select public.subscriptions_chase()$cron$);
  end if;
end $$;

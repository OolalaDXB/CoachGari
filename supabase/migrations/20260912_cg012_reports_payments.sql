-- =====================================================================
-- CG-012 — Client session recap + payment requests (Stripe + Aani), renewal
--
-- session_packs stays the coaching entitlement / OPERATIONAL PROJECTION.
-- orders + payments + refunds + partner ledger remain the AUTHORITATIVE
-- financial truth (CG-003). This sprint links a pack to an order, adds a
-- secure client report/payment page, a config-driven Aani (UAE instant
-- payment) option that is settled MANUALLY, and package renewal.
--
-- Money paths:
--   Stripe  (Oolala collects) : pack → order → Checkout → webhook →
--            process_stripe_event → payment + recompute_earning (Oolala
--            commission) → project onto pack.
--   Aani/manual (paid to Gari): operator records the received payment →
--            payment row (no Stripe id, source stored) → project onto pack.
--            NO Oolala earning (the money never passed through Oolala).
--            Viewing/copying Aani details never marks anything paid.
--
-- No frontend-supplied amount is ever trusted. No USD→AED conversion.
-- The client report never exposes body metrics, BMI, health or private notes.
-- Forward migration only; existing booking→order behaviour is preserved.
-- =====================================================================

-- ---------- 1. audit areas ----------
alter table public.admin_audit drop constraint if exists admin_audit_area_check;
alter table public.admin_audit add constraint admin_audit_area_check
  check (area in ('crm_contact','crm_note','body_measurement','permission','consent','merge',
                  'coaching_session','session_pack','block','report','payment','payment_method'));

-- ---------- 2. orders can belong to a booking OR a session_pack ----------
alter table public.orders alter column booking_id drop not null;
alter table public.orders add column if not exists session_pack_id uuid references public.session_packs(id);
alter table public.orders add column if not exists order_reason text not null default 'booking'
  check (order_reason in ('booking','session_pack'));
alter table public.orders drop constraint if exists orders_target_ck;
alter table public.orders add constraint orders_target_ck check (
  (order_reason = 'booking'      and booking_id is not null) or
  (order_reason = 'session_pack' and session_pack_id is not null));
create index if not exists orders_pack_idx on public.orders (session_pack_id) where session_pack_id is not null;

-- payments: room for a manual/external reference (never a fabricated Stripe id)
alter table public.payments add column if not exists note text;

-- packs may be settled via Aani (kept as an explicit source)
alter table public.session_packs drop constraint if exists session_packs_payment_source_check;
alter table public.session_packs add constraint session_packs_payment_source_check
  check (payment_source in ('stripe','bank_transfer','cash','manual','external','aani'));

-- ---------- 3. payment method config (Aani), managed under finance ----------
create table if not exists public.payment_methods (
  method       text primary key check (method in ('aani')),
  enabled      boolean not null default false,
  proxy_type   text check (proxy_type in ('mobile','email','merchant','qr')),
  proxy_value  text,                       -- machine value, e.g. +971521365065 (E.164)
  display_value text,                      -- human value, e.g. +971 52 136 5065
  instructions text,
  currency     text not null default 'AED' check (currency ~ '^[A-Z]{3}$'),
  qr_url       text,                        -- only ever a verified/authorised QR; empty in V1
  updated_by   text,
  updated_at   timestamptz not null default now()
);
alter table public.payment_methods enable row level security;
revoke all on public.payment_methods from anon, authenticated;
grant select on public.payment_methods to authenticated;
drop policy if exists payment_methods_view on public.payment_methods;
create policy payment_methods_view on public.payment_methods for select to authenticated
  using (public.has_permission('finance:view'));

create or replace function public.payment_method_set(p jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare e text := public.current_email(); row public.payment_methods%rowtype; m text := coalesce(p->>'method','aani');
begin
  if not public.has_permission('finance:manage') then raise exception 'forbidden' using errcode = '42501'; end if;
  if m <> 'aani' then raise exception 'unknown method' using errcode = '22023'; end if;
  insert into public.payment_methods (method, enabled, proxy_type, proxy_value, display_value, instructions, currency, qr_url, updated_by)
  values (m, coalesce((p->>'enabled')::boolean, false), nullif(p->>'proxy_type',''), nullif(p->>'proxy_value',''),
          nullif(p->>'display_value',''), nullif(p->>'instructions',''), coalesce(nullif(p->>'currency',''),'AED'), nullif(p->>'qr_url',''), e)
  on conflict (method) do update set
    enabled = excluded.enabled, proxy_type = excluded.proxy_type, proxy_value = excluded.proxy_value,
    display_value = excluded.display_value, instructions = excluded.instructions, currency = excluded.currency,
    qr_url = excluded.qr_url, updated_by = e, updated_at = now()
  returning * into row;
  insert into public.admin_audit (area, entity_id, action, changed_by, summary)
  values ('payment_method', m, 'set', e, jsonb_build_object('enabled', row.enabled));
  return to_jsonb(row);
end $$;
revoke execute on function public.payment_method_set(jsonb) from public, anon;
grant  execute on function public.payment_method_set(jsonb) to authenticated, service_role;

-- ---------- 4. secure report tokens (client report/payment page) ----------
create table if not exists public.report_tokens (
  token_hash      text primary key,
  crm_contact_id  uuid not null references public.crm_contacts(id) on delete cascade,
  session_pack_id uuid not null references public.session_packs(id) on delete cascade,
  expires_at      timestamptz,
  revoked_at      timestamptz,
  created_by      text,
  created_at      timestamptz not null default now()
);
create index if not exists report_tokens_pack_idx on public.report_tokens (session_pack_id);
alter table public.report_tokens enable row level security;   -- no anon/authenticated access; service role only

-- ---------- 5. recap data (authoritative; never health/notes) ----------
-- p_finance = include price/amount-due (true for the client page and for
-- finance-permitted staff). Sessions come from coaching_sessions; money from
-- the pack snapshot. No body metrics, no notes, ever.
create or replace function public.pack_recap_data(p_pack_id uuid, p_finance boolean)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare sp public.session_packs%rowtype; used int; cname text; fname text;
  done jsonb; upcoming jsonb; due int;
begin
  select * into sp from public.session_packs where id = p_pack_id;
  if not found then raise exception 'pack not found' using errcode = 'P0002'; end if;
  used := public.pack_used(sp.id);
  select display_name into cname from public.crm_contacts where id = sp.crm_contact_id;
  fname := split_part(coalesce(cname,''), ' ', 1);
  select coalesce(jsonb_agg(jsonb_build_object('start_at', s.start_at, 'title', s.title) order by s.start_at), '[]'::jsonb)
    into done from public.coaching_sessions s
    where s.session_pack_id = sp.id and (s.status = 'completed' or (s.status = 'no_show' and s.chargeable));
  select coalesce(jsonb_agg(jsonb_build_object('start_at', s.start_at, 'title', s.title) order by s.start_at), '[]'::jsonb)
    into upcoming from public.coaching_sessions s
    where s.session_pack_id = sp.id and s.status = 'scheduled' and s.end_at > now();
  due := case when sp.payment_status = 'paid' then 0 else coalesce(sp.price_amount, 0) end;
  return jsonb_build_object(
    'pack_id', sp.id, 'client_name', cname, 'first_name', nullif(fname,''),
    'title', sp.title, 'total_sessions', sp.total_sessions, 'used', used,
    'remaining', greatest(sp.total_sessions - used, 0),
    'agreement_date', sp.agreement_date, 'status', sp.status,
    'completed', done, 'upcoming', upcoming,
    'price_amount', case when p_finance then sp.price_amount else null end,
    'currency', sp.currency,
    'payment_status', sp.payment_status,
    'paid_at', case when p_finance then sp.paid_at else null end,
    'amount_due', case when p_finance then due else null end);
end $$;
revoke execute on function public.pack_recap_data(uuid, boolean) from public, anon;
grant  execute on function public.pack_recap_data(uuid, boolean) to authenticated, service_role;

-- admin preview (coach:operations; price only with finance:view)
create or replace function public.pack_recap(p_pack_id uuid)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
begin
  if not public.has_permission('coach:operations') then raise exception 'forbidden' using errcode = '42501'; end if;
  return public.pack_recap_data(p_pack_id, public.has_permission('finance:view'));
end $$;
revoke execute on function public.pack_recap(uuid) from public, anon;
grant  execute on function public.pack_recap(uuid) to authenticated, service_role;

-- ---------- 6. issue / revoke a secure report link ----------
create or replace function public.report_issue_link(p_pack_id uuid, p_days int default 30)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare e text := public.current_email(); sp public.session_packs%rowtype; tok text;
begin
  if not public.has_permission('coach:operations') then raise exception 'forbidden' using errcode = '42501'; end if;
  select * into sp from public.session_packs where id = p_pack_id;
  if not found then raise exception 'pack not found' using errcode = 'P0002'; end if;
  tok := encode(extensions.gen_random_bytes(32), 'hex');
  insert into public.report_tokens (token_hash, crm_contact_id, session_pack_id, expires_at, created_by)
  values (encode(extensions.digest(tok,'sha256'),'hex'), sp.crm_contact_id, sp.id,
          now() + make_interval(days => greatest(least(coalesce(p_days,30), 180), 1)), e);
  insert into public.admin_audit (area, entity_id, action, changed_by, summary)
  values ('report', sp.id::text, 'issue_link', e, jsonb_build_object('contact', sp.crm_contact_id));
  return jsonb_build_object('token', tok, 'expires_in_days', greatest(least(coalesce(p_days,30),180),1));
end $$;
revoke execute on function public.report_issue_link(uuid, int) from public, anon;
grant  execute on function public.report_issue_link(uuid, int) to authenticated, service_role;

create or replace function public.report_revoke(p_pack_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare e text := public.current_email(); n int;
begin
  if not public.has_permission('coach:operations') then raise exception 'forbidden' using errcode = '42501'; end if;
  update public.report_tokens set revoked_at = now() where session_pack_id = p_pack_id and revoked_at is null;
  get diagnostics n = row_count;
  insert into public.admin_audit (area, entity_id, action, changed_by, summary)
  values ('report', p_pack_id::text, 'revoke', e, jsonb_build_object('revoked', n));
  return jsonb_build_object('revoked', n);
end $$;
revoke execute on function public.report_revoke(uuid) from public, anon;
grant  execute on function public.report_revoke(uuid) to authenticated, service_role;

-- client-facing view (service role, via the report Edge Function). Includes
-- the amount due (the client's own bill) and the Aani config, never health/notes.
create or replace function public.report_view(p_token text)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare t public.report_tokens%rowtype; recap jsonb; aani public.payment_methods%rowtype; aani_json jsonb;
begin
  if p_token is null or p_token !~ '^[0-9a-f]{64}$' then raise exception 'invalid token' using errcode = 'P0002'; end if;
  select * into t from public.report_tokens where token_hash = encode(extensions.digest(p_token,'sha256'),'hex');
  if not found then raise exception 'invalid token' using errcode = 'P0002'; end if;
  if t.revoked_at is not null then raise exception 'this link has been revoked' using errcode = 'P0003'; end if;
  if t.expires_at is not null and t.expires_at < now() then raise exception 'this link has expired' using errcode = 'P0003'; end if;
  recap := public.pack_recap_data(t.session_pack_id, true);   -- the client sees their own amount due
  select * into aani from public.payment_methods where method = 'aani' and enabled;
  if found then
    aani_json := jsonb_build_object('enabled', true, 'proxy_type', aani.proxy_type, 'display_value', aani.display_value,
      'instructions', aani.instructions, 'currency', aani.currency, 'qr_url', aani.qr_url,
      'reference', 'PACK-' || upper(substr(t.session_pack_id::text, 1, 8)));
  else
    aani_json := jsonb_build_object('enabled', false);
  end if;
  return jsonb_build_object('ok', true, 'recap', recap, 'aani', aani_json,
    'pay_ref', 'PACK-' || upper(substr(t.session_pack_id::text, 1, 8)));
end $$;
revoke execute on function public.report_view(text) from public, anon, authenticated;
grant  execute on function public.report_view(text) to service_role;

-- ---------- 7. create an order for a pack (Stripe path) ----------
-- Amount and currency come from the pack snapshot, never from the caller.
create or replace function public.create_order_for_pack(p_pack_id uuid)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare sp public.session_packs%rowtype; o public.orders%rowtype; c public.crm_contacts%rowtype; v_ref text; v_contact text;
begin
  select * into sp from public.session_packs where id = p_pack_id for update;
  if not found then raise exception 'pack not found' using errcode = 'P0002'; end if;
  if sp.price_amount is null or sp.price_amount <= 0 then raise exception 'pack has no price' using errcode = 'P0003'; end if;
  if sp.payment_status = 'paid' then raise exception 'already paid' using errcode = 'P0003'; end if;
  select * into c from public.crm_contacts where id = sp.crm_contact_id;
  v_contact := coalesce(c.email, c.phone, 'n/a');

  select * into o from public.orders where session_pack_id = sp.id and status = 'pending_payment';
  if found then return public.order_to_json(o); end if;

  loop
    v_ref := 'OR-' || upper(substr(encode(extensions.gen_random_bytes(4), 'hex'), 1, 6));
    exit when not exists (select 1 from public.orders where reference = v_ref);
  end loop;
  insert into public.orders (reference, booking_id, session_pack_id, order_reason, customer_name, customer_contact, currency, gross_amount, status)
  values (v_ref, null, sp.id, 'session_pack', coalesce(c.display_name,'Client'), v_contact, sp.currency, sp.price_amount, 'pending_payment')
  returning * into o;
  return public.order_to_json(o);
end $$;
revoke execute on function public.create_order_for_pack(uuid) from public, anon, authenticated;
grant  execute on function public.create_order_for_pack(uuid) to service_role;

-- resolve a report token to its pack (service role, for the Edge Function's card action)
create or replace function public.report_pack_id(p_token text)
returns uuid language plpgsql stable security definer set search_path = '' as $$
declare t public.report_tokens%rowtype;
begin
  if p_token is null or p_token !~ '^[0-9a-f]{64}$' then raise exception 'invalid token' using errcode = 'P0002'; end if;
  select * into t from public.report_tokens where token_hash = encode(extensions.digest(p_token,'sha256'),'hex');
  if not found or t.revoked_at is not null or (t.expires_at is not null and t.expires_at < now()) then raise exception 'invalid token' using errcode = 'P0003'; end if;
  return t.session_pack_id;
end $$;
revoke execute on function public.report_pack_id(text) from public, anon, authenticated;
grant  execute on function public.report_pack_id(text) to service_role;

-- ---------- 8. project a paid order onto its pack ----------
create or replace function public.project_pack_payment(p_order_id uuid)
returns void language plpgsql volatile security definer set search_path = '' as $$
declare o public.orders%rowtype; p public.payments%rowtype; src text;
begin
  select * into o from public.orders where id = p_order_id;
  if not found or o.session_pack_id is null then return; end if;
  select * into p from public.payments where order_id = o.id and status = 'succeeded' order by paid_at desc nulls last limit 1;
  src := case when p.provider is null then null
              when p.provider = 'stripe' then 'stripe'
              when p.provider in ('aani','bank_transfer','cash','manual','external') then p.provider
              else 'external' end;
  update public.session_packs set
    payment_status = case when o.status = 'paid' then 'paid'
                          when o.status in ('partially_refunded') then 'partial'
                          when o.status in ('refunded','cancelled') then 'unpaid'
                          else payment_status end,
    paid_at = case when o.status = 'paid' then coalesce(p.paid_at, o.paid_at, now()) else paid_at end,
    order_id = o.id,
    payment_source = coalesce(src, payment_source)
  where id = o.session_pack_id;
end $$;
revoke execute on function public.project_pack_payment(uuid) from public, anon;
grant  execute on function public.project_pack_payment(uuid) to authenticated, service_role;

-- ---------- 9. record a manual / external (Aani) payment ----------
-- The operator confirms money actually received (never triggered by the client
-- viewing/copying instructions). Amount/currency are what was received.
-- Stripe is NOT this path. No Oolala earning: money went straight to Gari, it
-- never passed through Oolala's Stripe (settle Oolala's cut separately if ever
-- agreed). Never fabricates a Stripe/Aani transaction id.
create or replace function public.payment_record_manual(
  p_pack_id uuid, p_amount int, p_currency text, p_source text default 'aani', p_reference text default null, p_paid_at timestamptz default null)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare e text := public.current_email(); sp public.session_packs%rowtype; o public.orders%rowtype; c public.crm_contacts%rowtype; v_ref text; pay public.payments%rowtype;
begin
  if not public.has_permission('finance:manage') then raise exception 'forbidden' using errcode = '42501'; end if;
  if p_source not in ('aani','bank_transfer','cash','manual','external') then raise exception 'invalid source' using errcode = '22023'; end if;
  if p_amount is null or p_amount <= 0 then raise exception 'amount required' using errcode = '22023'; end if;
  if coalesce(p_currency,'') !~ '^[A-Z]{3}$' then raise exception 'currency required (ISO 4217)' using errcode = '22023'; end if;
  select * into sp from public.session_packs where id = p_pack_id for update;
  if not found then raise exception 'pack not found' using errcode = 'P0002'; end if;
  select * into c from public.crm_contacts where id = sp.crm_contact_id;

  select * into o from public.orders where session_pack_id = sp.id and status in ('pending_payment') limit 1;
  if not found then
    loop v_ref := 'OR-' || upper(substr(encode(extensions.gen_random_bytes(4),'hex'),1,6)); exit when not exists (select 1 from public.orders where reference = v_ref); end loop;
    insert into public.orders (reference, booking_id, session_pack_id, order_reason, customer_name, customer_contact, currency, gross_amount, status)
    values (v_ref, null, sp.id, 'session_pack', coalesce(c.display_name,'Client'), coalesce(c.email,c.phone,'n/a'), p_currency, p_amount, 'pending_payment')
    returning * into o;
  end if;

  insert into public.payments (order_id, provider, amount, currency, status, paid_at, note)
  values (o.id, p_source, p_amount, p_currency, 'succeeded', coalesce(p_paid_at, now()), nullif(p_reference,''))
  returning * into pay;
  update public.orders set status = 'paid', paid_at = coalesce(paid_at, pay.paid_at) where id = o.id;
  perform public.project_pack_payment(o.id);       -- source recorded on the pack; NO recompute_earning (not Oolala-collected)
  insert into public.admin_audit (area, entity_id, action, changed_by, summary)
  values ('payment', o.reference, 'manual', e, jsonb_build_object('pack', sp.id, 'source', p_source, 'amount', p_amount, 'currency', p_currency));
  return jsonb_build_object('ok', true, 'order', o.reference, 'payment_id', pay.id, 'source', p_source);
end $$;
revoke execute on function public.payment_record_manual(uuid, int, text, text, text, timestamptz) from public, anon;
grant  execute on function public.payment_record_manual(uuid, int, text, text, text, timestamptz) to authenticated, service_role;

-- ---------- 10. payments / requests history for a pack (client-scoped projection) ----------
create or replace function public.pack_payment_history(p_pack_id uuid)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare fin boolean := public.has_permission('finance:view');
begin
  if not public.has_permission('coach:operations') then raise exception 'forbidden' using errcode = '42501'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object(
      'order_reference', o.reference, 'status', o.status, 'created_at', o.created_at,
      'amount', case when fin then o.gross_amount else null end, 'currency', o.currency,
      'paid_at', o.paid_at,
      'source', (select p.provider from public.payments p where p.order_id = o.id and p.status='succeeded' order by p.paid_at desc nulls last limit 1)
    ) order by o.created_at desc)
    from public.orders o where o.session_pack_id = p_pack_id), '[]'::jsonb);
end $$;
revoke execute on function public.pack_payment_history(uuid) from public, anon;
grant  execute on function public.pack_payment_history(uuid) to authenticated, service_role;

-- ---------- 11. package renewal (new pack; old is immutable) ----------
create or replace function public.pack_renew(p_pack_id uuid)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare e text := public.current_email(); old public.session_packs%rowtype; row public.session_packs%rowtype; fin boolean := public.has_permission('finance:view');
begin
  if not public.has_permission('coach:operations') then raise exception 'forbidden' using errcode = '42501'; end if;
  select * into old from public.session_packs where id = p_pack_id;
  if not found then raise exception 'pack not found' using errcode = 'P0002'; end if;
  insert into public.session_packs (crm_contact_id, service_id, title, total_sessions,
      price_amount, currency, payment_status, agreement_date, renewed_from_pack_id, created_by)
  values (old.crm_contact_id, old.service_id, old.title, old.total_sessions,
      case when fin then old.price_amount else null end, old.currency, 'unpaid', current_date, old.id, e)
  returning * into row;
  insert into public.admin_audit (area, entity_id, action, changed_by, summary)
  values ('session_pack', row.id::text, 'renew', e, jsonb_build_object('from', old.id));
  return public.pack_json(row);
end $$;
revoke execute on function public.pack_renew(uuid) from public, anon;
grant  execute on function public.pack_renew(uuid) to authenticated, service_role;

-- ---------- 12. patch process_stripe_event: booking-optional + pack projection ----------
-- Identical booking behaviour; adds a pack branch (project onto the pack after
-- the Stripe payment is recorded and the Oolala earning computed).
create or replace function public.process_stripe_event(p_event jsonb)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare
  ev_id text := p_event ->> 'id'; ev_type text := p_event ->> 'type'; obj jsonb := p_event -> 'data' -> 'object';
  enrich jsonb := coalesce(p_event -> '_enrich', '{}'::jsonb);
  existing public.webhook_events%rowtype;
  o public.orders%rowtype; b public.bookings%rowtype; p public.payments%rowtype;
  v_amount int; v_currency text; v_pi text; v_total_refunded int; v_status text;
  result jsonb;
begin
  if ev_id is null or ev_type is null then raise exception 'malformed event' using errcode = '22023'; end if;

  insert into public.webhook_events (event_id, event_type, payload) values (ev_id, ev_type, p_event)
  on conflict (event_id) do nothing;
  if not found then
    select * into existing from public.webhook_events where event_id = ev_id;
    if existing.status in ('processed','ignored') then
      return jsonb_build_object('event_id', ev_id, 'duplicate', true, 'status', existing.status);
    end if;
  end if;

  if ev_type = 'checkout.session.completed' then
    select * into o from public.orders where stripe_checkout_session_id = obj ->> 'id';
    if not found and (obj -> 'metadata' ->> 'order_id') is not null then
      select * into o from public.orders where id = (obj -> 'metadata' ->> 'order_id')::uuid;
    end if;
    if not found and (obj ->> 'client_reference_id') is not null then
      select * into o from public.orders where reference = obj ->> 'client_reference_id';
    end if;
    if not found then
      update public.webhook_events set status = 'ignored', note = 'unknown order', processed_at = now() where event_id = ev_id;
      return jsonb_build_object('event_id', ev_id, 'status', 'ignored', 'note', 'unknown order');
    end if;
    if coalesce(obj ->> 'payment_status', '') <> 'paid' then
      update public.webhook_events set status = 'ignored', note = 'payment_status ' || coalesce(obj ->> 'payment_status', 'null'), processed_at = now() where event_id = ev_id;
      return jsonb_build_object('event_id', ev_id, 'status', 'ignored', 'note', 'not paid');
    end if;
    v_amount := (obj ->> 'amount_total')::int; v_currency := upper(obj ->> 'currency'); v_pi := obj ->> 'payment_intent';
    if v_amount <> o.gross_amount or v_currency <> o.currency then
      update public.webhook_events set status = 'ignored', note = format('amount mismatch: got %s %s, order %s %s', v_amount, v_currency, o.gross_amount, o.currency), processed_at = now() where event_id = ev_id;
      return jsonb_build_object('event_id', ev_id, 'status', 'ignored', 'note', 'amount mismatch');
    end if;

    insert into public.payments (order_id, provider_payment_intent_id, provider_charge_id, provider_balance_transaction_id,
                                 amount, currency, fee_amount, fee_known, status, paid_at, provider_event_id)
    values (o.id, v_pi, enrich ->> 'charge_id', enrich ->> 'balance_transaction_id', v_amount, v_currency,
            coalesce((enrich ->> 'fee_amount')::int, 0), (enrich ->> 'fee_amount') is not null, 'succeeded', now(), ev_id)
    on conflict (provider_payment_intent_id) do update
      set fee_amount = case when public.payments.fee_known then public.payments.fee_amount else excluded.fee_amount end,
          fee_known  = public.payments.fee_known or excluded.fee_known,
          provider_charge_id = coalesce(public.payments.provider_charge_id, excluded.provider_charge_id),
          provider_balance_transaction_id = coalesce(public.payments.provider_balance_transaction_id, excluded.provider_balance_transaction_id)
    returning * into p;

    update public.orders set status = 'paid', paid_at = coalesce(paid_at, now())
     where id = o.id and status in ('pending_payment','paid');
    perform public.recompute_earning(o.id);   -- Stripe = Oolala-collected → commission applies (booking and pack alike)

    if o.booking_id is not null then
      update public.bookings set status = 'confirmed', hold_expires_at = null
       where id = o.booking_id and status in ('hold','pending_payment','confirmed');
      select * into b from public.bookings where id = o.booking_id;
      insert into public.email_events (booking_id, order_id, kind, to_address)
      values (b.id, o.id, 'booking_confirmed', case when b.customer_contact ~ '^[^\s@]+@[^\s@]+\.[^\s@]{2,}$' then b.customer_contact else null end),
             (b.id, o.id, 'payment_received', 'letsgo@coachgari.com')
      on conflict (order_id, kind) do nothing;
      update public.email_events set status = 'skipped', error = 'no email address (contact is a phone number)'
       where order_id = o.id and kind = 'booking_confirmed' and to_address is null and status = 'pending';
      result := jsonb_build_object('order', o.reference, 'payment_id', p.id, 'booking', b.reference, 'booking_status', 'confirmed');
    else
      perform public.project_pack_payment(o.id);
      result := jsonb_build_object('order', o.reference, 'payment_id', p.id, 'session_pack', o.session_pack_id);
    end if;

  elsif ev_type = 'checkout.session.expired' then
    select * into o from public.orders where stripe_checkout_session_id = obj ->> 'id';
    if found then
      update public.orders set status = 'cancelled' where id = o.id and status = 'pending_payment';
      if o.booking_id is not null then
        update public.bookings set status = 'expired' where id = o.booking_id and status in ('hold','pending_payment');
      end if;
      result := jsonb_build_object('order', o.reference, 'status', 'expired');
    else
      update public.webhook_events set status = 'ignored', note = 'unknown order', processed_at = now() where event_id = ev_id;
      return jsonb_build_object('event_id', ev_id, 'status', 'ignored');
    end if;

  elsif ev_type in ('refund.created','refund.updated') then
    v_pi := obj ->> 'payment_intent';
    select * into p from public.payments where provider_payment_intent_id = v_pi;
    if not found then
      update public.webhook_events set status = 'ignored', note = 'unknown payment', processed_at = now() where event_id = ev_id;
      return jsonb_build_object('event_id', ev_id, 'status', 'ignored');
    end if;
    v_status := case obj ->> 'status' when 'succeeded' then 'succeeded' when 'pending' then 'pending' when 'failed' then 'failed'
                     when 'canceled' then 'cancelled' else 'pending' end;
    insert into public.refunds (payment_id, order_id, amount, currency, reason, provider_refund_id, status, provider_event_id)
    values (p.id, p.order_id, (obj ->> 'amount')::int, upper(obj ->> 'currency'), obj ->> 'reason', obj ->> 'id', v_status, ev_id)
    on conflict (provider_refund_id) do update set status = excluded.status, amount = excluded.amount, reason = excluded.reason;
    select coalesce(sum(amount), 0) into v_total_refunded from public.refunds where order_id = p.order_id and status = 'succeeded';
    update public.orders set status = case when v_total_refunded >= p.amount then 'refunded'
                                           when v_total_refunded > 0 then 'partially_refunded' else status end
     where id = p.order_id;
    perform public.recompute_earning(p.order_id);
    perform public.project_pack_payment(p.order_id);
    result := jsonb_build_object('order_id', p.order_id, 'refunded', v_total_refunded);

  elsif ev_type like 'charge.dispute.%' then
    v_pi := obj ->> 'payment_intent';
    select * into p from public.payments where provider_payment_intent_id = v_pi
       or (v_pi is null and provider_charge_id = obj ->> 'charge');
    if not found then
      update public.webhook_events set status = 'ignored', note = 'unknown payment', processed_at = now() where event_id = ev_id;
      return jsonb_build_object('event_id', ev_id, 'status', 'ignored');
    end if;
    insert into public.chargebacks (payment_id, order_id, amount, currency, provider_dispute_id, status, reason, provider_event_id)
    values (p.id, p.order_id, (obj ->> 'amount')::int, upper(obj ->> 'currency'), obj ->> 'id', obj ->> 'status', obj ->> 'reason', ev_id)
    on conflict (provider_dispute_id) do update set status = excluded.status, amount = excluded.amount;
    perform public.recompute_earning(p.order_id);
    result := jsonb_build_object('order_id', p.order_id, 'dispute', obj ->> 'status');

  else
    update public.webhook_events set status = 'ignored', note = 'unhandled type', processed_at = now() where event_id = ev_id;
    return jsonb_build_object('event_id', ev_id, 'status', 'ignored', 'type', ev_type);
  end if;

  update public.webhook_events set status = 'processed', processed_at = now() where event_id = ev_id;
  return result || jsonb_build_object('event_id', ev_id, 'status', 'processed');
end $$;

-- ---------- 13. hardening (advisors) ----------
-- Trigger functions must not be callable as RPCs (they need a trigger context).
revoke all on function public.coaching_sessions_pack_guard() from public, anon, authenticated;
revoke all on function public.sync_session_from_booking() from public, anon, authenticated;
-- Internal helpers: reachable only through the gated pack_recap / service-role
-- report_view, and through the definer payment functions. Not directly by a
-- signed-in user (p_finance=true would otherwise bypass the finance gate).
revoke execute on function public.pack_recap_data(uuid, boolean) from authenticated;
revoke execute on function public.project_pack_payment(uuid) from authenticated;

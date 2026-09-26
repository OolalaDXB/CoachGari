-- =====================================================================
-- A payment link the coach issues himself: a label, an amount, a URL.
--
-- Everything Coach Gari could charge for until now had to hang off something
-- already in the system — a booking or a package, and therefore a client. That
-- covers "be paid for this, by this person". It does not cover the ordinary
-- case of quoting someone who is not in the CRM yet, or charging for a thing
-- that is not a course of sessions.
--
-- The money path is not reinvented. A link is an `orders` row with a new
-- reason, and it reaches BEAU PH through cg_ph_request_for_order like every
-- other order, which maps an unrecognised reason to the `other` intent. Two
-- consequences worth stating, because both were checked rather than assumed:
--
--   * process_stripe_event needs no change. Its non-booking branch calls
--     project_pack_payment, which returns immediately when session_pack_id is
--     null — the same reason a `support` payment reconciles safely today.
--
--   * the card rail has to opt in to the `other` intent explicitly. Rails are
--     never enabled for an intent by default here, and that rule is not worth
--     breaking for convenience: Aani, bank transfer and cash stay scoped to
--     service and package until someone decides otherwise on purpose.
--
-- The BEAU PH request is created when the payer OPENS the link, not when the
-- coach writes it. A request carries an expiry and a live status; minting one
-- that then sits untouched for a month would have the ledger describe an
-- attempt nobody made.
--
-- The token is held by the payer, stored only as a sha256, and is a key to one
-- link and nothing else. It proves no identity and grants no read of anything
-- but that link's own amount and status.
-- =====================================================================

-- ---------- 1. a fourth kind of order, with no target row ----------
alter table public.orders drop constraint if exists orders_order_reason_check;
alter table public.orders add constraint orders_order_reason_check
  check (order_reason in ('booking','session_pack','support','collaboration','payment_link'));
alter table public.orders drop constraint if exists orders_target_ck;
alter table public.orders add constraint orders_target_ck check (
  (order_reason = 'booking'       and booking_id is not null) or
  (order_reason = 'session_pack'  and session_pack_id is not null) or
  (order_reason in ('support','collaboration','payment_link')
     and booking_id is null and session_pack_id is null));

-- who it was written for, when the coach knows: optional, and never required to pay
alter table public.orders add column if not exists crm_contact_id uuid references public.crm_contacts(id) on delete set null;
create index if not exists orders_crm_contact_idx on public.orders (crm_contact_id) where crm_contact_id is not null;

-- the audit ledger has to know the word before it can record the act
alter table public.admin_audit drop constraint if exists admin_audit_area_check;
alter table public.admin_audit add constraint admin_audit_area_check check (area in (
  'crm_contact','crm_note','body_measurement','permission','consent','merge','coaching_session',
  'session_pack','block','report','payment','payment_method','beau_ph_rail','beau_ph_fx',
  'settlement_destination','collaboration','email','commission','enquiry','analytics','whatsapp',
  'agreement','subscription','client_rate','order'));

-- ---------- 2. the card rail opts in to `other` ----------
do $$
begin
  perform beau_ph.merchant_method_configure('coach_gari', 'stripe',
            '{"intents":["service","package","support","other"]}'::jsonb, 'migration:20261074');
end $$;

-- ---------- 3. create a link ----------
/* Floor and ceiling are the same magnitudes support uses. A link is written by the
   coach rather than typed by a stranger, so the ceiling is higher — but there is
   still one, because a typo in an amount is a thing that happens and an invoice for
   a hundred times the price is not a payment anyone completes. */
create or replace function public.payment_link_create(p_label text, p_amount int, p_currency text,
                                                      p_crm_contact_id uuid default null, p_days int default 30)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare e text := public.current_email(); cur text := upper(coalesce(p_currency, '')); lbl text;
        o public.orders%rowtype; tok text; v_ref text; days int := greatest(1, least(coalesce(p_days, 30), 365));
        nm text; ct text;
begin
  if not public.has_permission('finance:manage') then raise exception 'forbidden' using errcode = '42501'; end if;
  lbl := nullif(left(regexp_replace(btrim(coalesce(p_label, '')), '\s+', ' ', 'g'), 120), '');
  if lbl is null then raise exception 'a label is required — it is what the payer reads' using errcode = '22023'; end if;
  if cur !~ '^[A-Z]{3}$' then raise exception 'currency required (ISO 4217)' using errcode = '22023'; end if;
  if p_amount is null or p_amount < 1000 then raise exception 'amount must be at least 10' using errcode = '22023'; end if;
  if p_amount > 5000000 then raise exception 'amount above the maximum (50,000)' using errcode = '22023'; end if;

  /* Is this a currency Coach Gari is set up to charge in at all? A CONFIGURATION
     question, deliberately — not beau_ph.eligible_currencies, which also weighs the
     runtime of the browser making the request. The coach is not the payer: there is
     no Stripe runtime in a back-office session, so asking the runtime question here
     refuses every currency, which is exactly what the suite caught. The runtime
     question belongs where the runtime exists, and payment_link_open asks it there. */
  if not exists (
    select 1 from beau_ph.merchant_methods mm
      join beau_ph.merchants m on m.id = mm.merchant_id
     where m.key = 'coach_gari' and mm.enabled and 'other' = any (mm.intents) and cur = any (mm.currencies)
  ) then
    raise exception 'currency % is not configured for a payment link', cur using errcode = '22023';
  end if;

  if p_crm_contact_id is not null then
    select display_name, coalesce(email, phone) into nm, ct from public.crm_contacts where id = p_crm_contact_id;
    if nm is null and ct is null then raise exception 'contact not found' using errcode = 'P0002'; end if;
  end if;

  loop v_ref := 'PL-' || upper(substr(encode(extensions.gen_random_bytes(4), 'hex'), 1, 6));
       exit when not exists (select 1 from public.orders where reference = v_ref); end loop;
  tok := encode(extensions.gen_random_bytes(32), 'hex');

  insert into public.orders (reference, booking_id, session_pack_id, crm_contact_id, order_reason,
                             customer_name, customer_contact, currency, gross_amount, status,
                             service_title, access_token_hash, checkout_expires_at)
  values (v_ref, null, null, p_crm_contact_id, 'payment_link',
          coalesce(nm, 'Payer'), coalesce(ct, 'n/a'), cur, p_amount, 'pending_payment',
          lbl, encode(extensions.digest(tok, 'sha256'), 'hex'), now() + make_interval(days => days))
  returning * into o;

  insert into public.admin_audit (area, entity_id, action, changed_by, summary)
  values ('order', o.id::text, 'payment_link:create', e,
          jsonb_build_object('reference', o.reference, 'label', lbl, 'amount', p_amount, 'currency', cur, 'days', days));

  return jsonb_build_object('reference', o.reference, 'token', tok, 'label', lbl,
                            'amount', o.gross_amount, 'currency', o.currency, 'expires_at', o.checkout_expires_at);
end $$;
revoke execute on function public.payment_link_create(text, int, text, uuid, int) from public, anon;
grant  execute on function public.payment_link_create(text, int, text, uuid, int) to authenticated, service_role;

-- ---------- 4. the payer opens it ----------
/* Returns what the page needs and nothing more. The BEAU PH request is minted here,
   on the first open, and reused afterwards — cg_ph_request_for_order already returns
   the live one when a request for this order exists in a payable state. */
create or replace function public.payment_link_open(p_reference text, p_token text, p_runtime jsonb default '{}'::jsonb)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare o public.orders%rowtype; req jsonb;
begin
  if p_token is null or p_token !~ '^[0-9a-f]{64}$' then raise exception 'invalid link' using errcode = 'P0002'; end if;
  select * into o from public.orders
   where reference = p_reference and order_reason = 'payment_link'
     and access_token_hash = encode(extensions.digest(p_token, 'sha256'), 'hex');
  if not found then raise exception 'invalid link' using errcode = 'P0002'; end if;

  -- a settled or withdrawn link answers honestly instead of offering a payment
  if o.status = 'paid' then
    return jsonb_build_object('state', 'paid', 'label', o.service_title, 'amount', o.gross_amount,
                              'currency', o.currency, 'reference', o.reference, 'paid_at', o.paid_at);
  end if;
  if o.status in ('cancelled','failed','refunded','partially_refunded') then
    return jsonb_build_object('state', 'closed', 'label', o.service_title, 'reference', o.reference);
  end if;
  if o.checkout_expires_at is not null and o.checkout_expires_at < now() then
    return jsonb_build_object('state', 'expired', 'label', o.service_title, 'reference', o.reference);
  end if;

  req := public.cg_ph_request_for_order(o, 'stripe', coalesce(p_runtime, '{}'::jsonb), false, null, null, null, null);
  if req is null or (req ->> 'id') is null then raise exception 'payment unavailable' using errcode = 'P0003'; end if;

  return jsonb_build_object('state', 'payable', 'label', o.service_title, 'amount', o.gross_amount,
                            'currency', o.currency, 'reference', o.reference, 'request', req);
end $$;
revoke execute on function public.payment_link_open(text, text, jsonb) from public, anon, authenticated;
grant  execute on function public.payment_link_open(text, text, jsonb) to service_role;

-- ---------- 5. the coach's side ----------
create or replace function public.payment_link_list(p_limit int default 50)
returns table (reference text, label text, amount int, currency text, status text, contact text,
               created_at timestamptz, expires_at timestamptz, paid_at timestamptz)
language sql stable security definer set search_path = '' as $$
  select o.reference, o.service_title, o.gross_amount, o.currency,
         case when o.status = 'pending_payment' and o.checkout_expires_at < now() then 'expired' else o.status end,
         c.display_name, o.created_at, o.checkout_expires_at, o.paid_at
    from public.orders o
    left join public.crm_contacts c on c.id = o.crm_contact_id
   where o.order_reason = 'payment_link'
     and public.has_permission('finance:view')
   order by o.created_at desc
   limit greatest(1, least(coalesce(p_limit, 50), 200))
$$;
revoke execute on function public.payment_link_list(int) from public, anon;
grant  execute on function public.payment_link_list(int) to authenticated, service_role;

/* Withdrawing a link cancels the order AND the payment request behind it. Cancelling
   only the order would leave BEAU PH holding a live request against a reference the
   host considers closed — the kind of drift that is invisible until a payment lands
   on it. */
create or replace function public.payment_link_void(p_reference text)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare e text := public.current_email(); o public.orders%rowtype; r beau_ph.payment_requests%rowtype; mid uuid;
begin
  if not public.has_permission('finance:manage') then raise exception 'forbidden' using errcode = '42501'; end if;
  select * into o from public.orders where reference = p_reference and order_reason = 'payment_link';
  if not found then raise exception 'link not found' using errcode = 'P0002'; end if;
  if o.status = 'paid' then raise exception 'this link has been paid — it cannot be withdrawn' using errcode = 'P0003'; end if;

  select id into mid from beau_ph.merchants where key = 'coach_gari';
  for r in select * from beau_ph.payment_requests
            where merchant_id = mid and external_reference = o.reference
              and status in ('created','pending','requires_action') loop
    -- 'operator': BEAU PH's word for a person acting on the merchant's side
    perform beau_ph.cancel_request(r.id, 'operator', e, 'payment link withdrawn', 'coach_gari');
  end loop;

  update public.orders set status = 'cancelled' where id = o.id;
  insert into public.admin_audit (area, entity_id, action, changed_by, summary)
  values ('order', o.id::text, 'payment_link:void', e, jsonb_build_object('reference', o.reference));
  return jsonb_build_object('reference', o.reference, 'status', 'cancelled');
end $$;
revoke execute on function public.payment_link_void(text) from public, anon;
grant  execute on function public.payment_link_void(text) to authenticated, service_role;

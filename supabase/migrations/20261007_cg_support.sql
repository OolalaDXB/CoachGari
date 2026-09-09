-- =====================================================================
-- Coach Gari — "Support Coach Gari": a generic BEAU PH payment (intent
-- `support`), not a service, booking, package or session
--
-- Host record: an `orders` row with order_reason = 'support' — the host's
-- generic money record (reference, amount, currency, status, payer hint),
-- with NO booking and NO session pack, so nothing downstream can confirm a
-- booking, mark a pack paid or consume a credit. The BEAU PH request
-- carries intent = 'support' and the optional message in its metadata.
-- The browser proposes an amount; support_create() validates merchant,
-- intent, currency (what BEAU PH can offer for `support` right now),
-- floor / ceiling and rail eligibility before anything is created. Only
-- the verified Stripe webhook marks it paid (process_stripe_event, whose
-- support path touches no booking and no pack). Rails: only the methods
-- whose merchant configuration lists the `support` intent are eligible —
-- card (Stripe) today; Aani, bank transfer and cash are scoped to service
-- and package. Forward migration only.
-- =====================================================================

-- 1. the host record may carry a support intent, with no target row
alter table public.orders drop constraint if exists orders_order_reason_check;
alter table public.orders add constraint orders_order_reason_check check (order_reason in ('booking','session_pack','support'));
alter table public.orders drop constraint if exists orders_target_ck;
alter table public.orders add constraint orders_target_ck check (
  (order_reason = 'booking'      and booking_id is not null) or
  (order_reason = 'session_pack' and session_pack_id is not null) or
  (order_reason = 'support'      and booking_id is null and session_pack_id is null));
-- a payer-held credential for reading the state of a support payment (sha256 only), the same way bookings and reports are read
alter table public.orders add column if not exists access_token_hash text;
create unique index if not exists orders_access_token_hash_idx on public.orders (access_token_hash) where access_token_hash is not null;

-- 2. rails opt in to the support intent explicitly (never every rail by default)
do $$
begin
  perform beau_ph.merchant_method_configure('coach_gari', 'stripe',        '{"intents":["service","package","support"]}'::jsonb, 'migration:20261007');
  perform beau_ph.merchant_method_configure('coach_gari', 'aani',          '{"intents":["service","package"]}'::jsonb, 'migration:20261007');
  perform beau_ph.merchant_method_configure('coach_gari', 'cash',          '{"intents":["service","package"]}'::jsonb, 'migration:20261007');
  if exists (select 1 from beau_ph.merchant_methods mm join beau_ph.merchants m on m.id = mm.merchant_id where m.key = 'coach_gari' and mm.provider_key = 'bank_transfer') then
    perform beau_ph.merchant_method_configure('coach_gari', 'bank_transfer', '{"intents":["service","package"]}'::jsonb, 'migration:20261007');
  end if;
end $$;

-- 3. create a support payment: validated server-side, BEAU PH request with intent support, payer-held state token
create or replace function public.support_create(p_amount int, p_currency text, p_message text default null, p_runtime jsonb default '{}'::jsonb)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare cur text := upper(coalesce(p_currency, '')); msg text; o public.orders%rowtype; req jsonb; tok text; v_ref text; pub text;
  floor_minor int; ceil_minor int; offered jsonb;
begin
  if cur !~ '^[A-Z]{3}$' then raise exception 'currency required (ISO 4217)' using errcode = '22023'; end if;
  if p_amount is null or p_amount <= 0 then raise exception 'amount required' using errcode = '22023'; end if;
  -- what BEAU PH can offer for a support payment right now: the merchant's home market, the rails that list the intent
  offered := beau_ph.eligible_currencies('coach_gari', null, p_runtime, null, 'customer', 'support');
  if not exists (select 1 from jsonb_array_elements(offered) c where c ->> 'currency' = cur) then
    raise exception 'currency % is not available for support', cur using errcode = '22023';
  end if;
  -- floor / ceiling for a support payment (minor units): AED 10 – 5,000; other currencies follow the same magnitude
  floor_minor := 1000; ceil_minor := 500000;
  if p_amount < floor_minor then raise exception 'amount below the minimum (% %)', cur, floor_minor / 100 using errcode = '22023'; end if;
  if p_amount > ceil_minor then raise exception 'amount above the maximum (% %)', cur, ceil_minor / 100 using errcode = '22023'; end if;
  msg := nullif(left(regexp_replace(btrim(coalesce(p_message, '')), '\s+', ' ', 'g'), 500), '');
  loop v_ref := 'OR-' || upper(substr(encode(extensions.gen_random_bytes(4), 'hex'), 1, 6)); exit when not exists (select 1 from public.orders where reference = v_ref); end loop;
  loop pub := 'SUP-' || upper(substr(encode(extensions.gen_random_bytes(4), 'hex'), 1, 6));
       exit when not exists (select 1 from beau_ph.payment_requests where public_reference = pub); end loop;
  tok := encode(extensions.gen_random_bytes(32), 'hex');
  insert into public.orders (reference, booking_id, session_pack_id, order_reason, customer_name, customer_contact, currency, gross_amount, status, service_title, access_token_hash)
  values (v_ref, null, null, 'support', 'Supporter', 'n/a', cur, p_amount, 'pending_payment', 'Support Coach Gari', encode(extensions.digest(tok, 'sha256'), 'hex'))
  returning * into o;
  -- the BEAU PH request: intent support (from the order reason), rail eligibility enforced, amount from the order row just written
  req := public.cg_ph_request_for_order(o, 'stripe', p_runtime, false, null, null, null);
  if req is null or (req ->> 'id') is null then raise exception 'support payment unavailable' using errcode = 'P0003'; end if;
  update beau_ph.payment_requests
     set public_reference = pub, metadata = metadata || jsonb_strip_nulls(jsonb_build_object('message', msg))
   where id = (req ->> 'id')::uuid;
  req := beau_ph.request_json((select r from beau_ph.payment_requests r where r.id = (req ->> 'id')::uuid));
  return jsonb_build_object('request', req, 'token', tok,
                            'order', jsonb_build_object('reference', o.reference, 'status', o.status, 'gross_amount', o.gross_amount, 'currency', o.currency,
                                                        'customer_contact', o.customer_contact, 'public_reference', pub));
end $$;
revoke execute on function public.support_create(int, text, text, jsonb) from public, anon, authenticated;
grant  execute on function public.support_create(int, text, text, jsonb) to service_role;

-- 4. the payer reads the state with the token; never proof of anything, only what the webhook has established
create or replace function public.support_state(p_reference text, p_token text)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare o public.orders%rowtype;
begin
  if p_token is null or p_token !~ '^[0-9a-f]{64}$' then raise exception 'invalid token' using errcode = 'P0002'; end if;
  select * into o from public.orders where reference = p_reference and order_reason = 'support' and access_token_hash = encode(extensions.digest(p_token, 'sha256'), 'hex');
  if not found then raise exception 'invalid token' using errcode = 'P0002'; end if;
  return jsonb_build_object('reference', o.reference, 'status', o.status, 'amount', o.gross_amount, 'currency', o.currency, 'paid_at', o.paid_at);
end $$;
revoke execute on function public.support_state(text, text) from public, anon, authenticated;
grant  execute on function public.support_state(text, text) to service_role;

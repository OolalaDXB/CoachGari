-- =====================================================================
-- BEAU PH — Wise and PayPal
--
-- Two rails that the hub was missing, and they are not the same kind of thing.
--
--   WISE is a manual rail. Wise's API sends money and reads balances; it has no
--   hosted checkout and no way to tell us a payment arrived. What a Wise
--   Business account gives a merchant is LOCAL bank details in several
--   currencies, so the payer makes a cheap local transfer instead of an
--   international wire. That is a bank transfer that lands in Wise, and it is
--   modelled as exactly that: instructions, operator confirmation. Calling it
--   an integration would be dressing up a manual rail.
--
--   PAYPAL is a real online rail. Orders v2 with intent CAPTURE, and a payment
--   confirmed only by a signature-verified webhook — never by the payer's
--   browser returning to a URL. PayPal publishes no livemode flag in its
--   events, so the adapter stamps the mode of the credentials that verified the
--   event, and ingest_provider_event keeps refusing anything whose mode does
--   not match the merchant's.
--
-- BUSINESS ACCOUNTS, AND NEVER FRIENDS AND FAMILY. Receiving business income
-- into a personal Wise or PayPal account is outside both providers' terms, and
-- a commercial payment sent as friends-and-family removes protection for both
-- sides and is the usual reason a receiving account is limited. Nothing here
-- seeds an account; the merchant configures one, and the instruction fields
-- offer no friends-and-family wording to copy.
-- =====================================================================

-- ---------- 1. the providers ----------
/* The key list is a deliberate enumeration, not a free-text column: a typo must
   not be able to invent a payment provider. Extending it is therefore an
   explicit act, and the full list is re-issued because a CHECK cannot grow in
   place. */
alter table beau_ph.providers drop constraint if exists providers_key_check;
alter table beau_ph.providers add constraint providers_key_check check (key = any (array[
  'stripe','aani','bank_transfer','cash','paynow','mpesa','ozow','payshap','beau_wallet',
  'network_international','magnati','adyen','wise','paypal']));

insert into beau_ph.providers (key, display_name, kind, confirmation, countries, currencies, readiness, sort, notes) values
  ('wise', 'Wise (local transfer)', 'manual', 'operator', null, null, 'available', 35,
   'Local account details from a Wise Business account (AED, EUR, GBP, USD …) so the payer sends a local transfer rather than an international wire; an authorised operator confirms receipt. No Wise API call is made: Wise has no acceptance API, only payouts and balance reads. Business account only.'),
  ('paypal', 'PayPal', 'online', 'provider_event', null, null, 'available', 15,
   'Orders v2, intent CAPTURE, confirmed only by a signature-verified webhook. Commercial order — never friends and family. Falls back to instructions when the API is not configured. Business account only.')
on conflict (key) do nothing;

-- ---------- 2. what each can do ----------
insert into beau_ph.provider_capabilities (provider_key, capability, readiness, confirmation, platforms, initiated_by, handoff, notes) values
  ('wise',   'bank_transfer',       'available', 'operator',       null, 'any',      false, 'Wise Business local account details; an authorised operator confirms receipt.'),
  ('wise',   'manual_instructions', 'available', 'operator',       null, 'any',      false, 'Same rail, instruction form.'),
  ('paypal', 'online_checkout',     'available', 'provider_event', null, 'customer', false, 'Orders v2 CAPTURE; the payer approves on PayPal and a verified webhook confirms.'),
  ('paypal', 'wallet',              'available', 'provider_event', null, 'customer', false, 'The payer settles from their PayPal balance or a card on their account; it is the same order either way.'),
  ('paypal', 'manual_instructions', 'available', 'operator',       null, 'any',      false, 'Fallback when the API is not configured: pay the business account with the reference; an operator confirms.')
on conflict do nothing;

-- ---------- 3. how much is that, in minor units ----------
/* PayPal quotes decimal strings. Turning one into the integer the hub compares
   against needs the currency's exponent, and guessing it is how a JPY payment
   silently becomes a hundredth of itself. Three-decimal currencies are refused
   rather than rounded: PayPal does not support them, so an amount in one should
   never have reached this point. */
create or replace function beau_ph.currency_exponent(p_currency text)
returns int language sql immutable set search_path = '' as $$
  select case upper(coalesce(p_currency, ''))
           when 'JPY' then 0 when 'HUF' then 0 when 'TWD' then 0
           when 'BHD' then 3 when 'IQD' then 3 when 'JOD' then 3 when 'KWD' then 3
           when 'LYD' then 3 when 'OMR' then 3 when 'TND' then 3
           else 2
         end
$$;

create or replace function beau_ph.paypal_minor(p_value text, p_currency text)
returns int language plpgsql immutable set search_path = '' as $$
declare e int := beau_ph.currency_exponent(p_currency); n numeric;
begin
  if p_value is null or btrim(p_value) = '' then return null; end if;
  if e = 3 then return null; end if;                    -- PayPal cannot quote these; never round one into existence
  begin n := p_value::numeric; exception when others then return null; end;
  return round(n * power(10, e))::int;
end $$;

-- ---------- 4. a PayPal event, in the hub's own vocabulary ----------
/* The shape is the one ingest_provider_event already understands. Only the
   events that mean something are mapped; anything else is ignored explicitly so
   it is recorded and visible rather than silently dropped.

   The order id is carried on a capture through
   resource.supplementary_data.related_ids.order_id, and the BEAU PH request id
   through custom_id, which createPaymentRequest set. Both are tried, plus the
   invoice id, which is "<order reference>-<attempt>". */
create or replace function beau_ph.normalize_paypal_event(p_event jsonb)
returns jsonb language plpgsql stable set search_path = '' as $$
declare t text := p_event ->> 'event_type';
        res jsonb := p_event -> 'resource';
        v_currency text; v_amount int; v_order text; v_capture text; v_request text; v_invoice text;
        v_status text; v_refund int;
begin
  if res is null then return jsonb_build_object('ignore', 'no_resource'); end if;

  v_capture  := res ->> 'id';
  v_order    := coalesce(res #>> '{supplementary_data,related_ids,order_id}',
                         case when t like 'CHECKOUT.ORDER.%' then res ->> 'id' else null end);
  v_request  := nullif(res ->> 'custom_id', '');
  v_invoice  := nullif(res ->> 'invoice_id', '');
  v_currency := upper(coalesce(res #>> '{amount,currency_code}', res #>> '{seller_receivable_breakdown,gross_amount,currency_code}'));
  v_amount   := beau_ph.paypal_minor(coalesce(res #>> '{amount,value}', res #>> '{seller_receivable_breakdown,gross_amount,value}'), v_currency);

  v_status := case t
    when 'PAYMENT.CAPTURE.COMPLETED' then 'paid'
    when 'PAYMENT.CAPTURE.DENIED'    then 'failed'
    when 'PAYMENT.CAPTURE.REVERSED'  then 'refunded'
    when 'PAYMENT.CAPTURE.REFUNDED'  then 'refunded'
    when 'CHECKOUT.ORDER.APPROVED'   then 'requires_action'
    when 'CHECKOUT.ORDER.COMPLETED'  then 'evidence'
    else null end;
  if v_status is null then return jsonb_build_object('ignore', 'unhandled:' || coalesce(t, 'null')); end if;

  -- a partial refund is evidence, not a state change; ingest already handles that
  if v_status = 'refunded' then v_refund := v_amount; end if;

  return jsonb_strip_nulls(jsonb_build_object(
    'request_id',         case when v_request ~ '^[0-9a-f-]{36}$' then v_request else null end,
    'provider_reference', v_order,
    'payment_reference',  v_capture,
    'external_reference', case when v_invoice is null then null else regexp_replace(v_invoice, '-[0-9]+$', '') end,
    'status',             v_status,
    'amount',             v_amount,
    'currency',           v_currency,
    'refund_amount',      v_refund,
    'provider_status',    t,
    'evidence', jsonb_build_object(
      'livemode',   (p_event ->> 'beau_ph_livemode')::boolean,
      'event_type', t,
      'order_id',   v_order,
      'capture_id', v_capture,
      'invoice_id', v_invoice,
      'seller_fee', res #>> '{seller_receivable_breakdown,paypal_fee,value}',
      'net_amount', res #>> '{seller_receivable_breakdown,net_amount,value}')));
end $$;

/* The one door a verified PayPal event comes through. service_role only: the
   Edge Function has already checked the signature with PayPal itself. */
create or replace function beau_ph.process_paypal_event(p_event jsonb)
returns jsonb language sql volatile security definer set search_path = '' as $$
  select beau_ph.ingest_provider_event('paypal', p_event ->> 'id', p_event ->> 'event_type',
                                       p_event, beau_ph.normalize_paypal_event(p_event))
$$;
revoke all on function beau_ph.process_paypal_event(jsonb) from public, anon, authenticated;
grant execute on function beau_ph.process_paypal_event(jsonb) to service_role;
revoke all on function beau_ph.normalize_paypal_event(jsonb) from public, anon, authenticated;
revoke all on function beau_ph.paypal_minor(text, text) from public, anon, authenticated;
revoke all on function beau_ph.currency_exponent(text) from public, anon, authenticated;

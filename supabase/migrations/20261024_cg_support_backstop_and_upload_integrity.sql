-- =====================================================================
-- Coach Gari — P2: guard the public support order creation, and make the upload
-- confirmation check what was actually stored rather than only that it exists.
--
--  * support_create had no guard at all on a PUBLIC path that mints an order, a
--    BEAU PH request and a Stripe Checkout Session per call. It now carries the
--    same identity-independent back-stop as contact / booking / collab: unpaid
--    support checkouts started in a short window, all callers together.
--  * confirm_contact_media only flipped the row on the caller's word that the
--    object existed, so a caller could reserve a small jpeg and upload something
--    else entirely. It now takes the OBSERVED size and MIME type read back from
--    Storage and compares them with what was reserved; a mismatch fails the row
--    (and the edge deletes the object). Both observed values default to NULL so
--    the previously deployed 3-argument call keeps working.
-- =====================================================================

create or replace function public.support_create(p_amount int, p_currency text, p_message text default null, p_runtime jsonb default '{}'::jsonb, p_country text default null)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare cur text := upper(coalesce(p_currency, '')); ctry text := upper(coalesce(p_country, '')); msg text; o public.orders%rowtype; req jsonb; tok text; v_ref text; pub text;
  floor_minor int; ceil_minor int; offered jsonb; recent int;
begin
  if ctry !~ '^[A-Z]{2}$' then raise exception 'country required (ISO 3166-1 alpha-2)' using errcode = '22023'; end if;
  if cur !~ '^[A-Z]{3}$' then raise exception 'currency required (ISO 4217)' using errcode = '22023'; end if;
  if p_amount is null or p_amount <= 0 then raise exception 'amount required' using errcode = '22023'; end if;
  -- back-stop: unpaid support checkouts started in a short window, all callers together.
  -- Far above real traffic (a few a week); a loop minting orders and Stripe sessions hits this.
  select count(*) into recent from public.orders
   where order_reason = 'support' and status = 'pending_payment' and created_at > now() - interval '10 minutes';
  if recent >= 20 then
    raise exception 'too many support payments are being started just now; please try again shortly' using errcode = 'P0003';
  end if;
  offered := beau_ph.eligible_currencies('coach_gari', ctry, p_runtime, null, 'customer', 'support');
  if not exists (select 1 from jsonb_array_elements(offered) c where c ->> 'currency' = cur) then
    raise exception 'no payment method is available for % in %', cur, ctry using errcode = '22023';
  end if;
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
  req := public.cg_ph_request_for_order(o, 'stripe', p_runtime, false, null, null, null, ctry);
  if req is null or (req ->> 'id') is null then raise exception 'support payment unavailable' using errcode = 'P0003'; end if;
  update beau_ph.payment_requests
     set public_reference = pub, metadata = metadata || jsonb_strip_nulls(jsonb_build_object('message', msg))
   where id = (req ->> 'id')::uuid;
  req := beau_ph.request_json((select r from beau_ph.payment_requests r where r.id = (req ->> 'id')::uuid));
  return jsonb_build_object('request', req, 'token', tok,
                            'order', jsonb_build_object('reference', o.reference, 'status', o.status, 'gross_amount', o.gross_amount, 'currency', o.currency,
                                                        'customer_contact', o.customer_contact, 'public_reference', pub));
end $$;
revoke execute on function public.support_create(int, text, text, jsonb, text) from public, anon, authenticated;
grant  execute on function public.support_create(int, text, text, jsonb, text) to service_role;

drop function if exists public.confirm_contact_media(text, text, boolean);
create or replace function public.confirm_contact_media(p_upload_token text, p_path text, p_ok boolean,
                                                        p_observed_size bigint default null, p_observed_type text default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare m record; ok boolean := p_ok; reason text := null; obs_type text := lower(nullif(btrim(coalesce(p_observed_type,'')), ''));
begin
  if p_upload_token is null or p_upload_token !~ '^[0-9a-f]{64}$' then raise exception 'invalid upload token' using errcode = 'P0002'; end if;
  select cm.* into m from public.contact_media cm join public.contacts c on c.id = cm.contact_id
   where c.upload_token_hash = encode(extensions.digest(p_upload_token, 'sha256'), 'hex') and cm.storage_path = p_path;
  if not found then raise exception 'file not found' using errcode = 'P0002'; end if;
  -- the object must be what was reserved: same declared type, same size
  if ok and p_observed_size is not null then
    if p_observed_size <= 0 or p_observed_size > 52428800 then ok := false; reason := 'size_out_of_range';
    elsif p_observed_size <> m.size_bytes then ok := false; reason := 'size_mismatch';
    end if;
  end if;
  if ok and obs_type is not null then
    if obs_type !~ '^(image|video)/[a-z0-9.+-]+$' then ok := false; reason := 'content_type_rejected';
    elsif obs_type <> lower(m.content_type) then ok := false; reason := 'content_type_mismatch';
    end if;
  end if;
  update public.contact_media set status = case when ok then 'uploaded' else 'failed' end,
         uploaded_at = case when ok then now() else null end where id = m.id;
  return jsonb_strip_nulls(jsonb_build_object('media_id', m.id, 'status', case when ok then 'uploaded' else 'failed' end, 'reason', reason));
end $$;
revoke execute on function public.confirm_contact_media(text, text, boolean, bigint, text) from public, anon, authenticated;
grant  execute on function public.confirm_contact_media(text, text, boolean, bigint, text) to service_role;

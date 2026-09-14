/* =============================================================
   CG — the exemption workflow: request, two signatures, close
   Requesting costs nothing and decides nothing. Signing is the act, and it takes
   one signature from each side of the table. Closing goes the safe way — back to
   the standard commission — so either side may do it alone.
   Every verb writes to admin_audit, and an exemption that starts or stops biting
   reprices what it covers immediately rather than waiting for the next payment.
   ============================================================= */

-- Which side of the table the caller sits on. Oolala is Studio MT's platform, so it signs
-- as Studio; Gari signs as Gari. Anyone else has no signature to give.
create or replace function public.commission_party()
returns text language sql stable security definer set search_path = '' as $$
  select case u.party when 'gari' then 'gari' when 'studio' then 'studio' when 'oolala' then 'studio' end
    from public.app_users u where u.email = public.current_email() and u.active;
$$;
revoke all on function public.commission_party() from public, anon, authenticated;

-- Which client an order belongs to, whichever door it came through.
create or replace function public.commission_contact_for_order(p_order_id uuid)
returns uuid language sql stable security definer set search_path = '' as $$
  select coalesce(b.crm_contact_id, sp.crm_contact_id, d.crm_contact_id)
    from public.orders o
    left join public.bookings b on b.id = o.booking_id
    left join public.session_packs sp on sp.id = o.session_pack_id
    left join public.collaboration_payments cp on cp.order_reference = o.reference
    left join public.collaboration_deals d on d.id = cp.collaboration_id
   where o.id = p_order_id
   limit 1;
$$;
revoke all on function public.commission_contact_for_order(uuid) from public, anon, authenticated;

-- The governed rate for an order, if any: the line beats the client, and only a
-- fully signed exemption counts. Returns null when no exemption applies.
create or replace function public.commission_exempt_rate(p_order_id uuid, out rate numeric, out exemption_id uuid)
language plpgsql stable security definer set search_path = '' as $$
declare v_contact uuid;
begin
  select x.rate, x.id into rate, exemption_id
    from public.commission_exemptions x
   where x.scope = 'order' and x.order_id = p_order_id and x.status = 'active' limit 1;
  if exemption_id is not null then return; end if;
  v_contact := public.commission_contact_for_order(p_order_id);
  if v_contact is null then return; end if;
  select x.rate, x.id into rate, exemption_id
    from public.commission_exemptions x
   where x.scope = 'client' and x.crm_contact_id = v_contact and x.status = 'active' limit 1;
end $$;
revoke all on function public.commission_exempt_rate(uuid) from public, anon, authenticated;

-- ---------- request ----------
create or replace function public.commission_exemption_request(p jsonb)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare e text := public.current_email(); v_scope text; v_contact uuid; v_order uuid; v_rate numeric; v_reason text; x public.commission_exemptions%rowtype;
begin
  if not public.has_permission('finance:manage') then raise exception 'forbidden' using errcode = '42501'; end if;
  v_scope  := nullif(btrim(coalesce(p ->> 'scope', '')), '');
  v_reason := nullif(btrim(coalesce(p ->> 'reason', '')), '');
  v_rate   := coalesce((p ->> 'rate')::numeric, 0);
  if v_scope not in ('client','order') then raise exception 'scope must be client or order' using errcode = '22023'; end if;
  if v_reason is null or length(v_reason) < 3 then raise exception 'a reason is required' using errcode = '22023'; end if;
  if v_rate < 0 or v_rate > 1 then raise exception 'rate must be between 0 and 1' using errcode = '22023'; end if;
  if v_scope = 'client' then
    v_contact := (p ->> 'crm_contact_id')::uuid;
    if not exists (select 1 from public.crm_contacts where id = v_contact) then raise exception 'client not found' using errcode = 'P0002'; end if;
  else
    select id into v_order from public.orders where id = nullif(p ->> 'order_id','')::uuid or reference = (p ->> 'order_reference');
    if v_order is null then raise exception 'order not found' using errcode = 'P0002'; end if;
  end if;

  insert into public.commission_exemptions (scope, crm_contact_id, order_id, rate, reason, requested_by)
  values (v_scope, v_contact, v_order, v_rate, v_reason, e)
  returning * into x;

  insert into public.admin_audit (area, entity_id, action, changed_by, summary)
  values ('commission', x.id::text, 'exemption_requested', e,
          jsonb_build_object('scope', v_scope, 'rate', v_rate, 'client', v_contact, 'order', v_order, 'reason', v_reason));
  return to_jsonb(x);
end $$;
revoke all    on function public.commission_exemption_request(jsonb) from public, anon;
grant execute on function public.commission_exemption_request(jsonb) to authenticated, service_role;

-- ---------- approve: one signature per side, and the second one is what activates it ----------
create or replace function public.commission_exemption_approve(p_id uuid)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare e text := public.current_email(); v_side text; x public.commission_exemptions%rowtype;
begin
  if not public.has_permission('finance:manage') then raise exception 'forbidden' using errcode = '42501'; end if;
  v_side := public.commission_party();
  if v_side is null then raise exception 'only Coach Gari or Studio MT can sign a commission exemption' using errcode = '42501'; end if;
  select * into x from public.commission_exemptions where id = p_id for update;
  if not found then raise exception 'exemption not found' using errcode = 'P0002'; end if;
  if x.status not in ('pending','active') then raise exception 'this exemption is %', x.status using errcode = 'P0003'; end if;
  if (v_side = 'gari' and x.gari_by is not null) or (v_side = 'studio' and x.studio_by is not null) then
    raise exception 'your side has already signed this exemption' using errcode = 'P0003';
  end if;

  update public.commission_exemptions set
    gari_by   = case when v_side = 'gari'   then e     else gari_by   end,
    gari_at   = case when v_side = 'gari'   then now() else gari_at   end,
    studio_by = case when v_side = 'studio' then e     else studio_by end,
    studio_at = case when v_side = 'studio' then now() else studio_at end,
    updated_at = now()
  where id = p_id returning * into x;
  -- the second signature, and only the second, makes it bite
  if x.gari_by is not null and x.studio_by is not null and x.status = 'pending' then
    update public.commission_exemptions set status = 'active', updated_at = now() where id = p_id returning * into x;
  end if;

  insert into public.admin_audit (area, entity_id, action, changed_by, summary)
  values ('commission', x.id::text, 'exemption_approved', e, jsonb_build_object('side', v_side, 'status', x.status));

  -- an exemption that just became live reprices what it covers, at once
  if x.status = 'active' then
    if x.scope = 'order' then
      perform public.recompute_earning(x.order_id);
    else
      perform public.recompute_earning(o.id) from public.orders o
       where o.status in ('paid','partially_refunded','refunded')
         and public.commission_contact_for_order(o.id) = x.crm_contact_id;
    end if;
  end if;
  return to_jsonb(x);
end $$;
revoke all    on function public.commission_exemption_approve(uuid) from public, anon;
grant execute on function public.commission_exemption_approve(uuid) to authenticated, service_role;

-- ---------- reject / revoke: back to the standard rate, the direction that surprises nobody ----------
create or replace function public.commission_exemption_close(p_id uuid, p_reason text default null)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare e text := public.current_email(); v_side text; x public.commission_exemptions%rowtype; v_new text;
begin
  if not public.has_permission('finance:manage') then raise exception 'forbidden' using errcode = '42501'; end if;
  v_side := public.commission_party();
  if v_side is null then raise exception 'only Coach Gari or Studio MT can close a commission exemption' using errcode = '42501'; end if;
  select * into x from public.commission_exemptions where id = p_id for update;
  if not found then raise exception 'exemption not found' using errcode = 'P0002'; end if;
  if x.status not in ('pending','active') then raise exception 'this exemption is already %', x.status using errcode = 'P0003'; end if;
  v_new := case when x.status = 'pending' then 'rejected' else 'revoked' end;

  update public.commission_exemptions set status = v_new, closed_by = e, closed_at = now(),
         closed_reason = nullif(btrim(coalesce(p_reason, '')), ''), updated_at = now()
   where id = p_id returning * into x;
  insert into public.admin_audit (area, entity_id, action, changed_by, summary)
  values ('commission', x.id::text, 'exemption_' || v_new, e, jsonb_build_object('side', v_side, 'reason', x.closed_reason));

  if v_new = 'revoked' then
    if x.scope = 'order' then
      perform public.recompute_earning(x.order_id);
    else
      perform public.recompute_earning(o.id) from public.orders o
       where o.status in ('paid','partially_refunded','refunded')
         and public.commission_contact_for_order(o.id) = x.crm_contact_id;
    end if;
  end if;
  return to_jsonb(x);
end $$;
revoke all    on function public.commission_exemption_close(uuid, text) from public, anon;
grant execute on function public.commission_exemption_close(uuid, text) to authenticated, service_role;

-- ---------- list, with what this caller may still do to each row ----------
create or replace function public.commission_exemptions_list()
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare v_side text;
begin
  if not public.has_permission('finance:view') then raise exception 'forbidden' using errcode = '42501'; end if;
  v_side := public.commission_party();
  return jsonb_build_object('side', v_side, 'rows', coalesce((select jsonb_agg(row_to_json(r)::jsonb order by r.created_at desc) from (
    select x.id, x.scope, x.rate, x.reason, x.status, x.requested_by, x.requested_at,
           x.gari_by, x.gari_at, x.studio_by, x.studio_at, x.closed_by, x.closed_at, x.closed_reason, x.created_at,
           c.display_name as client_name, x.crm_contact_id, o.reference as order_reference, x.order_id,
           (v_side is not null and x.status in ('pending','active')
              and ((v_side = 'gari' and x.gari_by is null) or (v_side = 'studio' and x.studio_by is null))) as can_sign,
           (v_side is not null and x.status in ('pending','active')) as can_close
      from public.commission_exemptions x
      left join public.crm_contacts c on c.id = x.crm_contact_id
      left join public.orders o on o.id = x.order_id) r), '[]'::jsonb));
end $$;
revoke all    on function public.commission_exemptions_list() from public, anon;
grant execute on function public.commission_exemptions_list() to authenticated, service_role;

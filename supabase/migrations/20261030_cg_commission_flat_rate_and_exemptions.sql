/* =============================================================
   CG — one commission rate, and exemptions that need two signatures
   Correction to 20261025: the rate does NOT vary by origin. The commission is
   10 % wherever the money came from. The ORIGIN keeps deciding the accounting
   DIRECTION — Oolala collected means Oolala owes Gari the net; Gari collected
   means Gari owes Studio the commission — but no longer the rate.

   Holding a client, or one line, out of commission is a commercial decision that
   costs one party money, so neither party may take it alone: it needs a signature
   from Coach Gari's side AND from Studio MT's side. Until both are in, the
   exemption exists on the record and changes nothing.
   ============================================================= */

-- ---------- 1. one rate, both origins ----------
update public.commission_origins set rate = 0.1000, updated_at = now() where rate <> 0.1000;
update public.commission_origins set description =
  'Oolala collected the money (platform checkout). Oolala holds the cash and owes Coach Gari the net.'
  where origin = 'platform';
update public.commission_origins set description =
  'Coach Gari collected the money directly (cash, Aani, bank transfer, in-person PSP). Gari holds the cash and owes Studio the commission.'
  where origin = 'direct';

-- ---------- 2. exemptions, and the two signatures that make one real ----------
alter table public.admin_audit drop constraint if exists admin_audit_area_check;
alter table public.admin_audit add constraint admin_audit_area_check check (area = any (array[
  'crm_contact','crm_note','body_measurement','permission','consent','merge','coaching_session',
  'session_pack','block','report','payment','payment_method','beau_ph_rail','beau_ph_fx',
  'settlement_destination','collaboration','email','commission']));

create table if not exists public.commission_exemptions (
  id              uuid primary key default gen_random_uuid(),
  scope           text not null check (scope in ('client','order')),
  crm_contact_id  uuid references public.crm_contacts(id) on delete cascade,
  order_id        uuid references public.orders(id) on delete cascade,
  rate            numeric(6,4) not null default 0 check (rate >= 0 and rate <= 1),
  reason          text not null check (length(btrim(reason)) between 3 and 2000),
  status          text not null default 'pending' check (status in ('pending','active','rejected','revoked')),
  requested_by    text not null,
  requested_at    timestamptz not null default now(),
  gari_by         text, gari_at   timestamptz,
  studio_by       text, studio_at timestamptz,
  closed_by       text, closed_at timestamptz, closed_reason text,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  -- the scope and its target agree, always
  constraint commission_exemptions_target_ck check (
    (scope = 'client' and crm_contact_id is not null and order_id is null) or
    (scope = 'order'  and order_id is not null and crm_contact_id is null)),
  -- active is not a label an operator can set: it means both signatures are on the row
  constraint commission_exemptions_dual_ck check (
    status <> 'active' or (gari_by is not null and studio_by is not null))
);
-- one live exemption per target; a rejected or revoked one never blocks a new request
create unique index if not exists commission_exemptions_client_live
  on public.commission_exemptions (crm_contact_id) where scope = 'client' and status in ('pending','active');
create unique index if not exists commission_exemptions_order_live
  on public.commission_exemptions (order_id) where scope = 'order' and status in ('pending','active');

alter table public.commission_exemptions enable row level security;
revoke all on public.commission_exemptions from public, anon, authenticated;

-- the earning remembers which exemption priced it
alter table public.partner_earnings add column if not exists exemption_id uuid references public.commission_exemptions(id);

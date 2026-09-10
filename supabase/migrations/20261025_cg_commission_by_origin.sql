/* =============================================================
   CG — commission by ORIGIN, never by rail
   The commission was a hardcoded 0.1000 inside recompute_earning, and it was
   applied to Stripe only because Stripe was the only rail that recomputed.
   The validated model is a rate that follows who COLLECTED the money:
     · platform (Oolala collected, Stripe checkout)          → 10 %, payable
     · direct   (Coach Gari collected: cash, Aani, bank,
                 in-person PSP terminal)                     →  6 %, receivable
   Accounting direction is structural, not decorative: money Oolala holds and
   owes Gari is not money Gari holds and owes Studio. This migration puts the
   rate in data and makes the two directions impossible to confuse in the ledger.
   ============================================================= */

-- ---------- 1. the rate lives in data, keyed by ORIGIN (who collected), not by rail ----------
create table if not exists public.commission_origins (
  origin      text primary key check (origin in ('platform','direct')),
  rate        numeric(6,4) not null check (rate >= 0 and rate <= 1),
  direction   text not null check (direction in ('payable','receivable')),
  description text not null,
  updated_at  timestamptz not null default now()
);
insert into public.commission_origins (origin, rate, direction, description) values
  ('platform', 0.1000, 'payable',
   'Oolala collected the money (platform checkout). Oolala holds the cash and owes Coach Gari the net.'),
  ('direct',   0.0600, 'receivable',
   'Coach Gari collected the money directly (cash, Aani, bank transfer, in-person PSP). Gari holds the cash and owes Studio the commission.')
on conflict (origin) do nothing;

-- Which collection rail belongs to which ORIGIN. Declared data, so adding a rail is an
-- explicit accounting decision; recompute_earning never switches on the rail itself.
create table if not exists public.collection_rails (
  rail   text primary key,                                        -- public.payments.provider
  origin text not null references public.commission_origins(origin),
  note   text
);
insert into public.collection_rails (rail, origin, note) values
  ('stripe',                'platform', 'Card checkout settled into the Oolala Stripe account.'),
  ('aani',                  'direct',   'Aani transfer received by Coach Gari.'),
  ('bank_transfer',         'direct',   'Bank transfer received by Coach Gari.'),
  ('cash',                  'direct',   'Cash taken in person by Coach Gari.'),
  ('manual',                'direct',   'Recorded by hand outside the rails; the money reached Coach Gari.'),
  ('external',              'direct',   'Collected outside the platform entirely.'),
  ('network_international', 'direct',   'In-person PSP terminal operated by Coach Gari.'),
  ('magnati',               'direct',   'In-person PSP terminal operated by Coach Gari.'),
  ('adyen',                 'direct',   'In-person PSP terminal operated by Coach Gari.')
on conflict (rail) do nothing;

alter table public.commission_origins enable row level security;
alter table public.collection_rails   enable row level security;
revoke all on public.commission_origins, public.collection_rails from public, anon, authenticated;

-- ---------- 2. the ledger carries the origin and the accounting direction ----------
alter table public.partner_earnings
  add column if not exists collection_origin text not null default 'platform' references public.commission_origins(origin),
  add column if not exists studio_receivable int not null default 0;

alter table public.partner_earnings drop column if exists direction;
alter table public.partner_earnings
  add column direction text generated always as
    (case when collection_origin = 'platform' then 'payable' else 'receivable' end) stored;

-- The direction is structural, not a label: a platform row pays Gari the net and owes Studio
-- nothing to receive; a direct row pays Gari nothing (he already holds the cash) and books the
-- commission as receivable by Studio. A receivable can never look like Studio holding funds.
alter table public.partner_earnings drop constraint if exists partner_earnings_check1;
alter table public.partner_earnings add constraint partner_earnings_direction_check check (
  (collection_origin = 'platform' and gari_payable = net_collected - oolala_commission and studio_receivable = 0)
  or
  (collection_origin = 'direct'   and gari_payable = 0 and studio_receivable = oolala_commission)
);

-- =====================================================================
-- BEAU FX — server-side authoritative FX subsystem inside BEAU PH
--
-- Design source: the Maisons Collection FX subsystem (fx_daily_rates,
-- fx_rate_on, refresh-fx-rates, fxValidate, useFxRateFreshness). What is
-- kept: EUR reference base, "foreign units per 1 EUR" convention, daily
-- historical rates, rate-on-or-before lookup, source tracking, ±20 %
-- anomaly rejection, per-source isolation, run observability, freshness
-- categories (≤ 36 h fresh · 36–72 h acceptable · > 72 h stale),
-- transactional snapshots. What is NOT carried over: Maisons never blocks a
-- sale on a stale rate; BEAU PH fails closed — a stale or missing rate never
-- produces a converted payment (the host offers the pricing currency).
-- Nothing property/booking-specific is copied.
--
-- Concepts kept distinct: pricing currency (host commercial offer), payment
-- currency (what the payer is offered), settlement currency (what the
-- merchant / provider receives — on the rail), reporting currency (merchant
-- FX settings). Rate components kept separate on a quote: reference /
-- market rate, provider rate (null in V0), merchant adjustment (bps),
-- final customer rate.
--
-- Refresh runs entirely in the database with pg_net (no Edge Function, no
-- extra secret): fx_refresh_start() issues the HTTP calls, the minute job
-- fx_refresh_collect() reads the responses, validates, upserts and closes
-- the run. Frankfurter (ECB) for the currencies it quotes, pegs derived
-- from USD (AED = 3.6725), NBG defined as a source for GEL/RUB but disabled
-- until a merchant needs it.
--
-- Quotes are immutable rows with an expiry (15 min default); a request
-- consumes exactly one quote, and the amount on the request is the quote's
-- payment amount — the browser never supplies a rate or an amount.
-- Forward migration only.
-- =====================================================================

-- ---------- 1. sources and currencies (configuration, data-driven) ----------
create table if not exists beau_ph.fx_sources (
  key      text primary key check (key ~ '^[a-z][a-z0-9_]{1,30}$'),
  kind     text not null check (kind in ('frankfurter','nbg','peg')),
  url      text,
  enabled  boolean not null default true,
  sort     int not null default 100,
  notes    text
);
create table if not exists beau_ph.fx_currencies (
  currency     text primary key check (beau_ph.is_iso_currency(currency)),
  enabled      boolean not null default false,
  source_key   text references beau_ph.fx_sources(key),
  peg_currency text check (peg_currency is null or beau_ph.is_iso_currency(peg_currency)),
  peg_rate     numeric(18,8) check (peg_rate is null or peg_rate > 0),
  notes        text,
  updated_by   text,
  updated_at   timestamptz not null default now(),
  check (not enabled or source_key is not null)
);
create table if not exists beau_ph.fx_rates (
  id             uuid primary key default gen_random_uuid(),
  base_currency  text not null default 'EUR' check (beau_ph.is_iso_currency(base_currency)),
  quote_currency text not null check (beau_ph.is_iso_currency(quote_currency)),
  rate           numeric(18,8) not null check (rate > 0),          -- quote units per 1 base unit
  rate_date      date not null,
  source         text not null,
  fetched_at     timestamptz not null default now(),
  unique (base_currency, quote_currency, rate_date)
);
create index if not exists fx_rates_lookup_idx on beau_ph.fx_rates (base_currency, quote_currency, rate_date desc);
create table if not exists beau_ph.fx_refresh_runs (
  id                 uuid primary key default gen_random_uuid(),
  requested_at       timestamptz not null default now(),
  requested_by       text not null default 'cron',
  status             text not null default 'requested' check (status in ('requested','success','partial','failed')),
  http               jsonb not null default '{}'::jsonb,           -- {source_key: pg_net request id}
  rate_date          date,
  currencies_updated int not null default 0,
  currencies_skipped int not null default 0,
  details            jsonb not null default '{}'::jsonb,
  finished_at        timestamptz
);
create index if not exists fx_refresh_runs_open_idx on beau_ph.fx_refresh_runs (requested_at desc) where status = 'requested';
create table if not exists beau_ph.merchant_fx (
  merchant_id        uuid primary key references beau_ph.merchants(id) on delete cascade,
  enabled            boolean not null default false,               -- offer payment currencies other than the pricing currency
  reporting_currency text check (reporting_currency is null or beau_ph.is_iso_currency(reporting_currency)),
  adjustment_bps     int not null default 0 check (adjustment_bps between -1000 and 1000),
  quote_ttl_minutes  int not null default 15 check (quote_ttl_minutes between 1 and 120),
  max_age_hours      int not null default 72 check (max_age_hours between 1 and 720),
  updated_by         text,
  updated_at         timestamptz not null default now()
);
create table if not exists beau_ph.fx_quotes (
  id                     uuid primary key default gen_random_uuid(),
  merchant_id            uuid not null references beau_ph.merchants(id),
  pricing_currency       text not null check (beau_ph.is_iso_currency(pricing_currency)),
  pricing_amount         int  not null check (pricing_amount > 0),
  payment_currency       text not null check (beau_ph.is_iso_currency(payment_currency)),
  payment_amount         int  not null check (payment_amount > 0),
  rate_from              numeric(18,8) not null,                   -- EUR → pricing currency
  rate_to                numeric(18,8) not null,                   -- EUR → payment currency
  rate_date_from         date not null,
  rate_date_to           date not null,
  source_from            text not null,
  source_to              text not null,
  reference_rate         numeric(20,10) not null,                  -- payment units per pricing unit, market
  provider_rate          numeric(20,10),                           -- a provider's own conversion rate (V0: null)
  merchant_adjustment_bps int not null default 0,
  customer_rate          numeric(20,10) not null,                  -- final rate applied to the payer
  freshness              text not null check (freshness in ('fresh','acceptable')),
  age_hours              numeric(8,2) not null,
  created_at             timestamptz not null default now(),
  expires_at             timestamptz not null,
  status                 text not null default 'active' check (status in ('active','consumed','expired')),
  request_id             uuid,
  consumed_at            timestamptz
);
create index if not exists fx_quotes_merchant_idx on beau_ph.fx_quotes (merchant_id, created_at desc);

alter table beau_ph.fx_sources        enable row level security;
alter table beau_ph.fx_currencies     enable row level security;
alter table beau_ph.fx_rates          enable row level security;
alter table beau_ph.fx_refresh_runs   enable row level security;
alter table beau_ph.merchant_fx       enable row level security;
alter table beau_ph.fx_quotes         enable row level security;
revoke all on beau_ph.fx_sources, beau_ph.fx_currencies, beau_ph.fx_rates, beau_ph.fx_refresh_runs, beau_ph.merchant_fx, beau_ph.fx_quotes from public, anon, authenticated;

-- a quote never changes after creation, except its lifecycle fields
create or replace function beau_ph.fx_quotes_guard()
returns trigger language plpgsql set search_path = '' as $$
begin
  if tg_op = 'DELETE' then raise exception 'fx quotes are never deleted' using errcode = 'P0003'; end if;
  if (to_jsonb(new) - 'status' - 'request_id' - 'consumed_at') is distinct from (to_jsonb(old) - 'status' - 'request_id' - 'consumed_at') then
    raise exception 'fx quote is immutable' using errcode = 'P0003';
  end if;
  if old.status <> 'active' and new.status is distinct from old.status then
    raise exception 'fx quote already %', old.status using errcode = 'P0003';
  end if;
  return new;
end $$;
drop trigger if exists fx_quotes_guard on beau_ph.fx_quotes;
create trigger fx_quotes_guard before update or delete on beau_ph.fx_quotes for each row execute function beau_ph.fx_quotes_guard();

insert into beau_ph.fx_sources (key, kind, url, enabled, sort, notes) values
  ('frankfurter', 'frankfurter', 'https://api.frankfurter.app/latest', true, 10, 'ECB reference rates (business days). EUR base.'),
  ('usd_peg',     'peg',         null,                                 true, 20, 'Currencies pegged to USD, derived from the USD rate of the same day.'),
  ('nbg',         'nbg',         'https://nbg.gov.ge/gw/api/ct/monetarypolicy/currencies/en/json/', false, 30, 'National Bank of Georgia official rates (GEL, RUB). Disabled until a merchant needs GEL.')
on conflict (key) do nothing;
insert into beau_ph.fx_currencies (currency, enabled, source_key, peg_currency, peg_rate, notes) values
  ('USD', true,  'frankfurter', null,  null,   'ECB'),
  ('GBP', true,  'frankfurter', null,  null,   'ECB'),
  ('ZAR', true,  'frankfurter', null,  null,   'ECB'),
  ('CHF', false, 'frankfurter', null,  null,   'ECB'),
  ('AED', true,  'usd_peg',     'USD', 3.6725, 'AED is pegged to USD at 3.6725'),
  ('SAR', false, 'usd_peg',     'USD', 3.75,   'SAR is pegged to USD at 3.75'),
  ('QAR', false, 'usd_peg',     'USD', 3.64,   'QAR is pegged to USD at 3.64'),
  ('GEL', false, 'nbg',         null,  null,   'NBG official rate'),
  ('RUB', false, 'nbg',         null,  null,   'NBG official rate'),
  ('KES', false, null,          null,  null,   'No configured source. Add one before enabling.')
on conflict (currency) do nothing;
insert into beau_ph.merchant_fx (merchant_id, enabled, reporting_currency)
  select id, false, default_currency from beau_ph.merchants where key = 'coach_gari' on conflict (merchant_id) do nothing;

-- ---------- 2. rates: lookup, freshness, validation, ingestion ----------
create or replace function beau_ph.fx_currency_exponent(p text)
returns int language sql immutable set search_path = '' as $$
  select case when p in ('JPY','KRW','CLP','VND','XAF','XOF','UGX','RWF','ISK','PYG','KMF','GNF','DJF','BIF','VUV','XPF') then 0 else 2 end
$$;

-- EUR → p_ccy on the latest rate date on or before p_date (Maisons fx_rate_on semantics), with provenance.
create or replace function beau_ph.fx_rate_on(p_ccy text, p_date date default current_date)
returns table (rate numeric, rate_date date, source text, fetched_at timestamptz)
language sql stable security definer set search_path = '' as $$
  select 1::numeric, p_date, 'base'::text, now() where upper(p_ccy) = 'EUR'
  union all
  (select r.rate, r.rate_date, r.source, r.fetched_at
     from beau_ph.fx_rates r
    where upper(p_ccy) <> 'EUR' and r.base_currency = 'EUR' and r.quote_currency = upper(p_ccy) and r.rate_date <= p_date
    order by r.rate_date desc limit 1)
$$;

create or replace function beau_ph.fx_freshness(p_age_hours numeric)
returns text language sql immutable set search_path = '' as $$
  select case when p_age_hours is null then 'missing' when p_age_hours <= 36 then 'fresh' when p_age_hours <= 72 then 'acceptable' else 'stale' end
$$;

-- Maisons fxValidate: finite, strictly positive, and within ±20 % of the last known rate. Returns null when the rate is acceptable.
create or replace function beau_ph.fx_validate_rate(p_rate numeric, p_last numeric)
returns text language sql immutable set search_path = '' as $$
  select case when p_rate is null then 'not_numeric'
              when p_rate <= 0 then 'non_positive'
              when p_last is not null and p_last > 0 and abs(p_rate - p_last) / p_last > 0.20 then 'variation_' || round(abs(p_rate - p_last) / p_last * 100, 1) || 'pct'
              else null end
$$;

-- Validate against the last known rate, then upsert (idempotent on the day). A rejected candidate leaves the last valid rate in place.
create or replace function beau_ph.fx_ingest_rate(p_quote text, p_rate numeric, p_rate_date date, p_source text)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare last_rate numeric; why text;
begin
  select r.rate into last_rate from beau_ph.fx_rates r where r.base_currency = 'EUR' and r.quote_currency = upper(p_quote) order by r.rate_date desc limit 1;
  why := beau_ph.fx_validate_rate(p_rate, last_rate);
  if why is not null then return jsonb_build_object('currency', upper(p_quote), 'accepted', false, 'reason', why, 'rate', p_rate, 'source', p_source); end if;
  insert into beau_ph.fx_rates (base_currency, quote_currency, rate, rate_date, source, fetched_at)
  values ('EUR', upper(p_quote), p_rate, p_rate_date, p_source, now())
  on conflict (base_currency, quote_currency, rate_date) do update set rate = excluded.rate, source = excluded.source, fetched_at = now();
  return jsonb_build_object('currency', upper(p_quote), 'accepted', true, 'rate', p_rate, 'rate_date', p_rate_date, 'source', p_source);
end $$;

create or replace function beau_ph.fx_currency_status(p_ccy text)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare c beau_ph.fx_currencies%rowtype; r record; age numeric; s beau_ph.fx_sources%rowtype;
begin
  select * into c from beau_ph.fx_currencies where currency = upper(p_ccy);
  select * into s from beau_ph.fx_sources where key = c.source_key;
  select * into r from beau_ph.fx_rate_on(upper(p_ccy), current_date);
  age := case when r.fetched_at is null then null else round(extract(epoch from (now() - r.fetched_at)) / 3600, 2) end;
  return jsonb_build_object('currency', upper(p_ccy), 'enabled', coalesce(c.enabled, upper(p_ccy) = 'EUR'), 'source', coalesce(c.source_key, case when upper(p_ccy) = 'EUR' then 'base' end),
                            'source_kind', s.kind, 'peg_currency', c.peg_currency, 'peg_rate', c.peg_rate, 'notes', c.notes,
                            'rate', r.rate, 'rate_date', r.rate_date, 'rate_source', r.source, 'fetched_at', r.fetched_at, 'age_hours', age,
                            'freshness', beau_ph.fx_freshness(age));
end $$;

-- ---------- 3. refresh: HTTP out of the database (pg_net), collected by the minute job ----------
create or replace function beau_ph.fx_refresh_start(p_actor text default 'cron')
returns uuid language plpgsql volatile security definer set search_path = '' as $$
declare run_id uuid; s beau_ph.fx_sources%rowtype; ccys text; req bigint; v_http jsonb := '{}'::jsonb; url text;
begin
  if exists (select 1 from beau_ph.fx_refresh_runs where status = 'requested' and requested_at > now() - interval '10 minutes') then
    raise exception 'a refresh is already in progress' using errcode = 'P0003';
  end if;
  insert into beau_ph.fx_refresh_runs (requested_by) values (coalesce(p_actor, 'cron')) returning id into run_id;
  for s in select * from beau_ph.fx_sources where enabled and kind in ('frankfurter','nbg') order by sort loop
    select string_agg(currency, ',' order by currency) into ccys from beau_ph.fx_currencies where enabled and source_key = s.key;
    if ccys is null then continue; end if;
    url := case s.kind when 'frankfurter' then s.url || '?base=EUR&to=' || ccys
                       when 'nbg' then s.url || '?date=' || to_char(current_date, 'YYYY-MM-DD') end;
    begin
      req := net.http_get(url, '{}'::jsonb, '{"accept":"application/json"}'::jsonb, 8000);
      v_http := v_http || jsonb_build_object(s.key, req);
    exception when others then
      v_http := v_http || jsonb_build_object(s.key, jsonb_build_object('error', sqlerrm));
    end;
  end loop;
  update beau_ph.fx_refresh_runs set http = v_http where id = run_id;
  if v_http = '{}'::jsonb then
    update beau_ph.fx_refresh_runs set status = 'failed', finished_at = now(), details = '{"error":"no enabled source with enabled currencies"}'::jsonb where id = run_id;
  end if;
  return run_id;
end $$;

-- Reads the pg_net responses of open runs; validates and upserts each candidate; derives pegs; closes the run.
create or replace function beau_ph.fx_refresh_collect()
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare run beau_ph.fx_refresh_runs%rowtype; s beau_ph.fx_sources%rowtype; k text; req bigint; resp record; body jsonb; d date;
  accepted jsonb; skipped jsonb; errors jsonb; c beau_ph.fx_currencies%rowtype; res jsonb; gel_per_eur numeric; q numeric; item jsonb; summary jsonb := '[]'::jsonb;
  pending boolean; usd record; last_date date;
begin
  for run in select * from beau_ph.fx_refresh_runs where status = 'requested' order by requested_at loop
    accepted := '[]'::jsonb; skipped := '[]'::jsonb; errors := '{}'::jsonb; pending := false; last_date := null;
    for k in select jsonb_object_keys(run.http) loop
      select * into s from beau_ph.fx_sources where key = k;
      if jsonb_typeof(run.http -> k) <> 'number' then errors := errors || jsonb_build_object(k, run.http -> k ->> 'error'); continue; end if;
      req := (run.http ->> k)::bigint;
      select r.status_code, r.content, r.timed_out, r.error_msg into resp from net._http_response r where r.id = req;
      if resp is null or resp.status_code is null and resp.error_msg is null and not coalesce(resp.timed_out, false) then
        if run.requested_at > now() - interval '10 minutes' then pending := true; continue; end if;
        errors := errors || jsonb_build_object(k, 'no response within 10 minutes'); continue;
      end if;
      if coalesce(resp.timed_out, false) or resp.error_msg is not null or resp.status_code <> 200 then
        errors := errors || jsonb_build_object(k, coalesce(resp.error_msg, 'http ' || coalesce(resp.status_code::text, 'timeout'))); continue;
      end if;
      begin body := resp.content::jsonb; exception when others then errors := errors || jsonb_build_object(k, 'invalid json'); continue; end;
      if s.kind = 'frankfurter' then
        d := (body ->> 'date')::date;
        for c in select * from beau_ph.fx_currencies where enabled and source_key = s.key loop
          q := (body -> 'rates' ->> c.currency)::numeric;
          res := beau_ph.fx_ingest_rate(c.currency, q, d, s.key);
          if (res ->> 'accepted')::boolean then accepted := accepted || res; else skipped := skipped || res; end if;
        end loop;
        last_date := coalesce(greatest(last_date, d), d);
      elsif s.kind = 'nbg' then
        item := case when jsonb_typeof(body) = 'array' then body -> 0 else body end;
        d := left(item ->> 'date', 10)::date;
        select (x ->> 'rate')::numeric / nullif((x ->> 'quantity')::numeric, 0) into gel_per_eur from jsonb_array_elements(item -> 'currencies') x where x ->> 'code' = 'EUR';
        for c in select * from beau_ph.fx_currencies where enabled and source_key = s.key loop
          if c.currency = 'GEL' then q := gel_per_eur;
          else select gel_per_eur / nullif((x ->> 'rate')::numeric / nullif((x ->> 'quantity')::numeric, 0), 0) into q from jsonb_array_elements(item -> 'currencies') x where x ->> 'code' = c.currency;
          end if;
          res := beau_ph.fx_ingest_rate(c.currency, q, d, s.key);
          if (res ->> 'accepted')::boolean then accepted := accepted || res; else skipped := skipped || res; end if;
        end loop;
        last_date := coalesce(greatest(last_date, d), d);
      end if;
    end loop;
    if pending then continue; end if;
    -- pegs: derived from the peg currency's rate of the same day (never from a stale one)
    for c in select fc.* from beau_ph.fx_currencies fc join beau_ph.fx_sources fs on fs.key = fc.source_key where fc.enabled and fs.enabled and fs.kind = 'peg' loop
      select * into usd from beau_ph.fx_rate_on(c.peg_currency, current_date);
      if usd.rate is null or c.peg_rate is null or usd.rate_date < current_date - 7 then
        skipped := skipped || jsonb_build_object('currency', c.currency, 'accepted', false, 'reason', 'peg_base_missing');
      else
        res := beau_ph.fx_ingest_rate(c.currency, usd.rate * c.peg_rate, usd.rate_date, c.source_key || '(' || c.peg_currency || ')');
        if (res ->> 'accepted')::boolean then accepted := accepted || res; else skipped := skipped || res; end if;
      end if;
    end loop;
    update beau_ph.fx_refresh_runs set
      status = case when jsonb_array_length(accepted) = 0 then 'failed' when jsonb_array_length(skipped) > 0 or errors <> '{}'::jsonb then 'partial' else 'success' end,
      rate_date = last_date, currencies_updated = jsonb_array_length(accepted), currencies_skipped = jsonb_array_length(skipped),
      details = jsonb_build_object('accepted', accepted, 'skipped', skipped, 'source_errors', errors), finished_at = now()
     where id = run.id;
    summary := summary || jsonb_build_object('run', run.id, 'accepted', jsonb_array_length(accepted), 'skipped', jsonb_array_length(skipped), 'errors', errors);
  end loop;
  -- lifecycle of quotes (allowed by the guard)
  update beau_ph.fx_quotes set status = 'expired' where status = 'active' and expires_at < now();
  return summary;
end $$;

-- ---------- 4. quotes: server-side amount in another currency, immutable, expiring ----------
create or replace function beau_ph.fx_quote_json(q beau_ph.fx_quotes)
returns jsonb language sql stable set search_path = '' as $$
  select jsonb_build_object('id', q.id, 'same_currency', false, 'preview', false, 'pricing_amount', q.pricing_amount, 'pricing_currency', q.pricing_currency,
                            'payment_amount', q.payment_amount, 'payment_currency', q.payment_currency, 'reference_rate', round(q.reference_rate, 6),
                            'provider_rate', q.provider_rate, 'merchant_adjustment_bps', q.merchant_adjustment_bps, 'customer_rate', round(q.customer_rate, 6),
                            'rate_date', least(q.rate_date_from, q.rate_date_to), 'source', q.source_from || ' / ' || q.source_to, 'freshness', q.freshness, 'age_hours', q.age_hours,
                            'created_at', q.created_at, 'expires_at', q.expires_at,
                            'status', case when q.status = 'active' and q.expires_at < now() then 'expired' else q.status end, 'request_id', q.request_id)
$$;

create or replace function beau_ph.fx_quote(p_merchant_key text, p_pricing_amount int, p_pricing_currency text, p_payment_currency text, p_preview boolean default true)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare m beau_ph.merchants%rowtype; f beau_ph.merchant_fx%rowtype; rf record; rt record; age numeric; fresh text;
  pc text := upper(p_pricing_currency); yc text := upper(p_payment_currency); major numeric; amt int; ref numeric; cust numeric; q beau_ph.fx_quotes%rowtype;
begin
  select * into m from beau_ph.merchants where key = p_merchant_key;
  if not found then raise exception 'unknown merchant' using errcode = 'P0002'; end if;
  if p_pricing_amount is null or p_pricing_amount <= 0 then raise exception 'amount required' using errcode = '22023'; end if;
  if not beau_ph.is_iso_currency(pc) or not beau_ph.is_iso_currency(yc) then raise exception 'ISO currencies required' using errcode = '22023'; end if;
  if pc = yc then
    return jsonb_build_object('same_currency', true, 'pricing_amount', p_pricing_amount, 'pricing_currency', pc, 'payment_amount', p_pricing_amount, 'payment_currency', yc);
  end if;
  select * into f from beau_ph.merchant_fx where merchant_id = m.id;
  if not found or not f.enabled then raise exception 'fx_disabled: this merchant does not offer other payment currencies' using errcode = 'P0003'; end if;
  if not exists (select 1 from beau_ph.fx_currencies where currency = yc and enabled) and yc <> 'EUR' then
    raise exception 'fx_currency_disabled: % is not an enabled FX currency', yc using errcode = 'P0003';
  end if;
  select * into rf from beau_ph.fx_rate_on(pc, current_date);
  select * into rt from beau_ph.fx_rate_on(yc, current_date);
  if rf.rate is null or rt.rate is null then raise exception 'fx_rate_missing: no rate for % or %', pc, yc using errcode = 'P0003'; end if;
  age := round(extract(epoch from (now() - least(rf.fetched_at, rt.fetched_at))) / 3600, 2);
  fresh := beau_ph.fx_freshness(age);
  if fresh not in ('fresh','acceptable') or age > f.max_age_hours then
    raise exception 'fx_rate_stale: the reference rate is % hours old', age using errcode = 'P0003';
  end if;
  -- pivot through EUR (Maisons formula), then the merchant adjustment; one rounding, in the payment currency's minor unit
  major := p_pricing_amount::numeric / power(10, beau_ph.fx_currency_exponent(pc));
  ref := rt.rate / rf.rate;
  cust := ref * (1 + f.adjustment_bps::numeric / 10000);
  amt := round(major * cust * power(10, beau_ph.fx_currency_exponent(yc)))::int;
  if amt <= 0 then raise exception 'fx_amount_invalid' using errcode = 'P0003'; end if;
  if p_preview then
    return jsonb_build_object('same_currency', false, 'preview', true, 'pricing_amount', p_pricing_amount, 'pricing_currency', pc,
                              'payment_amount', amt, 'payment_currency', yc, 'reference_rate', round(ref, 6), 'customer_rate', round(cust, 6),
                              'merchant_adjustment_bps', f.adjustment_bps, 'rate_date', least(rf.rate_date, rt.rate_date), 'freshness', fresh, 'age_hours', age,
                              'source', rf.source || ' / ' || rt.source, 'quote_ttl_minutes', f.quote_ttl_minutes);
  end if;
  insert into beau_ph.fx_quotes (merchant_id, pricing_currency, pricing_amount, payment_currency, payment_amount, rate_from, rate_to, rate_date_from, rate_date_to,
                                 source_from, source_to, reference_rate, provider_rate, merchant_adjustment_bps, customer_rate, freshness, age_hours, expires_at)
  values (m.id, pc, p_pricing_amount, yc, amt, rf.rate, rt.rate, rf.rate_date, rt.rate_date, rf.source, rt.source, ref, null, f.adjustment_bps, cust, fresh, age,
          now() + make_interval(mins => f.quote_ttl_minutes))
  returning * into q;
  return beau_ph.fx_quote_json(q);
end $$;

-- Consumed by create_request: exactly one request, same merchant, not expired, amounts as quoted.
create or replace function beau_ph.fx_quote_consume(p_quote_id uuid, p_merchant_id uuid, p_request_id uuid, p_amount int, p_currency text, p_pricing_amount int, p_pricing_currency text)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare q beau_ph.fx_quotes%rowtype;
begin
  select * into q from beau_ph.fx_quotes where id = p_quote_id for update;
  if not found or q.merchant_id <> p_merchant_id then raise exception 'fx_quote_invalid' using errcode = 'P0003'; end if;
  if q.status <> 'active' then raise exception 'fx_quote_%', q.status using errcode = 'P0003'; end if;
  if q.expires_at < now() then
    update beau_ph.fx_quotes set status = 'expired' where id = q.id;
    raise exception 'fx_quote_expired: request a new quote' using errcode = 'P0003';
  end if;
  if q.payment_amount <> p_amount or q.payment_currency <> upper(p_currency) or q.pricing_amount <> p_pricing_amount or q.pricing_currency <> upper(p_pricing_currency) then
    raise exception 'fx_quote_mismatch: the request does not match the quote' using errcode = 'P0003';
  end if;
  update beau_ph.fx_quotes set status = 'consumed', request_id = p_request_id, consumed_at = now() where id = q.id returning * into q;
  return beau_ph.fx_quote_json(q);
end $$;

-- ---------- 5. merchant FX settings + platform currency configuration (audited) ----------
create or replace function beau_ph.merchant_fx_json(f beau_ph.merchant_fx)
returns jsonb language sql stable set search_path = '' as $$
  select jsonb_build_object('enabled', f.enabled, 'reporting_currency', f.reporting_currency, 'adjustment_bps', f.adjustment_bps,
                            'quote_ttl_minutes', f.quote_ttl_minutes, 'max_age_hours', f.max_age_hours, 'updated_by', f.updated_by, 'updated_at', f.updated_at)
$$;
create or replace function beau_ph.merchant_fx_set(p_merchant_key text, p jsonb, p_actor text)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare m beau_ph.merchants%rowtype; cur beau_ph.merchant_fx%rowtype; nxt beau_ph.merchant_fx%rowtype;
begin
  select * into m from beau_ph.merchants where key = p_merchant_key;
  if not found then raise exception 'unknown merchant' using errcode = 'P0002'; end if;
  select * into cur from beau_ph.merchant_fx where merchant_id = m.id;
  insert into beau_ph.merchant_fx (merchant_id, enabled, reporting_currency, adjustment_bps, quote_ttl_minutes, max_age_hours, updated_by)
  values (m.id, coalesce((p ->> 'enabled')::boolean, cur.enabled, false),
          coalesce(nullif(upper(p ->> 'reporting_currency'), ''), cur.reporting_currency, m.default_currency),
          coalesce((p ->> 'adjustment_bps')::int, cur.adjustment_bps, 0), coalesce((p ->> 'quote_ttl_minutes')::int, cur.quote_ttl_minutes, 15),
          coalesce((p ->> 'max_age_hours')::int, cur.max_age_hours, 72), p_actor)
  on conflict (merchant_id) do update set enabled = excluded.enabled, reporting_currency = excluded.reporting_currency, adjustment_bps = excluded.adjustment_bps,
    quote_ttl_minutes = excluded.quote_ttl_minutes, max_age_hours = excluded.max_age_hours, updated_by = excluded.updated_by, updated_at = now()
  returning * into nxt;
  perform beau_ph.audit_diff(m.id, 'merchant_fx', m.key, p_actor,
                             case when cur.merchant_id is null then '{}'::jsonb else beau_ph.merchant_fx_json(cur) - 'updated_at' - 'updated_by' end,
                             beau_ph.merchant_fx_json(nxt) - 'updated_at' - 'updated_by');
  return beau_ph.merchant_fx_json(nxt);
end $$;

create or replace function beau_ph.fx_currency_set(p_currency text, p jsonb, p_actor text)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare cur beau_ph.fx_currencies%rowtype; nxt beau_ph.fx_currencies%rowtype; c text := upper(p_currency); src beau_ph.fx_sources%rowtype;
begin
  if not beau_ph.is_iso_currency(c) or c = 'EUR' then raise exception 'ISO currency other than the EUR base required' using errcode = '22023'; end if;
  select * into cur from beau_ph.fx_currencies where currency = c;
  if p ? 'source_key' and p ->> 'source_key' is not null then
    select * into src from beau_ph.fx_sources where key = p ->> 'source_key';
    if not found then raise exception 'unknown source' using errcode = '22023'; end if;
    if src.kind = 'peg' and coalesce(nullif(upper(p ->> 'peg_currency'), ''), cur.peg_currency) is null then raise exception 'a peg needs peg_currency and peg_rate' using errcode = '22023'; end if;
  end if;
  insert into beau_ph.fx_currencies (currency, enabled, source_key, peg_currency, peg_rate, notes, updated_by)
  values (c, coalesce((p ->> 'enabled')::boolean, cur.enabled, false), case when p ? 'source_key' then p ->> 'source_key' else cur.source_key end,
          case when p ? 'peg_currency' then nullif(upper(p ->> 'peg_currency'), '') else cur.peg_currency end,
          case when p ? 'peg_rate' then (p ->> 'peg_rate')::numeric else cur.peg_rate end,
          case when p ? 'notes' then p ->> 'notes' else cur.notes end, p_actor)
  on conflict (currency) do update set enabled = excluded.enabled, source_key = excluded.source_key, peg_currency = excluded.peg_currency, peg_rate = excluded.peg_rate,
    notes = excluded.notes, updated_by = excluded.updated_by, updated_at = now()
  returning * into nxt;
  perform beau_ph.audit_diff(null, 'fx_currency', c, p_actor,
                             case when cur.currency is null then '{}'::jsonb else to_jsonb(cur) - 'updated_at' - 'updated_by' end, to_jsonb(nxt) - 'updated_at' - 'updated_by');
  return to_jsonb(nxt);
end $$;

-- platform-level audit rows (no merchant) are listed alongside the merchant's
create or replace function beau_ph.config_audit_list(p_merchant_key text, p_limit int default 100)
returns jsonb language sql stable security definer set search_path = '' as $$
  select coalesce(jsonb_agg(jsonb_build_object('area', a.area, 'entity', a.entity, 'actor', a.actor, 'changed_at', a.changed_at, 'field', a.field,
                                               'old_value', a.old_value, 'new_value', a.new_value) order by a.changed_at desc), '[]'::jsonb)
    from (select ca.* from beau_ph.config_audit ca left join beau_ph.merchants m on m.id = ca.merchant_id
           where ca.merchant_id is null or m.key = p_merchant_key
           order by ca.changed_at desc limit greatest(1, least(coalesce(p_limit, 100), 500))) a
$$;

-- ---------- 6. the FX workspace ----------
create or replace function beau_ph.fx_overview(p_merchant_key text)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare m beau_ph.merchants%rowtype; f beau_ph.merchant_fx%rowtype; ccy_rows jsonb; last_run beau_ph.fx_refresh_runs%rowtype;
begin
  select * into m from beau_ph.merchants where key = p_merchant_key;
  if not found then raise exception 'unknown merchant' using errcode = 'P0002'; end if;
  select * into f from beau_ph.merchant_fx where merchant_id = m.id;
  select * into last_run from beau_ph.fx_refresh_runs where status <> 'requested' order by requested_at desc limit 1;
  ccy_rows := (select coalesce(jsonb_agg(beau_ph.fx_currency_status(c.currency) order by (not c.enabled), c.currency), '[]'::jsonb) from beau_ph.fx_currencies c);
  return jsonb_build_object(
    'base_currency', 'EUR',
    'settings', case when f.merchant_id is null then null else beau_ph.merchant_fx_json(f) end,
    'health', jsonb_build_object(
      'last_refresh_at', last_run.finished_at, 'last_refresh_status', last_run.status, 'last_rate_date', last_run.rate_date,
      'in_progress', exists (select 1 from beau_ph.fx_refresh_runs where status = 'requested'),
      'fresh',      (select count(*) from jsonb_array_elements(ccy_rows) r where (r ->> 'enabled')::boolean and r ->> 'freshness' = 'fresh'),
      'acceptable', (select count(*) from jsonb_array_elements(ccy_rows) r where (r ->> 'enabled')::boolean and r ->> 'freshness' = 'acceptable'),
      'stale',      (select count(*) from jsonb_array_elements(ccy_rows) r where (r ->> 'enabled')::boolean and r ->> 'freshness' = 'stale'),
      'missing',    (select count(*) from jsonb_array_elements(ccy_rows) r where (r ->> 'enabled')::boolean and r ->> 'freshness' = 'missing'),
      'rejected',   coalesce(last_run.details -> 'skipped', '[]'::jsonb), 'source_errors', coalesce(last_run.details -> 'source_errors', '{}'::jsonb)),
    'currencies', ccy_rows,
    'sources', (select coalesce(jsonb_agg(to_jsonb(s) order by s.sort), '[]'::jsonb) from beau_ph.fx_sources s),
    'runs', (select coalesce(jsonb_agg(jsonb_build_object('id', r.id, 'requested_at', r.requested_at, 'requested_by', r.requested_by, 'status', r.status, 'rate_date', r.rate_date,
                                                          'currencies_updated', r.currencies_updated, 'currencies_skipped', r.currencies_skipped, 'finished_at', r.finished_at,
                                                          'source_errors', r.details -> 'source_errors', 'skipped', r.details -> 'skipped') order by r.requested_at desc), '[]'::jsonb)
               from (select * from beau_ph.fx_refresh_runs order by requested_at desc limit 8) r),
    'quotes', jsonb_build_object(
      'active',       (select count(*) from beau_ph.fx_quotes q where q.merchant_id = m.id and q.status = 'active' and q.expires_at >= now()),
      'consumed_30d', (select count(*) from beau_ph.fx_quotes q where q.merchant_id = m.id and q.status = 'consumed' and q.consumed_at > now() - interval '30 days')));
end $$;

-- ---------- 7. schedule: daily refresh after the ECB publication; minute collector (cheap: indexed no-op when idle) ----------
do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') and exists (select 1 from pg_extension where extname = 'pg_net') then
    begin perform cron.unschedule('beau-ph-fx-refresh'); exception when others then null; end;
    begin perform cron.unschedule('beau-ph-fx-collect'); exception when others then null; end;
    perform cron.schedule('beau-ph-fx-refresh', '5 6 * * *', $cron$select beau_ph.fx_refresh_start('cron')$cron$);
    perform cron.schedule('beau-ph-fx-collect', '* * * * *', $cron$select beau_ph.fx_refresh_collect()$cron$);
  end if;
end $$;

-- ---------- 8. grants ----------
revoke all on function beau_ph.fx_quotes_guard(), beau_ph.fx_currency_exponent(text), beau_ph.fx_rate_on(text, date), beau_ph.fx_freshness(numeric),
  beau_ph.fx_validate_rate(numeric, numeric), beau_ph.fx_ingest_rate(text, numeric, date, text), beau_ph.fx_currency_status(text), beau_ph.fx_refresh_start(text),
  beau_ph.fx_refresh_collect(), beau_ph.fx_quote(text, int, text, text, boolean), beau_ph.fx_quote_json(beau_ph.fx_quotes),
  beau_ph.fx_quote_consume(uuid, uuid, uuid, int, text, int, text), beau_ph.merchant_fx_json(beau_ph.merchant_fx), beau_ph.merchant_fx_set(text, jsonb, text),
  beau_ph.fx_currency_set(text, jsonb, text), beau_ph.config_audit_list(text, int), beau_ph.fx_overview(text)
  from public, anon, authenticated;
grant execute on function beau_ph.fx_currency_exponent(text), beau_ph.fx_rate_on(text, date), beau_ph.fx_freshness(numeric),
  beau_ph.fx_validate_rate(numeric, numeric), beau_ph.fx_ingest_rate(text, numeric, date, text), beau_ph.fx_currency_status(text), beau_ph.fx_refresh_start(text),
  beau_ph.fx_refresh_collect(), beau_ph.fx_quote(text, int, text, text, boolean), beau_ph.fx_quote_json(beau_ph.fx_quotes),
  beau_ph.fx_quote_consume(uuid, uuid, uuid, int, text, int, text), beau_ph.merchant_fx_json(beau_ph.merchant_fx), beau_ph.merchant_fx_set(text, jsonb, text),
  beau_ph.fx_currency_set(text, jsonb, text), beau_ph.config_audit_list(text, int), beau_ph.fx_overview(text)
  to service_role;

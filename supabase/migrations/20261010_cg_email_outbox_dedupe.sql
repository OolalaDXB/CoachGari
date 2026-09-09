-- =====================================================================
-- Coach Gari — email outbox: the dedupe key is the only uniqueness rule
--
-- The original outbox (20260904) enforced unique (order_id, kind). Since
-- 20261009 every row carries a dedupe_key that already encodes the order
-- for the per-order kinds, and a booking can legitimately carry several
-- `reschedule` rows for the same order (one per actual time change), which
-- the old constraint silently swallowed. Forward migration only.
-- =====================================================================
alter table public.email_events drop constraint if exists email_events_order_id_kind_key;
create index if not exists email_events_order_kind_idx on public.email_events (order_id, kind) where order_id is not null;

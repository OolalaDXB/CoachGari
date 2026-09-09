-- =====================================================================
-- BEAU PH — covering indexes for the foreign keys introduced by the rails
-- configuration and FX migrations (performance advisor, additive only)
-- =====================================================================
create index if not exists merchant_methods_provider_idx    on beau_ph.merchant_methods (provider_key);
create index if not exists method_settlements_destination_idx on beau_ph.method_settlements (destination_id);
create index if not exists fx_currencies_source_idx         on beau_ph.fx_currencies (source_key);
create index if not exists provider_events_request_idx      on beau_ph.provider_events (request_id);
create index if not exists reconciliations_request_idx      on beau_ph.reconciliations (request_id);
create index if not exists reconciliations_merchant_idx     on beau_ph.reconciliations (merchant_id);

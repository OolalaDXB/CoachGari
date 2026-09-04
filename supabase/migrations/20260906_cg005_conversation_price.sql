-- CG-005 — approved Route C catalogue price: The Conversation, 60 min, 100 USD.
-- The database is the only source of the price: bookings snapshot it at hold
-- time, orders take it from the snapshot, Stripe Checkout is created with the
-- order's amount, and the webhook refuses any other amount_total.
update public.services
   set price_amount = 10000, currency = 'USD', duration_minutes = 60, updated_at = now()
 where slug = 'conversation';

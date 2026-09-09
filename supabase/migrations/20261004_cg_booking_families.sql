-- =====================================================================
-- Coach Gari — canonical services behind the public booking picker
--
-- The picker offers three families: The Conversation · Personal training ·
-- Padel (one-to-one / group session). Only The Conversation existed as a
-- bookable service. The three canonical records below make the other
-- choices bookable through the SAME engine (available_slots / create_hold):
--   * active, slot-bookable, UNLISTED — they are booking-picker entries,
--     not marketing cards (the page's Padel surface stays an enquiry);
--   * priced ON REQUEST (price_amount null): no price is invented here; a
--     hold on them takes the existing "request this time" path until the
--     owner sets a price in Services. Duration 60 min, capacity 1, Dubai.
-- Availability: the placeholder rules apply to every active service
-- (service_ids null); Gari scopes real hours per service in Schedule.
-- Forward migration only; audited like a catalogue create.
-- =====================================================================
insert into public.services (slug, title, category, description, duration_minutes, price_amount, currency, delivery_mode, default_capacity, booking_mode, active, listed, sort_order, updated_by)
values
  ('personal-training-dubai', 'Personal training in Dubai', 'onsite',
   'Sixty minutes of personal training, in person in Dubai.',
   60, null, 'USD', 'onsite', 1, 'slot', true, false, 40, 'migration:20261004'),
  ('padel-one-to-one', 'Padel one-to-one', 'onsite',
   'Sixty minutes on court, one-to-one, in Dubai.',
   60, null, 'USD', 'onsite', 1, 'slot', true, false, 41, 'migration:20261004'),
  ('padel-group-session', 'Padel group session', 'onsite',
   'A padel group session on court in Dubai.',
   60, null, 'USD', 'onsite', 1, 'slot', true, false, 42, 'migration:20261004')
on conflict (slug) do nothing;

insert into public.catalog_audit (service_id, slug, action, changed_by, changed_fields, before, after)
select s.id, s.slug, 'create', 'migration:20261004',
       array['slug','title','category','description','duration_minutes','price_amount','currency','delivery_mode','default_capacity','booking_mode','active','listed','sort_order'],
       null,
       jsonb_build_object('slug', s.slug, 'title', s.title, 'category', s.category, 'description', s.description, 'duration_minutes', s.duration_minutes,
                          'price_amount', s.price_amount, 'currency', s.currency, 'delivery_mode', s.delivery_mode, 'default_capacity', s.default_capacity,
                          'booking_mode', s.booking_mode, 'active', s.active, 'listed', s.listed, 'sort_order', s.sort_order)
  from public.services s
 where s.slug in ('personal-training-dubai', 'padel-one-to-one', 'padel-group-session')
   and not exists (select 1 from public.catalog_audit a where a.slug = s.slug and a.action = 'create');

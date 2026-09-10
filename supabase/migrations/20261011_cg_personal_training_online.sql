-- =====================================================================
-- Coach Gari — Personal training, online option
--
-- Personal training existed only as an in-person Dubai service
-- (personal-training-dubai, delivery_mode 'onsite'), so the public
-- booking picker offered no online / in-person choice. delivery_mode is
-- fixed per service row (online XOR onsite), so an online option needs its
-- own canonical service. This adds it, through the SAME booking engine
-- (available_slots / create_hold) as every other picker entry:
--   * active, slot-bookable, UNLISTED (a picker entry, not a marketing card);
--   * priced ON REQUEST (price_amount null) — no price is invented here; a
--     hold takes the existing "request this time" path until the owner sets a
--     price in Services. Duration 60 min, capacity 1, delivery online.
-- The picker (assets/booking.js) turns the "Personal training" family into
-- an In person / Online choice, exactly like Padel's two children.
-- Availability: the placeholder rules apply to every active service
-- (service_ids null); Gari scopes real hours per service in Schedule.
-- Forward migration only; audited like a catalogue create.
-- =====================================================================
insert into public.services (slug, title, category, description, duration_minutes, price_amount, currency, delivery_mode, default_capacity, booking_mode, active, listed, sort_order, updated_by)
values
  ('personal-training-online', 'Personal training online', 'coaching',
   'Sixty minutes of personal training, online, wherever you are.',
   60, null, 'USD', 'online', 1, 'slot', true, false, 39, 'migration:20261011')
on conflict (slug) do nothing;

insert into public.catalog_audit (service_id, slug, action, changed_by, changed_fields, before, after)
select s.id, s.slug, 'create', 'migration:20261011',
       array['slug','title','category','description','duration_minutes','price_amount','currency','delivery_mode','default_capacity','booking_mode','active','listed','sort_order'],
       null,
       jsonb_build_object('slug', s.slug, 'title', s.title, 'category', s.category, 'description', s.description, 'duration_minutes', s.duration_minutes,
                          'price_amount', s.price_amount, 'currency', s.currency, 'delivery_mode', s.delivery_mode, 'default_capacity', s.default_capacity,
                          'booking_mode', s.booking_mode, 'active', s.active, 'listed', s.listed, 'sort_order', s.sort_order)
  from public.services s
 where s.slug = 'personal-training-online'
   and not exists (select 1 from public.catalog_audit a where a.slug = s.slug and a.action = 'create');

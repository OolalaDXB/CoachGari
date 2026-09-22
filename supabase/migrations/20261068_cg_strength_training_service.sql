-- =====================================================================
-- A Strength Training line, priced by the client rather than by itself.
--
-- CG-040 settled where a session's price comes from: the package it
-- belongs to, or failing that the client's own rate. A session never
-- carries a price of its own. This service follows that rule by leaving
-- price_amount NULL — which in this table means "on request", i.e. not
-- payable online, which is exactly right: the amount lives in
-- client_rates and is decided per person.
--
-- listed = false: it does not belong on the public catalogue, which is
-- deliberately four cards. active = true so it can be chosen when
-- creating a session in the back-office.
--
-- delivery_mode is 'onsite' because a session priced from the client's
-- own rate is the in-person Dubai case; online coaching is already sold
-- as a monthly subscription. The session itself still carries its own
-- delivery_mode, so a one-off online session is unaffected — this field
-- only describes the default.
-- =====================================================================

insert into public.services
  (slug, title, category, description, duration_minutes, price_amount, currency,
   price_unit, delivery_mode, default_capacity, booking_mode, active, listed, sort_order)
values
  ('strength-training', 'Strength Training', 'onsite',
   'Strength work shaped to the person: loading, progression and technique. Priced by the client rate.',
   60, null, 'USD', 'per session', 'onsite', 1, 'slot', true, false, 43)
on conflict (slug) do update
  set title = excluded.title,
      category = excluded.category,
      description = excluded.description,
      price_amount = excluded.price_amount,
      delivery_mode = excluded.delivery_mode,
      booking_mode = excluded.booking_mode,
      active = excluded.active,
      listed = excluded.listed;

-- The pack whose title named a count it could not guarantee. "10-session coaching pack"
-- was the default in the New package form, sitting next to a Total sessions field that
-- could say anything — so a pack of six could be created carrying the word ten, and that
-- title is the snapshot printed on the client's receipt and report. Renamed here and in
-- the form's default; a neutral title cannot contradict the count beside it.
update public.session_packs
   set title = 'Training Session package'
 where title = '10-session coaching pack';

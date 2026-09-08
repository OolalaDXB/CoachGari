-- =============================================================
-- Editorial cleanup of the public catalogue copy (2026-09-08)
-- Sentence-case programme titles and no em dashes in the card copy.
-- Text only: no slug, price, duration, capacity, mode or ordering changes.
-- Product names "The Programme" and "The Conversation" are kept as branded.
-- =============================================================
update public.services set title = 'Online coaching', updated_at = now()
 where slug = 'online-coaching' and title = 'Online Coaching';

update public.services set title = 'Live group sessions',
       description = 'Train live with me and everyone else, twice a week. Camera on or off. Nobody''s watching but me.',
       updated_at = now()
 where slug = 'live-group' and title = 'Live Group Sessions';

update public.services
   set description = 'An hour to talk it through: what you''re stuck on, why the last three attempts stopped, what you actually want.',
       updated_at = now()
 where slug = 'conversation' and description like 'An hour to talk it through — %';

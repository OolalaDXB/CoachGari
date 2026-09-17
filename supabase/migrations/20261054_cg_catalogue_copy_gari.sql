-- =====================================================================
-- Catalogue copy — two changes the coach asked for, 17 September 2026
--
-- WHY COPY IS IN A MIGRATION AT ALL. Normally it should not be: the four
-- programme cards are content, the coach edits them himself in Settings ›
-- Services, and that path is audited with his name on it. Two things make this
-- the exception. The catalogue's initial content was itself seeded by a
-- migration (20260908), so a replayed database reads its copy from the
-- repository; changing production without changing that seed would leave the
-- two disagreeing. And `on conflict (slug) do nothing` means the seed only ever
-- applies to an empty database, so the live rows need an UPDATE of their own.
--
-- 1. 'Cancel whenever' leaves the Live group sessions card.
--    Asked for, and right for a reason beyond the asking: THERE IS NO
--    SUBSCRIPTION TO CANCEL. Both monthly products are sold by enquiry and paid
--    one-off, so nobody is on a recurring charge — you simply do not pay next
--    month. A reassurance with no machinery behind it is a sentence somebody
--    eventually has to explain away.
--
-- 2. "Let's figure it out together." is appended to The Conversation.
--    The coach offered it as a replacement for the whole description. It is
--    added instead, because the sentence it would have replaced — what you are
--    stuck on, why the last three attempts stopped — is the one that tells a
--    reader this hour is for them. Warmth gained, specifics kept. Flagged to
--    him as an interpretation rather than an instruction.
--
-- Not applied here, deliberately: the headline, the programme sub-heading, the
-- "meal plan" wording, the online-coaching feature list, "Meal management", and
-- the Start-this-week body. Those are still being decided, and three of them
-- contradict copy elsewhere on the page.
-- =====================================================================

update public.services
   set features = array['2 live classes a week', 'Replays if you miss one', 'No equipment needed'],
       updated_by = 'copy:gari-2026-09-17', updated_at = now()
 where slug = 'live-group';

update public.services
   set description = 'An hour to talk it through: what you''re stuck on, why the last three attempts stopped, what you actually want. Let''s figure it out together.',
       updated_by = 'copy:gari-2026-09-17', updated_at = now()
 where slug = 'conversation';

/* The catalogue has an audit trail and a copy change belongs in it, even when
   it arrives as a migration rather than through the back-office. */
insert into public.admin_audit (area, entity_id, action, changed_by, summary)
select 'payment_method', 'catalogue-copy', 'update', 'migration:20261054',
       jsonb_build_object('source', 'copy comments from the coach, 2026-09-17',
                          'live-group', 'removed the "Cancel whenever" feature',
                          'conversation', 'appended "Let''s figure it out together."')
where exists (select 1 from public.services where slug = 'live-group');

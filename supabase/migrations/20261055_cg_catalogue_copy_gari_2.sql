-- =====================================================================
-- Catalogue copy — the coach's second pass, 18 September 2026
--
-- He came back with every before/after spelled out, which answered the three
-- questions the first pass left open and settled the two I had argued against.
-- Same reasoning as 20261054 for why copy is in a migration at all: the
-- catalogue was seeded by one, so production and a replayed database have to
-- keep saying the same thing.
--
-- WHAT HE SETTLED, and it is worth recording because it changed my objections:
--
--   * The online-coaching features are REPLACED, not reduced. The two live
--     sessions a month and the WhatsApp check-ins stay; only the two plan lines
--     change wording. My worry that the concrete differentiators would be lost
--     was unfounded.
--   * "No meal plan full of things you can't buy" leaves the page in the same
--     pass that brings "meal plan" onto this card, so the contradiction I
--     flagged is resolved by deletion rather than left standing.
--   * The headline is NOT in his list. "Train with me from anywhere" stays.
--
-- ONE THING STILL OVER-PROMISES, recorded rather than silently fixed:
-- "Own your personal twelve-week meal plan" sits on a self-guided video product
-- that is identical for every buyer. "Personal" is his word and his call; it is
-- also the kind of word that produces a refund request from someone who
-- expected something written for them.
--
-- Two spellings changed against his text, both to stop a card contradicting
-- itself: "program" → "programme" (the card is titled "The Programme") and
-- "twelve week" → "twelve-week" (its own feature list says "12-week training
-- plan"). Both flagged to him; both trivially reversible.
-- =====================================================================

update public.services
   set description = 'Own your personal twelve-week meal plan and training programme.',
       updated_by = 'copy:gari-2026-09-18', updated_at = now()
 where slug = 'programme-12w';

/* Positions 1 and 4 are untouched on purpose: the live sessions and the
   between-session check-ins are what a video course cannot copy. */
update public.services
   set features = array['2 live video sessions a month', 'Monthly training plan review',
                        'Monthly meal plan review', 'WhatsApp check-ins between'],
       updated_by = 'copy:gari-2026-09-18', updated_at = now()
 where slug = 'online-coaching';

update public.services
   set description = 'Let''s train as a group and push each other to be the best versions of ourselves.',
       updated_by = 'copy:gari-2026-09-18', updated_at = now()
 where slug = 'live-group';

update public.services
   set description = 'Book a one-on-one conversation with me and let''s figure it out together.',
       updated_by = 'copy:gari-2026-09-18', updated_at = now()
 where slug = 'conversation';

insert into public.admin_audit (area, entity_id, action, changed_by, summary)
select 'payment_method', 'catalogue-copy', 'update', 'migration:20261055',
       jsonb_build_object('source', 'copy comments from the coach, 2026-09-18',
                          'cards', jsonb_build_array('programme-12w', 'online-coaching', 'live-group', 'conversation'))
where exists (select 1 from public.services where slug = 'programme-12w');

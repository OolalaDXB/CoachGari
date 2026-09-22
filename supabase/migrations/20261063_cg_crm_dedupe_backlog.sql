-- =====================================================================
-- One record per client: clear the duplicate backlog before going live.
--
-- 20261059 stopped the matcher breeding new duplicates and 20261061 put
-- the phone numbers into one shape, which made two more pairs comparable.
-- Neither cleaned up what was already there: 43 of 67 records were flagged,
-- in 18 groups, almost all of them the same import run recorded twice —
-- same name, same number, timestamps seconds apart.
--
-- MERGE, NOT DELETE. Most of these pairs look empty on both sides, but
-- "looks empty" is not a thing to bet a client's history on: AMAN's four
-- records carry two coaching sessions on the *newest* of them, and Sami's
-- pair the same. crm_merge_contacts moves sessions, packs, bookings,
-- subscriptions, notes, measurements, consents and tokens across and then
-- deletes the emptied row, so the outcome is one record either way and
-- nothing can be lost by guessing wrong about which copy mattered.
--
-- Into the OLDEST of each group, one pair at a time, repeating until
-- nothing shares an email or a phone. Merging is transitive, so the groups
-- of three (Walid) and four (AMAN) converge without special handling.
--
-- TWO PLACES THE GENERIC RULE IS WRONG, AND BOTH ARE IN ONE GROUP.
-- Four records share mickael.thomas@pm.me:
--
--   * DARYA THOMAS is a different person. She used that address on the
--     collaboration form, and she carries her own deal. Merging her into
--     Mickael on the strength of a shared mailbox would destroy a real
--     distinction, so she is excluded and her flag is cleared instead.
--     Sharing an address with a partner is not being the same person.
--   * The record to keep is not the oldest. "MICKAEL THOMAS", from the
--     Paris enquiry, is older; the live one is the active Dubai record
--     with the session, the pack and the phone. So that group is merged by
--     hand, into the right target.
--
-- Veronica's pair first: both rows read `05o6548633`, a letter o where a
-- zero belongs. 20261061 left it alone deliberately rather than invent a
-- number — the owner has since confirmed it is a typo, so it becomes
-- 0506548633, a 050 mobile, and the pair then merges like the rest.
--
-- Written to be safely re-runnable and to do nothing at all on a database
-- that has no contacts in it, which is how CI replays it.
-- =====================================================================

do $$
declare
  v_darya uuid := '7a9d3168-8e9d-4310-b0b3-3d834b11b84d';  -- shares the address, is NOT Mickael
  v_mick  uuid := '7e0fc59e-6d91-4122-a8e6-53ea777dd543';  -- the live record: active, session, pack, phone
  v_src uuid; v_tgt uuid; merged int := 0; guard int := 0;
begin
  -- act as the owner who asked for this, so the merge audit names a real person
  perform set_config('request.jwt.claims',
    '{"role":"authenticated","email":"mickael@thestudio.mt"}', true);

  -- the typo, now confirmed: 05o6548633 -> 0506548633. The display trigger
  -- turns phone_norm back into the readable +971 form.
  update public.crm_contacts set phone_norm = '971506548633' where phone = '05o6548633';

  -- Mickael's own group, by hand and only if it is still there
  if exists (select 1 from public.crm_contacts where id = v_mick) then
    if exists (select 1 from public.crm_contacts where id = '0e012c2c-376b-49d1-a687-12fe835d49cb') then
      perform public.crm_merge_contacts('0e012c2c-376b-49d1-a687-12fe835d49cb', v_mick);
    end if;
    if exists (select 1 from public.crm_contacts where id = '22ef5b79-578b-4735-a1d8-18c55ff9dc06') then
      perform public.crm_merge_contacts('22ef5b79-578b-4735-a1d8-18c55ff9dc06', v_mick);
    end if;
  end if;

  -- everything else: the newer of any matching pair folds into the older
  loop
    guard := guard + 1; exit when guard > 500;      -- a loop that edits its own input gets a stop
    v_src := null;
    select c.id, t.id into v_src, v_tgt
      from public.crm_contacts c
      join public.crm_contacts t
        on t.id <> c.id
       and ((t.email_norm is not null and t.email_norm = c.email_norm)
         or (t.phone_norm is not null and t.phone_norm = c.phone_norm))
       and (t.first_seen_at, t.id) < (c.first_seen_at, c.id)
     where c.id <> v_darya and t.id <> v_darya
     order by t.first_seen_at, t.id, c.first_seen_at, c.id
     limit 1;
    exit when v_src is null;
    perform public.crm_merge_contacts(v_src, v_tgt);
    merged := merged + 1;
  end loop;

  -- two people who share a mailbox are not a duplicate; stop asking about them
  update public.crm_contacts set needs_review = false where id in (v_darya, v_mick);

  raise notice 'crm dedupe: % pairs merged', merged;
end $$;

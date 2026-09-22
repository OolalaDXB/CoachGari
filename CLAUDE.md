# Working rules for this repository

## Apply database changes without asking

The owner has given standing permission to run SQL against the Supabase project
(`acrjrlgeeyseyolmofuq`) — queries and migrations alike — without stopping to
ask each time. Apply it, then say plainly what changed.

The safety net is rehearsal, not permission. Before anything touches production
data, write it as a migration in `supabase/migrations/`, replay it with
`scripts/db-ci.sh` (every migration into an empty Postgres, then the suites in
`supabase/tests/`), and where it rewrites or deletes existing rows, run it
against a fixture shaped like the real data first and check the outcome. A
migration carrying a data fix must also be safe to replay into an empty
database — guard it so it does nothing there.

Two things still stop and ask, because no rehearsal can undo them: destroying
payment or order records, and anything that would send mail, WhatsApp messages
or push notifications to real clients.

After applying, report the before/after counts rather than asserting success.

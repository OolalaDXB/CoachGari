# Working rules for this repository

## Ask before running SQL against the database

Do not run SQL on the Supabase project (`acrjrlgeeyseyolmofuq`) — neither
queries nor migrations — without asking the owner first. Show the SQL, say what
it will read or change, and wait for a yes.

This covers `execute_sql`, `apply_migration`, and anything equivalent. It is not
a review of the idea, it is a review of the statement: paste it in full, not a
summary of it.

Writing a migration file into `supabase/migrations/` and testing it locally
against a throwaway Postgres (`scripts/db-ci.sh`) needs no permission — that
touches no real data. Applying it does.

## How the database is tested

`scripts/db-ci.sh` replays every migration into an empty database and then runs
the suites in `supabase/tests/`. A migration that carries a data fix must be
safe to replay into an empty database — guard it so it does nothing there.

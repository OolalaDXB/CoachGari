#!/usr/bin/env bash
# Builds the whole schema from scratch into a throwaway Postgres and runs the
# database suites against it.
#
#   DATABASE_URL=postgresql://postgres:postgres@localhost:5432/postgres scripts/db-ci.sh
#
# The database is left in whatever state the migrations produced — it is
# expected to be a container that dies with the job. Never point this at
# anything you care about: it applies eighty migrations to it.
#
# Order matters and is the whole point: supabase/tests/_harness.sql first (the
# Supabase-provided surface: roles, auth, vault, net, storage, pgcrypto), then
# every migration in filename order, then scripts/db-tests.sh.
#
# A migration that fails stops the run. That is deliberate: a schema that
# cannot be rebuilt from its own migrations is a real defect, and the suites
# passing on a half-applied schema would hide it.
#
# LC_ALL=C is not cosmetic. The order of application is the filenames' byte
# order, and a locale that ignores punctuation would silently reorder
# 20260905b_… against 20260905_…, which is exactly the pair whose order matters.
set -u
export LC_ALL=C
: "${DATABASE_URL:?set DATABASE_URL (a throwaway Postgres, not production)}"
cd "$(dirname "$0")/.."

psql_q() { psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -X -q "$@"; }

echo "── harness"
if ! out=$(psql_q -f supabase/tests/_harness.sql 2>&1); then
  printf '%s\n' "$out"; echo "FAIL  harness"; exit 1
fi

echo "── migrations"
count=0
for f in supabase/migrations/*.sql; do
  if ! out=$(psql_q -f "$f" 2>&1); then
    printf '%s\n' "$out" | tail -25
    echo "FAIL  $f"
    exit 1
  fi
  count=$((count + 1))
done
echo "      $count migrations applied"

echo "── suites"
exec bash scripts/db-tests.sh

#!/usr/bin/env bash
# Runs the database suites (booking, payments, permissions/RLS) against a
# Postgres connection string and fails unless every suite reports fail=0.
# Each suite is a single transaction that ends with RAISE EXCEPTION, so
# nothing is ever persisted — safe against the live project.
#   DATABASE_URL=postgresql://... scripts/db-tests.sh
set -u
: "${DATABASE_URL:?set DATABASE_URL (Supabase → Connect → session pooler URI)}"
cd "$(dirname "$0")/.."
status=0
for f in supabase/tests/cg002_booking.sql supabase/tests/cg003_payments.sql supabase/tests/cg0025_permissions.sql; do
  out=$(psql "$DATABASE_URL" -v ON_ERROR_STOP=0 -q -f "$f" 2>&1)
  line=$(printf '%s\n' "$out" | grep -oE '[A-Z0-9_]+_TESTS ok=[0-9]+ fail=[0-9]+.*' | head -1)
  if [[ -n "$line" && "$line" == *" fail=0"* ]]; then
    echo "PASS  $f — $line"
  else
    echo "FAIL  $f"; printf '%s\n' "$out" | tail -20; status=1
  fi
done
exit $status

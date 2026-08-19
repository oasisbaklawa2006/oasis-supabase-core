#!/usr/bin/env bash
# Regression test: step1-staging-certification.yml must be permanently
# incapable of touching production, even if someone manually dispatches it.
# This asserts the structural properties that guarantee that, so a future
# edit that re-adds a live step cannot silently reintroduce the 2026-08-16/17
# incident's write path.
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

WORKFLOW='.github/workflows/step1-staging-certification.yml'
fail() { echo "STEP1-FAILS-CLOSED REGRESSION FAILED: $*" >&2; exit 1; }

[[ -f "$WORKFLOW" ]] || fail "$WORKFLOW is missing"

# 1. No job in the workflow may reference production write credentials.
if grep -qE 'secrets\.(SUPABASE_DB_URL|SUPABASE_ACCESS_TOKEN)' "$WORKFLOW"; then
  fail "$WORKFLOW references production credentials; it must never receive them"
fi

# 2. No job may declare a protected production environment.
if grep -qE '^[[:space:]]*environment:[[:space:]]*supabase-production' "$WORKFLOW"; then
  fail "$WORKFLOW declares a supabase-production(-readonly) environment"
fi

# 3. No step (i.e. within the actual jobs: block, not the header comment
#    that documents the historical incident in prose) may invoke psql, the
#    Supabase CLI's migration/db commands, or the certification runner.
jobs_block="$(awk '/^jobs:/{flag=1} flag{print}' "$WORKFLOW")"
if grep -qE 'psql|supabase (db push|migration (up|repair))|step1-certification/run\.mjs' <<< "$jobs_block"; then
  fail "$WORKFLOW's jobs block still invokes a schema-write-capable command"
fi

# 4. The only job present must unconditionally fail, regardless of dispatch
#    inputs -- i.e. there is no 'if:' condition gating the failure, so a
#    manual dispatch always hits it.
if grep -qE '^[[:space:]]*if:' "$WORKFLOW"; then
  fail "$WORKFLOW's retirement job is conditional; it must fail unconditionally on every dispatch"
fi

if ! grep -qE '^[[:space:]]*exit 1[[:space:]]*$' "$WORKFLOW"; then
  fail "$WORKFLOW's retirement job does not exit non-zero"
fi

# 5. scripts/step1-certification/run.mjs (the historical write-capable
#    runner, even though nothing calls it) must itself be neutralized.
RUNNER='scripts/step1-certification/run.mjs'
if [[ -f "$RUNNER" ]]; then
  if ! grep -qE "^throw new Error" "$RUNNER"; then
    fail "$RUNNER no longer throws unconditionally at module load; its psql-write capability may be reachable again"
  fi
  if grep -qE "(execFileSync|execFile|spawnSync|spawn|execSync|exec)\\([[:space:]]*['\"]psql['\"]" "$RUNNER"; then
    fail "$RUNNER still contains a live programmatic psql invocation"
  fi
fi

echo "OK: step1-staging-certification.yml is structurally incapable of a production write, even under manual dispatch."

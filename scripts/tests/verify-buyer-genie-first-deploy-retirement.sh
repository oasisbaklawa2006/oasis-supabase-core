#!/usr/bin/env bash
# Regression test: buyer-genie-production-first-deploy.yml must remain
# permanently incapable of a production write or a broad/indirect Edge
# Function deploy, even if someone manually dispatches it. ai-order-parse
# is already ACTIVE in production (independently verified 2026-10-09 via
# the Supabase Management API), so this workflow's own
# absent-before-first-deploy precondition can never be satisfied again --
# this test guards against a future edit silently reviving its
# supabase-functions-deploy step instead of building a new, separately
# reviewed workflow for any genuine future redeploy need.
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

WORKFLOW='.github/workflows/buyer-genie-production-first-deploy.yml'
fail() { echo "GENIE-FIRST-DEPLOY-RETIREMENT REGRESSION FAILED: $*" >&2; exit 1; }

[[ -f "$WORKFLOW" ]] || fail "$WORKFLOW is missing"

# 1. No job in the workflow may reference production write credentials.
if grep -qE 'secrets\.(SUPABASE_DB_URL|SUPABASE_ACCESS_TOKEN)' "$WORKFLOW"; then
  fail "$WORKFLOW references production credentials; it must never receive them"
fi

# 2. No job may declare a protected production environment.
if grep -qE '^[[:space:]]*environment:[[:space:]]*supabase-production' "$WORKFLOW"; then
  fail "$WORKFLOW declares a supabase-production(-readonly) environment"
fi

# 3. No form of the Edge Function deploy command -- broad or
#    variable-indirect, matching the exact pattern
#    scripts/check-edge-function-governance.sh scans for -- may remain
#    anywhere in the file.
if grep -qE 'supabase functions deploy([[:space:]]|$)' "$WORKFLOW"; then
  fail "$WORKFLOW still invokes 'supabase functions deploy'; the workflow must be retired, not partially corrected"
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

# 5. The retirement must not quietly drop the workflow_dispatch trigger
#    (which would make the retirement notice unreachable) nor reintroduce
#    a pull_request trigger (which would make it run on every PR).
grep -qE '^[[:space:]]*workflow_dispatch:' "$WORKFLOW" \
  || fail "$WORKFLOW no longer accepts workflow_dispatch; its retirement notice must stay reachable"
if grep -qE '^[[:space:]]*pull_request:' "$WORKFLOW"; then
  fail "$WORKFLOW must not run automatically on pull_request"
fi

# 6. The header must name the specific, independently-verified fact that
#    makes this retirement correct, so a future reader cannot mistake it
#    for an unexplained deletion.
grep -Fq 'ai-order-parse' "$WORKFLOW" \
  || fail "$WORKFLOW header no longer documents which function this retirement concerns"
grep -Fiq 'ACTIVE' "$WORKFLOW" \
  || fail "$WORKFLOW header no longer documents the independently-verified production ACTIVE state"

echo "OK: buyer-genie-production-first-deploy.yml is structurally incapable of a production write or an indirect broad deploy, even under manual dispatch."

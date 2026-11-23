#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$root"

check="scripts/check-gifting-enquiries-production-first-deploy.sh"
runbook="docs/programme/GIFTING_OPTION_A_PRODUCTION_RUNBOOK.md"
workflow=".github/workflows/gifting-enquiries-production-first-deploy.yml"

fixture_dir="$(mktemp -d)"
trap 'rm -rf "$fixture_dir"' EXIT

fail() {
  echo "GIFTING ENQUIRIES FIRST DEPLOY REGRESSION FAILED: $*" >&2
  exit 1
}

bash -n "$check"

# The real runbook must pass the production-only guard.
bash "$check" --assert-runbook "$runbook" >/dev/null || fail "real runbook rejected by production-only guard"

# A runbook that binds an executable block to staging must be rejected.
cat >"$fixture_dir/staging-binding.md" <<'MD'
# fixture
```sql
select public.connect_admin_register_consumer_v1('oasis_gifting_website_prod', 'b2c_website', 'staging', 'x');
select public.connect_admin_bind_profile_v1('<C>'::uuid, '<P>'::uuid, 'production');
-- website_retail_v1 gifting_enquiries_v1 oasis_gifting_website_prod
```
MD
if bash "$check" --assert-runbook "$fixture_dir/staging-binding.md" >/dev/null 2>&1; then
  fail "runbook binding CONNECT_ENV to staging was accepted"
fi

# A runbook without a production binding must be rejected.
cat >"$fixture_dir/no-production.md" <<'MD'
# fixture
```sql
select public.connect_admin_register_consumer_v1('oasis_gifting_website_prod', 'b2c_website', 'x', 'y');
-- website_retail_v1 gifting_enquiries_v1
```
MD
if bash "$check" --assert-runbook "$fixture_dir/no-production.md" >/dev/null 2>&1; then
  fail "runbook without a production binding was accepted"
fi

# A runbook that references the staging project must be rejected.
cat >"$fixture_dir/staging-project.md" <<'MD'
# fixture
```sql
-- 'production' oasis_gifting_website_prod website_retail_v1 gifting_enquiries_v1 ypeoiobkqvlalxgugtgm
```
MD
if bash "$check" --assert-runbook "$fixture_dir/staging-project.md" >/dev/null 2>&1; then
  fail "runbook referencing the staging project was accepted"
fi

# Structural markers that the governance gate depends on.
grep -Fq 'environment: supabase-production-readonly' "$workflow" || fail "read-only preflight environment missing"
grep -Fq 'environment: supabase-production' "$workflow" || fail "production approval environment missing"
grep -Fq 'SUPABASE_PROJECT_REF: tcxvcatsqqertcnycuop' "$workflow" || fail "production project binding missing"
grep -Fq 'FUNCTION_NAME: gifting-enquiries' "$workflow" || fail "function binding missing"
grep -Fq 'GIFTING_ENQUIRIES_FUNCTION_ABSENT' "$workflow" || fail "absent-function marker missing"
grep -Fq '.verify_jwt == false' "$workflow" || fail "verify_jwt=false metadata assertion missing"
grep -Fq 'test "$unauthenticated_code" = "401"' "$workflow" || fail "401 boundary smoke missing"
grep -Fq 'Production Migration Release' "$runbook" || fail "runbook omits the Production Migration Release step"
grep -Fq "'production'" "$runbook" || fail "runbook omits production binding"
grep -Fq 'verify-gifting-enquiries-production-db-prerequisites.sql' "$workflow" || fail "DB prerequisite SQL missing"

echo "Gifting enquiries production first-deploy governance regression passed."

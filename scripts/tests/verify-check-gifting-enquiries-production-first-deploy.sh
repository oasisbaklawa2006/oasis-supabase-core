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

# Control: an otherwise-valid fixture must pass, so the negative cases below fail only for the binding under test.
cat >"$fixture_dir/valid-control.md" <<'MD'
# fixture
```sql
-- CONNECT_ENV = 'production'
select public.connect_admin_register_consumer_v1('oasis_gifting_website_prod', 'b2c_website', 'production', 'x');
select public.connect_admin_bind_profile_v1('<C>'::uuid, '<P>'::uuid, 'production');
-- website_retail_v1 gifting_enquiries_v1
```
must never be placed in Vercel
MD
bash "$check" --assert-runbook "$fixture_dir/valid-control.md" >/dev/null || fail "valid control fixture was rejected"

# A block that binds CONNECT_ENV to staging must be rejected.
cat >"$fixture_dir/staging-binding.md" <<'MD'
# fixture
```sql
select public.connect_admin_register_consumer_v1('oasis_gifting_website_prod', 'b2c_website', 'staging', 'x');
select public.connect_admin_bind_profile_v1('<C>'::uuid, '<P>'::uuid, 'production');
-- website_retail_v1 gifting_enquiries_v1
```
must never be placed in Vercel
MD
if bash "$check" --assert-runbook "$fixture_dir/staging-binding.md" >/dev/null 2>&1; then
  fail "runbook binding CONNECT_ENV to staging was accepted"
fi

# A runbook without any production binding must be rejected.
cat >"$fixture_dir/no-production.md" <<'MD'
# fixture
```sql
select public.connect_admin_register_consumer_v1('oasis_gifting_website_prod', 'b2c_website', 'x', 'y');
-- website_retail_v1 gifting_enquiries_v1
```
must never be placed in Vercel
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
must never be placed in Vercel
MD
if bash "$check" --assert-runbook "$fixture_dir/staging-project.md" >/dev/null 2>&1; then
  fail "runbook referencing the staging project was accepted"
fi

# A valid first block must not excuse an unbound second block that calls a Connect admin RPC.
cat >"$fixture_dir/unbound-second-block.md" <<'MD'
# fixture
```sql
-- CONNECT_ENV = 'production'
select public.connect_admin_register_consumer_v1('oasis_gifting_website_prod', 'b2c_website', 'production', 'x');
-- website_retail_v1 gifting_enquiries_v1
```

```sql
select public.connect_admin_issue_token_v1('<CONSUMER_ID>'::uuid, array['enquiries:gifting:write']::text[], 'x', now(), 120);
```
must never be placed in Vercel
MD
if bash "$check" --assert-runbook "$fixture_dir/unbound-second-block.md" >/dev/null 2>&1; then
  fail "unbound second Connect admin block was accepted because a first block was production-bound"
fi

# A double-quoted preview binding must be rejected, not only the single-quoted form.
cat >"$fixture_dir/double-quoted-preview.md" <<'MD'
# fixture
```sql
select public.connect_admin_register_consumer_v1('oasis_gifting_website_prod', 'b2c_website', "preview", 'x');
select public.connect_admin_bind_profile_v1('<C>'::uuid, '<P>'::uuid, 'production');
-- website_retail_v1 gifting_enquiries_v1
```
must never be placed in Vercel
MD
if bash "$check" --assert-runbook "$fixture_dir/double-quoted-preview.md" >/dev/null 2>&1; then
  fail "double-quoted preview binding was accepted"
fi

# Structural markers that the governance gate depends on.
grep -Fq 'environment: supabase-production-readonly' "$workflow" || fail "read-only preflight environment missing"
grep -Fq 'environment: supabase-production' "$workflow" || fail "production approval environment missing"
grep -Fq 'SUPABASE_PROJECT_REF: tcxvcatsqqertcnycuop' "$workflow" || fail "production project binding missing"
grep -Fq 'FUNCTION_NAME: gifting-enquiries' "$workflow" || fail "function binding missing"
grep -Fq 'GIFTING_ENQUIRIES_FUNCTION_ABSENT' "$workflow" || fail "absent-function marker missing"
grep -Fq '.verify_jwt == false' "$workflow" || fail "verify_jwt=false metadata assertion missing"
grep -Fq 'test "$unauthenticated_code" = "401"' "$workflow" || fail "401 boundary smoke missing"
grep -Fq 'idempotency-key: 00000000-0000-4000-8000-000000000001' "$workflow" || fail "invalid-JWT smoke lacks idempotency key"
grep -Fq 'steps.failed_evidence_scan.outcome' "$workflow" || fail "failed-evidence upload is not gated on the scan"
# A runbook that lists the service_role key as a required Vercel variable must be rejected.
tick="$(printf '\x60')"
for variable in SUPABASE_SERVICE_ROLE_KEY SUPABASE_URL; do
  { cat "$runbook"; printf '\n| %s%s%s | value | Yes |\n' "$tick" "$variable" "$tick"; printf 'must never be placed in Vercel\n'; } >"$fixture_dir/requires-$variable.md"
  if bash "$check" --assert-runbook "$fixture_dir/requires-$variable.md" >/dev/null 2>&1; then
    fail "runbook requiring $variable in Vercel was accepted"
  fi
done
grep -Fq 'purge_synced_website_leads_v1(90)' "$runbook" || fail "runbook omits the 90-day retention default"

grep -Fq 'Production Migration Release' "$runbook" || fail "runbook omits the Production Migration Release step"
grep -Fq "'production'" "$runbook" || fail "runbook omits production binding"
grep -Fq 'verify-gifting-enquiries-production-db-prerequisites.sql' "$workflow" || fail "DB prerequisite SQL missing"

echo "Gifting enquiries production first-deploy governance regression passed."

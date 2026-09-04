#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
verifier="$repo_root/scripts/verify-production-migration-ledger.sh"
test_root="$(mktemp -d)"
trap 'rm -rf "$test_root"' EXIT

write_stub() {
  local path="$1"
  cat > "$path" <<'SQL'
-- Preview ledger compatibility stub (non-production preview branches only).
-- Preview ledger compatibility: no schema mutation in this file.
select 1;
SQL
}

setup_base_fixtures() {
  local dir="$1"
  mkdir -p "$dir/migrations" "$dir/docs/reconciliation" "$dir/bin"

  for i in $(seq 1 16); do
    printf -v historical_version '2024010100%04d' "$i"
    printf -v replacement_version '2026010100%04d' "$i"
    : > "$dir/migrations/${historical_version}_historical-gap.sql"
    : > "$dir/migrations/${replacement_version}_forward-replacement.sql"
  done

  {
    printf '%s\n' 'version,source,evidence'
    printf '%s\n' '20260101000001,reconciled,replacement-already-applied'
    for i in $(seq 1 31); do
      printf '2025020100%04d,production,test\n' "$i"
    done
  } > "$dir/docs/reconciliation/production-history.csv"

  {
    printf '%s\n' 'canonical_version,status,replacement_version,remote_evidence,evidence'
    for i in $(seq 1 16); do
      printf '2024010100%04d,pending_forward,2026010100%04d,production,test\n' "$i" "$i"
    done
  } > "$dir/docs/reconciliation/canonical-lineage.csv"

  cat > "$dir/bin/psql" <<'PSQL'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' '20260101000001'
for i in $(seq 1 31); do
  printf '2025020100%04d\n' "$i"
done
PSQL
  chmod +x "$dir/bin/psql"
}

run_verifier() {
  local dir="$1"
  shift
  local -a extra_env=("$@")
  (
    export PATH="$dir/bin:$PATH"
    export SUPABASE_DB_URL='postgresql://ledger-regression.invalid/test'
    export MIGRATIONS_DIR="$dir/migrations"
    export REPORT_FILE="$dir/report.txt"
    export REMOTE_HISTORY_LEDGER="$dir/docs/reconciliation/production-history.csv"
    export CANONICAL_LINEAGE_LEDGER="$dir/docs/reconciliation/canonical-lineage.csv"
    export EXPECTED_REMOTE_HISTORY_COUNT=32
    export EXPECTED_CANONICAL_LINEAGE_COUNT=16
    for assignment in "${extra_env[@]}"; do
      export "$assignment"
    done
    bash "$verifier"
  )
}

expect_fail() {
  local dir="$1" pattern="$2"
  shift 2
  set +e
  run_verifier "$dir" "$@" >"$dir/out.txt" 2>"$dir/err.txt"
  status=$?
  set -e
  test "$status" -ne 0
  grep -Eqi "$pattern" "$dir/err.txt"
}

# 1. A validated preview-compat historical gap is excluded from unreconciled-local failures.
case1="$test_root/valid-compat"
setup_base_fixtures "$case1"
write_stub "$case1/migrations/20251201000000_point29_preview_compat.sql"
printf '%s\n' '20251201000000' > "$case1/preview-migration-ledger-compat.txt"
run_verifier "$case1" "PREVIEW_MIGRATION_LEDGER_COMPAT_FILE=$case1/preview-migration-ledger-compat.txt"
grep -q '^Status: SUCCESS$' "$case1/report.txt"

# 2. A historical gap that is not inventory-listed still fails closed.
case2="$test_root/stale-non-inventory"
setup_base_fixtures "$case2"
: > "$case2/migrations/20251201000000_unreconciled_stale.sql"
expect_fail "$case2" 'Unreconciled canonical-local migration versions detected' \
  "PREVIEW_MIGRATION_LEDGER_COMPAT_FILE=$case2/preview-migration-ledger-compat.txt"

# 3. Malformed compatibility inventory entries fail closed.
case3="$test_root/malformed-inventory"
setup_base_fixtures "$case3"
write_stub "$case3/migrations/20260903100000_point29_preview_compat.sql"
printf '%s\n' 'not-a-14-digit-version' > "$case3/preview-migration-ledger-compat.txt"
expect_fail "$case3" 'entry must be exactly 14 digits' \
  "PREVIEW_MIGRATION_LEDGER_COMPAT_FILE=$case3/preview-migration-ledger-compat.txt"

# 4. Duplicate compatibility inventory entries fail closed.
case4="$test_root/duplicate-inventory"
setup_base_fixtures "$case4"
write_stub "$case4/migrations/20260903100000_point29_preview_compat.sql"
{
  printf '%s\n' '20260903100000'
  printf '%s\n' '20260903100000'
} > "$case4/preview-migration-ledger-compat.txt"
expect_fail "$case4" 'Duplicate preview ledger compatibility version' \
  "PREVIEW_MIGRATION_LEDGER_COMPAT_FILE=$case4/preview-migration-ledger-compat.txt"

# 5. Inventory-listed versions without a matching migration file fail closed.
case5="$test_root/missing-stub"
setup_base_fixtures "$case5"
printf '%s\n' '20260903100000' > "$case5/preview-migration-ledger-compat.txt"
expect_fail "$case5" 'lacks a matching migration file' \
  "PREVIEW_MIGRATION_LEDGER_COMPAT_FILE=$case5/preview-migration-ledger-compat.txt"

# 6. Inventory-listed versions with real DDL/DML fail closed.
case6="$test_root/mutated-stub"
setup_base_fixtures "$case6"
cat > "$case6/migrations/20260903100000_point29_preview_compat.sql" <<'SQL'
-- Preview ledger compatibility: falsely claimed no-op.
create table public.should_never_pass(id bigint);
SQL
printf '%s\n' '20260903100000' > "$case6/preview-migration-ledger-compat.txt"
expect_fail "$case6" 'exact no-op stub' \
  "PREVIEW_MIGRATION_LEDGER_COMPAT_FILE=$case6/preview-migration-ledger-compat.txt"

# 7. Path traversal cannot redirect the compatibility inventory.
case7="$test_root/compat-traversal"
setup_base_fixtures "$case7"
set +e
run_verifier "$case7" "PREVIEW_MIGRATION_LEDGER_COMPAT_FILE=../outside" >"$case7/out.txt" 2>"$case7/err.txt"
status=$?
set -e
test "$status" -ne 0
grep -q 'PREVIEW_MIGRATION_LEDGER_COMPAT_FILE must be repository-relative' "$case7/err.txt"

echo 'verify-production-migration-ledger-preview-compat-regression.sh: all cases passed'

#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$repo_root"
overlay="$repo_root/scripts/run-production-migration-overlay.sh"
test_root="$(mktemp -d)"
link_state='supabase/.temp/project-ref'
created_link_state=0
trap 'rm -rf "$test_root"; if [[ "$created_link_state" == 1 ]]; then rm -f "$link_state"; rmdir supabase/.temp 2>/dev/null || true; fi' EXIT

if [[ ! -f "$link_state" ]]; then
  mkdir -p supabase/.temp
  printf '%s\n' test-project-ref > "$link_state"
  created_link_state=1
fi

write_stub() {
  local path="$1"
  cat > "$path" <<'SQL'
-- Preview ledger compatibility stub (non-production preview branches only).
-- Preview ledger compatibility: no schema mutation in this file.
select 1;
SQL
}

write_forward() {
  local path="$1"
  cat > "$path" <<'SQL'
-- Forward production candidate migration.
create table if not exists public.overlay_preview_compat_regression(id bigint primary key);
SQL
}

setup_overlay_fixtures() {
  local dir="$1"
  mkdir -p "$dir/migrations" "$dir/docs/reconciliation" "$dir/supabase/.temp" "$dir/bin"

  cp "$repo_root/docs/reconciliation/production-migration-ledger-remote-history-2026-08-18.csv" \
    "$dir/docs/reconciliation/production-migration-ledger-remote-history-2026-08-18.csv"
  cp "$repo_root/docs/reconciliation/canonical-production-lineage-2026-08-18.csv" \
    "$dir/docs/reconciliation/canonical-production-lineage-2026-08-18.csv"
  cp "$repo_root/supabase/config.toml" "$dir/supabase/config.toml"
  printf '%s\n' test-project-ref > "$dir/supabase/.temp/project-ref"

  cp -a "$repo_root/supabase/migrations/." "$dir/migrations/"
}

run_overlay() {
  local dir="$1"
  shift
  local -a extra_env=("$@")
  (
    export PATH="$dir/bin:$PATH"
    export SUPABASE_DB_URL='postgresql://postgres:test@127.0.0.1:5432/postgres'
    export MIGRATIONS_DIR="$dir/migrations"
    export REMOTE_HISTORY_LEDGER="$dir/docs/reconciliation/production-migration-ledger-remote-history-2026-08-18.csv"
    export CANONICAL_LINEAGE_LEDGER="$dir/docs/reconciliation/canonical-production-lineage-2026-08-18.csv"
    for assignment in "${extra_env[@]}"; do
      export "$assignment"
    done
    bash "$overlay" --dry-run
  )
}

expect_overlay_fail() {
  local dir="$1" pattern="$2"
  shift 2
  set +e
  run_overlay "$dir" "$@" >"$dir/out.txt" 2>"$dir/err.txt"
  status=$?
  set -e
  test "$status" -ne 0
  grep -Eqi "$pattern" "$dir/err.txt"
}

mkdir -p "$test_root/bin"
cat > "$test_root/bin/supabase" <<'FAKE_SUPABASE'
#!/usr/bin/env bash
set -euo pipefail
case "$#" in
  5)
    [[ "$1" == db && "$2" == push && "$3" == --db-url && "$5" == --dry-run ]] || exit 1
    migration_dir="$SUPABASE_WORKDIR/supabase/migrations"
    [[ ! -e "$migration_dir/20260903100000_point29_atomic_intake_barcode_authority.sql" ]] || exit 1
    [[ -f "$migration_dir/20260904030100_point29_atomic_intake_barcode_authority.sql" ]] || exit 1
    [[ -f "$migration_dir/20260904030200_point29_blocker_hardening_reconcile.sql" ]] || exit 1
    echo 'fake overlay dry-run accepted preview-compat exclusion'
    ;;
  *) exit 1 ;;
esac
FAKE_SUPABASE
chmod +x "$test_root/bin/supabase"

# 1. Valid preview-compat inventory excludes inert stubs from the CLI overlay.
case1="$test_root/valid-compat"
setup_overlay_fixtures "$case1"
cp "$test_root/bin/supabase" "$case1/bin/supabase"
run_overlay "$case1" "PREVIEW_MIGRATION_LEDGER_COMPAT_FILE=supabase/preview-migration-ledger-compat.txt" \
  >"$case1/out.txt"
grep -q 'Hidden preview ledger compatibility stubs: 7' "$case1/out.txt"
grep -q 'fake overlay dry-run accepted preview-compat exclusion' "$case1/out.txt"

# 2. A stale historical migration that is not inventory-listed remains in the overlay.
case2="$test_root/stale-non-inventory"
setup_overlay_fixtures "$case2"
write_forward "$case2/migrations/20251201000000_unreconciled_stale.sql"
cat > "$case2/bin/supabase" <<'FAKE_SUPABASE'
#!/usr/bin/env bash
set -euo pipefail
[[ "$1" == db && "$2" == push && "$5" == --dry-run ]] || exit 1
migration_dir="$SUPABASE_WORKDIR/supabase/migrations"
[[ -f "$migration_dir/20251201000000_unreconciled_stale.sql" ]] || { echo 'non-inventory stale migration was hidden' >&2; exit 1; }
[[ ! -e "$migration_dir/20260903100000_point29_atomic_intake_barcode_authority.sql" ]] || { echo 'preview compat stub was not hidden' >&2; exit 1; }
echo 'fake overlay dry-run preserved non-inventory stale migration'
FAKE_SUPABASE
chmod +x "$case2/bin/supabase"
run_overlay "$case2" "PREVIEW_MIGRATION_LEDGER_COMPAT_FILE=supabase/preview-migration-ledger-compat.txt" \
  >"$case2/out.txt"
grep -q 'fake overlay dry-run preserved non-inventory stale migration' "$case2/out.txt"

# 3. Malformed compatibility inventory entries fail closed.
case3="$test_root/malformed-inventory"
setup_overlay_fixtures "$case3"
rm -f "$case3/migrations/20260903100000_"*.sql
write_stub "$case3/migrations/20260903100000_point29_preview_compat.sql"
printf '%s\n' 'not-a-14-digit-version' > "$case3/preview-migration-ledger-compat.txt"
expect_overlay_fail "$case3" 'entry must be exactly 14 digits' \
  "PREVIEW_MIGRATION_LEDGER_COMPAT_FILE=$case3/preview-migration-ledger-compat.txt"

# 4. Duplicate compatibility inventory entries fail closed.
case4="$test_root/duplicate-inventory"
setup_overlay_fixtures "$case4"
rm -f "$case4/migrations/20260903100000_"*.sql
write_stub "$case4/migrations/20260903100000_point29_preview_compat.sql"
{
  printf '%s\n' '20260903100000'
  printf '%s\n' '20260903100000'
} > "$case4/preview-migration-ledger-compat.txt"
expect_overlay_fail "$case4" 'duplicate preview ledger compatibility version' \
  "PREVIEW_MIGRATION_LEDGER_COMPAT_FILE=$case4/preview-migration-ledger-compat.txt"

# 5. Inventory-listed versions without a matching migration file fail closed.
case5="$test_root/missing-stub"
setup_overlay_fixtures "$case5"
rm -f "$case5/migrations/20260903100000_"*.sql
printf '%s\n' '20260903100000' > "$case5/preview-migration-ledger-compat.txt"
expect_overlay_fail "$case5" 'lacks a matching migration file' \
  "PREVIEW_MIGRATION_LEDGER_COMPAT_FILE=$case5/preview-migration-ledger-compat.txt"

# 6. Inventory-listed versions with real DDL/DML fail closed.
case6="$test_root/mutated-stub"
setup_overlay_fixtures "$case6"
rm -f "$case6/migrations/20260903100000_"*.sql
cat > "$case6/migrations/20260903100000_point29_preview_compat.sql" <<'SQL'
-- Preview ledger compatibility: falsely claimed no-op.
create table public.should_never_pass(id bigint);
SQL
printf '%s\n' '20260903100000' > "$case6/preview-migration-ledger-compat.txt"
expect_overlay_fail "$case6" 'exact no-op stub' \
  "PREVIEW_MIGRATION_LEDGER_COMPAT_FILE=$case6/preview-migration-ledger-compat.txt"

# 7. Path traversal cannot redirect the compatibility inventory.
case7="$test_root/compat-traversal"
setup_overlay_fixtures "$case7"
set +e
run_overlay "$case7" "PREVIEW_MIGRATION_LEDGER_COMPAT_FILE=../outside" >"$case7/out.txt" 2>"$case7/err.txt"
status=$?
set -e
test "$status" -ne 0
grep -q 'PREVIEW_MIGRATION_LEDGER_COMPAT_FILE must be repository-relative' "$case7/err.txt"

echo 'verify-production-migration-overlay-preview-compat-regression.sh: all cases passed'

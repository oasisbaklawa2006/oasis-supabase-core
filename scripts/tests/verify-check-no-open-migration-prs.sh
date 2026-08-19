#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
test_root="$(mktemp -d)"
trap 'rm -rf "$test_root"' EXIT

mkdir -p "$test_root/bin" "$test_root/migrations"
: > "$test_root/migrations/20260101000001_already_on_main.sql"

# --- Case 1: an open PR introduces a migration filename already present on
#     main (e.g. that PR's own branch, or a merged-then-rebased duplicate) --
#     must PASS, not a false positive.
cat > "$test_root/bin/gh" <<'GH'
#!/usr/bin/env bash
set -euo pipefail
if [[ "$1 $2" == "pr list" ]]; then
  echo "101"
elif [[ "$1 $2" == "pr diff" ]]; then
  case "$3" in
    101) echo "supabase/migrations/20260101000001_already_on_main.sql" ;;
  esac
fi
GH
chmod +x "$test_root/bin/gh"

output="$(PATH="$test_root/bin:$PATH" MIGRATIONS_DIR="$test_root/migrations" bash "$repo_root/scripts/check-no-open-migration-prs.sh")"
grep -q '^OK: no open Core pull request' <<< "$output"

# --- Case 2: an open PR introduces a migration filename NOT present on
#     main -- must FAIL closed with the exact sentinel string.
cat > "$test_root/bin/gh" <<'GH'
#!/usr/bin/env bash
set -euo pipefail
if [[ "$1 $2" == "pr list" ]]; then
  printf '%s\n' 101 102
elif [[ "$1 $2" == "pr diff" ]]; then
  case "$3" in
    101) echo "supabase/migrations/20260101000001_already_on_main.sql" ;;
    102)
      printf '%s\n' \
        "supabase/migrations/20260819999999_unmerged_blocking_migration.sql" \
        "README.md"
      ;;
  esac
fi
GH
chmod +x "$test_root/bin/gh"

if PATH="$test_root/bin:$PATH" MIGRATIONS_DIR="$test_root/migrations" bash "$repo_root/scripts/check-no-open-migration-prs.sh" > "$test_root/out.txt" 2>&1; then
  echo "expected the guard to fail closed on an unmerged migration PR, but it exited 0" >&2
  cat "$test_root/out.txt" >&2
  exit 1
fi
grep -q '^OPEN_MIGRATION_PR_BLOCKS_PRODUCTION_RELEASE: PR #102 introduces supabase/migrations/20260819999999_unmerged_blocking_migration.sql' "$test_root/out.txt"
grep -q '^FAIL: one or more open Core pull requests' "$test_root/out.txt"
if grep -q 'PR #101 introduces' "$test_root/out.txt"; then
  echo "PR #101 (already-on-main migration) was incorrectly flagged as blocking" >&2
  exit 1
fi

# --- Case 3: zero open PRs -- must PASS.
cat > "$test_root/bin/gh" <<'GH'
#!/usr/bin/env bash
set -euo pipefail
if [[ "$1 $2" == "pr list" ]]; then
  :
fi
GH
chmod +x "$test_root/bin/gh"

output="$(PATH="$test_root/bin:$PATH" MIGRATIONS_DIR="$test_root/migrations" bash "$repo_root/scripts/check-no-open-migration-prs.sh")"
grep -q '^OK: no open Core pull request' <<< "$output"

echo "verify-check-no-open-migration-prs.sh: all cases passed"

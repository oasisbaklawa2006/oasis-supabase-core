#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
checker="$repo_root/scripts/check-migration-base-monotonicity.sh"
test_root="$(mktemp -d)"
trap 'rm -rf "$test_root"' EXIT

new_repo() {
  local dir="$1"
  mkdir -p "$dir/supabase/migrations"
  git -C "$dir" init -q -b main
  git -C "$dir" config user.name 'Migration Guard Test'
  git -C "$dir" config user.email 'migration-guard@example.invalid'
  printf '%s\n' '-- base' > "$dir/supabase/migrations/20260828002100_base.sql"
  git -C "$dir" add .
  git -C "$dir" commit -q -m base
}

run_checker() {
  local dir="$1"
  (cd "$dir" && bash "$checker" main)
}

expect_fail() {
  local dir="$1" pattern="$2"
  set +e
  run_checker "$dir" >"$dir/check.out" 2>"$dir/check.err"
  status=$?
  set -e
  if [[ "$status" -eq 0 ]]; then
    echo "expected monotonicity checker to fail in $dir" >&2
    exit 1
  fi
  grep -Eqi "$pattern" "$dir/check.err"
}

# 1. A genuinely new timestamp above the current target-base ceiling passes.
case1="$test_root/valid"
new_repo "$case1"
git -C "$case1" switch -q -c feature
printf '%s\n' '-- future' > "$case1/supabase/migrations/20260828120000_future.sql"
git -C "$case1" add . && git -C "$case1" commit -q -m future
run_checker "$case1" >/dev/null

# 2. Equal/older timestamps are stale relative to current target base.
case2="$test_root/stale"
new_repo "$case2"
git -C "$case2" switch -q -c feature
printf '%s\n' '-- stale' > "$case2/supabase/migrations/20260828002000_stale.sql"
git -C "$case2" add . && git -C "$case2" commit -q -m stale
expect_fail "$case2" 'not strictly greater|ceiling'

# 3. Editing a migration that existed on the branch base is forbidden.
case3="$test_root/modify"
new_repo "$case3"
git -C "$case3" switch -q -c feature
printf '%s\n' '-- modified historical migration' >> "$case3/supabase/migrations/20260828002100_base.sql"
git -C "$case3" add . && git -C "$case3" commit -q -m modify
expect_fail "$case3" 'M of migration|already present'

# 4. Deleting a base migration is forbidden.
case4="$test_root/delete"
new_repo "$case4"
git -C "$case4" switch -q -c feature
git -C "$case4" rm -q supabase/migrations/20260828002100_base.sql
git -C "$case4" commit -q -m delete
expect_fail "$case4" 'D of migration|already present'

# 5. Renaming history is forbidden even if the destination timestamp is newer.
case5="$test_root/rename"
new_repo "$case5"
git -C "$case5" switch -q -c feature
git -C "$case5" mv supabase/migrations/20260828002100_base.sql supabase/migrations/20260828130000_renamed.sql
git -C "$case5" commit -q -m rename
expect_fail "$case5" 'rename of migration history'

# 6. A new path cannot reuse a timestamp already present on current target base.
case6="$test_root/collision"
new_repo "$case6"
printf '%s\n' '-- current base high' > "$case6/supabase/migrations/20260828120000_current.sql"
git -C "$case6" add . && git -C "$case6" commit -q -m high-base
git -C "$case6" switch -q -c feature
printf '%s\n' '-- collision' > "$case6/supabase/migrations/20260828120000_collision.sql"
git -C "$case6" add . && git -C "$case6" commit -q -m collision
expect_fail "$case6" 'collides|not strictly greater'

# 7. Newly added migration filenames fail closed when malformed.
case7="$test_root/malformed"
new_repo "$case7"
git -C "$case7" switch -q -c feature
printf '%s\n' '-- malformed' > "$case7/supabase/migrations/20260829120000-Bad-Name.sql"
git -C "$case7" add . && git -C "$case7" commit -q -m malformed
expect_fail "$case7" 'must match YYYYMMDDHHMMSS_snake_case.sql'

# 8. The decisive stale-branch case: feature timestamp was future when created,
# but main later advances beyond it. The same untouched feature must now fail
# against current main, forcing rebase/re-timestamp/retest before merge.
case8="$test_root/base-advanced"
new_repo "$case8"
git -C "$case8" switch -q -c feature
printf '%s\n' '-- initially future' > "$case8/supabase/migrations/20260828120000_feature.sql"
git -C "$case8" add . && git -C "$case8" commit -q -m feature
feature_sha="$(git -C "$case8" rev-parse HEAD)"
git -C "$case8" switch -q main
printf '%s\n' '-- base advanced' > "$case8/supabase/migrations/20260829100000_base_advanced.sql"
git -C "$case8" add . && git -C "$case8" commit -q -m base-advanced
git -C "$case8" switch -q --detach "$feature_sha"
expect_fail "$case8" 'not strictly greater|ceiling'

# 9. Non-migration changes remain non-blocking.
case9="$test_root/no-migrations"
new_repo "$case9"
git -C "$case9" switch -q -c feature
printf '%s\n' 'docs only' > "$case9/README.md"
git -C "$case9" add . && git -C "$case9" commit -q -m docs
run_checker "$case9" >/dev/null

# 10. Path traversal in MIGRATIONS_DIR fails closed.
set +e
(cd "$case9" && MIGRATIONS_DIR='../outside' bash "$checker" main) >"$case9/traversal.out" 2>"$case9/traversal.err"
status=$?
set -e
test "$status" -ne 0
grep -q "MIGRATIONS_DIR must be repository-relative" "$case9/traversal.err"

# 11. Malformed migration filenames already present on the target base must
# fail closed; they cannot be ignored when calculating the current ceiling.
case11="$test_root/malformed-base"
new_repo "$case11"
printf '%s\n' '-- malformed base' > "$case11/supabase/migrations/20260829120000-Bad-Base.sql"
git -C "$case11" add . && git -C "$case11" commit -q -m malformed-base
git -C "$case11" switch -q -c feature
printf '%s\n' 'docs only' > "$case11/README.md"
git -C "$case11" add . && git -C "$case11" commit -q -m docs
expect_fail "$case11" 'target base contains malformed canonical migration filename'

echo 'verify-check-migration-base-monotonicity.sh: all cases passed'

#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$repo_root"
test_root="$(mktemp -d)"
custom_dir="$repo_root/.tmp-migration-gate-config-$$"
trap 'rm -rf "$test_root" "$custom_dir"' EXIT
mkdir -p "$test_root/bin"

script="$repo_root/scripts/check-no-open-migration-prs.sh"

# Static invariants for the collision-aware release-ceiling guard.
grep -qF -- 'PR_LIST_LIMIT' "$script"
grep -qF -- '--state open --limit' "$script"
grep -qF -- 'isCrossRepository' "$script"
grep -qF -- 'RELEASE_MIGRATION_CEILING' "$script"
grep -qF -- 'FUTURE_MIGRATION_PR_DOES_NOT_BLOCK_RELEASE' "$script"
grep -qF -- '"$MIGRATIONS_DIR"/*.sql' "$script"

latest_version="$(find supabase/migrations -maxdepth 1 -type f -name '*.sql' -printf '%f\n' \
  | sed -nE 's/^([0-9]{14})_.+\.sql$/\1/p' \
  | sort \
  | tail -n1)"
test -n "$latest_version"
future_version="99999999999999"
past_version="00000000000000"

# One configurable gh stub is reused by all cases. The production script makes
# two `gh pr list` calls: a raw count (`--jq length`) and a same-repo filtered
# number list. TEST_PR_NUMBERS therefore represents only same-repository PRs;
# fork-only cases leave it empty while keeping TEST_RAW_COUNT non-zero.
cat > "$test_root/bin/gh" <<'GH'
#!/usr/bin/env bash
set -euo pipefail
if [[ "$1 $2" == "pr list" ]]; then
  for arg in "$@"; do
    if [[ "$arg" == "length" ]]; then
      echo "${TEST_RAW_COUNT:-0}"
      exit 0
    fi
  done
  if [[ -n "${TEST_PR_NUMBERS:-}" ]]; then
    printf '%s\n' ${TEST_PR_NUMBERS}
  fi
elif [[ "$1 $2" == "pr diff" ]]; then
  pr_number="$3"
  var_name="TEST_DIFF_${pr_number}"
  printf '%b' "${!var_name:-}"
fi
GH
chmod +x "$test_root/bin/gh"

run_guard() {
  PATH="$test_root/bin:$PATH" bash "$script"
}

# 1. Zero open PRs: PASS.
export TEST_RAW_COUNT=0 TEST_PR_NUMBERS=''
output="$(run_guard)"
grep -q "^RELEASE_MIGRATION_CEILING: $latest_version$" <<< "$output"
grep -q '^OK: no open same-repository Core PR touches migration history' <<< "$output"

# 2. Code/docs-only PR: PASS.
export TEST_RAW_COUNT=1 TEST_PR_NUMBERS='201'
export TEST_DIFF_201=$'README.md\ndocs/reconciliation/notes.md\n'
output="$(run_guard)"
grep -q '^OK: no open same-repository Core PR touches migration history' <<< "$output"

# 3. Strictly-future migration PR: PASS and explicitly classify as future.
export TEST_RAW_COUNT=1 TEST_PR_NUMBERS='202'
export TEST_DIFF_202="supabase/migrations/${future_version}_future_train.sql\n"
output="$(run_guard)"
grep -q "^FUTURE_MIGRATION_PR_DOES_NOT_BLOCK_RELEASE: PR #202 migration $future_version" <<< "$output"
grep -q '^OK: open future migration PRs exist' <<< "$output"

# 4. Migration at or before the release ceiling: FAIL closed.
export TEST_RAW_COUNT=1 TEST_PR_NUMBERS='203'
export TEST_DIFF_203="supabase/migrations/${past_version}_stale_or_collision.sql\n"
if run_guard > "$test_root/out.txt" 2>&1; then
  echo "expected FAIL for a migration at/before the release ceiling" >&2
  exit 1
fi
grep -q "^OPEN_MIGRATION_PR_BLOCKS_PRODUCTION_RELEASE: PR #203 migration $past_version" "$test_root/out.txt"

# 5. Modifying an existing migration on main: FAIL.
existing_rel="supabase/migrations/$(find supabase/migrations -maxdepth 1 -type f -name '*.sql' -printf '%f\n' | sort | tail -n1)"
export TEST_RAW_COUNT=1 TEST_PR_NUMBERS='204'
export TEST_DIFF_204="$existing_rel\n"
if run_guard > "$test_root/out.txt" 2>&1; then
  echo "expected FAIL for an existing migration path" >&2
  exit 1
fi
grep -q '^OPEN_MIGRATION_PR_BLOCKS_PRODUCTION_RELEASE: PR #204' "$test_root/out.txt"

# 6. Mixed PRs: future migration is non-blocking, stale migration blocks.
export TEST_RAW_COUNT=3 TEST_PR_NUMBERS='205 206 207'
export TEST_DIFF_205=$'README.md\n'
export TEST_DIFF_206="supabase/migrations/${future_version}_future.sql\n"
export TEST_DIFF_207="supabase/migrations/${past_version}_blocking.sql\n"
if run_guard > "$test_root/out.txt" 2>&1; then
  echo "expected FAIL when one PR touches migration history inside the ceiling" >&2
  exit 1
fi
grep -q '^FUTURE_MIGRATION_PR_DOES_NOT_BLOCK_RELEASE: PR #206' "$test_root/out.txt"
grep -q '^OPEN_MIGRATION_PR_BLOCKS_PRODUCTION_RELEASE: PR #207' "$test_root/out.txt"

# 7. Raw PR list reaches PR_LIST_LIMIT: FAIL closed on possible truncation.
export TEST_RAW_COUNT=3 TEST_PR_NUMBERS='208 209 210'
if PR_LIST_LIMIT=3 PATH="$test_root/bin:$PATH" bash "$script" > "$test_root/out.txt" 2>&1; then
  echo "expected FAIL at PR_LIST_LIMIT boundary" >&2
  exit 1
fi
grep -qF 'gh pr list returned 3 open pull requests, which is >= PR_LIST_LIMIT (3)' "$test_root/out.txt"

# 8. Same count under the limit with migration-free PRs: PASS.
export TEST_DIFF_208=$'README.md\n' TEST_DIFF_209=$'docs/a.md\n' TEST_DIFF_210=$'scripts/a.sh\n'
output="$(PR_LIST_LIMIT=1000 run_guard)"
grep -q '^OK: no open same-repository Core PR touches migration history' <<< "$output"

# 9. Fork-only migration PR cannot block production. Raw count sees it, but
# same-repository selection must return no PR number at all.
export TEST_RAW_COUNT=1 TEST_PR_NUMBERS=''
output="$(run_guard)"
grep -q '^OK: no open same-repository Core PR touches migration history' <<< "$output"

# 10. Malformed same-repo migration filename: FAIL closed.
export TEST_RAW_COUNT=1 TEST_PR_NUMBERS='211'
export TEST_DIFF_211=$'supabase/migrations/not_a_timestamp_bad.sql\n'
if run_guard > "$test_root/out.txt" 2>&1; then
  echo "expected FAIL for malformed migration path" >&2
  exit 1
fi
grep -q '^OPEN_MIGRATION_PR_BLOCKS_PRODUCTION_RELEASE: PR #211 contains malformed migration path' "$test_root/out.txt"

# 11. Explicit ceiling must equal the exact latest migration on the release commit.
export TEST_RAW_COUNT=0 TEST_PR_NUMBERS=''
if RELEASE_MIGRATION_CEILING="$past_version" run_guard > "$test_root/out.txt" 2>&1; then
  echo "expected FAIL for a lower partial release ceiling" >&2
  exit 1
fi
grep -q '^FAIL: RELEASE_MIGRATION_CEILING' "$test_root/out.txt"
output="$(RELEASE_MIGRATION_CEILING="$latest_version" run_guard)"
grep -q "^RELEASE_MIGRATION_CEILING: $latest_version$" <<< "$output"

# 12. Malformed explicit ceiling: FAIL.
if RELEASE_MIGRATION_CEILING='not-a-version' run_guard > "$test_root/out.txt" 2>&1; then
  echo "expected FAIL for malformed explicit release ceiling" >&2
  exit 1
fi
grep -q '^FAIL: RELEASE_MIGRATION_CEILING must be exactly 14 digits' "$test_root/out.txt"

# 13. MIGRATIONS_DIR is one authority path for BOTH release-ceiling discovery
# and PR-diff collision scanning. This directly guards against accidentally
# hardcoding `supabase/migrations` in only one half of the algorithm.
custom_rel="${custom_dir#$repo_root/}"
mkdir -p "$custom_dir"
printf '%s\n' '-- test fixture' > "$custom_dir/${latest_version}_custom_authority.sql"
export TEST_RAW_COUNT=1 TEST_PR_NUMBERS='212'
export TEST_DIFF_212="${custom_rel}/${past_version}_must_block.sql\n"
if MIGRATIONS_DIR="$custom_rel" run_guard > "$test_root/out.txt" 2>&1; then
  echo "expected FAIL for a configured-directory migration at/before its release ceiling" >&2
  exit 1
fi
grep -q '^OPEN_MIGRATION_PR_BLOCKS_PRODUCTION_RELEASE: PR #212' "$test_root/out.txt"

# Path traversal/absolute migration-directory overrides are invalid because gh
# PR diffs are repository-relative and the guard must compare like with like.
if MIGRATIONS_DIR='../outside' run_guard > "$test_root/out.txt" 2>&1; then
  echo "expected FAIL for path-traversing MIGRATIONS_DIR" >&2
  exit 1
fi
grep -q '^FAIL: MIGRATIONS_DIR must be a non-empty repository-relative path' "$test_root/out.txt"

echo 'verify-check-no-open-migration-prs.sh: all cases passed'

#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
test_root="$(mktemp -d)"
trap 'rm -rf "$test_root"' EXIT
mkdir -p "$test_root/bin"

script="$repo_root/scripts/check-no-open-migration-prs.sh"

# Static invariants for the collision-aware release-ceiling guard.
grep -qF -- 'PR_LIST_LIMIT' "$script"
grep -qF -- '--state open --limit' "$script"
grep -qF -- 'isCrossRepository' "$script"
grep -qF -- 'RELEASE_MIGRATION_CEILING' "$script"
grep -qF -- 'FUTURE_MIGRATION_PR_DOES_NOT_BLOCK_RELEASE' "$script"

latest_version="$(find "$repo_root/supabase/migrations" -maxdepth 1 -type f -name '*.sql' -printf '%f\n' \
  | sed -nE 's/^([0-9]{14})_.+\.sql$/\1/p' \
  | sort \
  | tail -n1)"
test -n "$latest_version"
future_version="99999999999999"
past_version="00000000000000"

write_gh() {
  cat > "$test_root/bin/gh"
  chmod +x "$test_root/bin/gh"
}

run_guard() {
  PATH="$test_root/bin:$PATH" bash "$script"
}

# 1. Zero open PRs: PASS.
write_gh <<'GH'
#!/usr/bin/env bash
set -euo pipefail
if [[ "$1 $2" == "pr list" ]]; then
  for a in "$@"; do [[ "$a" == "length" ]] && { echo 0; exit 0; }; done
  :
fi
GH
output="$(run_guard)"
grep -q "^RELEASE_MIGRATION_CEILING: $latest_version$" <<< "$output"
grep -q '^OK: no open same-repository Core PR touches migration history' <<< "$output"

# 2. Code/docs-only PR: PASS.
write_gh <<'GH'
#!/usr/bin/env bash
set -euo pipefail
if [[ "$1 $2" == "pr list" ]]; then
  for a in "$@"; do [[ "$a" == "length" ]] && { echo 1; exit 0; }; done
  echo 201
elif [[ "$1 $2" == "pr diff" ]]; then
  printf '%s\n' README.md docs/reconciliation/notes.md
fi
GH
output="$(run_guard)"
grep -q '^OK: no open same-repository Core PR touches migration history' <<< "$output"

# 3. Strictly-future migration PR: PASS and explicitly classify as future.
write_gh <<GH
#!/usr/bin/env bash
set -euo pipefail
if [[ "\$1 \$2" == "pr list" ]]; then
  for a in "\$@"; do [[ "\$a" == "length" ]] && { echo 1; exit 0; }; done
  echo 202
elif [[ "\$1 \$2" == "pr diff" ]]; then
  echo "supabase/migrations/${future_version}_future_train.sql"
fi
GH
output="$(run_guard)"
grep -q "^FUTURE_MIGRATION_PR_DOES_NOT_BLOCK_RELEASE: PR #202 migration $future_version" <<< "$output"
grep -q '^OK: open future migration PRs exist' <<< "$output"

# 4. Migration at or before the release ceiling: FAIL closed.
write_gh <<GH
#!/usr/bin/env bash
set -euo pipefail
if [[ "\$1 \$2" == "pr list" ]]; then
  for a in "\$@"; do [[ "\$a" == "length" ]] && { echo 1; exit 0; }; done
  echo 203
elif [[ "\$1 \$2" == "pr diff" ]]; then
  echo "supabase/migrations/${past_version}_stale_or_collision.sql"
fi
GH
if run_guard > "$test_root/out.txt" 2>&1; then
  echo "expected FAIL for a migration at/before the release ceiling" >&2
  exit 1
fi
grep -q "^OPEN_MIGRATION_PR_BLOCKS_PRODUCTION_RELEASE: PR #203 migration $past_version" "$test_root/out.txt"

# 5. Modifying an existing migration on main: FAIL.
existing_path="$(find "$repo_root/supabase/migrations" -maxdepth 1 -type f -name '*.sql' | sort | tail -n1)"
existing_rel="supabase/migrations/$(basename "$existing_path")"
write_gh <<GH
#!/usr/bin/env bash
set -euo pipefail
if [[ "\$1 \$2" == "pr list" ]]; then
  for a in "\$@"; do [[ "\$a" == "length" ]] && { echo 1; exit 0; }; done
  echo 204
elif [[ "\$1 \$2" == "pr diff" ]]; then
  echo "$existing_rel"
fi
GH
if run_guard > "$test_root/out.txt" 2>&1; then
  echo "expected FAIL for an existing migration path" >&2
  exit 1
fi
grep -q '^OPEN_MIGRATION_PR_BLOCKS_PRODUCTION_RELEASE: PR #204' "$test_root/out.txt"

# 6. Mixed PRs: future migration is non-blocking, stale migration blocks.
write_gh <<GH
#!/usr/bin/env bash
set -euo pipefail
if [[ "\$1 \$2" == "pr list" ]]; then
  for a in "\$@"; do [[ "\$a" == "length" ]] && { echo 3; exit 0; }; done
  printf '%s\n' 205 206 207
elif [[ "\$1 \$2" == "pr diff" ]]; then
  case "\$3" in
    205) echo README.md ;;
    206) echo "supabase/migrations/${future_version}_future.sql" ;;
    207) echo "supabase/migrations/${past_version}_blocking.sql" ;;
  esac
fi
GH
if run_guard > "$test_root/out.txt" 2>&1; then
  echo "expected FAIL when one PR touches migration history inside the ceiling" >&2
  exit 1
fi
grep -q '^FUTURE_MIGRATION_PR_DOES_NOT_BLOCK_RELEASE: PR #206' "$test_root/out.txt"
grep -q '^OPEN_MIGRATION_PR_BLOCKS_PRODUCTION_RELEASE: PR #207' "$test_root/out.txt"

# 7. Raw PR list reaches PR_LIST_LIMIT: FAIL closed on possible truncation.
write_gh <<'GH'
#!/usr/bin/env bash
set -euo pipefail
if [[ "$1 $2" == "pr list" ]]; then
  for a in "$@"; do [[ "$a" == "length" ]] && { echo 3; exit 0; }; done
  seq 1 3
elif [[ "$1 $2" == "pr diff" ]]; then
  echo README.md
fi
GH
if PR_LIST_LIMIT=3 PATH="$test_root/bin:$PATH" bash "$script" > "$test_root/out.txt" 2>&1; then
  echo "expected FAIL at PR_LIST_LIMIT boundary" >&2
  exit 1
fi
grep -qF 'gh pr list returned 3 open pull requests, which is >= PR_LIST_LIMIT (3)' "$test_root/out.txt"

# 8. Same count under the limit: PASS.
output="$(PR_LIST_LIMIT=1000 run_guard)"
grep -q '^OK: no open same-repository Core PR touches migration history' <<< "$output"

# 9. Fork-only migration PR cannot block production.
write_gh <<GH
#!/usr/bin/env bash
set -euo pipefail
if [[ "\$1 \$2" == "pr list" ]]; then
  for a in "\$@"; do [[ "\$a" == "length" ]] && { echo 1; exit 0; }; done
  :
elif [[ "\$1 \$2" == "pr diff" ]]; then
  echo "supabase/migrations/${past_version}_fork.sql"
fi
GH
output="$(run_guard)"
grep -q '^OK: no open same-repository Core PR touches migration history' <<< "$output"

# 10. Malformed same-repo migration filename: FAIL closed.
write_gh <<'GH'
#!/usr/bin/env bash
set -euo pipefail
if [[ "$1 $2" == "pr list" ]]; then
  for a in "$@"; do [[ "$a" == "length" ]] && { echo 1; exit 0; }; done
  echo 210
elif [[ "$1 $2" == "pr diff" ]]; then
  echo 'supabase/migrations/not_a_timestamp_bad.sql'
fi
GH
if run_guard > "$test_root/out.txt" 2>&1; then
  echo "expected FAIL for malformed migration path" >&2
  exit 1
fi
grep -q '^OPEN_MIGRATION_PR_BLOCKS_PRODUCTION_RELEASE: PR #210 contains malformed migration path' "$test_root/out.txt"

# 11. Explicit ceiling must equal the exact latest migration on the release commit.
write_gh <<'GH'
#!/usr/bin/env bash
set -euo pipefail
if [[ "$1 $2" == "pr list" ]]; then
  for a in "$@"; do [[ "$a" == "length" ]] && { echo 0; exit 0; }; done
  :
fi
GH
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

echo 'verify-check-no-open-migration-prs.sh: all cases passed'

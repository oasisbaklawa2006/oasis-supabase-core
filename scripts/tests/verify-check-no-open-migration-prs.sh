#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
test_root="$(mktemp -d)"
trap 'rm -rf "$test_root"' EXIT

mkdir -p "$test_root/bin"

# --- Static coverage: the script must pass an explicit --limit to
#     `gh pr list`, never relying on gh's default (30) result cap, which
#     would silently stop looking after the 30th open PR. Two separate
#     fixed-string greps (rather than one pattern containing a literal $)
#     avoid a "single quotes don't expand" false positive on a pattern that
#     was never meant to expand.
grep -qF -- 'PR_LIST_LIMIT' "$repo_root/scripts/check-no-open-migration-prs.sh"
grep -qF -- 'pr list' "$repo_root/scripts/check-no-open-migration-prs.sh"
grep -qF -- '--state open --limit' "$repo_root/scripts/check-no-open-migration-prs.sh"
grep -qF -- 'isCrossRepository' "$repo_root/scripts/check-no-open-migration-prs.sh"

# Each stub `gh` below distinguishes the script's two `pr list` calls (a raw
# count via `--jq 'length'` for truncation detection, and a fork-filtered
# `.number` list for the actual scan) by inspecting argv for "length" vs an
# "isCrossRepository" jq expression -- both real, distinct arguments the
# script actually passes, not stub-only shortcuts.

# --- Case 1: zero open PRs -- must PASS.
cat > "$test_root/bin/gh" <<'GH'
#!/usr/bin/env bash
set -euo pipefail
if [[ "$1 $2" == "pr list" ]]; then
  for a in "$@"; do [[ "$a" == "length" ]] && { echo 0; exit 0; }; done
  :
fi
GH
chmod +x "$test_root/bin/gh"

output="$(PATH="$test_root/bin:$PATH" bash "$repo_root/scripts/check-no-open-migration-prs.sh")"
grep -q '^OK: no open Core pull request' <<< "$output"

# --- Case 2: an open code/docs-only PR -- must PASS.
cat > "$test_root/bin/gh" <<'GH'
#!/usr/bin/env bash
set -euo pipefail
if [[ "$1 $2" == "pr list" ]]; then
  for a in "$@"; do [[ "$a" == "length" ]] && { echo 1; exit 0; }; done
  echo "201"
elif [[ "$1 $2" == "pr diff" ]]; then
  case "$3" in
    201)
      printf '%s\n' "README.md" "docs/reconciliation/notes.md"
      ;;
  esac
fi
GH
chmod +x "$test_root/bin/gh"

output="$(PATH="$test_root/bin:$PATH" bash "$repo_root/scripts/check-no-open-migration-prs.sh")"
grep -q '^OK: no open Core pull request' <<< "$output"

# --- Case 3: an open PR ADDING a new migration -- must FAIL closed with the
#     exact sentinel string, no exception of any kind.
cat > "$test_root/bin/gh" <<'GH'
#!/usr/bin/env bash
set -euo pipefail
if [[ "$1 $2" == "pr list" ]]; then
  for a in "$@"; do [[ "$a" == "length" ]] && { echo 1; exit 0; }; done
  echo "202"
elif [[ "$1 $2" == "pr diff" ]]; then
  case "$3" in
    202) echo "supabase/migrations/20260819999999_new_migration.sql" ;;
  esac
fi
GH
chmod +x "$test_root/bin/gh"

if PATH="$test_root/bin:$PATH" bash "$repo_root/scripts/check-no-open-migration-prs.sh" > "$test_root/out.txt" 2>&1; then
  echo "expected FAIL on a new-migration PR, but the guard exited 0" >&2
  cat "$test_root/out.txt" >&2
  exit 1
fi
grep -q '^OPEN_MIGRATION_PR_BLOCKS_PRODUCTION_RELEASE: PR #202' "$test_root/out.txt"

# --- Case 4: an open PR whose migration filename ALREADY EXISTS on main --
#     must still FAIL. The literal conservative policy has no
#     filename-equivalence exception (an identical filename does not prove
#     identical contents -- a stale/rebased branch can still carry
#     migration-history changes).
cat > "$test_root/bin/gh" <<'GH'
#!/usr/bin/env bash
set -euo pipefail
if [[ "$1 $2" == "pr list" ]]; then
  for a in "$@"; do [[ "$a" == "length" ]] && { echo 1; exit 0; }; done
  echo "203"
elif [[ "$1 $2" == "pr diff" ]]; then
  case "$3" in
    203) echo "supabase/migrations/20260819110000_staff_provisioning_authority.sql" ;;
  esac
fi
GH
chmod +x "$test_root/bin/gh"

if PATH="$test_root/bin:$PATH" bash "$repo_root/scripts/check-no-open-migration-prs.sh" > "$test_root/out.txt" 2>&1; then
  echo "expected FAIL even for a filename that already exists on main (no exception), but the guard exited 0" >&2
  cat "$test_root/out.txt" >&2
  exit 1
fi
grep -q '^OPEN_MIGRATION_PR_BLOCKS_PRODUCTION_RELEASE: PR #203' "$test_root/out.txt"

# --- Case 5: an open PR MODIFYING an existing migration file (same
#     mechanism as case 3/4 -- `gh pr diff --name-only` lists the path
#     regardless of add/modify/delete-then-readd; the guard does not
#     distinguish change type, matching the literal "any changed path"
#     policy) -- must FAIL.
cat > "$test_root/bin/gh" <<'GH'
#!/usr/bin/env bash
set -euo pipefail
if [[ "$1 $2" == "pr list" ]]; then
  for a in "$@"; do [[ "$a" == "length" ]] && { echo 1; exit 0; }; done
  echo "204"
elif [[ "$1 $2" == "pr diff" ]]; then
  case "$3" in
    204) echo "supabase/migrations/20260817090000_rgs_department_taxonomy.sql" ;;
  esac
fi
GH
chmod +x "$test_root/bin/gh"

if PATH="$test_root/bin:$PATH" bash "$repo_root/scripts/check-no-open-migration-prs.sh" > "$test_root/out.txt" 2>&1; then
  echo "expected FAIL on a modified-migration PR, but the guard exited 0" >&2
  cat "$test_root/out.txt" >&2
  exit 1
fi
grep -q '^OPEN_MIGRATION_PR_BLOCKS_PRODUCTION_RELEASE: PR #204' "$test_root/out.txt"

# --- Case 6: multiple open PRs, only one migration-bearing -- the guard
#     must not stop at the first PR; it must enumerate all of them and
#     report every blocking one.
cat > "$test_root/bin/gh" <<'GH'
#!/usr/bin/env bash
set -euo pipefail
if [[ "$1 $2" == "pr list" ]]; then
  for a in "$@"; do [[ "$a" == "length" ]] && { echo 3; exit 0; }; done
  printf '%s\n' 205 206 207
elif [[ "$1 $2" == "pr diff" ]]; then
  case "$3" in
    205) echo "README.md" ;;
    206) echo "supabase/migrations/20260819999998_blocking.sql" ;;
    207) echo "docs/runbooks/notes.md" ;;
  esac
fi
GH
chmod +x "$test_root/bin/gh"

if PATH="$test_root/bin:$PATH" bash "$repo_root/scripts/check-no-open-migration-prs.sh" > "$test_root/out.txt" 2>&1; then
  echo "expected FAIL when one of several open PRs is migration-bearing, but the guard exited 0" >&2
  cat "$test_root/out.txt" >&2
  exit 1
fi
grep -q '^OPEN_MIGRATION_PR_BLOCKS_PRODUCTION_RELEASE: PR #206' "$test_root/out.txt"
if grep -qE '^OPEN_MIGRATION_PR_BLOCKS_PRODUCTION_RELEASE: PR #(205|207)' "$test_root/out.txt"; then
  echo "a non-migration-bearing PR was incorrectly flagged as blocking" >&2
  exit 1
fi

# --- Case 7: the RAW PR list returns exactly PR_LIST_LIMIT results -- the
#     guard cannot tell this apart from a truncated (>PR_LIST_LIMIT) list,
#     so it must FAIL closed rather than assume the list was exhaustive,
#     even though every listed PR is migration-free on its own.
cat > "$test_root/bin/gh" <<'GH'
#!/usr/bin/env bash
set -euo pipefail
if [[ "$1 $2" == "pr list" ]]; then
  for a in "$@"; do [[ "$a" == "length" ]] && { echo 3; exit 0; }; done
  seq 1 3
elif [[ "$1 $2" == "pr diff" ]]; then
  echo "README.md"
fi
GH
chmod +x "$test_root/bin/gh"

if PR_LIST_LIMIT=3 PATH="$test_root/bin:$PATH" bash "$repo_root/scripts/check-no-open-migration-prs.sh" > "$test_root/out.txt" 2>&1; then
  echo "expected FAIL when the RAW PR count reaches PR_LIST_LIMIT (possible truncation), but the guard exited 0" >&2
  cat "$test_root/out.txt" >&2
  exit 1
fi
grep -qF 'gh pr list returned 3 open pull requests, which is >= PR_LIST_LIMIT (3)' "$test_root/out.txt"

# --- Case 8: same PR count, but comfortably under the limit -- must PASS,
#     proving case 7 is about the boundary, not about rejecting valid lists.
cat > "$test_root/bin/gh" <<'GH'
#!/usr/bin/env bash
set -euo pipefail
if [[ "$1 $2" == "pr list" ]]; then
  for a in "$@"; do [[ "$a" == "length" ]] && { echo 3; exit 0; }; done
  seq 1 3
elif [[ "$1 $2" == "pr diff" ]]; then
  echo "README.md"
fi
GH
chmod +x "$test_root/bin/gh"

if ! PR_LIST_LIMIT=1000 PATH="$test_root/bin:$PATH" bash "$repo_root/scripts/check-no-open-migration-prs.sh" > "$test_root/out.txt" 2>&1; then
  echo "expected PASS when the returned PR count is well under PR_LIST_LIMIT" >&2
  cat "$test_root/out.txt" >&2
  exit 1
fi
grep -q '^OK: no open Core pull request' "$test_root/out.txt"

# --- Case 9: a migration-bearing PR exists ONLY as a fork (cross-repository)
#     PR -- must PASS. "Core pull request" means same-repo; an untrusted
#     fork PR must not be able to block production releases just by adding a
#     supabase/migrations/*.sql file (availability attack on a public repo).
cat > "$test_root/bin/gh" <<'GH'
#!/usr/bin/env bash
set -euo pipefail
if [[ "$1 $2" == "pr list" ]]; then
  for a in "$@"; do [[ "$a" == "length" ]] && { echo 1; exit 0; }; done
  # Fork PR #208 is excluded from the fork-filtered list entirely -- the
  # script's own isCrossRepository==false select never returns it.
  :
elif [[ "$1 $2" == "pr diff" ]]; then
  case "$3" in
    208) echo "supabase/migrations/20260819999997_fork_migration.sql" ;;
  esac
fi
GH
chmod +x "$test_root/bin/gh"

output="$(PATH="$test_root/bin:$PATH" bash "$repo_root/scripts/check-no-open-migration-prs.sh")"
grep -q '^OK: no open Core pull request' <<< "$output"

# --- Case 10: a fork PR AND a same-repo migration-bearing PR are both open
#     -- must FAIL on the same-repo PR only, proving the fork exclusion
#     doesn't accidentally swallow real same-repo findings.
cat > "$test_root/bin/gh" <<'GH'
#!/usr/bin/env bash
set -euo pipefail
if [[ "$1 $2" == "pr list" ]]; then
  for a in "$@"; do [[ "$a" == "length" ]] && { echo 2; exit 0; }; done
  # Only the same-repo PR (#209) survives the isCrossRepository==false
  # filter; fork PR #208 does not appear here.
  echo "209"
elif [[ "$1 $2" == "pr diff" ]]; then
  case "$3" in
    209) echo "supabase/migrations/20260819999996_same_repo.sql" ;;
    208) echo "supabase/migrations/20260819999997_fork_migration.sql" ;;
  esac
fi
GH
chmod +x "$test_root/bin/gh"

if PATH="$test_root/bin:$PATH" bash "$repo_root/scripts/check-no-open-migration-prs.sh" > "$test_root/out.txt" 2>&1; then
  echo "expected FAIL on the same-repo migration-bearing PR, but the guard exited 0" >&2
  cat "$test_root/out.txt" >&2
  exit 1
fi
grep -q '^OPEN_MIGRATION_PR_BLOCKS_PRODUCTION_RELEASE: PR #209' "$test_root/out.txt"
if grep -q 'PR #208' "$test_root/out.txt"; then
  echo "the fork PR (#208) was queried/flagged even though it must be excluded before any pr diff call" >&2
  exit 1
fi

echo "verify-check-no-open-migration-prs.sh: all cases passed"

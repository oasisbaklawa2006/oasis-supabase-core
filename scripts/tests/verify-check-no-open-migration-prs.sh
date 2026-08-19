#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
test_root="$(mktemp -d)"
trap 'rm -rf "$test_root"' EXIT

mkdir -p "$test_root/bin"

# --- Static coverage: the script must pass an explicit --limit to
#     `gh pr list`, never relying on gh's default (30) result cap, which
#     would silently stop looking after the 30th open PR.
grep -q -- '--limit "$PR_LIST_LIMIT"' "$repo_root/scripts/check-no-open-migration-prs.sh"

# --- Case 1: zero open PRs -- must PASS.
cat > "$test_root/bin/gh" <<'GH'
#!/usr/bin/env bash
set -euo pipefail
if [[ "$1 $2" == "pr list" ]]; then
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

echo "verify-check-no-open-migration-prs.sh: all cases passed"

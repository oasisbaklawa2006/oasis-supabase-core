#!/usr/bin/env bash
set -euo pipefail

# PRODUCTION MIGRATION INVARIANT extension (Central issue #368 migration-train
# normalization). A production migration release must fail closed if any OPEN
# pull request on this repository introduces a supabase/migrations/*.sql file
# that is not already present in the migrations directory checked out here --
# i.e. a migration that exists only in an unmerged PR, not yet canonical on
# main. This closes a gap the original PRODUCTION MIGRATION INVARIANT (commit
# on main, applied only from main) does not cover on its own: an unmerged PR
# can reserve a migration timestamp that a later production release could
# otherwise race past or shadow.
#
# Runs at production preflight and again immediately before write (both
# production-migration-release.yml jobs call this script). Conservative
# policy: no production migration deployment while ANY unmerged
# migration-bearing Core PR exists, regardless of that PR's own base branch,
# draft state, or CI status. Never auto-closes, retimestamps, reconciles, or
# forward-copies anything -- it only reports and fails.

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
MIGRATIONS_DIR="${MIGRATIONS_DIR:-$repo_root/supabase/migrations}"
GH_BIN="${GH_BIN:-gh}"
REPO_SLUG="${REPO_SLUG:-oasisbaklawa2006/oasis-supabase-core}"

if ! command -v "$GH_BIN" >/dev/null 2>&1; then
  echo "ERROR: '$GH_BIN' CLI not found on PATH -- cannot verify open migration-bearing PRs" >&2
  exit 1
fi

if [[ ! -d "$MIGRATIONS_DIR" ]]; then
  echo "ERROR: migrations directory not found at $MIGRATIONS_DIR" >&2
  exit 1
fi

pr_numbers="$("$GH_BIN" pr list --repo "$REPO_SLUG" --state open --json number --jq '.[].number')"

blocking_found=0
while IFS= read -r pr_number; do
  [[ -n "$pr_number" ]] || continue
  changed_files="$("$GH_BIN" pr diff "$pr_number" --repo "$REPO_SLUG" --name-only)"
  while IFS= read -r file; do
    [[ "$file" == supabase/migrations/*.sql ]] || continue
    filename="$(basename "$file")"
    if [[ ! -f "$MIGRATIONS_DIR/$filename" ]]; then
      echo "OPEN_MIGRATION_PR_BLOCKS_PRODUCTION_RELEASE: PR #$pr_number introduces $file, not present on the checked-out main" >&2
      blocking_found=1
    fi
  done <<< "$changed_files"
done <<< "$pr_numbers"

if [[ "$blocking_found" -eq 1 ]]; then
  echo "FAIL: one or more open Core pull requests contain an unmerged supabase/migrations/*.sql file. Merge or close them before any production migration release. See PRODUCTION MIGRATION INVARIANT in the release runbook." >&2
  exit 1
fi

echo "OK: no open Core pull request contains an unmerged supabase/migrations/*.sql file."

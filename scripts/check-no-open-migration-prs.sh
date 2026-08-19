#!/usr/bin/env bash
set -euo pipefail

# PRODUCTION MIGRATION INVARIANT extension (Central issue #368 migration-train
# normalization). A production migration release must fail closed if ANY OPEN
# pull request on this repository has ANY changed path matching
# supabase/migrations/*.sql. This closes a gap the original PRODUCTION
# MIGRATION INVARIANT (commit on main, applied only from main) does not cover
# on its own: an unmerged PR can reserve a migration timestamp that a later
# production release could otherwise race past or shadow.
#
# Literal, conservative policy -- NO PRODUCTION MIGRATION DEPLOYMENT WHILE ANY
# UNMERGED MIGRATION-BEARING CORE PR EXISTS. Deliberately no exception for a
# changed file whose filename happens to already exist on main: an identical
# filename does not prove identical contents (a stale or rebased PR branch
# can still carry migration-history changes), and there is no operational
# need to deploy production while any migration-bearing Core PR remains
# open -- merging or closing it costs nothing a real release schedule can't
# absorb.
#
# Runs at production preflight and again immediately before write (both
# production-migration-release.yml jobs call this script). Applies regardless
# of a flagged PR's own base branch, draft state, or CI status. Never
# auto-closes, retimestamps, reconciles, or forward-copies anything -- it
# only reports and fails.

GH_BIN="${GH_BIN:-gh}"
# GITHUB_REPOSITORY is set automatically by GitHub Actions to the exact repo
# this workflow run is executing against, so prefer it over the hardcoded
# fallback -- keeps this script correct if the repo is ever renamed, without
# giving up the explicit override.
REPO_SLUG="${REPO_SLUG:-${GITHUB_REPOSITORY:-oasisbaklawa2006/oasis-supabase-core}}"
# gh pr list defaults to 30 results -- an explicit, deliberately exhaustive
# bound is required so this guard can never silently stop looking after the
# 30th open PR. 1000 is far beyond any plausible open-PR count for this repo;
# raise it before it could ever be reached in practice, not after.
PR_LIST_LIMIT="${PR_LIST_LIMIT:-1000}"

if ! command -v "$GH_BIN" >/dev/null 2>&1; then
  echo "ERROR: '$GH_BIN' CLI not found on PATH -- cannot verify open migration-bearing PRs" >&2
  exit 1
fi

pr_numbers="$("$GH_BIN" pr list --repo "$REPO_SLUG" --state open --limit "$PR_LIST_LIMIT" --json number --jq '.[].number')"

blocking_found=0
while IFS= read -r pr_number; do
  [[ -n "$pr_number" ]] || continue
  changed_files="$("$GH_BIN" pr diff "$pr_number" --repo "$REPO_SLUG" --name-only)"
  while IFS= read -r file; do
    [[ "$file" = supabase/migrations/*.sql ]] || continue
    echo "OPEN_MIGRATION_PR_BLOCKS_PRODUCTION_RELEASE: PR #$pr_number has a changed path matching supabase/migrations/*.sql ($file)" >&2
    blocking_found=1
  done <<< "$changed_files"
done <<< "$pr_numbers"

if [[ "$blocking_found" -eq 1 ]]; then
  echo "FAIL: one or more open Core pull requests contain a supabase/migrations/*.sql change. Merge or close them before any production migration release. See PRODUCTION MIGRATION INVARIANT in the release runbook." >&2
  exit 1
fi

echo "OK: no open Core pull request has any changed path matching supabase/migrations/*.sql."

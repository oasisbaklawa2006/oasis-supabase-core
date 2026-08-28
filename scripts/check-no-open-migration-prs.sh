#!/usr/bin/env bash
set -euo pipefail

# PRODUCTION MIGRATION INVARIANT extension.
#
# A production release is bounded by the latest canonical migration version on
# the exact Core commit being released. Open same-repository PRs only block the
# release when they touch migration history at or below that release ceiling.
# A strictly later migration belongs to a future train and must not paralyse
# deployment of an already-merged earlier train.
#
# This preserves the original fail-closed protections against stale branches,
# timestamp collisions, historical rewrites and malformed migration paths while
# removing the availability failure caused by the former blanket "any open
# migration PR blocks production" rule.
#
# The production overlay currently applies every pending migration present on
# the checked-out release commit. Therefore an explicit
# RELEASE_MIGRATION_CEILING, when supplied, MUST equal the latest canonical
# migration version on that exact commit; lower/partial ceilings are rejected.

GH_BIN="${GH_BIN:-gh}"
REPO_SLUG="${REPO_SLUG:-${GITHUB_REPOSITORY:-oasisbaklawa2006/oasis-supabase-core}}"
PR_LIST_LIMIT="${PR_LIST_LIMIT:-1000}"
MIGRATIONS_DIR="${MIGRATIONS_DIR:-supabase/migrations}"
MIGRATIONS_DIR="${MIGRATIONS_DIR%/}"

if ! command -v "$GH_BIN" >/dev/null 2>&1; then
  echo "ERROR: '$GH_BIN' CLI not found on PATH -- cannot verify open migration-bearing PRs" >&2
  exit 1
fi

# PR diffs return repository-relative paths. Keep the configurable migration
# directory repository-relative as well so the exact same authority path is
# used for both the checked-out release commit and open-PR collision scanning.
if [[ -z "$MIGRATIONS_DIR" || "$MIGRATIONS_DIR" = /* || "$MIGRATIONS_DIR" = ".." || "$MIGRATIONS_DIR" = ../* || "$MIGRATIONS_DIR" = */../* || "$MIGRATIONS_DIR" = */.. ]]; then
  echo "FAIL: MIGRATIONS_DIR must be a non-empty repository-relative path without '..'; got '$MIGRATIONS_DIR'" >&2
  exit 1
fi

if [[ ! -d "$MIGRATIONS_DIR" ]]; then
  echo "FAIL: canonical migrations directory '$MIGRATIONS_DIR' does not exist on the release commit" >&2
  exit 1
fi

# Build the canonical version set from the exact checked-out release commit.
# Duplicate or malformed local migration versions are a hard stop here even
# though migration governance should already have rejected them earlier.
declare -A local_version_paths=()
latest_local_version=""
local_migration_count=0
shopt -s nullglob
local_migration_paths=("$MIGRATIONS_DIR"/*.sql)
shopt -u nullglob

for path in "${local_migration_paths[@]}"; do
  file="$(basename "$path")"
  if [[ ! "$file" =~ ^([0-9]{14})_.+\.sql$ ]]; then
    echo "FAIL: malformed canonical migration filename on release commit: $path" >&2
    exit 1
  fi

  version="${BASH_REMATCH[1]}"
  if [[ -n "${local_version_paths[$version]:-}" ]]; then
    echo "FAIL: duplicate canonical migration version $version on release commit: ${local_version_paths[$version]} and $path" >&2
    exit 1
  fi

  local_version_paths[$version]="$path"
  local_migration_count=$((local_migration_count + 1))
  if [[ -z "$latest_local_version" || "$version" > "$latest_local_version" ]]; then
    latest_local_version="$version"
  fi
done

if [[ "$local_migration_count" -eq 0 || -z "$latest_local_version" ]]; then
  echo "FAIL: no canonical migrations found in '$MIGRATIONS_DIR' -- release ceiling cannot be established" >&2
  exit 1
fi

release_ceiling="${RELEASE_MIGRATION_CEILING:-$latest_local_version}"
if [[ ! "$release_ceiling" =~ ^[0-9]{14}$ ]]; then
  echo "FAIL: RELEASE_MIGRATION_CEILING must be exactly 14 digits; got '$release_ceiling'" >&2
  exit 1
fi

# The current overlay is intentionally all-pending, not partial. Refuse an
# operator-supplied ceiling that is anything other than the exact latest
# migration on the approved release commit.
if [[ "$release_ceiling" != "$latest_local_version" ]]; then
  echo "FAIL: RELEASE_MIGRATION_CEILING ($release_ceiling) does not equal the latest canonical migration on the exact release commit ($latest_local_version). Partial or future ceilings are not supported by the all-pending production overlay." >&2
  exit 1
fi

echo "RELEASE_MIGRATION_CEILING: $release_ceiling"

# gh pr list defaults to 30 results. Keep an explicit exhaustive bound and
# fail closed if the result reaches that bound because it may be truncated.
raw_pr_count="$("$GH_BIN" pr list --repo "$REPO_SLUG" --state open --limit "$PR_LIST_LIMIT" --json number --jq 'length')"
if [[ "$raw_pr_count" -ge "$PR_LIST_LIMIT" ]]; then
  echo "FAIL: gh pr list returned $raw_pr_count open pull requests, which is >= PR_LIST_LIMIT ($PR_LIST_LIMIT) -- the list may be truncated and cannot be trusted as exhaustive. Raise PR_LIST_LIMIT and re-run before any production migration release." >&2
  exit 1
fi

# Only same-repository PRs participate in this guard. A fork PR must never be
# able to create a production-release availability attack by adding a fake
# migration path.
pr_numbers="$("$GH_BIN" pr list --repo "$REPO_SLUG" --state open --limit "$PR_LIST_LIMIT" --json number,isCrossRepository --jq '.[] | select(.isCrossRepository == false) | .number')"

blocking_found=0
future_found=0
while IFS= read -r pr_number; do
  [[ -n "$pr_number" ]] || continue
  changed_files="$("$GH_BIN" pr diff "$pr_number" --repo "$REPO_SLUG" --name-only)"

  while IFS= read -r file; do
    [[ "$file" = "$MIGRATIONS_DIR"/*.sql ]] || continue

    migration_file="$(basename "$file")"
    if [[ ! "$migration_file" =~ ^([0-9]{14})_.+\.sql$ ]]; then
      echo "OPEN_MIGRATION_PR_BLOCKS_PRODUCTION_RELEASE: PR #$pr_number contains malformed migration path '$file'; cannot prove it is outside release ceiling $release_ceiling" >&2
      blocking_found=1
      continue
    fi

    version="${BASH_REMATCH[1]}"
    if [[ "$version" > "$release_ceiling" ]]; then
      echo "FUTURE_MIGRATION_PR_DOES_NOT_BLOCK_RELEASE: PR #$pr_number migration $version is strictly after release ceiling $release_ceiling ($file)"
      future_found=1
      continue
    fi

    echo "OPEN_MIGRATION_PR_BLOCKS_PRODUCTION_RELEASE: PR #$pr_number migration $version is at or before release ceiling $release_ceiling ($file)" >&2
    blocking_found=1
  done <<< "$changed_files"
done <<< "$pr_numbers"

if [[ "$blocking_found" -eq 1 ]]; then
  echo "FAIL: one or more open same-repository Core PRs touch migration history at or before RELEASE_MIGRATION_CEILING=$release_ceiling. Merge, close, or retimestamp only through normal reviewed migration governance before deploying this train." >&2
  exit 1
fi

if [[ "$future_found" -eq 1 ]]; then
  echo "OK: open future migration PRs exist, but all are strictly after RELEASE_MIGRATION_CEILING=$release_ceiling and do not block this release train."
else
  echo "OK: no open same-repository Core PR touches migration history at or before RELEASE_MIGRATION_CEILING=$release_ceiling."
fi

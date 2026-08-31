#!/usr/bin/env bash
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

base_ref="${1:-${BASE_REF:-}}"
migrations_dir="${MIGRATIONS_DIR:-supabase/migrations}"
preview_ledger_compat_file="${PREVIEW_MIGRATION_LEDGER_COMPAT_FILE:-supabase/preview-migration-ledger-compat.txt}"
violations=0

declare -A preview_ledger_compat_versions=()
if [[ -f "$preview_ledger_compat_file" ]]; then
  while IFS= read -r compat_line; do
    [[ -z "$compat_line" || "$compat_line" =~ ^[[:space:]]*# ]] && continue
    compat_version="${compat_line%%#*}"
    compat_version="$(printf '%s' "$compat_version" | tr -d '[:space:]')"
    [[ "$compat_version" =~ ^[0-9]{14}$ ]] || continue
    preview_ledger_compat_versions["$compat_version"]=1
  done < "$preview_ledger_compat_file"
fi

fail() {
  echo "MIGRATION BASE MONOTONICITY VIOLATION: $*" >&2
  violations=$((violations + 1))
}

if [[ -z "$base_ref" ]]; then
  if git rev-parse --verify HEAD^ >/dev/null 2>&1; then
    base_ref='HEAD^'
  else
    echo 'Migration base monotonicity: no parent/base commit exists; nothing to compare.'
    exit 0
  fi
fi

if ! git rev-parse --verify "${base_ref}^{commit}" >/dev/null 2>&1; then
  echo "MIGRATION BASE MONOTONICITY VIOLATION: target base ref cannot be resolved: $base_ref" >&2
  exit 1
fi

# MIGRATIONS_DIR must be a repository-relative directory. This mirrors the
# release-ceiling guard and prevents path traversal from weakening enforcement.
if [[ "$migrations_dir" = /* || "$migrations_dir" == '..' || "$migrations_dir" == ../* || "$migrations_dir" == */../* || "$migrations_dir" == */.. ]]; then
  echo "MIGRATION BASE MONOTONICITY VIOLATION: MIGRATIONS_DIR must be repository-relative without '..': $migrations_dir" >&2
  exit 1
fi
migrations_dir="${migrations_dir%/}"
[[ -n "$migrations_dir" ]] || { echo 'MIGRATION BASE MONOTONICITY VIOLATION: MIGRATIONS_DIR is empty' >&2; exit 1; }

merge_base="$(git merge-base "$base_ref" HEAD)"

# Build the authoritative timestamp inventory from the CURRENT target base,
# not merely the branch's historical merge-base. Historical names only need
# the release guard's non-empty suffix contract; newer migrations are held to
# the stricter snake_case contract below. Crucially, malformed target-base SQL
# files fail closed rather than disappearing from the ceiling calculation.
declare -A base_versions=()
latest_base_version=''
while IFS= read -r path; do
  [[ -n "$path" ]] || continue
  file="$(basename "$path")"
  if [[ ! "$file" =~ ^([0-9]{14})_(.+)\.sql$ ]]; then
    fail "target base contains malformed canonical migration filename: $path"
    continue
  fi

  version="${BASH_REMATCH[1]}"
  if [[ -n "${base_versions[$version]:-}" ]]; then
    fail "target base contains duplicate migration version $version (${base_versions[$version]} and $path)"
  else
    base_versions[$version]="$path"
  fi
  if [[ -z "$latest_base_version" || "$version" > "$latest_base_version" ]]; then
    latest_base_version="$version"
  fi
done < <(git ls-tree -r --name-only "$base_ref" -- "$migrations_dir" | grep -E '\.sql$' | LC_ALL=C sort)

if [[ -z "$latest_base_version" ]]; then
  fail "target base $base_ref has no valid timestamped migrations under $migrations_dir"
fi

# Examine ONLY changes introduced by this branch since its merge-base with the
# current target base. Base-side changes are intentionally excluded, while the
# current base's latest timestamp above still defines the release ceiling.
mapfile -t changes < <(git diff --name-status --find-renames "$merge_base" HEAD -- "$migrations_dir")

new_paths=()
for entry in "${changes[@]}"; do
  [[ -n "$entry" ]] || continue
  IFS=$'\t' read -r status path1 path2 <<< "$entry"

  case "$status" in
    A)
      [[ "$path1" == *.sql ]] && new_paths+=("$path1")
      ;;
    M|D)
      if [[ "$path1" == *.sql ]]; then
        # A file present at merge-base is immutable history for this PR. It may
        # be pending or already production-applied; corrections require a new
        # forward migration, never an edit/delete of the old file.
        if git cat-file -e "$merge_base:$path1" 2>/dev/null; then
          fail "$status of migration already present on PR base: $path1"
        fi
      fi
      ;;
    R*)
      if [[ "$path1" == *.sql || "$path2" == *.sql ]]; then
        fail "rename of migration history is forbidden: $path1 -> $path2"
      fi
      ;;
    C*)
      [[ "$path2" == *.sql ]] && new_paths+=("$path2")
      ;;
    *)
      # Unknown git status involving migrations is safer to reject than to
      # silently bypass history immutability.
      if [[ "$path1" == *.sql || "${path2:-}" == *.sql ]]; then
        fail "unsupported migration change status '$status' for $path1 ${path2:-}"
      fi
      ;;
  esac
done

declare -A new_versions=()
for path in "${new_paths[@]}"; do
  [[ -f "$path" ]] || { fail "new migration path is missing from working tree: $path"; continue; }
  file="$(basename "$path")"
  if [[ ! "$file" =~ ^([0-9]{14})_([a-z0-9_]+)\.sql$ ]]; then
    fail "new migration must match YYYYMMDDHHMMSS_snake_case.sql: $file"
    continue
  fi
  version="${BASH_REMATCH[1]}"

  if [[ -n "${new_versions[$version]:-}" ]]; then
    fail "new migration version $version is duplicated by ${new_versions[$version]} and $path"
  else
    new_versions[$version]="$path"
  fi

  if [[ -n "${base_versions[$version]:-}" ]]; then
    fail "new migration $path collides with target-base migration version $version (${base_versions[$version]})"
  fi

  if [[ -n "${preview_ledger_compat_versions[$version]:-}" ]]; then
    if ! grep -Fq 'Preview ledger compatibility' "$path"; then
      fail "preview ledger compat migration $path must contain 'Preview ledger compatibility' marker comment"
    fi
    if grep -Eiq '(^|[[:space:]])(create|alter|drop|insert|update|delete|truncate)[[:space:]]' "$path"; then
      fail "preview ledger compat migration $path must be a no-op stub (select 1 only)"
    fi
    if ! grep -Fq 'select 1;' "$path"; then
      fail "preview ledger compat migration $path must include select 1; no-op marker"
    fi
    continue
  fi

  if [[ -n "$latest_base_version" && ( "$version" < "$latest_base_version" || "$version" == "$latest_base_version" ) ]]; then
    fail "new migration $path version $version is not strictly greater than current target-base ceiling $latest_base_version; rebase and create a newer forward migration"
  fi
done

if ((violations > 0)); then
  echo "Migration base monotonicity check FAILED ($violations violation(s))." >&2
  exit 1
fi

echo "Migration base monotonicity check passed: target=$base_ref merge-base=$merge_base ceiling=${latest_base_version:-none}; ${#new_paths[@]} new migration(s)."

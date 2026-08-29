#!/usr/bin/env bash
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

activation_ref="${1:-${MIGRATION_DISCIPLINE_BASE_REF:-}}"
migrations_dir="${MIGRATIONS_DIR:-supabase/migrations}"
violations=0

fail() {
  echo "MIGRATION HISTORY SEQUENCE VIOLATION: $*" >&2
  violations=$((violations + 1))
}

[[ -n "$activation_ref" ]] || { echo 'MIGRATION HISTORY SEQUENCE VIOLATION: activation ref is required' >&2; exit 1; }
if ! git rev-parse --verify "${activation_ref}^{commit}" >/dev/null 2>&1; then
  echo "MIGRATION HISTORY SEQUENCE VIOLATION: activation ref cannot be resolved: $activation_ref" >&2
  exit 1
fi
if ! git merge-base --is-ancestor "$activation_ref" HEAD; then
  echo "MIGRATION HISTORY SEQUENCE VIOLATION: activation ref $activation_ref is not an ancestor of HEAD" >&2
  exit 1
fi

if [[ "$migrations_dir" = /* || "$migrations_dir" == '..' || "$migrations_dir" == ../* || "$migrations_dir" == */../* || "$migrations_dir" == */.. ]]; then
  echo "MIGRATION HISTORY SEQUENCE VIOLATION: MIGRATIONS_DIR must be repository-relative without '..': $migrations_dir" >&2
  exit 1
fi
migrations_dir="${migrations_dir%/}"
[[ -n "$migrations_dir" ]] || { echo 'MIGRATION HISTORY SEQUENCE VIOLATION: MIGRATIONS_DIR is empty' >&2; exit 1; }

# Seed the version inventory and ceiling from the immutable post-recovery
# activation commit. Historical filenames use the release guard's non-empty
# suffix contract so recovered legacy names are accepted but malformed SQL
# paths never disappear from the ceiling calculation.
declare -A known_versions=()
ceiling=''
while IFS= read -r path; do
  [[ -n "$path" ]] || continue
  file="$(basename "$path")"
  if [[ ! "$file" =~ ^([0-9]{14})_(.+)\.sql$ ]]; then
    fail "activation base contains malformed canonical migration filename: $path"
    continue
  fi
  version="${BASH_REMATCH[1]}"
  if [[ -n "${known_versions[$version]:-}" ]]; then
    fail "activation base contains duplicate migration version $version (${known_versions[$version]} and $path)"
  else
    known_versions[$version]="$path"
  fi
  if [[ -z "$ceiling" || "$version" > "$ceiling" ]]; then
    ceiling="$version"
  fi
done < <(git ls-tree -r --name-only "$activation_ref" -- "$migrations_dir" | grep -E '\.sql$' | LC_ALL=C sort)

[[ -n "$ceiling" ]] || fail "activation base $activation_ref has no valid timestamped migrations under $migrations_dir"

# Walk every commit introduced after the activation point in topological order.
# Each commit is compared with its first parent, which is the canonical mainline
# state being advanced. A merge/squash that brings migrations in is therefore
# checked as one atomic migration train against the prior mainline ceiling.
mapfile -t commits < <(git rev-list --reverse --topo-order "$activation_ref"..HEAD)
for commit in "${commits[@]}"; do
  parent="$(git rev-parse "${commit}^1")"
  mapfile -t changes < <(git diff --name-status --find-renames "$parent" "$commit" -- "$migrations_dir")
  added_paths=()

  for entry in "${changes[@]}"; do
    [[ -n "$entry" ]] || continue
    IFS=$'\t' read -r status path1 path2 <<< "$entry"
    case "$status" in
      A)
        [[ "$path1" == *.sql ]] && added_paths+=("$path1")
        ;;
      C*)
        [[ "$path2" == *.sql ]] && added_paths+=("$path2")
        ;;
      M|D)
        [[ "$path1" == *.sql ]] && fail "$status of canonical migration history in commit $commit: $path1"
        ;;
      R*)
        if [[ "$path1" == *.sql || "$path2" == *.sql ]]; then
          fail "rename of canonical migration history in commit $commit: $path1 -> $path2"
        fi
        ;;
      *)
        if [[ "$path1" == *.sql || "${path2:-}" == *.sql ]]; then
          fail "unsupported migration change status '$status' in commit $commit: $path1 ${path2:-}"
        fi
        ;;
    esac
  done

  # Sort additions by filename so multiple migrations in one atomic commit form
  # a deterministic strictly-increasing train.
  if ((${#added_paths[@]} > 0)); then
    mapfile -t added_paths < <(printf '%s\n' "${added_paths[@]}" | LC_ALL=C sort)
  fi

  for path in "${added_paths[@]}"; do
    file="$(basename "$path")"
    if [[ ! "$file" =~ ^([0-9]{14})_([a-z0-9_]+)\.sql$ ]]; then
      fail "new migration in commit $commit must match YYYYMMDDHHMMSS_snake_case.sql: $file"
      continue
    fi
    version="${BASH_REMATCH[1]}"

    if [[ -n "${known_versions[$version]:-}" ]]; then
      fail "migration version $version in commit $commit collides with ${known_versions[$version]} ($path)"
      continue
    fi
    if [[ -n "$ceiling" && ( "$version" < "$ceiling" || "$version" == "$ceiling" ) ]]; then
      fail "migration $path in commit $commit version $version is not strictly greater than prior canonical ceiling $ceiling"
      continue
    fi

    known_versions[$version]="$path"
    ceiling="$version"
  done
done

if ((violations > 0)); then
  echo "Migration history sequence check FAILED ($violations violation(s))." >&2
  exit 1
fi

echo "Migration history sequence check passed: activation=$activation_ref final_ceiling=$ceiling commits_checked=${#commits[@]}."

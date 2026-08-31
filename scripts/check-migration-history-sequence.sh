#!/usr/bin/env bash
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

activation_ref="${1:-${MIGRATION_DISCIPLINE_BASE_REF:-}}"
migrations_dir="${MIGRATIONS_DIR:-supabase/migrations}"
preview_ledger_compat_file="${PREVIEW_MIGRATION_LEDGER_COMPAT_FILE:-supabase/preview-migration-ledger-compat.txt}"
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

if [[ "$preview_ledger_compat_file" = /* || "$preview_ledger_compat_file" == '..' || "$preview_ledger_compat_file" == ../* || "$preview_ledger_compat_file" == */../* || "$preview_ledger_compat_file" == */.. ]]; then
  echo "MIGRATION HISTORY SEQUENCE VIOLATION: PREVIEW_MIGRATION_LEDGER_COMPAT_FILE must be repository-relative without '..': $preview_ledger_compat_file" >&2
  exit 1
fi

# Preview branches can retain migration ledger versions that were applied before
# a forward migration was resequenced above a newer canonical mainline ceiling.
# Those historical versions are represented in Core by explicit no-op stubs.
# The current compatibility inventory may recognize such a historical stub only
# when the file as INTRODUCED in that exact commit is provably inert. This keeps
# the exception useful for preview ledgers without allowing a later ledger edit
# to whitewash a real historical schema mutation.
declare -A preview_ledger_compat_versions=()
if [[ -f "$preview_ledger_compat_file" ]]; then
  while IFS= read -r compat_line || [[ -n "$compat_line" ]]; do
    [[ -z "$compat_line" || "$compat_line" =~ ^[[:space:]]*# ]] && continue
    compat_version="${compat_line%%#*}"
    compat_version="$(printf '%s' "$compat_version" | tr -d '[:space:]')"
    [[ -z "$compat_version" ]] && continue
    if [[ ! "$compat_version" =~ ^[0-9]{14}$ ]]; then
      fail "preview ledger compatibility entry must be exactly 14 digits: $compat_line"
      continue
    fi
    if [[ -n "${preview_ledger_compat_versions[$compat_version]:-}" ]]; then
      fail "duplicate preview ledger compatibility version: $compat_version"
      continue
    fi
    preview_ledger_compat_versions["$compat_version"]=1
  done < "$preview_ledger_compat_file"
fi

validate_preview_compat_stub() {
  local commit="$1" path="$2" version="$3"
  local content executable_sql

  if ! content="$(git show "${commit}:${path}" 2>/dev/null)"; then
    fail "preview ledger compatibility migration $path cannot be read from introducing commit $commit"
    return 1
  fi

  if ! grep -Fq 'Preview ledger compatibility' <<<"$content"; then
    fail "preview ledger compatibility migration $path must contain 'Preview ledger compatibility' marker comment in introducing commit $commit"
    return 1
  fi

  # Strip line comments and normalize whitespace. The only executable SQL an
  # exempt historical compatibility file may contain is the exact inert marker
  # `select 1;`. Anything else fails closed, including DDL/DML hidden behind a
  # version that happens to appear in the compatibility inventory.
  executable_sql="$(printf '%s\n' "$content" \
    | sed -E 's/--.*$//' \
    | tr '\n' ' ' \
    | sed -E 's/[[:space:]]+/ /g; s/^ //; s/ $//')"
  if [[ "$executable_sql" != 'select 1;' ]]; then
    fail "preview ledger compatibility migration $path version $version must be an exact no-op stub (comments plus select 1;) in introducing commit $commit"
    return 1
  fi

  return 0
}

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
  # a deterministic strictly-increasing train. Preview compatibility stubs are
  # validated below but deliberately do not advance the canonical schema ceiling.
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

    if [[ -n "${preview_ledger_compat_versions[$version]:-}" ]]; then
      if ! validate_preview_compat_stub "$commit" "$path" "$version"; then
        : # validate_preview_compat_stub records the fail-closed violation.
      fi
      known_versions[$version]="$path"
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

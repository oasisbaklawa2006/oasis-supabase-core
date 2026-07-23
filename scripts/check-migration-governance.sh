#!/usr/bin/env bash
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

base_ref="${1:-}"
violations=0

fail() {
  echo "MIGRATION GOVERNANCE VIOLATION: $*"
  violations=$((violations + 1))
}

mapfile -t migrations < <(find supabase/migrations -maxdepth 1 -type f -name '*.sql' -printf '%f\n' | sort)

if [ "${#migrations[@]}" -eq 0 ]; then
  fail "no migration files found"
fi

declare -A versions=()
declare -A names=()
for file in "${migrations[@]}"; do
  if [[ ! "$file" =~ ^([0-9]{14})_([a-z0-9_]+)\.sql$ ]]; then
    fail "$file must match YYYYMMDDHHMMSS_snake_case.sql"
    continue
  fi
  version="${BASH_REMATCH[1]}"
  name="${BASH_REMATCH[2]}"
  if [[ -n "${versions[$version]:-}" ]]; then
    fail "duplicate migration version $version in ${versions[$version]} and $file"
  fi
  if [[ -n "${names[$name]:-}" ]]; then
    fail "duplicate migration name $name in ${names[$name]} and $file"
  fi
  versions[$version]="$file"
  names[$name]="$file"

  path="supabase/migrations/$file"
  if LC_ALL=C grep -q $'\r' "$path"; then
    fail "$file contains CRLF line endings"
  fi
  if head -c3 "$path" | od -An -tx1 | tr -d ' \n' | grep -qi '^efbbbf$'; then
    fail "$file contains a UTF-8 BOM"
  fi
  if grep -Eiq '(^|[^a-z_])supabase_migrations\.' "$path"; then
    fail "$file writes or depends directly on Supabase migration internals"
  fi
done

changed=()
if [[ -n "$base_ref" ]] && git rev-parse --verify "$base_ref" >/dev/null 2>&1; then
  mapfile -t changed < <(git diff --name-only --diff-filter=ACMR "$base_ref"...HEAD -- 'supabase/migrations/*.sql')
else
  mapfile -t changed < <(git diff-tree --no-commit-id --name-only -r HEAD -- 'supabase/migrations/*.sql' || true)
fi

for path in "${changed[@]}"; do
  [[ -f "$path" ]] || continue
  file="$(basename "$path")"
  stem="${file%.sql}"
  version="${stem%%_*}"
  name="${stem#*_}"

  test_match=""
  while IFS= read -r candidate; do
    if grep -Fq "$version" "$candidate" || grep -Fq "$name" "$candidate"; then
      test_match="$candidate"
      break
    fi
  done < <(find supabase/tests -maxdepth 1 -type f -name '*.sql' 2>/dev/null | sort)

  if [[ -z "$test_match" ]]; then
    fail "$file has no SQL contract test referencing migration version or name"
  fi

  if grep -Eiq 'security[[:space:]]+definer' "$path"; then
    grep -Eiq 'set[[:space:]]+search_path' "$path" || fail "$file creates SECURITY DEFINER code without SET search_path"
    grep -Eiq 'revoke[[:space:]]+all[[:space:]]+on[[:space:]]+function' "$path" || fail "$file creates SECURITY DEFINER code without explicit REVOKE ALL"
  fi

  if grep -Eiq 'create([[:space:]]+or[[:space:]]+replace)?[[:space:]]+view' "$path"; then
    grep -Eiq 'security_invoker[[:space:]]*=[[:space:]]*true' "$path" || fail "$file creates a view without security_invoker=true"
  fi

  if grep -Eiq '(^|[[:space:]])(drop[[:space:]]+(table|schema|type)|truncate[[:space:]]|alter[[:space:]]+table.+drop[[:space:]]+column)[[:space:]]' "$path"; then
    grep -Fqi -- '-- destructive-change-approved:' "$path" || fail "$file contains destructive SQL without -- destructive-change-approved:"
    grep -Fqi -- '-- rollback-plan:' "$path" || fail "$file contains destructive SQL without -- rollback-plan:"
  fi
done

if [[ "$violations" -gt 0 ]]; then
  echo "Migration governance check FAILED ($violations violation(s))."
  exit 1
fi

echo "Migration governance check passed: ${#migrations[@]} migrations scanned; ${#changed[@]} changed migration(s) hardened."

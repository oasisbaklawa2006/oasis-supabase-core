#!/usr/bin/env bash
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

base_ref="${1:-}"
violations=0
baseline_ledger='docs/reconciliation/production-migration-ledger-2026-07-25.csv'
post_baseline_ledger='docs/reconciliation/production-migration-ledger-post-baseline-2026-07-27.csv'

# WO-TB-01 (PR #590) lead-approved, content-pinned exception. It applies ONLY to this
# exact path AND this exact Git blob (computed with git hash-object below), so any
# edit to the migration voids the exemption and the standard rules apply in full.
# Exempts: (a) the security_invoker=true rule (the frozen contract requires explicit
# security_invoker=false, which is verified instead) and (b) the supabase_migrations.
# ban, limited to the read-only supabase_migrations.schema_migrations projection.
torch_bearer_path='supabase/migrations/20261121220000_torch_bearer_readonly_debugger.sql'
torch_bearer_blob='8834c5ea6b6bb09290c3d1516a465a144cceb9ec'

if [[ -x scripts/check-production-baseline.sh ]]; then
  scripts/check-production-baseline.sh
fi

fail() {
  echo "MIGRATION GOVERNANCE VIOLATION: $*"
  violations=$((violations + 1))
}

mapfile -t migrations < <(find supabase/migrations -maxdepth 1 -type f -name '*.sql' -printf '%f\n' | sort)

if [ "${#migrations[@]}" -eq 0 ]; then
  fail "no migration files found"
fi

# Supabase identifies migrations by the leading timestamp. A duplicate version
# anywhere in the repository makes deterministic replay impossible, even when
# neither colliding file changed in the current pull request.
declare -A version_files=()
for file in "${migrations[@]}"; do
  if [[ "$file" =~ ^([0-9]{14})_ ]]; then
    version="${BASH_REMATCH[1]}"
    if [[ -n "${version_files[$version]:-}" ]]; then
      fail "migration version $version is duplicated by ${version_files[$version]} and $file"
    else
      version_files[$version]="$file"
    fi
  fi
done

changed=()
if [[ -n "$base_ref" ]] && git rev-parse --verify "$base_ref" >/dev/null 2>&1; then
  mapfile -t changed < <(
    {
      git diff --name-only --diff-filter=ACMR "$base_ref"...HEAD -- 'supabase/migrations/*.sql'
      git diff --name-only --diff-filter=ACMR --cached -- 'supabase/migrations/*.sql'
      git diff --name-only --diff-filter=ACMR -- 'supabase/migrations/*.sql'
      git ls-files --others --exclude-standard -- 'supabase/migrations/*.sql'
    } | sort -u
  )
else
  mapfile -t changed < <(
    {
      git diff-tree --no-commit-id --name-only -r HEAD -- 'supabase/migrations/*.sql' || true
      git diff --name-only --diff-filter=ACMR --cached -- 'supabase/migrations/*.sql'
      git diff --name-only --diff-filter=ACMR -- 'supabase/migrations/*.sql'
      git ls-files --others --exclude-standard -- 'supabase/migrations/*.sql'
    } | sort -u
  )
fi

# Historical filenames remain immutable production history. Every new or
# modified migration is held to the hardened standard and must not reuse any
# timestamp already present in the repository.
for path in "${changed[@]}"; do
  [[ -f "$path" ]] || continue
  file="$(basename "$path")"

  if [[ ! "$file" =~ ^([0-9]{14})_([a-z0-9_]+)\.sql$ ]]; then
    fail "$file must match YYYYMMDDHHMMSS_snake_case.sql"
    continue
  fi
  version="${BASH_REMATCH[1]}"
  name="${BASH_REMATCH[2]}"

  version_count="$(printf '%s\n' "${migrations[@]}" | grep -Ec "^${version}_" || true)"
  if [[ "$version_count" -ne 1 ]]; then
    fail "$file reuses migration version $version ($version_count files found)"
  fi

  if LC_ALL=C grep -q $'\r' "$path"; then
    fail "$file contains CRLF line endings"
  fi
  if head -c3 "$path" | od -An -tx1 | tr -d ' \n' | grep -qi '^efbbbf$'; then
    fail "$file contains a UTF-8 BOM"
  fi

  # Versions already recorded in production are governed by the immutable
  # baseline and post-baseline ledgers. check-production-baseline.sh proves that
  # each has exactly one repository representation and that pre-baseline stubs
  # contain no executable SQL. Feature-migration contract rules do not apply.
  if {
    [[ -f "$baseline_ledger" ]] \
      && tail -n +2 "$baseline_ledger" | cut -d, -f1 | grep -Fxq "$version"
  } || {
    [[ -f "$post_baseline_ledger" ]] \
      && tail -n +2 "$post_baseline_ledger" | cut -d, -f1 | grep -Fxq "$version"
  }; then
    continue
  fi

  torch_bearer_pinned=0
  if [[ "$path" == "$torch_bearer_path" ]]; then
    torch_bearer_actual="$(git hash-object -- "$path")"
    if [[ "$torch_bearer_actual" == "$torch_bearer_blob" ]]; then
      torch_bearer_pinned=1
    else
      fail "$file blob $torch_bearer_actual does not match the pinned WO-TB-01 blob $torch_bearer_blob; exception void"
    fi
  fi

  if grep -Eiq '(^|[^a-z_])supabase_migrations\.' "$path"; then
    if [[ "$torch_bearer_pinned" -eq 1 ]]; then
      # Pinned exception: only the read-only schema_migrations projection is allowed.
      if grep -Eio '(^|[^a-z_])supabase_migrations\.[a-z_]+' "$path" \
          | grep -Eiv 'supabase_migrations\.schema_migrations$' | grep -q .; then
        fail "$file references a supabase_migrations object other than schema_migrations"
      fi
      if grep -Eiq '(insert[[:space:]]+into|update|delete[[:space:]]+from|truncate|alter[[:space:]]+table|drop[[:space:]]+table|grant[[:space:]]+(insert|update|delete|truncate|all))[[:space:]]+(only[[:space:]]+)?supabase_migrations\.' "$path"; then
        fail "$file writes to supabase_migrations"
      fi
    else
      fail "$file writes or depends directly on Supabase migration internals"
    fi
  fi

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
    if [[ "$torch_bearer_pinned" -eq 1 ]]; then
      # Pinned exception: explicit security_invoker=false is mandatory for every view
      # and security_invoker=true must not appear.
      view_count="$(grep -Eic 'create([[:space:]]+or[[:space:]]+replace)?[[:space:]]+view' "$path" || true)"
      false_count="$(grep -Eic 'with[[:space:]]*\(security_invoker[[:space:]]*=[[:space:]]*false\)' "$path" || true)"
      [[ "$false_count" -ge "$view_count" ]] \
        || fail "$file must declare WITH (security_invoker = false) for every view ($false_count < $view_count)"
      if grep -Eiq 'security_invoker[[:space:]]*=[[:space:]]*true' "$path"; then
        fail "$file must not set security_invoker=true"
      fi
    else
      grep -Eiq 'security_invoker[[:space:]]*=[[:space:]]*true' "$path" || fail "$file creates a view without security_invoker=true"
    fi
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

echo "Migration governance check passed: ${#migrations[@]} migration files inventoried; ${#changed[@]} changed migration(s) hardened."

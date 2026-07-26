#!/usr/bin/env bash
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

ledger='docs/reconciliation/production-migration-ledger-2026-07-25.csv'
baseline_version='20260723161256'
migrations_dir='supabase/migrations'

fail() {
  echo "PRODUCTION HISTORY MATERIALIZATION FAILED: $*" >&2
  exit 1
}

[[ -f "$ledger" ]] || fail "ledger snapshot is missing: $ledger"
[[ -d "$migrations_dir" ]] || fail "migration directory is missing: $migrations_dir"

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

while IFS=, read -r version name; do
  [[ "$version" == 'version' ]] && continue
  [[ "$version" =~ ^[0-9]{14}$ ]] || fail "invalid ledger version: $version"
  [[ "$version" == "$baseline_version" ]] && continue

  safe_name="${name:-legacy_production_history}"
  [[ "$safe_name" =~ ^[a-z0-9_]+$ ]] \
    || fail "ledger name for $version is not snake_case: $safe_name"

  path="$migrations_dir/${version}_${safe_name}.sql"
  expected="$tmp_dir/${version}.sql"

  {
    printf '%s\n' '-- Historical production-ledger compatibility stub.'
    printf '%s\n' "-- Production version: $version"
    printf '%s\n' "-- Production name: ${name:-<empty>}"
    printf '%s\n' "-- Schema effect is represented by the squashed baseline at $baseline_version."
    printf '%s\n' '-- This file intentionally contains no executable SQL.'
  } > "$expected"

  if [[ -e "$path" ]]; then
    cmp -s "$expected" "$path" \
      || fail "existing compatibility stub differs from ledger materialization: $path"
  else
    mv "$expected" "$path"
  fi
done < "$ledger"

echo "Materialized production-history stubs before baseline $baseline_version."

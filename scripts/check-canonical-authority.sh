#!/usr/bin/env bash
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

project_ref='tcxvcatsqqertcnycuop'
baseline_ledger='docs/reconciliation/production-migration-ledger-2026-07-25.csv'
post_baseline_ledger='docs/reconciliation/production-migration-ledger-post-baseline-2026-07-27.csv'
reconciliation='docs/reconciliation/WHATSAPP_BACKEND_RECONCILIATION.md'
runbook='docs/runbooks/WHATSAPP_DATABASE_RELEASE.md'

fail() { echo "CANONICAL AUTHORITY VIOLATION: $*" >&2; exit 1; }

[[ -f "$baseline_ledger" ]] || fail "immutable production baseline ledger is missing"
[[ -f "$post_baseline_ledger" ]] || fail "post-baseline production ledger is missing"
[[ -f "$reconciliation" ]] || fail "reconciliation decision record is missing"
[[ -f "$runbook" ]] || fail "database release runbook is missing"
[[ -x scripts/check-production-baseline.sh ]] || fail "production baseline verifier is missing or not executable"

scripts/check-production-baseline.sh

grep -Fxq "project_id = \"$project_ref\"" supabase/config.toml || fail "supabase/config.toml does not identify the verified production project"
grep -Fq 'This repository is the canonical Supabase backend authority' BACKEND_OWNERSHIP.md || fail "Core does not declare canonical backend ownership"

baseline_row_count="$(tail -n +2 "$baseline_ledger" | sed '/^[[:space:]]*$/d' | wc -l | tr -d ' ')"
[[ "$baseline_row_count" == '168' ]] || fail "immutable baseline must contain exactly 168 production versions; found $baseline_row_count"

post_baseline_row_count="$(tail -n +2 "$post_baseline_ledger" | sed '/^[[:space:]]*$/d' | wc -l | tr -d ' ')"
[[ "$post_baseline_row_count" == '17' ]] || fail "post-baseline ledger must contain exactly 17 deployed versions; found $post_baseline_row_count"

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

tail -n +2 "$baseline_ledger" | cut -d, -f1 | sort > "$tmp_dir/baseline"
tail -n +2 "$post_baseline_ledger" | cut -d, -f1 | sort > "$tmp_dir/post-baseline"
cat "$tmp_dir/baseline" "$tmp_dir/post-baseline" | sort > "$tmp_dir/current"

current_row_count="$(wc -l < "$tmp_dir/current" | tr -d ' ')"
[[ "$current_row_count" == '185' ]] || fail "current production ledger must contain exactly 185 versions; found $current_row_count"

duplicates="$(cat "$tmp_dir/baseline" "$tmp_dir/post-baseline" | sort | uniq -d)"
[[ -z "$duplicates" ]] || fail "duplicate production ledger versions: $duplicates"

removed_versions="$(comm -23 "$tmp_dir/baseline" "$tmp_dir/current")"
[[ -z "$removed_versions" ]] || fail "current production ledger removes immutable baseline versions: $removed_versions"

expected_post_baseline_versions=(
  20260725150000 20260725173000 20260725180000 20260725200000
  20260725210000 20260725220000 20260725230000
  20260727070123 20260727070129 20260727070135 20260727070140
  20260727070148 20260727070153 20260727070159
  20260727083848 20260727103946 20260727122338
)

for version in "${expected_post_baseline_versions[@]}"; do
  compgen -G "supabase/migrations/${version}_*.sql" >/dev/null || fail "deployed migration $version is missing from Core"
  grep -Fxq "$version" "$tmp_dir/post-baseline" || fail "deployed migration $version is absent from the post-baseline ledger"
done

printf '%s\n' "${expected_post_baseline_versions[@]}" | sort > "$tmp_dir/expected-post-baseline"
diff -u "$tmp_dir/expected-post-baseline" "$tmp_dir/post-baseline" || fail "current-minus-baseline delta is not the reviewed 17-version production delta"

grep -Fq 'Status: **PRODUCTION DEPLOYED AND VERIFIED**' "$reconciliation" || fail "reconciliation status must record the verified production deployment"
grep -Fq 'explicit final production GO approval was received' "$reconciliation" || fail "reconciliation lacks the recorded production approval"
grep -Fq 'Support schema-only artifact | Passed' "$runbook" || fail "runbook does not record the accepted schema-only artifact"
grep -Fq 'Isolated zero-state replay | Passed' "$runbook" || fail "runbook must record the successful isolated replay"
grep -Fq 'GitHub Actions `30221700997`' "$runbook" || fail "runbook must retain the exact successful replay evidence"
grep -Fq 'Rollback-only UAT | Passed' "$runbook" || fail "runbook must record the successful rollback-only preview UAT"
grep -Fq 'Temporary UAT branch cleanup | Passed' "$runbook" || fail "runbook must record preview branch cleanup"

echo "Canonical backend authority check passed: immutable 168-version baseline plus reviewed 17-version deployed delta yield 185 current production versions."

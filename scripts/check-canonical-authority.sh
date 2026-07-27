#!/usr/bin/env bash
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

project_ref='tcxvcatsqqertcnycuop'
ledger='docs/reconciliation/production-migration-ledger-2026-07-25.csv'
reconciliation='docs/reconciliation/WHATSAPP_BACKEND_RECONCILIATION.md'
runbook='docs/runbooks/WHATSAPP_DATABASE_RELEASE.md'

fail() {
  echo "CANONICAL AUTHORITY VIOLATION: $*" >&2
  exit 1
}

[[ -f "$ledger" ]] || fail "production ledger snapshot is missing"
[[ -f "$reconciliation" ]] || fail "reconciliation decision record is missing"
[[ -f "$runbook" ]] || fail "database release runbook is missing"
[[ -x scripts/check-production-baseline.sh ]] \
  || fail "production baseline verifier is missing or not executable"

scripts/check-production-baseline.sh

grep -Fxq "project_id = \"$project_ref\"" supabase/config.toml \
  || fail "supabase/config.toml does not identify the verified production project"

grep -Fq 'This repository is the canonical Supabase backend authority' BACKEND_OWNERSHIP.md \
  || fail "Core does not declare canonical backend ownership"

row_count="$(tail -n +2 "$ledger" | sed '/^[[:space:]]*$/d' | wc -l | tr -d ' ')"
[[ "$row_count" == '168' ]] \
  || fail "ledger snapshot must contain exactly 168 production versions; found $row_count"

duplicates="$(
  tail -n +2 "$ledger" |
    cut -d, -f1 |
    sort |
    uniq -d
)"
[[ -z "$duplicates" ]] || fail "duplicate production ledger versions: $duplicates"

pending_versions=(
  20260725150000
  20260725173000
  20260725180000
  20260725200000
  20260725210000
  20260725220000
  20260725230000
)

for version in "${pending_versions[@]}"; do
  compgen -G "supabase/migrations/${version}_*.sql" >/dev/null \
    || fail "pending WhatsApp migration $version is missing from Core"
  if tail -n +2 "$ledger" | cut -d, -f1 | grep -Fxq "$version"; then
    fail "pending WhatsApp migration $version already appears in the production snapshot"
  fi
done

grep -Fq 'Status: **PREVIEW UAT PROVEN — PRODUCTION DEPLOYMENT STILL BLOCKED**' "$reconciliation" \
  || fail "reconciliation status must record preview UAT proof and deployment block"
grep -Fq 'explicit final production GO approval' "$reconciliation" \
  || fail "reconciliation lacks the explicit production approval boundary"
grep -Fq 'Support schema-only artifact | Passed' "$runbook" \
  || fail "runbook does not record the accepted schema-only artifact"
grep -Fq 'Isolated zero-state replay | Passed' "$runbook" \
  || fail "runbook must record the successful isolated replay"
grep -Fq 'GitHub Actions `30221700997`' "$runbook" \
  || fail "runbook must retain the exact successful replay evidence"
grep -Fq 'Rollback-only UAT | Passed' "$runbook" \
  || fail "runbook must record the successful rollback-only preview UAT"
grep -Fq 'Temporary UAT branch cleanup | Passed' "$runbook" \
  || fail "runbook must record preview branch cleanup"

echo "Canonical backend authority check passed: production baseline, isolated replay, and preview UAT accepted; 168 production versions aligned; 7 WhatsApp migrations remain pending and deployment-blocked."

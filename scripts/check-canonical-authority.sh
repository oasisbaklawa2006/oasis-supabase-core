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

grep -Fq 'Status: **BASELINE INTAKEN — DEPLOYMENT STILL BLOCKED**' "$reconciliation" \
  || fail "reconciliation status must record baseline intake and deployment block"
grep -Fq 'explicit final production GO approval' "$reconciliation" \
  || fail "reconciliation lacks the explicit production approval boundary"
grep -Fq 'Support schema-only artifact | Passed' "$runbook" \
  || fail "runbook does not record the accepted schema-only artifact"
grep -Fq 'Local zero-state replay | Pending CI' "$runbook" \
  || fail "runbook must keep replay pending until isolated CI succeeds"

echo "Canonical backend authority check passed: production baseline accepted, 168 production versions aligned, and 7 WhatsApp migrations remain pending and deployment-blocked."

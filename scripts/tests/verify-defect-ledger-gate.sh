#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
checker="$repo_root/scripts/check-defect-ledger.sh"
ledger="$repo_root/APPVERSE_CERTIFICATION/07_DEFECT_LEDGER.md"
temp_dir="$(mktemp -d)"
trap 'rm -rf "$temp_dir"' EXIT

bash "$checker" --validate "$ledger"

if bash "$checker" --enforce "$ledger"; then
  echo "Expected the current T5-WA-001 P1 blocker to refuse release authority" >&2
  exit 1
fi

cleared_ledger="$temp_dir/cleared-ledger.md"
sed \
  -e 's/| T5-WA-001 | P1 | CURRENT | BLOCKED_EXTERNAL |/| T5-WA-001 | P1 | CURRENT | RUNTIME_VERIFIED |/' \
  -e 's/| `d6c6a662703c04f90f7e79c790d3b994f9a61f1b` | PENDING_EXTERNAL | PENDING_EXTERNAL | PENDING_EXTERNAL | BLOCK |/| test-covered-core-revision | test-provider-acceptance-id | ACCEPTED | test-alert-reconciliation-closure | ALLOW |/' \
  "$ledger" > "$cleared_ledger"

bash "$checker" --enforce "$cleared_ledger"

contradictory_ledger="$temp_dir/contradictory-ledger.md"
sed \
  -e 's/| T5-WA-001 | P1 | CURRENT | BLOCKED_EXTERNAL |/| T5-WA-001 | P1 | CURRENT | RUNTIME_VERIFIED |/' \
  -e 's/| BLOCK | Core WhatsApp owner; Mission Control release authority |/| ALLOW | Core WhatsApp owner; Mission Control release authority |/' \
  "$ledger" > "$contradictory_ledger"

if bash "$checker" --validate "$contradictory_ledger"; then
  echo "Expected runtime-verified T5-WA-001 without provider evidence to be rejected" >&2
  exit 1
fi

echo "Defect-ledger release-gate regression test passed."

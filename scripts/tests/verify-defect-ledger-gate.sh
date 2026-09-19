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
  -e 's/| BLOCK | Core WhatsApp owner; Mission Control release authority |/| ALLOW | Core WhatsApp owner; Mission Control release authority |/' \
  "$ledger" > "$cleared_ledger"

bash "$checker" --enforce "$cleared_ledger"

echo "Defect-ledger release-gate regression test passed."

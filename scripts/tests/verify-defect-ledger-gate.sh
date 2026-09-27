#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
checker="$repo_root/scripts/check-defect-ledger.sh"
ledger="$repo_root/APPVERSE_CERTIFICATION/07_DEFECT_LEDGER.md"
temp_dir="$(mktemp -d)"
trap 'rm -rf "$temp_dir"' EXIT

# The canonical ledger is now expected to carry complete provider evidence and
# therefore to pass both structural validation and release enforcement.
bash "$checker" --validate "$ledger"
bash "$checker" --enforce "$ledger"

# Regression: a CURRENT P1 row restored to BLOCK must still refuse release.
blocked_ledger="$temp_dir/blocked-ledger.md"
python3 - "$ledger" "$blocked_ledger" <<'PY'
from pathlib import Path
import sys

src = Path(sys.argv[1]).read_text(encoding="utf-8")
src = src.replace(
    "| T5-WA-001 | P1 | CURRENT | Core / WhatsApp operator-reply runtime | RUNTIME_VERIFIED |",
    "| T5-WA-001 | P1 | CURRENT | Core / WhatsApp operator-reply runtime | BLOCKED_EXTERNAL |",
    1,
)
src = src.replace(
    "| ALLOW | Core WhatsApp owner; Mission Control release authority |",
    "| BLOCK | Core WhatsApp owner; Mission Control release authority |",
    1,
)
Path(sys.argv[2]).write_text(src, encoding="utf-8")
PY

if bash "$checker" --enforce "$blocked_ledger"; then
  echo "Expected a CURRENT T5-WA-001 P1 BLOCK row to refuse release authority" >&2
  exit 1
fi

# Regression: RUNTIME_VERIFIED / ALLOW is invalid if any mandatory provider
# evidence field falls back to a placeholder.
missing_evidence_ledger="$temp_dir/missing-evidence-ledger.md"
python3 - "$ledger" "$missing_evidence_ledger" <<'PY'
from pathlib import Path
import sys

src = Path(sys.argv[1]).read_text(encoding="utf-8")
src = src.replace(
    "`8817da5f-218d-4e00-b0f3-5cf33db06922`",
    "PENDING_EXTERNAL",
    1,
)
Path(sys.argv[2]).write_text(src, encoding="utf-8")
PY

if bash "$checker" --validate "$missing_evidence_ledger"; then
  echo "Expected runtime-verified T5-WA-001 with missing provider evidence to be rejected" >&2
  exit 1
fi

echo "Defect-ledger release-gate regression test passed."

#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
checker="$repo_root/scripts/check-defect-ledger.sh"
ledger="$repo_root/APPVERSE_CERTIFICATION/07_DEFECT_LEDGER.md"
temp_dir="$(mktemp -d)"
trap 'rm -rf "$temp_dir"' EXIT

# The canonical ledger is expected to pass both structural validation and
# release enforcement regardless of whether T5-WA-001 is CURRENT or HISTORICAL.
bash "$checker" --validate "$ledger"
bash "$checker" --enforce "$ledger"

# Regression: restoring T5-WA-001 to a CURRENT P1 BLOCK row must still refuse
# release authority. Mutate by stable columns rather than matching old prose.
blocked_ledger="$temp_dir/blocked-ledger.md"
python3 - "$ledger" "$blocked_ledger" <<'PY'
from pathlib import Path
import sys

src = Path(sys.argv[1]).read_text(encoding="utf-8").splitlines()
updated = False
for index, line in enumerate(src):
    if not line.startswith("| T5-WA-001 |"):
        continue
    cells = [cell.strip() for cell in line.strip().strip("|").split("|")]
    if len(cells) != 16:
        raise SystemExit(f"unexpected T5-WA-001 field count: {len(cells)}")
    cells[2] = "CURRENT"
    cells[4] = "BLOCKED_EXTERNAL"
    cells[13] = "BLOCK"
    src[index] = "| " + " | ".join(cells) + " |"
    updated = True
    break

if not updated:
    raise SystemExit("T5-WA-001 row not found")

Path(sys.argv[2]).write_text("\n".join(src) + "\n", encoding="utf-8")
PY

if bash "$checker" --enforce "$blocked_ledger"; then
  echo "Expected a CURRENT T5-WA-001 P1 BLOCK row to refuse release authority" >&2
  exit 1
fi

# Regression: CLOSED/RUNTIME_VERIFIED/ALLOW is invalid if any mandatory
# provider evidence field falls back to a placeholder.
missing_evidence_ledger="$temp_dir/missing-evidence-ledger.md"
python3 - "$ledger" "$missing_evidence_ledger" <<'PY'
from pathlib import Path
import sys

src = Path(sys.argv[1]).read_text(encoding="utf-8").splitlines()
updated = False
for index, line in enumerate(src):
    if not line.startswith("| T5-WA-001 |"):
        continue
    cells = [cell.strip() for cell in line.strip().strip("|").split("|")]
    if len(cells) != 16:
        raise SystemExit(f"unexpected T5-WA-001 field count: {len(cells)}")
    cells[10] = "PENDING_EXTERNAL"
    src[index] = "| " + " | ".join(cells) + " |"
    updated = True
    break

if not updated:
    raise SystemExit("T5-WA-001 row not found")

Path(sys.argv[2]).write_text("\n".join(src) + "\n", encoding="utf-8")
PY

if bash "$checker" --validate "$missing_evidence_ledger"; then
  echo "Expected certified T5-WA-001 with missing provider evidence to be rejected" >&2
  exit 1
fi

echo "Defect-ledger release-gate regression test passed."

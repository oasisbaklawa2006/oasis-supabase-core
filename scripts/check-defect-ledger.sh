#!/usr/bin/env bash
# Enforce the canonical App-Verse defect-ledger release boundary.
#
# --validate checks that the stable machine-readable Markdown index is complete.
# --enforce additionally refuses a release while a CURRENT P0/P1 record has
# Release gate = BLOCK. This deliberately includes BLOCKED_EXTERNAL records:
# external runtime evidence is not a reason to bypass release authority.

set -euo pipefail

mode="${1:---validate}"
if [[ "$mode" != "--validate" && "$mode" != "--enforce" ]]; then
  echo "usage: $0 [--validate|--enforce] [ledger-path]" >&2
  exit 2
fi

ledger_path="${2:-APPVERSE_CERTIFICATION/07_DEFECT_LEDGER.md}"

python3 - "$ledger_path" "$mode" <<'PY'
from pathlib import Path
import sys

ledger_path = Path(sys.argv[1])
mode = sys.argv[2]
required_headers = (
    "Error ID",
    "Severity",
    "Classification",
    "Repository / domain",
    "Status",
    "Code / runtime state",
    "Production impact",
    "Required next action",
    "Certification / evidence reference",
    "Release gate",
    "Owner / routing",
    "Exact evidence",
)
allowed_severities = {"P0", "P1", "P2", "P3"}
allowed_classifications = {"CURRENT", "HISTORICAL", "SUPERSEDED"}
allowed_statuses = {
    "NEW", "REPRODUCED", "ROOT_CAUSE_FOUND", "FIXED_NOT_VERIFIED",
    "CI_VERIFIED", "DEPLOYMENT_PENDING", "DEPLOYED", "RUNTIME_VERIFIED",
    "BLOCKED_EXTERNAL", "CLOSED", "REOPENED", "STALE", "SUPERSEDED", "OPEN",
}
allowed_gates = {"ALLOW", "BLOCK", "TRACK"}

try:
    lines = ledger_path.read_text(encoding="utf-8").splitlines()
except OSError as error:
    print(f"DEFECT LEDGER INVALID: cannot read {ledger_path}: {error}", file=sys.stderr)
    sys.exit(1)

start = "<!-- RELEASE_GATE_INDEX:START -->"
end = "<!-- RELEASE_GATE_INDEX:END -->"
try:
    start_index = lines.index(start)
    end_index = lines.index(end)
except ValueError:
    print("DEFECT LEDGER INVALID: release-gate index markers are required", file=sys.stderr)
    sys.exit(1)
if end_index <= start_index + 2:
    print("DEFECT LEDGER INVALID: release-gate index has no records", file=sys.stderr)
    sys.exit(1)

def cells(row):
    return [cell.strip() for cell in row.strip().strip("|").split("|")]

headers = cells(lines[start_index + 1])
if tuple(headers) != required_headers:
    print("DEFECT LEDGER INVALID: release-gate index headers changed", file=sys.stderr)
    sys.exit(1)

records = []
for line_number, row in enumerate(lines[start_index + 3:end_index], start=start_index + 4):
    if not row.strip():
        continue
    values = cells(row)
    if len(values) != len(required_headers):
        print(f"DEFECT LEDGER INVALID: line {line_number} has {len(values)} fields", file=sys.stderr)
        sys.exit(1)
    record = dict(zip(required_headers, values))
    if not all(record.values()):
        print(f"DEFECT LEDGER INVALID: line {line_number} has an empty field", file=sys.stderr)
        sys.exit(1)
    if record["Severity"] not in allowed_severities:
        print(f"DEFECT LEDGER INVALID: line {line_number} has invalid severity", file=sys.stderr)
        sys.exit(1)
    if record["Classification"] not in allowed_classifications:
        print(f"DEFECT LEDGER INVALID: line {line_number} has invalid classification", file=sys.stderr)
        sys.exit(1)
    if record["Status"] not in allowed_statuses:
        print(f"DEFECT LEDGER INVALID: line {line_number} has invalid status", file=sys.stderr)
        sys.exit(1)
    if record["Release gate"] not in allowed_gates:
        print(f"DEFECT LEDGER INVALID: line {line_number} has invalid release gate", file=sys.stderr)
        sys.exit(1)
    records.append(record)

if not records:
    print("DEFECT LEDGER INVALID: release-gate index has no records", file=sys.stderr)
    sys.exit(1)

ids = [record["Error ID"] for record in records]
if len(ids) != len(set(ids)):
    print("DEFECT LEDGER INVALID: error IDs must be unique", file=sys.stderr)
    sys.exit(1)

required_task5_ids = {"T5-WA-001", "T5-AI-001", "CERT-SEC-001", "CERT-SEC-002", "T5-AI-002"}
missing_task5_ids = sorted(required_task5_ids - set(ids))
if missing_task5_ids:
    print("DEFECT LEDGER INVALID: missing required Task 5 IDs: " + ", ".join(missing_task5_ids), file=sys.stderr)
    sys.exit(1)

blockers = [
    record for record in records
    if record["Classification"] == "CURRENT"
    and record["Severity"] in {"P0", "P1"}
    and record["Release gate"] == "BLOCK"
]
print(f"DEFECT LEDGER VALID: {len(records)} records; {len(blockers)} current P0/P1 release blocker(s).")
for record in blockers:
    print(f"DEFECT LEDGER BLOCK: {record['Error ID']} ({record['Status']}) - {record['Exact evidence']}")

if mode == "--enforce" and blockers:
    print("Production release refused: clear or explicitly supersede the current P0/P1 release blocker in the canonical ledger.", file=sys.stderr)
    sys.exit(1)
PY

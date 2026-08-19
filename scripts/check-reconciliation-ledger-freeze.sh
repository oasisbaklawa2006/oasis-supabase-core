#!/usr/bin/env bash
# The 2026-08-18 reconciliation ledgers are immutable historical evidence of
# the production migration-lineage incident, not a living log. A normal
# feature PR must never add a new remote-only row to them -- doing so would
# be indistinguishable from quietly re-legitimizing a fresh out-of-band
# production write. Any legitimate extension requires an explicit incident
# marker plus a dedicated reconciliation-test update in the SAME diff, so it
# is visible in review and cannot slip through as an ordinary content edit.
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

base_ref="${1:-}"
fail() { echo "RECONCILIATION-LEDGER-FREEZE VIOLATION: $*" >&2; exit 1; }

FROZEN_LEDGERS=(
  docs/reconciliation/production-migration-ledger-remote-history-2026-08-14.csv
  docs/reconciliation/production-migration-ledger-remote-history-2026-08-18.csv
  docs/reconciliation/canonical-production-lineage-2026-08-18.csv
)
INCIDENT_MARKER='-- production-lineage-incident-approved:'

if [[ -z "$base_ref" ]]; then
  if git rev-parse HEAD^ >/dev/null 2>&1; then
    base_ref='HEAD^'
  else
    echo "OK: no base ref available for comparison (single-commit history); nothing to freeze against yet."
    exit 0
  fi
fi

git rev-parse --verify "$base_ref" >/dev/null 2>&1 || {
  echo "OK: base ref '$base_ref' not resolvable locally; skipping (CI always supplies a resolvable ref)."
  exit 0
}

changed=0
for ledger in "${FROZEN_LEDGERS[@]}"; do
  [[ -f "$ledger" ]] || continue
  if ! git diff --quiet "$base_ref" -- "$ledger" 2>/dev/null; then
    changed=1
    echo "Frozen reconciliation ledger changed: $ledger" >&2
  fi
done

if ((changed == 0)); then
  echo "OK: frozen reconciliation ledgers are unchanged since $base_ref."
  exit 0
fi

# A change was made. It is only legitimate if this same diff also:
#   1. adds/modifies a file carrying the explicit incident-approval marker, and
#   2. touches scripts/tests/ (a dedicated reconciliation test proving the
#      overlay/ledger verifiers were updated in lockstep, not just the data).
marker_present=0
if git diff "$base_ref" -- . | grep -qF "$INCIDENT_MARKER"; then
  marker_present=1
fi

tests_touched=0
if ! git diff --quiet "$base_ref" -- 'scripts/tests/*' 2>/dev/null; then
  tests_touched=1
fi

if ((marker_present == 0)); then
  fail "frozen reconciliation ledger(s) changed without the '$INCIDENT_MARKER' marker anywhere in the diff. This marker (plus a real incident record explaining it) is required to extend historical remote-only evidence. Normal feature work must never touch these files."
fi

if ((tests_touched == 0)); then
  fail "frozen reconciliation ledger(s) changed with an incident marker present, but no dedicated reconciliation test under scripts/tests/ was added or updated in the same diff. A ledger extension must ship with test coverage proving the verifiers were updated to match."
fi

echo "OK: frozen reconciliation ledger change is accompanied by an incident-approval marker and dedicated reconciliation test updates."

#!/usr/bin/env bash
# A snapshot records only counts and SHA-256 fingerprints of protected rows.
set -euo pipefail
umask 077
root="$(cd "$(dirname "$0")/../.." && pwd)"
python3 "$root/scripts/genie-qa/verify_qa_target.py" >/dev/null
[[ "$GENIE_QA_RUN_MODE" == preflight-forward || "$GENIE_QA_RUN_MODE" == apply-forward ]]
[[ "$PGSSLMODE" == verify-full && -s "$PGSSLROOTCERT" ]]
[[ "$1" == "$RUNNER_TEMP/qa-preservation-before.json" ]]
tmp="$(mktemp "$RUNNER_TEMP/qa-preservation.XXXXXX")"
trap 'rm -f -- "$tmp"' EXIT
if ! PGCONNECT_TIMEOUT=10 PGOPTIONS='-c default_transaction_read_only=on -c statement_timeout=60000' \
  psql "$GENIE_QA_DATABASE_URL" -X -qAt -v ON_ERROR_STOP=1 \
  -c "$(cat "$root/scripts/genie-qa/forward_preservation.sql")" >"$tmp" 2>/dev/null; then
  echo "::error::QA_PRESERVATION_READ_FAILED"
  exit 1
fi
python3 - "$tmp" <<'PY'
import json, re, sys
data=json.load(open(sys.argv[1]))
if len(data)!=17 or any(not isinstance(x.get("count"), int) or not re.fullmatch(r"[0-9a-f]{64}", x.get("sha256","")) for x in data.values()):
    raise SystemExit("QA_PRESERVATION_INVALID")
if data["storage.objects"]["count"] != 0:
    raise SystemExit("QA_STORAGE_OBJECTS_REQUIRE_SEPARATE_BACKUP")
PY
if [[ -e "$1" ]]; then
  cmp -s "$tmp" "$1" || { echo "::error::QA_PROTECTED_DATA_CHANGED; stop and investigate"; exit 1; }
else
  mv -- "$tmp" "$1"
fi

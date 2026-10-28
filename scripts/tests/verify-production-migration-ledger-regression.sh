#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
test_root="$(mktemp -d)"
trap 'rm -rf "$test_root"' EXIT

mkdir -p "$test_root/bin" "$test_root/migrations" "$test_root/docs/reconciliation"
: > "$test_root/preview-migration-ledger-compat.txt"

for i in $(seq 1 16); do
  printf -v historical_version '2024010100%04d' "$i"
  printf -v replacement_version '2026010100%04d' "$i"
  : > "$test_root/migrations/${historical_version}_historical-gap.sql"
  : > "$test_root/migrations/${replacement_version}_forward-replacement.sql"
done

{
  printf '%s\n' 'version,source,evidence'
  printf '%s\n' '20260101000001,reconciled,replacement-already-applied'
  for i in $(seq 1 31); do
    printf '2025020100%04d,production,test\n' "$i"
  done
} > "$test_root/docs/reconciliation/production-history.csv"

{
  printf '%s\n' 'canonical_version,status,replacement_version,remote_evidence,evidence'
  for i in $(seq 1 16); do
    printf '2024010100%04d,pending_forward,2026010100%04d,production,test\n' "$i" "$i"
  done
} > "$test_root/docs/reconciliation/canonical-lineage.csv"

cat > "$test_root/bin/psql" <<'PSQL'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' '20260101000001'
for i in $(seq 1 31); do
  printf '2025020100%04d\n' "$i"
done
PSQL
chmod +x "$test_root/bin/psql"

PATH="$test_root/bin:$PATH" \
SUPABASE_DB_URL='postgresql://ledger-regression.invalid/test' \
MIGRATIONS_DIR="$test_root/migrations" \
REPORT_FILE="$test_root/report.txt" \
REMOTE_HISTORY_LEDGER="$test_root/docs/reconciliation/production-history.csv" \
CANONICAL_LINEAGE_LEDGER="$test_root/docs/reconciliation/canonical-lineage.csv" \
PREVIEW_MIGRATION_LEDGER_COMPAT_FILE="$test_root/preview-migration-ledger-compat.txt" \
EXPECTED_REMOTE_HISTORY_COUNT=32 \
EXPECTED_CANONICAL_LINEAGE_COUNT=16 \
bash "$repo_root/scripts/verify-production-migration-ledger.sh"

grep -q '^Status: SUCCESS$' "$test_root/report.txt"
grep -q '^Pending append-only versions:$' "$test_root/report.txt"
if grep -q '^20260101000001$' "$test_root/report.txt"; then
  echo "already-applied replacement leaked into pending output" >&2
  exit 1
fi
grep -q '^20260101000002$' "$test_root/report.txt"
grep -q '^20260101000016$' "$test_root/report.txt"

grep -q '^20261028055454,wa450_d3_governed_customer_identity_anchor,direct-production-apply,' "$repo/docs/reconciliation/production-migration-ledger-remote-history-2026-08-18.csv"
grep -q '^20261028055458,wa450_d4_order_correction_ambiguity_gate,direct-production-apply,' "$repo/docs/reconciliation/production-migration-ledger-remote-history-2026-08-18.csv"
grep -q '^20261027120000,represented_remote,,20261028055454,' "$repo/docs/reconciliation/canonical-production-lineage-2026-08-18.csv"
grep -q '^20261027130000,represented_remote,,20261028055458,' "$repo/docs/reconciliation/canonical-production-lineage-2026-08-18.csv"
grep -q '^-- production-lineage-incident-approved: WA-450' "$repo/docs/reconciliation/production-lineage-incident-2026-10-28-wa450.md"

echo "Applied replacement and WA-450 production lineage reconciliation regressions passed."

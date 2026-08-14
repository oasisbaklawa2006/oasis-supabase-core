#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
test_root="$(mktemp -d)"
trap 'rm -rf "$test_root"' EXIT

mkdir -p "$test_root/bin" "$test_root/migrations" "$test_root/docs/reconciliation"

for i in $(seq 1 16); do
  printf -v historical_version '2024010100%04d' "$i"
  printf -v replacement_version '2026010100%04d' "$i"
  : > "$test_root/migrations/${historical_version}_historical-gap.sql"
  : > "$test_root/migrations/${replacement_version}_forward-replacement.sql"
done

{
  printf '%s\n' 'version,source,evidence'
  for i in $(seq 1 32); do
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
for i in $(seq 1 32); do
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
bash "$repo_root/scripts/verify-production-migration-ledger.sh"

grep -q '^Status: SUCCESS$' "$test_root/report.txt"
grep -q '^Pending append-only versions:$' "$test_root/report.txt"
grep -q '^20260101000001$' "$test_root/report.txt"
grep -q '^20260101000016$' "$test_root/report.txt"

echo "Multiline local_missing_versions regression passed."

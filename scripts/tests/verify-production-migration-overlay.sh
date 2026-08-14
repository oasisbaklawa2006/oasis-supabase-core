#!/usr/bin/env bash
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

bash -n scripts/run-production-migration-overlay.sh

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT
mkdir -p "$tmp_dir/bin"

cat > "$tmp_dir/bin/supabase" <<'FAKE_SUPABASE'
#!/usr/bin/env bash
set -euo pipefail

[[ "$#" == 4 ]] || { printf 'unexpected fake CLI arguments: %s\n' "$*" >&2; exit 1; }
[[ "$1" == db && "$2" == push && "$3" == --linked && "$4" == --dry-run ]] || {
  printf 'unexpected fake CLI command: %s\n' "$*" >&2
  exit 1
}
[[ -n "${SUPABASE_WORKDIR:-}" ]] || { echo 'SUPABASE_WORKDIR was not set' >&2; exit 1; }
migration_dir="$SUPABASE_WORKDIR/supabase/migrations"
[[ -d "$migration_dir" ]] || { echo 'overlay migration directory is missing' >&2; exit 1; }

stub_count="$(find "$migration_dir" -maxdepth 1 -type f -name '*.sql' -print0 | xargs -0 grep -l -- '^-- CI-only compatibility stub for an already-applied remote history row.$' | wc -l | tr -d ' ')"
if [[ "$stub_count" != 32 ]]; then
  echo "expected 32 compatibility stubs, found $stub_count" >&2
  find "$migration_dir" -maxdepth 1 -type f -name '*.sql' -print0 | while IFS= read -r -d '' file; do
    grep -q -- '^-- CI-only compatibility stub for an already-applied remote history row.$' "$file" || echo "missing-stub-marker: $file" >&2
  done
  exit 1
fi

while IFS=, read -r version name _classification _evidence; do
  [[ "$version" == version ]] && continue
  matches=("$migration_dir/${version}_"*.sql)
  [[ -f "${matches[0]}" && ! -e "${matches[1]:-}" ]] || { echo "remote history was not materialized exactly once: $version" >&2; exit 1; }
  grep -q -- '^-- This file is intentionally not committed and must never be deployed.$' "${matches[0]}" || {
    echo "remote history stub is not explicitly non-deployable: $version" >&2
    exit 1
  }
done < docs/reconciliation/production-migration-ledger-remote-history-2026-08-14.csv

represented_count="$(awk -F, 'NR > 1 && $2 == "represented_remote" {count++} END {print count + 0}' docs/reconciliation/canonical-production-lineage-2026-08-14.csv)"
pending_count="$(awk -F, 'NR > 1 && $2 == "pending_forward" {count++} END {print count + 0}' docs/reconciliation/canonical-production-lineage-2026-08-14.csv)"
[[ "$represented_count" == 12 ]] || { echo "expected 12 represented canonical versions, found $represented_count" >&2; exit 1; }
[[ "$pending_count" == 4 ]] || { echo "expected 4 pending canonical versions, found $pending_count" >&2; exit 1; }

while IFS=, read -r canonical_version status replacement_version _remote_evidence _evidence; do
  [[ "$canonical_version" == canonical_version ]] && continue
  if [[ "$status" == represented_remote ]]; then
    matches=("$migration_dir/${canonical_version}_"*.sql)
    [[ ! -e "${matches[0]}" ]] || { echo "represented canonical migration remained in overlay: $canonical_version" >&2; exit 1; }
  else
    matches=("$migration_dir/${replacement_version}_"*.sql)
    [[ -f "${matches[0]}" && ! -e "${matches[1]:-}" ]] || { echo "pending replacement missing from overlay: $replacement_version" >&2; exit 1; }
    grep -Evq '^[[:space:]]*(--.*)?$' "${matches[0]}" || { echo "pending replacement is only comments: $replacement_version" >&2; exit 1; }
  fi
done < docs/reconciliation/canonical-production-lineage-2026-08-14.csv

echo 'fake Supabase dry-run accepted the reconciled overlay'
FAKE_SUPABASE
chmod +x "$tmp_dir/bin/supabase"

before="$(git diff --no-ext-diff -- supabase/migrations)"
PATH="$tmp_dir/bin:$PATH" bash scripts/run-production-migration-overlay.sh --dry-run > "$tmp_dir/output.txt"
after="$(git diff --no-ext-diff -- supabase/migrations)"
[[ "$before" == "$after" ]] || { echo 'repository migrations changed during overlay run' >&2; exit 1; }

grep -q '^Remote-history compatibility stubs: 32$' "$tmp_dir/output.txt"
grep -q '^Hidden represented canonical versions: 12$' "$tmp_dir/output.txt"
grep -q '^Pending forward replacements: 4$' "$tmp_dir/output.txt"
grep -q '^fake Supabase dry-run accepted the reconciled overlay$' "$tmp_dir/output.txt"

echo 'Production migration overlay regression test passed.'

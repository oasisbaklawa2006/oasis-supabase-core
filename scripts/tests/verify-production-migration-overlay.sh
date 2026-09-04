#!/usr/bin/env bash
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

bash -n scripts/run-production-migration-overlay.sh

tmp_dir="$(mktemp -d)"
link_state='supabase/.temp/project-ref'
created_link_state=0
cleanup() {
  rm -rf "$tmp_dir"
  if [[ "$created_link_state" == 1 ]]; then
    rm -f "$link_state"
    rmdir supabase/.temp 2>/dev/null || true
  fi
}
trap cleanup EXIT

if [[ ! -f "$link_state" ]]; then
  mkdir -p supabase/.temp
  printf '%s\n' test-project-ref > "$link_state"
  created_link_state=1
fi

mkdir -p "$tmp_dir/bin"

cat > "$tmp_dir/bin/supabase" <<'FAKE_SUPABASE'
#!/usr/bin/env bash
set -euo pipefail

remote_applied_preview_compat() {
  case "$1" in
    20260830101500|20260830120001|20260830144000|20260901005100|20260901005200|20260901005300) return 0 ;;
    *) return 1 ;;
  esac
}

check_overlay() {
  [[ -n "${SUPABASE_WORKDIR:-}" ]] || { echo 'SUPABASE_WORKDIR was not set' >&2; exit 1; }
  migration_dir="$SUPABASE_WORKDIR/supabase/migrations"
  [[ -d "$migration_dir" ]] || { echo 'overlay migration directory is missing' >&2; exit 1; }

  remote_seen=0
  while IFS=, read -r version name _classification _evidence || [[ -n "${version:-}" ]]; do
    [[ "$version" == version ]] && continue
    version="${version//$'\r'/}"
    matches=("$migration_dir/${version}_"*.sql)
    [[ -f "${matches[0]}" && ! -e "${matches[1]:-}" ]] || { echo "remote history was not materialized exactly once: $version" >&2; exit 1; }
    grep -q -- '^-- CI-only compatibility stub for an already-applied remote history row.$' "${matches[0]}" || { echo "remote history stub marker is missing: $version" >&2; exit 1; }
    grep -q -- '^-- This file is intentionally not committed and must never be deployed.$' "${matches[0]}" || { echo "remote history stub is deployable: $version" >&2; exit 1; }
    remote_seen=$((remote_seen + 1))
  done < docs/reconciliation/production-migration-ledger-remote-history-2026-08-18.csv
  [[ "$remote_seen" == 33 ]] || { echo "expected 33 remote-history rows, found $remote_seen" >&2; exit 1; }

  matches=("$migration_dir/20260816125809_"*.sql)
  [[ -f "${matches[0]}" && ! -e "${matches[1]:-}" ]] || { echo "compatibility stub for 20260816125809 (wa_atomic_packet_authority) is missing" >&2; exit 1; }

  represented_count="$(awk -F, 'NR > 1 && $2 == "represented_remote" {count++} END {print count + 0}' docs/reconciliation/canonical-production-lineage-2026-08-18.csv)"
  pending_count="$(awk -F, 'NR > 1 && $2 == "pending_forward" {count++} END {print count + 0}' docs/reconciliation/canonical-production-lineage-2026-08-18.csv)"
  [[ "$represented_count" == 13 ]] || { echo "expected 13 represented canonical versions, found $represented_count" >&2; exit 1; }
  [[ "$pending_count" == 13 ]] || { echo "expected 13 pending canonical versions, found $pending_count" >&2; exit 1; }

  while IFS=, read -r canonical_version status replacement_version _remote_evidence _evidence || [[ -n "${canonical_version:-}" ]]; do
    [[ "$canonical_version" == canonical_version ]] && continue
    canonical_version="${canonical_version//$'\r'/}"
    status="${status//$'\r'/}"
    replacement_version="${replacement_version//$'\r'/}"
    matches=("$migration_dir/${canonical_version}_"*.sql)
    [[ ! -e "${matches[0]}" ]] || { echo "superseded canonical migration remained: $canonical_version" >&2; exit 1; }
    if [[ "$status" == pending_forward ]]; then
      matches=("$migration_dir/${replacement_version}_"*.sql)
      [[ -f "${matches[0]}" && ! -e "${matches[1]:-}" ]] || { echo "pending replacement missing: $replacement_version" >&2; exit 1; }
      grep -Evq '^[[:space:]]*(--.*)?$' "${matches[0]}" || { echo "pending replacement is only comments: $replacement_version" >&2; exit 1; }
    fi
  done < docs/reconciliation/canonical-production-lineage-2026-08-18.csv

  preview_compat_file="${PREVIEW_MIGRATION_LEDGER_COMPAT_FILE:-supabase/preview-migration-ledger-compat.txt}"
  [[ -f "$preview_compat_file" ]] || { echo "preview compat inventory missing: $preview_compat_file" >&2; exit 1; }
  preview_compat_seen=0
  preview_compat_preserved=0
  preview_compat_hidden=0
  while IFS= read -r compat_line || [[ -n "$compat_line" ]]; do
    [[ -z "$compat_line" || "$compat_line" =~ ^[[:space:]]*# ]] && continue
    compat_version="${compat_line%%#*}"
    compat_version="$(printf '%s' "$compat_version" | tr -d '[:space:]')"
    [[ -z "$compat_version" ]] && continue
    matches=("$migration_dir/${compat_version}_"*.sql)
    if remote_applied_preview_compat "$compat_version"; then
      [[ -f "${matches[0]}" && ! -e "${matches[1]:-}" ]] || { echo "remote-applied preview compatibility stub was hidden: $compat_version" >&2; exit 1; }
      preview_compat_preserved=$((preview_compat_preserved + 1))
    else
      [[ ! -e "${matches[0]}" ]] || { echo "preview-only compatibility stub remained in overlay: $compat_version" >&2; exit 1; }
      preview_compat_hidden=$((preview_compat_hidden + 1))
    fi
    preview_compat_seen=$((preview_compat_seen + 1))
  done < "$preview_compat_file"
  [[ "$preview_compat_seen" == 7 ]] || { echo "expected 7 preview compat inventory entries, found $preview_compat_seen" >&2; exit 1; }
  [[ "$preview_compat_preserved" == 6 ]] || { echo "expected 6 remote-applied preview compat rows, found $preview_compat_preserved" >&2; exit 1; }
  [[ "$preview_compat_hidden" == 1 ]] || { echo "expected 1 preview-only compat row, found $preview_compat_hidden" >&2; exit 1; }

  for forward_version in 20260904030100 20260904030200; do
    matches=("$migration_dir/${forward_version}_"*.sql)
    [[ -f "${matches[0]}" && ! -e "${matches[1]:-}" ]] || { echo "Point 29 forward migration missing from overlay: $forward_version" >&2; exit 1; }
  done
}

if [[ "$1" == migration && "$2" == list && "$3" == --db-url && "$4" == "$SUPABASE_DB_URL" ]]; then
  cat <<'LIST'
   Local            | Remote           | Time (UTC)
  ------------------|------------------|-----------------------
   `20260830101500` | `20260830101500` | `2026-08-30 10:15:00`
   `20260830120001` | `20260830120001` | `2026-08-30 12:00:01`
   `20260830144000` | `20260830144000` | `2026-08-30 14:40:00`
   `20260901005100` | `20260901005100` | `2026-09-01 00:51:00`
   `20260901005200` | `20260901005200` | `2026-09-01 00:52:00`
   `20260901005300` | `20260901005300` | `2026-09-01 00:53:00`
   `20260903100000` | ` `              | `2026-09-03 10:00:00`
   `20260904030000` | `20260904030000` | `2026-09-04 03:00:00`
   `20260904030100` | ` `              | `2026-09-04 03:01:00`
   `20260904030200` | ` `              | `2026-09-04 03:02:00`
LIST
  exit 0
fi

case "$#" in
  5)
    [[ "$1" == db && "$2" == push && "$3" == --db-url && "$4" == "$SUPABASE_DB_URL" && "$5" == --dry-run ]] || { echo "unexpected fake dry-run command: $*" >&2; exit 1; }
    check_overlay
    echo 'fake Supabase dry-run accepted the reconciled overlay'
    ;;
  4)
    [[ "$1" == db && "$2" == push && "$3" == --db-url && "$4" == "$SUPABASE_DB_URL" ]] || { echo "unexpected fake apply command: $*" >&2; exit 1; }
    check_overlay
    echo 'fake Supabase apply accepted the reconciled overlay'
    ;;
  *)
    echo "unexpected fake CLI arguments: $*" >&2
    exit 1
    ;;
esac
FAKE_SUPABASE
chmod +x "$tmp_dir/bin/supabase"

export SUPABASE_DB_URL='postgresql://postgres:test@127.0.0.1:5432/postgres'

before="$(git status --porcelain --untracked-files=all -- supabase/migrations)"
PATH="$tmp_dir/bin:$PATH" bash scripts/run-production-migration-overlay.sh --dry-run > "$tmp_dir/dry-run.txt"
after="$(git status --porcelain --untracked-files=all -- supabase/migrations)"
[[ "$before" == "$after" ]] || { echo 'repository migrations changed during dry-run overlay' >&2; exit 1; }

PATH="$tmp_dir/bin:$PATH" bash scripts/run-production-migration-overlay.sh --apply > "$tmp_dir/apply.txt"

grep -q '^Remote-history compatibility stubs: 33$' "$tmp_dir/dry-run.txt"
grep -q '^Hidden represented canonical versions: 13$' "$tmp_dir/dry-run.txt"
grep -q '^Hidden pending canonical versions: 13$' "$tmp_dir/dry-run.txt"
grep -q '^Preserved remote-applied preview ledger compatibility stubs: 6$' "$tmp_dir/dry-run.txt"
grep -q '^Hidden preview-only ledger compatibility stubs: 1$' "$tmp_dir/dry-run.txt"
grep -q '^Pending forward replacements: 13$' "$tmp_dir/dry-run.txt"
grep -q '^fake Supabase dry-run accepted the reconciled overlay$' "$tmp_dir/dry-run.txt"
grep -q '^fake Supabase apply accepted the reconciled overlay$' "$tmp_dir/apply.txt"

printf '%s\n' '#!/usr/bin/env bash' 'exit 7' > "$tmp_dir/bin/supabase"
chmod +x "$tmp_dir/bin/supabase"
status=0
PATH="$tmp_dir/bin:$PATH" bash scripts/run-production-migration-overlay.sh --dry-run >/dev/null 2>&1 || status=$?
[[ "$status" == 7 ]] || { echo "overlay did not propagate CLI exit status: $status" >&2; exit 1; }

echo 'Production migration overlay regression test passed.'

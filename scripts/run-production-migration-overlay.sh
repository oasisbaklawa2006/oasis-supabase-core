#!/usr/bin/env bash
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

REMOTE_HISTORY_LEDGER="${REMOTE_HISTORY_LEDGER:-docs/reconciliation/production-migration-ledger-remote-history-2026-08-14.csv}"
CANONICAL_LINEAGE_LEDGER="${CANONICAL_LINEAGE_LEDGER:-docs/reconciliation/canonical-production-lineage-2026-08-14.csv}"

fail() {
  echo "PRODUCTION MIGRATION OVERLAY FAILED: $*" >&2
  exit 1
}

mode="${1:-}"
case "$mode" in
  --dry-run) push_flags=(--linked --dry-run) ;;
  --apply) push_flags=(--linked) ;;
  *) fail "usage: $0 --dry-run|--apply" ;;
esac

[[ -f "$REMOTE_HISTORY_LEDGER" ]] || fail "remote-history ledger missing: $REMOTE_HISTORY_LEDGER"
[[ -f "$CANONICAL_LINEAGE_LEDGER" ]] || fail "canonical-lineage ledger missing: $CANONICAL_LINEAGE_LEDGER"
[[ -d supabase/migrations ]] || fail "migration directory missing: supabase/migrations"
link_state='supabase/.temp/project-ref'
[[ -f "$link_state" ]] || fail "linked project state is missing: $link_state"

overlay_root="$(mktemp -d)"
cleanup() {
  rm -rf "$overlay_root"
}
trap cleanup EXIT

mkdir -p "$overlay_root/supabase/.temp"
cp supabase/config.toml "$overlay_root/supabase/config.toml"
cp "$link_state" "$overlay_root/supabase/.temp/project-ref"
cp -a supabase/migrations "$overlay_root/supabase/migrations"

overlay_migrations="$overlay_root/supabase/migrations"
remote_stub_count=0
while IFS=, read -r version name classification evidence || [[ -n "${version:-}" ]]; do
  [[ "$version" == version ]] && continue
  version="${version// || fail "invalid remote-only version: $version"
  [[ "$evidence" == remote-ledger-only* ]] || fail "remote-only row lacks remote-ledger-only evidence: $version"
  case "$classification" in
    parallel-staging-lineage|duplicate-equivalent-lineage) ;;
    *) fail "unexpected remote-only classification: $version/$classification" ;;
  esac

  matches=("$overlay_migrations/${version}_"*.sql)
  [[ ! -e "${matches[0]}" ]] || fail "remote-only version already has a local migration: $version"
  safe_name="${name%.sql}"
  [[ "$safe_name" =~ ^[a-z0-9_]+$ ]] || fail "unsafe remote-only migration name: $version/$name"

  {
    echo '-- CI-only compatibility stub for an already-applied remote history row.'
    echo '-- This file is intentionally not committed and must never be deployed.'
    echo "-- Remote version: $version"
    echo "-- Remote name: $name"
    echo '-- The schema effect is represented by canonical remote lineage.'
  } > "$overlay_migrations/${version}_${safe_name}.sql"
  remote_stub_count=$((remote_stub_count + 1))
done < "$REMOTE_HISTORY_LEDGER"

[[ "$remote_stub_count" == 32 ]] || fail "remote-history ledger must contain exactly 32 rows; found $remote_stub_count"

represented_count=0
pending_count=0
while IFS=, read -r canonical_version status replacement_version _remote_evidence _evidence || [[ -n "${canonical_version:-}" ]]; do
  [[ "$canonical_version" == canonical_version ]] && continue
  canonical_version="${canonical_version// || fail "invalid canonical version: $canonical_version"

  case "$status" in
    represented_remote|pending_forward)
      matches=("$overlay_migrations/${canonical_version}_"*.sql)
      [[ -f "${matches[0]}" && ! -e "${matches[1]:-}" ]] || fail "canonical version must have exactly one local migration: $canonical_version"
      rm -- "${matches[0]}"
      if [[ "$status" == represented_remote ]]; then
        represented_count=$((represented_count + 1))
      else
        [[ "$replacement_version" =~ ^[0-9]{14}$ ]] || fail "pending canonical version lacks a replacement: $canonical_version"
        matches=("$overlay_migrations/${replacement_version}_"*.sql)
        [[ -f "${matches[0]}" && ! -e "${matches[1]:-}" ]] || fail "pending replacement must have exactly one local migration: $replacement_version"
        pending_count=$((pending_count + 1))
      fi
      ;;
    *) fail "unknown canonical-lineage status: $canonical_version/$status" ;;
  esac
done < "$CANONICAL_LINEAGE_LEDGER"

[[ "$represented_count" == 12 ]] || fail "canonical-lineage ledger must contain exactly 12 represented_remote rows; found $represented_count"
[[ "$pending_count" == 4 ]] || fail "canonical-lineage ledger must contain exactly 4 pending_forward rows; found $pending_count"

echo "Prepared temporary Supabase workdir: $overlay_root"
echo "Remote-history compatibility stubs: $remote_stub_count"
echo "Hidden represented canonical versions: $represented_count"
echo "Hidden pending canonical versions: $pending_count"
echo "Pending forward replacements: $pending_count"

set +e
SUPABASE_WORKDIR="$overlay_root" supabase db push "${push_flags[@]}"
status=$?
set -e
exit "$status"
\r'/}"
  name="${name// || fail "invalid remote-only version: $version"
  [[ "$evidence" == remote-ledger-only* ]] || fail "remote-only row lacks remote-ledger-only evidence: $version"
  case "$classification" in
    parallel-staging-lineage|duplicate-equivalent-lineage) ;;
    *) fail "unexpected remote-only classification: $version/$classification" ;;
  esac

  matches=("$overlay_migrations/${version}_"*.sql)
  [[ ! -e "${matches[0]}" ]] || fail "remote-only version already has a local migration: $version"
  safe_name="${name%.sql}"
  [[ "$safe_name" =~ ^[a-z0-9_]+$ ]] || fail "unsafe remote-only migration name: $version/$name"

  {
    echo '-- CI-only compatibility stub for an already-applied remote history row.'
    echo '-- This file is intentionally not committed and must never be deployed.'
    echo "-- Remote version: $version"
    echo "-- Remote name: $name"
    echo '-- The schema effect is represented by canonical remote lineage.'
  } > "$overlay_migrations/${version}_${safe_name}.sql"
  remote_stub_count=$((remote_stub_count + 1))
done < "$REMOTE_HISTORY_LEDGER"

[[ "$remote_stub_count" -gt 0 ]] || fail "remote-history ledger is empty"

represented_count=0
pending_count=0
while IFS=, read -r canonical_version status replacement_version _remote_evidence _evidence || [[ -n "${canonical_version:-}" ]]; do
  [[ "$canonical_version" == canonical_version ]] && continue
  [[ "$canonical_version" =~ ^[0-9]{14}$ ]] || fail "invalid canonical version: $canonical_version"

  case "$status" in
    represented_remote|pending_forward)
      matches=("$overlay_migrations/${canonical_version}_"*.sql)
      [[ -f "${matches[0]}" && ! -e "${matches[1]:-}" ]] || fail "canonical version must have exactly one local migration: $canonical_version"
      rm -- "${matches[0]}"
      if [[ "$status" == represented_remote ]]; then
        represented_count=$((represented_count + 1))
      else
        [[ "$replacement_version" =~ ^[0-9]{14}$ ]] || fail "pending canonical version lacks a replacement: $canonical_version"
        matches=("$overlay_migrations/${replacement_version}_"*.sql)
        [[ -f "${matches[0]}" && ! -e "${matches[1]:-}" ]] || fail "pending replacement must have exactly one local migration: $replacement_version"
        pending_count=$((pending_count + 1))
      fi
      ;;
    *) fail "unknown canonical-lineage status: $canonical_version/$status" ;;
  esac
done < "$CANONICAL_LINEAGE_LEDGER"

[[ "$represented_count" -gt 0 ]] || fail "canonical-lineage ledger has no represented remote versions"
[[ "$pending_count" -gt 0 ]] || fail "canonical-lineage ledger has no pending forward versions"

echo "Prepared temporary Supabase workdir: $overlay_root"
echo "Remote-history compatibility stubs: $remote_stub_count"
echo "Hidden represented canonical versions: $represented_count"
echo "Hidden pending canonical versions: $pending_count"
echo "Pending forward replacements: $pending_count"

set +e
SUPABASE_WORKDIR="$overlay_root" supabase db push "${push_flags[@]}"
status=$?
set -e
exit "$status"
\r'/}"
  classification="${classification// || fail "invalid remote-only version: $version"
  [[ "$evidence" == remote-ledger-only* ]] || fail "remote-only row lacks remote-ledger-only evidence: $version"
  case "$classification" in
    parallel-staging-lineage|duplicate-equivalent-lineage) ;;
    *) fail "unexpected remote-only classification: $version/$classification" ;;
  esac

  matches=("$overlay_migrations/${version}_"*.sql)
  [[ ! -e "${matches[0]}" ]] || fail "remote-only version already has a local migration: $version"
  safe_name="${name%.sql}"
  [[ "$safe_name" =~ ^[a-z0-9_]+$ ]] || fail "unsafe remote-only migration name: $version/$name"

  {
    echo '-- CI-only compatibility stub for an already-applied remote history row.'
    echo '-- This file is intentionally not committed and must never be deployed.'
    echo "-- Remote version: $version"
    echo "-- Remote name: $name"
    echo '-- The schema effect is represented by canonical remote lineage.'
  } > "$overlay_migrations/${version}_${safe_name}.sql"
  remote_stub_count=$((remote_stub_count + 1))
done < "$REMOTE_HISTORY_LEDGER"

[[ "$remote_stub_count" -gt 0 ]] || fail "remote-history ledger is empty"

represented_count=0
pending_count=0
while IFS=, read -r canonical_version status replacement_version _remote_evidence _evidence || [[ -n "${canonical_version:-}" ]]; do
  [[ "$canonical_version" == canonical_version ]] && continue
  [[ "$canonical_version" =~ ^[0-9]{14}$ ]] || fail "invalid canonical version: $canonical_version"

  case "$status" in
    represented_remote|pending_forward)
      matches=("$overlay_migrations/${canonical_version}_"*.sql)
      [[ -f "${matches[0]}" && ! -e "${matches[1]:-}" ]] || fail "canonical version must have exactly one local migration: $canonical_version"
      rm -- "${matches[0]}"
      if [[ "$status" == represented_remote ]]; then
        represented_count=$((represented_count + 1))
      else
        [[ "$replacement_version" =~ ^[0-9]{14}$ ]] || fail "pending canonical version lacks a replacement: $canonical_version"
        matches=("$overlay_migrations/${replacement_version}_"*.sql)
        [[ -f "${matches[0]}" && ! -e "${matches[1]:-}" ]] || fail "pending replacement must have exactly one local migration: $replacement_version"
        pending_count=$((pending_count + 1))
      fi
      ;;
    *) fail "unknown canonical-lineage status: $canonical_version/$status" ;;
  esac
done < "$CANONICAL_LINEAGE_LEDGER"

[[ "$represented_count" -gt 0 ]] || fail "canonical-lineage ledger has no represented remote versions"
[[ "$pending_count" -gt 0 ]] || fail "canonical-lineage ledger has no pending forward versions"

echo "Prepared temporary Supabase workdir: $overlay_root"
echo "Remote-history compatibility stubs: $remote_stub_count"
echo "Hidden represented canonical versions: $represented_count"
echo "Hidden pending canonical versions: $pending_count"
echo "Pending forward replacements: $pending_count"

set +e
SUPABASE_WORKDIR="$overlay_root" supabase db push "${push_flags[@]}"
status=$?
set -e
exit "$status"
\r'/}"
  evidence="${evidence// || fail "invalid remote-only version: $version"
  [[ "$evidence" == remote-ledger-only* ]] || fail "remote-only row lacks remote-ledger-only evidence: $version"
  case "$classification" in
    parallel-staging-lineage|duplicate-equivalent-lineage) ;;
    *) fail "unexpected remote-only classification: $version/$classification" ;;
  esac

  matches=("$overlay_migrations/${version}_"*.sql)
  [[ ! -e "${matches[0]}" ]] || fail "remote-only version already has a local migration: $version"
  safe_name="${name%.sql}"
  [[ "$safe_name" =~ ^[a-z0-9_]+$ ]] || fail "unsafe remote-only migration name: $version/$name"

  {
    echo '-- CI-only compatibility stub for an already-applied remote history row.'
    echo '-- This file is intentionally not committed and must never be deployed.'
    echo "-- Remote version: $version"
    echo "-- Remote name: $name"
    echo '-- The schema effect is represented by canonical remote lineage.'
  } > "$overlay_migrations/${version}_${safe_name}.sql"
  remote_stub_count=$((remote_stub_count + 1))
done < "$REMOTE_HISTORY_LEDGER"

[[ "$remote_stub_count" -gt 0 ]] || fail "remote-history ledger is empty"

represented_count=0
pending_count=0
while IFS=, read -r canonical_version status replacement_version _remote_evidence _evidence || [[ -n "${canonical_version:-}" ]]; do
  [[ "$canonical_version" == canonical_version ]] && continue
  [[ "$canonical_version" =~ ^[0-9]{14}$ ]] || fail "invalid canonical version: $canonical_version"

  case "$status" in
    represented_remote|pending_forward)
      matches=("$overlay_migrations/${canonical_version}_"*.sql)
      [[ -f "${matches[0]}" && ! -e "${matches[1]:-}" ]] || fail "canonical version must have exactly one local migration: $canonical_version"
      rm -- "${matches[0]}"
      if [[ "$status" == represented_remote ]]; then
        represented_count=$((represented_count + 1))
      else
        [[ "$replacement_version" =~ ^[0-9]{14}$ ]] || fail "pending canonical version lacks a replacement: $canonical_version"
        matches=("$overlay_migrations/${replacement_version}_"*.sql)
        [[ -f "${matches[0]}" && ! -e "${matches[1]:-}" ]] || fail "pending replacement must have exactly one local migration: $replacement_version"
        pending_count=$((pending_count + 1))
      fi
      ;;
    *) fail "unknown canonical-lineage status: $canonical_version/$status" ;;
  esac
done < "$CANONICAL_LINEAGE_LEDGER"

[[ "$represented_count" -gt 0 ]] || fail "canonical-lineage ledger has no represented remote versions"
[[ "$pending_count" -gt 0 ]] || fail "canonical-lineage ledger has no pending forward versions"

echo "Prepared temporary Supabase workdir: $overlay_root"
echo "Remote-history compatibility stubs: $remote_stub_count"
echo "Hidden represented canonical versions: $represented_count"
echo "Hidden pending canonical versions: $pending_count"
echo "Pending forward replacements: $pending_count"

set +e
SUPABASE_WORKDIR="$overlay_root" supabase db push "${push_flags[@]}"
status=$?
set -e
exit "$status"
\r'/}"
  [[ "$version" =~ ^[0-9]{14}$ ]] || fail "invalid remote-only version: $version"
  [[ "$evidence" == remote-ledger-only* ]] || fail "remote-only row lacks remote-ledger-only evidence: $version"
  case "$classification" in
    parallel-staging-lineage|duplicate-equivalent-lineage) ;;
    *) fail "unexpected remote-only classification: $version/$classification" ;;
  esac

  matches=("$overlay_migrations/${version}_"*.sql)
  [[ ! -e "${matches[0]}" ]] || fail "remote-only version already has a local migration: $version"
  safe_name="${name%.sql}"
  [[ "$safe_name" =~ ^[a-z0-9_]+$ ]] || fail "unsafe remote-only migration name: $version/$name"

  {
    echo '-- CI-only compatibility stub for an already-applied remote history row.'
    echo '-- This file is intentionally not committed and must never be deployed.'
    echo "-- Remote version: $version"
    echo "-- Remote name: $name"
    echo '-- The schema effect is represented by canonical remote lineage.'
  } > "$overlay_migrations/${version}_${safe_name}.sql"
  remote_stub_count=$((remote_stub_count + 1))
done < "$REMOTE_HISTORY_LEDGER"

[[ "$remote_stub_count" -gt 0 ]] || fail "remote-history ledger is empty"

represented_count=0
pending_count=0
while IFS=, read -r canonical_version status replacement_version _remote_evidence _evidence || [[ -n "${canonical_version:-}" ]]; do
  [[ "$canonical_version" == canonical_version ]] && continue
  [[ "$canonical_version" =~ ^[0-9]{14}$ ]] || fail "invalid canonical version: $canonical_version"

  case "$status" in
    represented_remote|pending_forward)
      matches=("$overlay_migrations/${canonical_version}_"*.sql)
      [[ -f "${matches[0]}" && ! -e "${matches[1]:-}" ]] || fail "canonical version must have exactly one local migration: $canonical_version"
      rm -- "${matches[0]}"
      if [[ "$status" == represented_remote ]]; then
        represented_count=$((represented_count + 1))
      else
        [[ "$replacement_version" =~ ^[0-9]{14}$ ]] || fail "pending canonical version lacks a replacement: $canonical_version"
        matches=("$overlay_migrations/${replacement_version}_"*.sql)
        [[ -f "${matches[0]}" && ! -e "${matches[1]:-}" ]] || fail "pending replacement must have exactly one local migration: $replacement_version"
        pending_count=$((pending_count + 1))
      fi
      ;;
    *) fail "unknown canonical-lineage status: $canonical_version/$status" ;;
  esac
done < "$CANONICAL_LINEAGE_LEDGER"

[[ "$represented_count" -gt 0 ]] || fail "canonical-lineage ledger has no represented remote versions"
[[ "$pending_count" -gt 0 ]] || fail "canonical-lineage ledger has no pending forward versions"

echo "Prepared temporary Supabase workdir: $overlay_root"
echo "Remote-history compatibility stubs: $remote_stub_count"
echo "Hidden represented canonical versions: $represented_count"
echo "Hidden pending canonical versions: $pending_count"
echo "Pending forward replacements: $pending_count"

set +e
SUPABASE_WORKDIR="$overlay_root" supabase db push "${push_flags[@]}"
status=$?
set -e
exit "$status"
\r'/}"
  status="${status// || fail "invalid canonical version: $canonical_version"

  case "$status" in
    represented_remote|pending_forward)
      matches=("$overlay_migrations/${canonical_version}_"*.sql)
      [[ -f "${matches[0]}" && ! -e "${matches[1]:-}" ]] || fail "canonical version must have exactly one local migration: $canonical_version"
      rm -- "${matches[0]}"
      if [[ "$status" == represented_remote ]]; then
        represented_count=$((represented_count + 1))
      else
        [[ "$replacement_version" =~ ^[0-9]{14}$ ]] || fail "pending canonical version lacks a replacement: $canonical_version"
        matches=("$overlay_migrations/${replacement_version}_"*.sql)
        [[ -f "${matches[0]}" && ! -e "${matches[1]:-}" ]] || fail "pending replacement must have exactly one local migration: $replacement_version"
        pending_count=$((pending_count + 1))
      fi
      ;;
    *) fail "unknown canonical-lineage status: $canonical_version/$status" ;;
  esac
done < "$CANONICAL_LINEAGE_LEDGER"

[[ "$represented_count" -gt 0 ]] || fail "canonical-lineage ledger has no represented remote versions"
[[ "$pending_count" -gt 0 ]] || fail "canonical-lineage ledger has no pending forward versions"

echo "Prepared temporary Supabase workdir: $overlay_root"
echo "Remote-history compatibility stubs: $remote_stub_count"
echo "Hidden represented canonical versions: $represented_count"
echo "Hidden pending canonical versions: $pending_count"
echo "Pending forward replacements: $pending_count"

set +e
SUPABASE_WORKDIR="$overlay_root" supabase db push "${push_flags[@]}"
status=$?
set -e
exit "$status"
\r'/}"
  name="${name// || fail "invalid remote-only version: $version"
  [[ "$evidence" == remote-ledger-only* ]] || fail "remote-only row lacks remote-ledger-only evidence: $version"
  case "$classification" in
    parallel-staging-lineage|duplicate-equivalent-lineage) ;;
    *) fail "unexpected remote-only classification: $version/$classification" ;;
  esac

  matches=("$overlay_migrations/${version}_"*.sql)
  [[ ! -e "${matches[0]}" ]] || fail "remote-only version already has a local migration: $version"
  safe_name="${name%.sql}"
  [[ "$safe_name" =~ ^[a-z0-9_]+$ ]] || fail "unsafe remote-only migration name: $version/$name"

  {
    echo '-- CI-only compatibility stub for an already-applied remote history row.'
    echo '-- This file is intentionally not committed and must never be deployed.'
    echo "-- Remote version: $version"
    echo "-- Remote name: $name"
    echo '-- The schema effect is represented by canonical remote lineage.'
  } > "$overlay_migrations/${version}_${safe_name}.sql"
  remote_stub_count=$((remote_stub_count + 1))
done < "$REMOTE_HISTORY_LEDGER"

[[ "$remote_stub_count" -gt 0 ]] || fail "remote-history ledger is empty"

represented_count=0
pending_count=0
while IFS=, read -r canonical_version status replacement_version _remote_evidence _evidence || [[ -n "${canonical_version:-}" ]]; do
  [[ "$canonical_version" == canonical_version ]] && continue
  [[ "$canonical_version" =~ ^[0-9]{14}$ ]] || fail "invalid canonical version: $canonical_version"

  case "$status" in
    represented_remote|pending_forward)
      matches=("$overlay_migrations/${canonical_version}_"*.sql)
      [[ -f "${matches[0]}" && ! -e "${matches[1]:-}" ]] || fail "canonical version must have exactly one local migration: $canonical_version"
      rm -- "${matches[0]}"
      if [[ "$status" == represented_remote ]]; then
        represented_count=$((represented_count + 1))
      else
        [[ "$replacement_version" =~ ^[0-9]{14}$ ]] || fail "pending canonical version lacks a replacement: $canonical_version"
        matches=("$overlay_migrations/${replacement_version}_"*.sql)
        [[ -f "${matches[0]}" && ! -e "${matches[1]:-}" ]] || fail "pending replacement must have exactly one local migration: $replacement_version"
        pending_count=$((pending_count + 1))
      fi
      ;;
    *) fail "unknown canonical-lineage status: $canonical_version/$status" ;;
  esac
done < "$CANONICAL_LINEAGE_LEDGER"

[[ "$represented_count" -gt 0 ]] || fail "canonical-lineage ledger has no represented remote versions"
[[ "$pending_count" -gt 0 ]] || fail "canonical-lineage ledger has no pending forward versions"

echo "Prepared temporary Supabase workdir: $overlay_root"
echo "Remote-history compatibility stubs: $remote_stub_count"
echo "Hidden represented canonical versions: $represented_count"
echo "Hidden pending canonical versions: $pending_count"
echo "Pending forward replacements: $pending_count"

set +e
SUPABASE_WORKDIR="$overlay_root" supabase db push "${push_flags[@]}"
status=$?
set -e
exit "$status"
\r'/}"
  classification="${classification// || fail "invalid remote-only version: $version"
  [[ "$evidence" == remote-ledger-only* ]] || fail "remote-only row lacks remote-ledger-only evidence: $version"
  case "$classification" in
    parallel-staging-lineage|duplicate-equivalent-lineage) ;;
    *) fail "unexpected remote-only classification: $version/$classification" ;;
  esac

  matches=("$overlay_migrations/${version}_"*.sql)
  [[ ! -e "${matches[0]}" ]] || fail "remote-only version already has a local migration: $version"
  safe_name="${name%.sql}"
  [[ "$safe_name" =~ ^[a-z0-9_]+$ ]] || fail "unsafe remote-only migration name: $version/$name"

  {
    echo '-- CI-only compatibility stub for an already-applied remote history row.'
    echo '-- This file is intentionally not committed and must never be deployed.'
    echo "-- Remote version: $version"
    echo "-- Remote name: $name"
    echo '-- The schema effect is represented by canonical remote lineage.'
  } > "$overlay_migrations/${version}_${safe_name}.sql"
  remote_stub_count=$((remote_stub_count + 1))
done < "$REMOTE_HISTORY_LEDGER"

[[ "$remote_stub_count" -gt 0 ]] || fail "remote-history ledger is empty"

represented_count=0
pending_count=0
while IFS=, read -r canonical_version status replacement_version _remote_evidence _evidence || [[ -n "${canonical_version:-}" ]]; do
  [[ "$canonical_version" == canonical_version ]] && continue
  [[ "$canonical_version" =~ ^[0-9]{14}$ ]] || fail "invalid canonical version: $canonical_version"

  case "$status" in
    represented_remote|pending_forward)
      matches=("$overlay_migrations/${canonical_version}_"*.sql)
      [[ -f "${matches[0]}" && ! -e "${matches[1]:-}" ]] || fail "canonical version must have exactly one local migration: $canonical_version"
      rm -- "${matches[0]}"
      if [[ "$status" == represented_remote ]]; then
        represented_count=$((represented_count + 1))
      else
        [[ "$replacement_version" =~ ^[0-9]{14}$ ]] || fail "pending canonical version lacks a replacement: $canonical_version"
        matches=("$overlay_migrations/${replacement_version}_"*.sql)
        [[ -f "${matches[0]}" && ! -e "${matches[1]:-}" ]] || fail "pending replacement must have exactly one local migration: $replacement_version"
        pending_count=$((pending_count + 1))
      fi
      ;;
    *) fail "unknown canonical-lineage status: $canonical_version/$status" ;;
  esac
done < "$CANONICAL_LINEAGE_LEDGER"

[[ "$represented_count" -gt 0 ]] || fail "canonical-lineage ledger has no represented remote versions"
[[ "$pending_count" -gt 0 ]] || fail "canonical-lineage ledger has no pending forward versions"

echo "Prepared temporary Supabase workdir: $overlay_root"
echo "Remote-history compatibility stubs: $remote_stub_count"
echo "Hidden represented canonical versions: $represented_count"
echo "Hidden pending canonical versions: $pending_count"
echo "Pending forward replacements: $pending_count"

set +e
SUPABASE_WORKDIR="$overlay_root" supabase db push "${push_flags[@]}"
status=$?
set -e
exit "$status"
\r'/}"
  evidence="${evidence// || fail "invalid remote-only version: $version"
  [[ "$evidence" == remote-ledger-only* ]] || fail "remote-only row lacks remote-ledger-only evidence: $version"
  case "$classification" in
    parallel-staging-lineage|duplicate-equivalent-lineage) ;;
    *) fail "unexpected remote-only classification: $version/$classification" ;;
  esac

  matches=("$overlay_migrations/${version}_"*.sql)
  [[ ! -e "${matches[0]}" ]] || fail "remote-only version already has a local migration: $version"
  safe_name="${name%.sql}"
  [[ "$safe_name" =~ ^[a-z0-9_]+$ ]] || fail "unsafe remote-only migration name: $version/$name"

  {
    echo '-- CI-only compatibility stub for an already-applied remote history row.'
    echo '-- This file is intentionally not committed and must never be deployed.'
    echo "-- Remote version: $version"
    echo "-- Remote name: $name"
    echo '-- The schema effect is represented by canonical remote lineage.'
  } > "$overlay_migrations/${version}_${safe_name}.sql"
  remote_stub_count=$((remote_stub_count + 1))
done < "$REMOTE_HISTORY_LEDGER"

[[ "$remote_stub_count" -gt 0 ]] || fail "remote-history ledger is empty"

represented_count=0
pending_count=0
while IFS=, read -r canonical_version status replacement_version _remote_evidence _evidence || [[ -n "${canonical_version:-}" ]]; do
  [[ "$canonical_version" == canonical_version ]] && continue
  [[ "$canonical_version" =~ ^[0-9]{14}$ ]] || fail "invalid canonical version: $canonical_version"

  case "$status" in
    represented_remote|pending_forward)
      matches=("$overlay_migrations/${canonical_version}_"*.sql)
      [[ -f "${matches[0]}" && ! -e "${matches[1]:-}" ]] || fail "canonical version must have exactly one local migration: $canonical_version"
      rm -- "${matches[0]}"
      if [[ "$status" == represented_remote ]]; then
        represented_count=$((represented_count + 1))
      else
        [[ "$replacement_version" =~ ^[0-9]{14}$ ]] || fail "pending canonical version lacks a replacement: $canonical_version"
        matches=("$overlay_migrations/${replacement_version}_"*.sql)
        [[ -f "${matches[0]}" && ! -e "${matches[1]:-}" ]] || fail "pending replacement must have exactly one local migration: $replacement_version"
        pending_count=$((pending_count + 1))
      fi
      ;;
    *) fail "unknown canonical-lineage status: $canonical_version/$status" ;;
  esac
done < "$CANONICAL_LINEAGE_LEDGER"

[[ "$represented_count" -gt 0 ]] || fail "canonical-lineage ledger has no represented remote versions"
[[ "$pending_count" -gt 0 ]] || fail "canonical-lineage ledger has no pending forward versions"

echo "Prepared temporary Supabase workdir: $overlay_root"
echo "Remote-history compatibility stubs: $remote_stub_count"
echo "Hidden represented canonical versions: $represented_count"
echo "Hidden pending canonical versions: $pending_count"
echo "Pending forward replacements: $pending_count"

set +e
SUPABASE_WORKDIR="$overlay_root" supabase db push "${push_flags[@]}"
status=$?
set -e
exit "$status"
\r'/}"
  [[ "$version" =~ ^[0-9]{14}$ ]] || fail "invalid remote-only version: $version"
  [[ "$evidence" == remote-ledger-only* ]] || fail "remote-only row lacks remote-ledger-only evidence: $version"
  case "$classification" in
    parallel-staging-lineage|duplicate-equivalent-lineage) ;;
    *) fail "unexpected remote-only classification: $version/$classification" ;;
  esac

  matches=("$overlay_migrations/${version}_"*.sql)
  [[ ! -e "${matches[0]}" ]] || fail "remote-only version already has a local migration: $version"
  safe_name="${name%.sql}"
  [[ "$safe_name" =~ ^[a-z0-9_]+$ ]] || fail "unsafe remote-only migration name: $version/$name"

  {
    echo '-- CI-only compatibility stub for an already-applied remote history row.'
    echo '-- This file is intentionally not committed and must never be deployed.'
    echo "-- Remote version: $version"
    echo "-- Remote name: $name"
    echo '-- The schema effect is represented by canonical remote lineage.'
  } > "$overlay_migrations/${version}_${safe_name}.sql"
  remote_stub_count=$((remote_stub_count + 1))
done < "$REMOTE_HISTORY_LEDGER"

[[ "$remote_stub_count" -gt 0 ]] || fail "remote-history ledger is empty"

represented_count=0
pending_count=0
while IFS=, read -r canonical_version status replacement_version _remote_evidence _evidence || [[ -n "${canonical_version:-}" ]]; do
  [[ "$canonical_version" == canonical_version ]] && continue
  [[ "$canonical_version" =~ ^[0-9]{14}$ ]] || fail "invalid canonical version: $canonical_version"

  case "$status" in
    represented_remote|pending_forward)
      matches=("$overlay_migrations/${canonical_version}_"*.sql)
      [[ -f "${matches[0]}" && ! -e "${matches[1]:-}" ]] || fail "canonical version must have exactly one local migration: $canonical_version"
      rm -- "${matches[0]}"
      if [[ "$status" == represented_remote ]]; then
        represented_count=$((represented_count + 1))
      else
        [[ "$replacement_version" =~ ^[0-9]{14}$ ]] || fail "pending canonical version lacks a replacement: $canonical_version"
        matches=("$overlay_migrations/${replacement_version}_"*.sql)
        [[ -f "${matches[0]}" && ! -e "${matches[1]:-}" ]] || fail "pending replacement must have exactly one local migration: $replacement_version"
        pending_count=$((pending_count + 1))
      fi
      ;;
    *) fail "unknown canonical-lineage status: $canonical_version/$status" ;;
  esac
done < "$CANONICAL_LINEAGE_LEDGER"

[[ "$represented_count" -gt 0 ]] || fail "canonical-lineage ledger has no represented remote versions"
[[ "$pending_count" -gt 0 ]] || fail "canonical-lineage ledger has no pending forward versions"

echo "Prepared temporary Supabase workdir: $overlay_root"
echo "Remote-history compatibility stubs: $remote_stub_count"
echo "Hidden represented canonical versions: $represented_count"
echo "Hidden pending canonical versions: $pending_count"
echo "Pending forward replacements: $pending_count"

set +e
SUPABASE_WORKDIR="$overlay_root" supabase db push "${push_flags[@]}"
status=$?
set -e
exit "$status"
\r'/}"
  replacement_version="${replacement_version// || fail "invalid canonical version: $canonical_version"

  case "$status" in
    represented_remote|pending_forward)
      matches=("$overlay_migrations/${canonical_version}_"*.sql)
      [[ -f "${matches[0]}" && ! -e "${matches[1]:-}" ]] || fail "canonical version must have exactly one local migration: $canonical_version"
      rm -- "${matches[0]}"
      if [[ "$status" == represented_remote ]]; then
        represented_count=$((represented_count + 1))
      else
        [[ "$replacement_version" =~ ^[0-9]{14}$ ]] || fail "pending canonical version lacks a replacement: $canonical_version"
        matches=("$overlay_migrations/${replacement_version}_"*.sql)
        [[ -f "${matches[0]}" && ! -e "${matches[1]:-}" ]] || fail "pending replacement must have exactly one local migration: $replacement_version"
        pending_count=$((pending_count + 1))
      fi
      ;;
    *) fail "unknown canonical-lineage status: $canonical_version/$status" ;;
  esac
done < "$CANONICAL_LINEAGE_LEDGER"

[[ "$represented_count" -gt 0 ]] || fail "canonical-lineage ledger has no represented remote versions"
[[ "$pending_count" -gt 0 ]] || fail "canonical-lineage ledger has no pending forward versions"

echo "Prepared temporary Supabase workdir: $overlay_root"
echo "Remote-history compatibility stubs: $remote_stub_count"
echo "Hidden represented canonical versions: $represented_count"
echo "Hidden pending canonical versions: $pending_count"
echo "Pending forward replacements: $pending_count"

set +e
SUPABASE_WORKDIR="$overlay_root" supabase db push "${push_flags[@]}"
status=$?
set -e
exit "$status"
\r'/}"
  name="${name// || fail "invalid remote-only version: $version"
  [[ "$evidence" == remote-ledger-only* ]] || fail "remote-only row lacks remote-ledger-only evidence: $version"
  case "$classification" in
    parallel-staging-lineage|duplicate-equivalent-lineage) ;;
    *) fail "unexpected remote-only classification: $version/$classification" ;;
  esac

  matches=("$overlay_migrations/${version}_"*.sql)
  [[ ! -e "${matches[0]}" ]] || fail "remote-only version already has a local migration: $version"
  safe_name="${name%.sql}"
  [[ "$safe_name" =~ ^[a-z0-9_]+$ ]] || fail "unsafe remote-only migration name: $version/$name"

  {
    echo '-- CI-only compatibility stub for an already-applied remote history row.'
    echo '-- This file is intentionally not committed and must never be deployed.'
    echo "-- Remote version: $version"
    echo "-- Remote name: $name"
    echo '-- The schema effect is represented by canonical remote lineage.'
  } > "$overlay_migrations/${version}_${safe_name}.sql"
  remote_stub_count=$((remote_stub_count + 1))
done < "$REMOTE_HISTORY_LEDGER"

[[ "$remote_stub_count" -gt 0 ]] || fail "remote-history ledger is empty"

represented_count=0
pending_count=0
while IFS=, read -r canonical_version status replacement_version _remote_evidence _evidence || [[ -n "${canonical_version:-}" ]]; do
  [[ "$canonical_version" == canonical_version ]] && continue
  [[ "$canonical_version" =~ ^[0-9]{14}$ ]] || fail "invalid canonical version: $canonical_version"

  case "$status" in
    represented_remote|pending_forward)
      matches=("$overlay_migrations/${canonical_version}_"*.sql)
      [[ -f "${matches[0]}" && ! -e "${matches[1]:-}" ]] || fail "canonical version must have exactly one local migration: $canonical_version"
      rm -- "${matches[0]}"
      if [[ "$status" == represented_remote ]]; then
        represented_count=$((represented_count + 1))
      else
        [[ "$replacement_version" =~ ^[0-9]{14}$ ]] || fail "pending canonical version lacks a replacement: $canonical_version"
        matches=("$overlay_migrations/${replacement_version}_"*.sql)
        [[ -f "${matches[0]}" && ! -e "${matches[1]:-}" ]] || fail "pending replacement must have exactly one local migration: $replacement_version"
        pending_count=$((pending_count + 1))
      fi
      ;;
    *) fail "unknown canonical-lineage status: $canonical_version/$status" ;;
  esac
done < "$CANONICAL_LINEAGE_LEDGER"

[[ "$represented_count" -gt 0 ]] || fail "canonical-lineage ledger has no represented remote versions"
[[ "$pending_count" -gt 0 ]] || fail "canonical-lineage ledger has no pending forward versions"

echo "Prepared temporary Supabase workdir: $overlay_root"
echo "Remote-history compatibility stubs: $remote_stub_count"
echo "Hidden represented canonical versions: $represented_count"
echo "Hidden pending canonical versions: $pending_count"
echo "Pending forward replacements: $pending_count"

set +e
SUPABASE_WORKDIR="$overlay_root" supabase db push "${push_flags[@]}"
status=$?
set -e
exit "$status"
\r'/}"
  classification="${classification// || fail "invalid remote-only version: $version"
  [[ "$evidence" == remote-ledger-only* ]] || fail "remote-only row lacks remote-ledger-only evidence: $version"
  case "$classification" in
    parallel-staging-lineage|duplicate-equivalent-lineage) ;;
    *) fail "unexpected remote-only classification: $version/$classification" ;;
  esac

  matches=("$overlay_migrations/${version}_"*.sql)
  [[ ! -e "${matches[0]}" ]] || fail "remote-only version already has a local migration: $version"
  safe_name="${name%.sql}"
  [[ "$safe_name" =~ ^[a-z0-9_]+$ ]] || fail "unsafe remote-only migration name: $version/$name"

  {
    echo '-- CI-only compatibility stub for an already-applied remote history row.'
    echo '-- This file is intentionally not committed and must never be deployed.'
    echo "-- Remote version: $version"
    echo "-- Remote name: $name"
    echo '-- The schema effect is represented by canonical remote lineage.'
  } > "$overlay_migrations/${version}_${safe_name}.sql"
  remote_stub_count=$((remote_stub_count + 1))
done < "$REMOTE_HISTORY_LEDGER"

[[ "$remote_stub_count" -gt 0 ]] || fail "remote-history ledger is empty"

represented_count=0
pending_count=0
while IFS=, read -r canonical_version status replacement_version _remote_evidence _evidence || [[ -n "${canonical_version:-}" ]]; do
  [[ "$canonical_version" == canonical_version ]] && continue
  [[ "$canonical_version" =~ ^[0-9]{14}$ ]] || fail "invalid canonical version: $canonical_version"

  case "$status" in
    represented_remote|pending_forward)
      matches=("$overlay_migrations/${canonical_version}_"*.sql)
      [[ -f "${matches[0]}" && ! -e "${matches[1]:-}" ]] || fail "canonical version must have exactly one local migration: $canonical_version"
      rm -- "${matches[0]}"
      if [[ "$status" == represented_remote ]]; then
        represented_count=$((represented_count + 1))
      else
        [[ "$replacement_version" =~ ^[0-9]{14}$ ]] || fail "pending canonical version lacks a replacement: $canonical_version"
        matches=("$overlay_migrations/${replacement_version}_"*.sql)
        [[ -f "${matches[0]}" && ! -e "${matches[1]:-}" ]] || fail "pending replacement must have exactly one local migration: $replacement_version"
        pending_count=$((pending_count + 1))
      fi
      ;;
    *) fail "unknown canonical-lineage status: $canonical_version/$status" ;;
  esac
done < "$CANONICAL_LINEAGE_LEDGER"

[[ "$represented_count" -gt 0 ]] || fail "canonical-lineage ledger has no represented remote versions"
[[ "$pending_count" -gt 0 ]] || fail "canonical-lineage ledger has no pending forward versions"

echo "Prepared temporary Supabase workdir: $overlay_root"
echo "Remote-history compatibility stubs: $remote_stub_count"
echo "Hidden represented canonical versions: $represented_count"
echo "Hidden pending canonical versions: $pending_count"
echo "Pending forward replacements: $pending_count"

set +e
SUPABASE_WORKDIR="$overlay_root" supabase db push "${push_flags[@]}"
status=$?
set -e
exit "$status"
\r'/}"
  evidence="${evidence// || fail "invalid remote-only version: $version"
  [[ "$evidence" == remote-ledger-only* ]] || fail "remote-only row lacks remote-ledger-only evidence: $version"
  case "$classification" in
    parallel-staging-lineage|duplicate-equivalent-lineage) ;;
    *) fail "unexpected remote-only classification: $version/$classification" ;;
  esac

  matches=("$overlay_migrations/${version}_"*.sql)
  [[ ! -e "${matches[0]}" ]] || fail "remote-only version already has a local migration: $version"
  safe_name="${name%.sql}"
  [[ "$safe_name" =~ ^[a-z0-9_]+$ ]] || fail "unsafe remote-only migration name: $version/$name"

  {
    echo '-- CI-only compatibility stub for an already-applied remote history row.'
    echo '-- This file is intentionally not committed and must never be deployed.'
    echo "-- Remote version: $version"
    echo "-- Remote name: $name"
    echo '-- The schema effect is represented by canonical remote lineage.'
  } > "$overlay_migrations/${version}_${safe_name}.sql"
  remote_stub_count=$((remote_stub_count + 1))
done < "$REMOTE_HISTORY_LEDGER"

[[ "$remote_stub_count" -gt 0 ]] || fail "remote-history ledger is empty"

represented_count=0
pending_count=0
while IFS=, read -r canonical_version status replacement_version _remote_evidence _evidence || [[ -n "${canonical_version:-}" ]]; do
  [[ "$canonical_version" == canonical_version ]] && continue
  [[ "$canonical_version" =~ ^[0-9]{14}$ ]] || fail "invalid canonical version: $canonical_version"

  case "$status" in
    represented_remote|pending_forward)
      matches=("$overlay_migrations/${canonical_version}_"*.sql)
      [[ -f "${matches[0]}" && ! -e "${matches[1]:-}" ]] || fail "canonical version must have exactly one local migration: $canonical_version"
      rm -- "${matches[0]}"
      if [[ "$status" == represented_remote ]]; then
        represented_count=$((represented_count + 1))
      else
        [[ "$replacement_version" =~ ^[0-9]{14}$ ]] || fail "pending canonical version lacks a replacement: $canonical_version"
        matches=("$overlay_migrations/${replacement_version}_"*.sql)
        [[ -f "${matches[0]}" && ! -e "${matches[1]:-}" ]] || fail "pending replacement must have exactly one local migration: $replacement_version"
        pending_count=$((pending_count + 1))
      fi
      ;;
    *) fail "unknown canonical-lineage status: $canonical_version/$status" ;;
  esac
done < "$CANONICAL_LINEAGE_LEDGER"

[[ "$represented_count" -gt 0 ]] || fail "canonical-lineage ledger has no represented remote versions"
[[ "$pending_count" -gt 0 ]] || fail "canonical-lineage ledger has no pending forward versions"

echo "Prepared temporary Supabase workdir: $overlay_root"
echo "Remote-history compatibility stubs: $remote_stub_count"
echo "Hidden represented canonical versions: $represented_count"
echo "Hidden pending canonical versions: $pending_count"
echo "Pending forward replacements: $pending_count"

set +e
SUPABASE_WORKDIR="$overlay_root" supabase db push "${push_flags[@]}"
status=$?
set -e
exit "$status"
\r'/}"
  [[ "$version" =~ ^[0-9]{14}$ ]] || fail "invalid remote-only version: $version"
  [[ "$evidence" == remote-ledger-only* ]] || fail "remote-only row lacks remote-ledger-only evidence: $version"
  case "$classification" in
    parallel-staging-lineage|duplicate-equivalent-lineage) ;;
    *) fail "unexpected remote-only classification: $version/$classification" ;;
  esac

  matches=("$overlay_migrations/${version}_"*.sql)
  [[ ! -e "${matches[0]}" ]] || fail "remote-only version already has a local migration: $version"
  safe_name="${name%.sql}"
  [[ "$safe_name" =~ ^[a-z0-9_]+$ ]] || fail "unsafe remote-only migration name: $version/$name"

  {
    echo '-- CI-only compatibility stub for an already-applied remote history row.'
    echo '-- This file is intentionally not committed and must never be deployed.'
    echo "-- Remote version: $version"
    echo "-- Remote name: $name"
    echo '-- The schema effect is represented by canonical remote lineage.'
  } > "$overlay_migrations/${version}_${safe_name}.sql"
  remote_stub_count=$((remote_stub_count + 1))
done < "$REMOTE_HISTORY_LEDGER"

[[ "$remote_stub_count" -gt 0 ]] || fail "remote-history ledger is empty"

represented_count=0
pending_count=0
while IFS=, read -r canonical_version status replacement_version _remote_evidence _evidence || [[ -n "${canonical_version:-}" ]]; do
  [[ "$canonical_version" == canonical_version ]] && continue
  [[ "$canonical_version" =~ ^[0-9]{14}$ ]] || fail "invalid canonical version: $canonical_version"

  case "$status" in
    represented_remote|pending_forward)
      matches=("$overlay_migrations/${canonical_version}_"*.sql)
      [[ -f "${matches[0]}" && ! -e "${matches[1]:-}" ]] || fail "canonical version must have exactly one local migration: $canonical_version"
      rm -- "${matches[0]}"
      if [[ "$status" == represented_remote ]]; then
        represented_count=$((represented_count + 1))
      else
        [[ "$replacement_version" =~ ^[0-9]{14}$ ]] || fail "pending canonical version lacks a replacement: $canonical_version"
        matches=("$overlay_migrations/${replacement_version}_"*.sql)
        [[ -f "${matches[0]}" && ! -e "${matches[1]:-}" ]] || fail "pending replacement must have exactly one local migration: $replacement_version"
        pending_count=$((pending_count + 1))
      fi
      ;;
    *) fail "unknown canonical-lineage status: $canonical_version/$status" ;;
  esac
done < "$CANONICAL_LINEAGE_LEDGER"

[[ "$represented_count" -gt 0 ]] || fail "canonical-lineage ledger has no represented remote versions"
[[ "$pending_count" -gt 0 ]] || fail "canonical-lineage ledger has no pending forward versions"

echo "Prepared temporary Supabase workdir: $overlay_root"
echo "Remote-history compatibility stubs: $remote_stub_count"
echo "Hidden represented canonical versions: $represented_count"
echo "Hidden pending canonical versions: $pending_count"
echo "Pending forward replacements: $pending_count"

set +e
SUPABASE_WORKDIR="$overlay_root" supabase db push "${push_flags[@]}"
status=$?
set -e
exit "$status"
\r'/}"
  [[ "$canonical_version" =~ ^[0-9]{14}$ ]] || fail "invalid canonical version: $canonical_version"

  case "$status" in
    represented_remote|pending_forward)
      matches=("$overlay_migrations/${canonical_version}_"*.sql)
      [[ -f "${matches[0]}" && ! -e "${matches[1]:-}" ]] || fail "canonical version must have exactly one local migration: $canonical_version"
      rm -- "${matches[0]}"
      if [[ "$status" == represented_remote ]]; then
        represented_count=$((represented_count + 1))
      else
        [[ "$replacement_version" =~ ^[0-9]{14}$ ]] || fail "pending canonical version lacks a replacement: $canonical_version"
        matches=("$overlay_migrations/${replacement_version}_"*.sql)
        [[ -f "${matches[0]}" && ! -e "${matches[1]:-}" ]] || fail "pending replacement must have exactly one local migration: $replacement_version"
        pending_count=$((pending_count + 1))
      fi
      ;;
    *) fail "unknown canonical-lineage status: $canonical_version/$status" ;;
  esac
done < "$CANONICAL_LINEAGE_LEDGER"

[[ "$represented_count" -gt 0 ]] || fail "canonical-lineage ledger has no represented remote versions"
[[ "$pending_count" -gt 0 ]] || fail "canonical-lineage ledger has no pending forward versions"

echo "Prepared temporary Supabase workdir: $overlay_root"
echo "Remote-history compatibility stubs: $remote_stub_count"
echo "Hidden represented canonical versions: $represented_count"
echo "Hidden pending canonical versions: $pending_count"
echo "Pending forward replacements: $pending_count"

set +e
SUPABASE_WORKDIR="$overlay_root" supabase db push "${push_flags[@]}"
status=$?
set -e
exit "$status"
\r'/}"
  name="${name// || fail "invalid remote-only version: $version"
  [[ "$evidence" == remote-ledger-only* ]] || fail "remote-only row lacks remote-ledger-only evidence: $version"
  case "$classification" in
    parallel-staging-lineage|duplicate-equivalent-lineage) ;;
    *) fail "unexpected remote-only classification: $version/$classification" ;;
  esac

  matches=("$overlay_migrations/${version}_"*.sql)
  [[ ! -e "${matches[0]}" ]] || fail "remote-only version already has a local migration: $version"
  safe_name="${name%.sql}"
  [[ "$safe_name" =~ ^[a-z0-9_]+$ ]] || fail "unsafe remote-only migration name: $version/$name"

  {
    echo '-- CI-only compatibility stub for an already-applied remote history row.'
    echo '-- This file is intentionally not committed and must never be deployed.'
    echo "-- Remote version: $version"
    echo "-- Remote name: $name"
    echo '-- The schema effect is represented by canonical remote lineage.'
  } > "$overlay_migrations/${version}_${safe_name}.sql"
  remote_stub_count=$((remote_stub_count + 1))
done < "$REMOTE_HISTORY_LEDGER"

[[ "$remote_stub_count" -gt 0 ]] || fail "remote-history ledger is empty"

represented_count=0
pending_count=0
while IFS=, read -r canonical_version status replacement_version _remote_evidence _evidence || [[ -n "${canonical_version:-}" ]]; do
  [[ "$canonical_version" == canonical_version ]] && continue
  [[ "$canonical_version" =~ ^[0-9]{14}$ ]] || fail "invalid canonical version: $canonical_version"

  case "$status" in
    represented_remote|pending_forward)
      matches=("$overlay_migrations/${canonical_version}_"*.sql)
      [[ -f "${matches[0]}" && ! -e "${matches[1]:-}" ]] || fail "canonical version must have exactly one local migration: $canonical_version"
      rm -- "${matches[0]}"
      if [[ "$status" == represented_remote ]]; then
        represented_count=$((represented_count + 1))
      else
        [[ "$replacement_version" =~ ^[0-9]{14}$ ]] || fail "pending canonical version lacks a replacement: $canonical_version"
        matches=("$overlay_migrations/${replacement_version}_"*.sql)
        [[ -f "${matches[0]}" && ! -e "${matches[1]:-}" ]] || fail "pending replacement must have exactly one local migration: $replacement_version"
        pending_count=$((pending_count + 1))
      fi
      ;;
    *) fail "unknown canonical-lineage status: $canonical_version/$status" ;;
  esac
done < "$CANONICAL_LINEAGE_LEDGER"

[[ "$represented_count" -gt 0 ]] || fail "canonical-lineage ledger has no represented remote versions"
[[ "$pending_count" -gt 0 ]] || fail "canonical-lineage ledger has no pending forward versions"

echo "Prepared temporary Supabase workdir: $overlay_root"
echo "Remote-history compatibility stubs: $remote_stub_count"
echo "Hidden represented canonical versions: $represented_count"
echo "Hidden pending canonical versions: $pending_count"
echo "Pending forward replacements: $pending_count"

set +e
SUPABASE_WORKDIR="$overlay_root" supabase db push "${push_flags[@]}"
status=$?
set -e
exit "$status"
\r'/}"
  classification="${classification// || fail "invalid remote-only version: $version"
  [[ "$evidence" == remote-ledger-only* ]] || fail "remote-only row lacks remote-ledger-only evidence: $version"
  case "$classification" in
    parallel-staging-lineage|duplicate-equivalent-lineage) ;;
    *) fail "unexpected remote-only classification: $version/$classification" ;;
  esac

  matches=("$overlay_migrations/${version}_"*.sql)
  [[ ! -e "${matches[0]}" ]] || fail "remote-only version already has a local migration: $version"
  safe_name="${name%.sql}"
  [[ "$safe_name" =~ ^[a-z0-9_]+$ ]] || fail "unsafe remote-only migration name: $version/$name"

  {
    echo '-- CI-only compatibility stub for an already-applied remote history row.'
    echo '-- This file is intentionally not committed and must never be deployed.'
    echo "-- Remote version: $version"
    echo "-- Remote name: $name"
    echo '-- The schema effect is represented by canonical remote lineage.'
  } > "$overlay_migrations/${version}_${safe_name}.sql"
  remote_stub_count=$((remote_stub_count + 1))
done < "$REMOTE_HISTORY_LEDGER"

[[ "$remote_stub_count" -gt 0 ]] || fail "remote-history ledger is empty"

represented_count=0
pending_count=0
while IFS=, read -r canonical_version status replacement_version _remote_evidence _evidence || [[ -n "${canonical_version:-}" ]]; do
  [[ "$canonical_version" == canonical_version ]] && continue
  [[ "$canonical_version" =~ ^[0-9]{14}$ ]] || fail "invalid canonical version: $canonical_version"

  case "$status" in
    represented_remote|pending_forward)
      matches=("$overlay_migrations/${canonical_version}_"*.sql)
      [[ -f "${matches[0]}" && ! -e "${matches[1]:-}" ]] || fail "canonical version must have exactly one local migration: $canonical_version"
      rm -- "${matches[0]}"
      if [[ "$status" == represented_remote ]]; then
        represented_count=$((represented_count + 1))
      else
        [[ "$replacement_version" =~ ^[0-9]{14}$ ]] || fail "pending canonical version lacks a replacement: $canonical_version"
        matches=("$overlay_migrations/${replacement_version}_"*.sql)
        [[ -f "${matches[0]}" && ! -e "${matches[1]:-}" ]] || fail "pending replacement must have exactly one local migration: $replacement_version"
        pending_count=$((pending_count + 1))
      fi
      ;;
    *) fail "unknown canonical-lineage status: $canonical_version/$status" ;;
  esac
done < "$CANONICAL_LINEAGE_LEDGER"

[[ "$represented_count" -gt 0 ]] || fail "canonical-lineage ledger has no represented remote versions"
[[ "$pending_count" -gt 0 ]] || fail "canonical-lineage ledger has no pending forward versions"

echo "Prepared temporary Supabase workdir: $overlay_root"
echo "Remote-history compatibility stubs: $remote_stub_count"
echo "Hidden represented canonical versions: $represented_count"
echo "Hidden pending canonical versions: $pending_count"
echo "Pending forward replacements: $pending_count"

set +e
SUPABASE_WORKDIR="$overlay_root" supabase db push "${push_flags[@]}"
status=$?
set -e
exit "$status"
\r'/}"
  evidence="${evidence// || fail "invalid remote-only version: $version"
  [[ "$evidence" == remote-ledger-only* ]] || fail "remote-only row lacks remote-ledger-only evidence: $version"
  case "$classification" in
    parallel-staging-lineage|duplicate-equivalent-lineage) ;;
    *) fail "unexpected remote-only classification: $version/$classification" ;;
  esac

  matches=("$overlay_migrations/${version}_"*.sql)
  [[ ! -e "${matches[0]}" ]] || fail "remote-only version already has a local migration: $version"
  safe_name="${name%.sql}"
  [[ "$safe_name" =~ ^[a-z0-9_]+$ ]] || fail "unsafe remote-only migration name: $version/$name"

  {
    echo '-- CI-only compatibility stub for an already-applied remote history row.'
    echo '-- This file is intentionally not committed and must never be deployed.'
    echo "-- Remote version: $version"
    echo "-- Remote name: $name"
    echo '-- The schema effect is represented by canonical remote lineage.'
  } > "$overlay_migrations/${version}_${safe_name}.sql"
  remote_stub_count=$((remote_stub_count + 1))
done < "$REMOTE_HISTORY_LEDGER"

[[ "$remote_stub_count" -gt 0 ]] || fail "remote-history ledger is empty"

represented_count=0
pending_count=0
while IFS=, read -r canonical_version status replacement_version _remote_evidence _evidence || [[ -n "${canonical_version:-}" ]]; do
  [[ "$canonical_version" == canonical_version ]] && continue
  [[ "$canonical_version" =~ ^[0-9]{14}$ ]] || fail "invalid canonical version: $canonical_version"

  case "$status" in
    represented_remote|pending_forward)
      matches=("$overlay_migrations/${canonical_version}_"*.sql)
      [[ -f "${matches[0]}" && ! -e "${matches[1]:-}" ]] || fail "canonical version must have exactly one local migration: $canonical_version"
      rm -- "${matches[0]}"
      if [[ "$status" == represented_remote ]]; then
        represented_count=$((represented_count + 1))
      else
        [[ "$replacement_version" =~ ^[0-9]{14}$ ]] || fail "pending canonical version lacks a replacement: $canonical_version"
        matches=("$overlay_migrations/${replacement_version}_"*.sql)
        [[ -f "${matches[0]}" && ! -e "${matches[1]:-}" ]] || fail "pending replacement must have exactly one local migration: $replacement_version"
        pending_count=$((pending_count + 1))
      fi
      ;;
    *) fail "unknown canonical-lineage status: $canonical_version/$status" ;;
  esac
done < "$CANONICAL_LINEAGE_LEDGER"

[[ "$represented_count" -gt 0 ]] || fail "canonical-lineage ledger has no represented remote versions"
[[ "$pending_count" -gt 0 ]] || fail "canonical-lineage ledger has no pending forward versions"

echo "Prepared temporary Supabase workdir: $overlay_root"
echo "Remote-history compatibility stubs: $remote_stub_count"
echo "Hidden represented canonical versions: $represented_count"
echo "Hidden pending canonical versions: $pending_count"
echo "Pending forward replacements: $pending_count"

set +e
SUPABASE_WORKDIR="$overlay_root" supabase db push "${push_flags[@]}"
status=$?
set -e
exit "$status"
\r'/}"
  [[ "$version" =~ ^[0-9]{14}$ ]] || fail "invalid remote-only version: $version"
  [[ "$evidence" == remote-ledger-only* ]] || fail "remote-only row lacks remote-ledger-only evidence: $version"
  case "$classification" in
    parallel-staging-lineage|duplicate-equivalent-lineage) ;;
    *) fail "unexpected remote-only classification: $version/$classification" ;;
  esac

  matches=("$overlay_migrations/${version}_"*.sql)
  [[ ! -e "${matches[0]}" ]] || fail "remote-only version already has a local migration: $version"
  safe_name="${name%.sql}"
  [[ "$safe_name" =~ ^[a-z0-9_]+$ ]] || fail "unsafe remote-only migration name: $version/$name"

  {
    echo '-- CI-only compatibility stub for an already-applied remote history row.'
    echo '-- This file is intentionally not committed and must never be deployed.'
    echo "-- Remote version: $version"
    echo "-- Remote name: $name"
    echo '-- The schema effect is represented by canonical remote lineage.'
  } > "$overlay_migrations/${version}_${safe_name}.sql"
  remote_stub_count=$((remote_stub_count + 1))
done < "$REMOTE_HISTORY_LEDGER"

[[ "$remote_stub_count" -gt 0 ]] || fail "remote-history ledger is empty"

represented_count=0
pending_count=0
while IFS=, read -r canonical_version status replacement_version _remote_evidence _evidence || [[ -n "${canonical_version:-}" ]]; do
  [[ "$canonical_version" == canonical_version ]] && continue
  [[ "$canonical_version" =~ ^[0-9]{14}$ ]] || fail "invalid canonical version: $canonical_version"

  case "$status" in
    represented_remote|pending_forward)
      matches=("$overlay_migrations/${canonical_version}_"*.sql)
      [[ -f "${matches[0]}" && ! -e "${matches[1]:-}" ]] || fail "canonical version must have exactly one local migration: $canonical_version"
      rm -- "${matches[0]}"
      if [[ "$status" == represented_remote ]]; then
        represented_count=$((represented_count + 1))
      else
        [[ "$replacement_version" =~ ^[0-9]{14}$ ]] || fail "pending canonical version lacks a replacement: $canonical_version"
        matches=("$overlay_migrations/${replacement_version}_"*.sql)
        [[ -f "${matches[0]}" && ! -e "${matches[1]:-}" ]] || fail "pending replacement must have exactly one local migration: $replacement_version"
        pending_count=$((pending_count + 1))
      fi
      ;;
    *) fail "unknown canonical-lineage status: $canonical_version/$status" ;;
  esac
done < "$CANONICAL_LINEAGE_LEDGER"

[[ "$represented_count" -gt 0 ]] || fail "canonical-lineage ledger has no represented remote versions"
[[ "$pending_count" -gt 0 ]] || fail "canonical-lineage ledger has no pending forward versions"

echo "Prepared temporary Supabase workdir: $overlay_root"
echo "Remote-history compatibility stubs: $remote_stub_count"
echo "Hidden represented canonical versions: $represented_count"
echo "Hidden pending canonical versions: $pending_count"
echo "Pending forward replacements: $pending_count"

set +e
SUPABASE_WORKDIR="$overlay_root" supabase db push "${push_flags[@]}"
status=$?
set -e
exit "$status"

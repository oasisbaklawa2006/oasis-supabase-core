#!/usr/bin/env bash
# Fails when a production-capable schema-write command is found anywhere in
# the tracked tree outside the single governed Production Migration Release
# implementation. This is a permanent guardrail against the class of
# incident recorded in docs/reconciliation/production-migration-lineage-recovery-2026-08-18.md
# (migrations applied directly against tcxvcatsqqertcnycuop from an
# unreviewed local/CI path, outside the governed release gate).
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

fail() { echo "PRODUCTION-WRITE-AUTHORITY VIOLATION: $*" >&2; exit 1; }

# The ONLY files permitted to invoke a production-capable schema-write
# command. Anything else matching the forbidden patterns below is a
# violation, full stop -- there is no per-line exemption mechanism, because
# the incident this guards against was itself a "just this once" exception.
declare -A ALLOWED_WRITE_FILES=(
  ["scripts/run-production-migration-overlay.sh"]=1
  [".github/workflows/production-migration-release.yml"]=1
)

# Read-only usages of psql against production (contract smoke tests, ledger
# verification, diagnostics) are legitimate and unrelated to schema writes;
# they are allowlisted separately so the forbidden-pattern scan below can
# stay strict about *write* commands without false-failing on them.
declare -A ALLOWED_READONLY_PSQL_FILES=(
  ["scripts/verify-production-migration-ledger.sh"]=1
  ["scripts/diagnose-production-gstin-index-readonly.sh"]=1
  [".github/workflows/production-migration-release.yml"]=1
  [".github/workflows/production-migration-drift-watch.yml"]=1
  [".github/workflows/production-gstin-index-diagnostic.yml"]=1
)

is_allowed_write_file() { [[ -n "${ALLOWED_WRITE_FILES[$1]:-}" ]]; }
is_allowed_readonly_psql_file() { [[ -n "${ALLOWED_READONLY_PSQL_FILES[$1]:-}" ]]; }

# These files are the detection mechanism itself: they necessarily contain
# the forbidden pattern strings as literal grep targets/comments/regression
# fixtures, not as a live production-write invocation. Scanning them against
# their own patterns is a guaranteed false positive, not a real finding.
declare -A SELF_EXCLUDE_FILES=(
  ["scripts/check-production-write-authority.sh"]=1
  ["scripts/tests/verify-step1-staging-certification-fails-closed.sh"]=1
)

mapfile -t tracked_files < <(git ls-files -- \
  '.github/workflows/*' \
  'scripts/*' \
  'supabase/*' \
  '*.sh' '*.mjs' '*.js' '*.ts' \
  | grep -v -E '(^|/)node_modules/' \
  | sort -u)

violations=0

report() {
  local file="$1" pattern="$2" line="$3"
  echo "  $file: forbidden pattern [$pattern]" >&2
  echo "    $line" >&2
  violations=$((violations + 1))
}

for file in "${tracked_files[@]}"; do
  [[ -f "$file" ]] || continue
  [[ -n "${SELF_EXCLUDE_FILES[$file]:-}" ]] && continue

  # supabase db push / migration up / migration repair
  while IFS=: read -r lineno line; do
    [[ -n "$lineno" ]] || continue
    is_allowed_write_file "$file" || report "$file" "supabase db push" "$lineno: $line"
  done < <(grep -noE 'supabase[[:space:]]+db[[:space:]]+push' "$file" 2>/dev/null || true)

  while IFS=: read -r lineno line; do
    [[ -n "$lineno" ]] || continue
    report "$file" "supabase migration up/repair" "$lineno: $line"
  done < <(grep -noE 'supabase[[:space:]]+migration[[:space:]]+(up|repair)' "$file" 2>/dev/null || true)

  # psql executing a migration/schema file directly (-f <path>.sql or
  # input-redirected < <path>.sql), as opposed to a ready-only single -c
  # statement or heredoc smoke test.
  while IFS=: read -r lineno line; do
    [[ -n "$lineno" ]] || continue
    report "$file" "psql executing a .sql file" "$lineno: $line"
  done < <(grep -noE 'psql[^|&;]*(-f[[:space:]]*[^ ]+\.sql|--file=[^ ]+\.sql|<[[:space:]]*[^ ]+\.sql)' "$file" 2>/dev/null || true)

  # execFileSync/execFile/spawn/exec invoking psql from JS/TS/mjs automation.
  while IFS=: read -r lineno line; do
    [[ -n "$lineno" ]] || continue
    is_allowed_write_file "$file" || report "$file" "programmatic psql invocation" "$lineno: $line"
  done < <(grep -noE "(execFileSync|execFile|spawnSync|spawn|execSync|exec)\\([[:space:]]*['\"]psql['\"]" "$file" 2>/dev/null || true)

  # Direct schema_migrations ledger mutation from anywhere outside the CLI's
  # own internals (this repo never issues raw DDL against the ledger table).
  while IFS=: read -r lineno line; do
    [[ -n "$lineno" ]] || continue
    report "$file" "direct schema_migrations mutation" "$lineno: $line"
  done < <(grep -noiE '(insert[[:space:]]+into[[:space:]]+[^;]*schema_migrations|update[[:space:]]+[a-z_."]*schema_migrations|delete[[:space:]]+from[[:space:]]+[^;]*schema_migrations)' "$file" 2>/dev/null || true)

  # migration repair CLI flag under any invocation form.
  while IFS=: read -r lineno line; do
    [[ -n "$lineno" ]] || continue
    report "$file" "migration repair" "$lineno: $line"
  done < <(grep -noE -- '--repair\b' "$file" 2>/dev/null || true)

  # psql invoked with a production-capable db-url variable that is not one
  # of the acknowledged read-only usages and not the governed write path.
  while IFS=: read -r lineno line; do
    [[ -n "$lineno" ]] || continue
    if ! is_allowed_write_file "$file" && ! is_allowed_readonly_psql_file "$file"; then
      report "$file" "raw production DDL execution path" "$lineno: $line"
    fi
  done < <(grep -noE 'psql[^|&;]*\$(SUPABASE_DB_URL|\{SUPABASE_DB_URL)' "$file" 2>/dev/null || true)
done

# SUPABASE_DB_URL is a direct Postgres connection string -- the one
# credential actually capable of a schema write -- and must exist only in
# the governed migration workflows, never in a feature/PR/staging workflow.
# (SUPABASE_ACCESS_TOKEN is a broader Supabase management-API token with
# legitimate non-schema uses elsewhere, e.g. edge-function secret sync, so it
# is intentionally not scanned for here.)
declare -A ALLOWED_PRODUCTION_DB_URL_WORKFLOWS=(
  [".github/workflows/production-migration-release.yml"]=1
  [".github/workflows/production-migration-drift-watch.yml"]=1
  [".github/workflows/production-gstin-index-diagnostic.yml"]=1
)
mapfile -t workflow_files < <(git ls-files -- '.github/workflows/*.yml' '.github/workflows/*.yaml' | sort -u)
for file in "${workflow_files[@]}"; do
  [[ -f "$file" ]] || continue
  [[ -n "${ALLOWED_PRODUCTION_DB_URL_WORKFLOWS[$file]:-}" ]] && continue
  while IFS=: read -r lineno line; do
    [[ -n "$lineno" ]] || continue
    report "$file" "production DB write credential outside governed workflows" "$lineno: $line"
  done < <(grep -noE 'secrets\.SUPABASE_DB_URL' "$file" 2>/dev/null || true)
done

if ((violations > 0)); then
  fail "$violations production-capable schema-write command(s) found outside the governed Production Migration Release path. Only scripts/run-production-migration-overlay.sh (invoked exclusively by .github/workflows/production-migration-release.yml's protected 'deploy' job) may apply production schema changes."
fi

echo "OK: no production-capable schema-write command exists outside the governed release path."

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

# The ONLY files permitted to invoke a schema-write command. The QA-only
# workflow is an additional *governed* path, never a production credential path:
# its exact-target and authorization invariants are checked below. No generic
# per-line exceptions exist, because that caused the original incident.
declare -A ALLOWED_WRITE_FILES=(
  ["scripts/run-production-migration-overlay.sh"]=1
  [".github/workflows/production-migration-release.yml"]=1
  [".github/workflows/genie-qa-canonical-bootstrap.yml"]=1
)

# QA-only schema replay exception is permitted ONLY when the manual protected
# workflow has all its independent, fail-closed source and target constraints.
# Removing any of these controls must fail Core Migration CI. This does not
# authorize use of production credentials, provider calls, or unattended apply.
qa_workflow=".github/workflows/genie-qa-canonical-bootstrap.yml"
[[ -f "$qa_workflow" ]] || fail "QA migration authority workflow missing"
# Inspect parsed active YAML controls, never comments or partial string matches.
# The validator refuses weakened apply predicates and unprotected job dispatch.
command -v ruby >/dev/null || fail "Ruby YAML parser is required for QA authority checks"
ruby scripts/genie-qa/verify_protected_workflow.rb "$qa_workflow" \
  || fail "QA-only workflow failed protected YAML validation"
if grep -Eq 'secrets\.SUPABASE_DB_URL|secrets\.SUPABASE_ACCESS_TOKEN' "$qa_workflow"; then
  fail "QA-only schema release must not use production database or management credentials"
fi
if grep -Eq '^[[:space:]]+(push|pull_request|schedule):' "$qa_workflow"; then
  fail "QA-only schema release must remain manual workflow_dispatch only"
fi
if [[ ! -f scripts/genie-qa/verify_qa_target.py ]] \
    || ! grep -Fq 'PRODUCTION_PROJECT_REF = "tcxvcatsqqertcnycuop"' scripts/genie-qa/verify_qa_target.py \
    || ! grep -Fq 'QA_PROJECT_REF = "skhpmltfjgqitntkmclb"' scripts/genie-qa/verify_qa_target.py \
    || ! grep -Fq 'mode == "preflight"' scripts/genie-qa/verify_qa_target.py; then
  fail "QA-only schema target validator missing fixed approved QA/ref or pooler preflight fence"
fi

# Read-only usages of psql against production (contract smoke tests, ledger
# verification, diagnostics and the bounded semantic schema census) are
# legitimate and unrelated to schema writes. This allowlist only permits the
# invocation site; referenced SQL files are independently required below to be
# explicit read-only transactions.
declare -A ALLOWED_READONLY_PSQL_FILES=(
  ["scripts/verify-production-migration-ledger.sh"]=1
  ["scripts/verify-production-schema-semantic-drift.sh"]=1
  ["scripts/diagnose-production-gstin-index-readonly.sh"]=1
  ["scripts/certify-production-drift-watch-credential.sh"]=1
  [".github/workflows/production-migration-release.yml"]=1
  [".github/workflows/production-migration-drift-watch.yml"]=1
  [".github/workflows/production-gstin-index-diagnostic.yml"]=1
  [".github/workflows/admin-provision-user-production-first-deploy.yml"]=1
  [".github/workflows/whatsapp-packet-ai-worker-production-release.yml"]=1
  [".github/workflows/whatsapp-packet-ai-consumer-production-release.yml"]=1
  ["scripts/observe-whatsapp-packet-ai-consumer-ticks.sh"]=1
)

# SQL files that are intentionally executed through psql by a read-only
# production diagnostic/census path. Every one must begin an explicit read-only
# transaction; adding a new SQL file requires adding it here and satisfying the
# same invariant.
declare -A APPROVED_READONLY_SQL_FILES=(
  ["scripts/sql/public-schema-semantic-manifest.sql"]=1
  ["scripts/sql/platform-schema-semantic-manifest.sql"]=1
  ["scripts/sql/verify-admin-provision-user-production-db-prerequisites.sql"]=1
  ["scripts/sql/verify-whatsapp-packet-ai-worker-production-runtime.sql"]=1
  ["scripts/sql/verify-whatsapp-packet-ai-consumer-production-runtime.sql"]=1
  ["scripts/sql/snapshot-whatsapp-packet-ai-consumer-production-state.sql"]=1
  ["scripts/sql/observe-whatsapp-packet-ai-consumer-production-ticks.sql"]=1
)

is_allowed_write_file() { [[ -n "${ALLOWED_WRITE_FILES[$1]:-}" ]]; }
is_allowed_readonly_psql_file() { [[ -n "${ALLOWED_READONLY_PSQL_FILES[$1]:-}" ]]; }
is_approved_readonly_sql_file() { [[ -n "${APPROVED_READONLY_SQL_FILES[$1]:-}" ]]; }

for sql_file in "${!APPROVED_READONLY_SQL_FILES[@]}"; do
  [[ -f "$sql_file" ]] || fail "approved read-only SQL file is missing: $sql_file"
  grep -Eq '^[[:space:]]*BEGIN[[:space:]]+READ[[:space:]]+ONLY[[:space:]]*;' "$sql_file" \
    || fail "approved read-only SQL file does not begin an explicit read-only transaction: $sql_file"
done

# These files are the detection mechanism itself: they necessarily contain
# the forbidden pattern strings as literal grep targets/comments/regression
# fixtures, not as a live production-write invocation. Scanning them against
# their own patterns is a guaranteed false positive, not a real finding.
declare -A SELF_EXCLUDE_FILES=(
  ["scripts/check-production-write-authority.sh"]=1
  # The validator quotes forbidden commands to test the workflow; it does
  # not invoke them. Exclude only this security validator's own source text.
  ["scripts/genie-qa/verify_protected_workflow.rb"]=1
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

  # psql executing a literal migration/schema file directly (-f <path>.sql or
  # input-redirected < <path>.sql). A read-only invocation site is not a blanket
  # exemption: every referenced SQL path must itself be on the explicit
  # read-only SQL allowlist and begin BEGIN READ ONLY;.
  while IFS=: read -r lineno line; do
    [[ -n "$lineno" ]] || continue
    if ! is_allowed_readonly_psql_file "$file"; then
      report "$file" "psql executing a .sql file" "$lineno: $line"
      continue
    fi

    mapfile -t sql_paths < <(printf '%s\n' "$line" | grep -oE '[[:alnum:]_./-]+\.sql' | LC_ALL=C sort -u || true)
    if ((${#sql_paths[@]} == 0)); then
      report "$file" "read-only psql SQL path could not be resolved" "$lineno: $line"
      continue
    fi
    for sql_path in "${sql_paths[@]}"; do
      if ! is_approved_readonly_sql_file "$sql_path"; then
        report "$file" "psql executing unapproved SQL file: $sql_path" "$lineno: $line"
        continue
      fi
      if [[ ! -f "$sql_path" ]] || ! grep -Eq '^[[:space:]]*BEGIN[[:space:]]+READ[[:space:]]+ONLY[[:space:]]*;' "$sql_path"; then
        report "$file" "psql executing SQL without explicit read-only transaction: $sql_path" "$lineno: $line"
      fi
    done
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
  [".github/workflows/admin-provision-user-production-first-deploy.yml"]=1
  [".github/workflows/whatsapp-packet-ai-worker-production-release.yml"]=1
  [".github/workflows/whatsapp-packet-ai-consumer-production-release.yml"]=1
  ["scripts/observe-whatsapp-packet-ai-consumer-ticks.sh"]=1
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
  fail "$violations schema-write command(s) found outside governed Production Migration Release or pinned QA-only bootstrap paths."
fi

echo "OK: schema writes restricted to governed production path and target-pinned QA-only bootstrap."

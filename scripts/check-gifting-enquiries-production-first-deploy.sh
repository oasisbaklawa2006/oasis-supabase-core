#!/usr/bin/env bash
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

db_prereq_sql="scripts/sql/verify-gifting-enquiries-production-db-prerequisites.sql"
manifest="scripts/edge-function-source-manifest.py"
manifest_test="scripts/tests/verify-edge-function-source-manifest.sh"
governance_regression_test="scripts/tests/verify-check-gifting-enquiries-production-first-deploy.sh"
runbook="docs/programme/GIFTING_OPTION_A_PRODUCTION_RUNBOOK.md"
config="supabase/config.toml"
migration="supabase/migrations/20261124000000_website_leads_core_authority_v1.sql"
migration_test="supabase/tests/website_leads_core_authority_v1.sql"
receiver_source="supabase/functions/_shared/giftingEnquiryReceiver.ts"
receiver_test="supabase/functions/_shared/giftingEnquiryReceiver.test.ts"
function_entry="supabase/functions/gifting-enquiries/index.ts"

# shellcheck disable=SC1091
source scripts/check-whatsapp-webhook-production-release.sh

fail() {
  echo "GIFTING ENQUIRIES FIRST DEPLOY GOVERNANCE VIOLATION: $*" >&2
  exit 1
}

# Production-only guard for the runbook. Each executable block that calls a Connect admin RPC must bind
# production and the production consumer by itself. No block may reference a non-production environment,
# in single or double quotes, or the staging project.
assert_runbook_production_only() {
  local path="$1"
  [[ -s "$path" ]] || fail "missing runbook: $path"
  python3 - "$path" <<'PY'
import re
import sys

text = open(sys.argv[1], encoding="utf-8").read()
blocks = re.findall(r"```(?:sql|bash|sh)\n(.*?)```", text, re.S)
if not blocks:
    raise SystemExit("runbook has no executable blocks")

forbidden = re.compile(r"'(staging|preview)'|\"(staging|preview)\"|ypeoiobkqvlalxgugtgm")
for index, block in enumerate(blocks, 1):
    if forbidden.search(block):
        raise SystemExit(
            f"executable block {index} references a non-production Connect environment or the staging project"
        )
    if "connect_admin_" in block:
        if "'production'" not in block:
            raise SystemExit(
                f"executable block {index} calls a Connect admin RPC without binding CONNECT_ENV to 'production'"
            )
        if "connect_admin_register_consumer_v1" in block and "oasis_gifting_website_prod" not in block:
            raise SystemExit(
                f"executable block {index} registers a consumer without the production consumer oasis_gifting_website_prod"
            )

joined = "\n".join(blocks)
for profile in ("website_retail_v1", "gifting_enquiries_v1"):
    if profile not in joined:
        raise SystemExit(f"runbook does not bind profile {profile}")
PY
}

if [[ "${1:-}" == "--assert-runbook" ]]; then
  assert_runbook_production_only "${2:?runbook path required}"
  echo "Runbook production-only guard passed: $2"
  exit 0
fi

first_deploy_workflow=".github/workflows/gifting-enquiries-production-first-deploy.yml"

require_file() {
  local path="$1"
  [[ -s "$path" ]] || fail "missing required file: $path"
}

for required in "$first_deploy_workflow" "$db_prereq_sql" "$manifest" "$manifest_test" \
  "$governance_regression_test" "$runbook" "$config" "$migration" "$migration_test" \
  "$receiver_source" "$receiver_test" "$function_entry"; do
  require_file "$required"
done

grep -A1 -Fx '[functions.gifting-enquiries]' "$config" | grep -Fxq 'verify_jwt = false' \
  || fail "gifting-enquiries must be declared with verify_jwt = false (Connect bearer is the credential)"

require_exact_count "$first_deploy_workflow" '^  preflight:$' 1 "first-deploy preflight job"
require_exact_count "$first_deploy_workflow" '^  deploy:$' 1 "first-deploy deploy job"

validate_workflow_on_triggers "$first_deploy_workflow"
validate_workflow_permissions "$first_deploy_workflow"

require_contains "$first_deploy_workflow" "group: gifting-enquiries-production-first-deploy" "first-deploy concurrency lock"
require_contains "$first_deploy_workflow" "environment: supabase-production-readonly" "read-only production environment gate"
require_contains "$first_deploy_workflow" "persist-credentials: false" "checkout credential hardening"
require_contains "$first_deploy_workflow" "SUPABASE_PROJECT_REF: tcxvcatsqqertcnycuop" "canonical production project binding"
require_contains "$first_deploy_workflow" 'FUNCTION_NAME: gifting-enquiries' "named function binding"
require_contains "$first_deploy_workflow" "SUPABASE_CLI_VERSION: 2.117.0" "pinned Supabase CLI"
require_contains "$first_deploy_workflow" '${{ github.run_attempt }}' "retry-safe evidence naming"
require_contains "$first_deploy_workflow" 'if-no-files-found: error' "required artifact failure policy"

reject_regex "$first_deploy_workflow" 'supabase[[:space:]]+db[[:space:]]+(push|reset|query)|supabase[[:space:]]+migration[[:space:]]+(up|repair)|supabase[[:space:]]+secrets[[:space:]]+(set|unset)' "database or secret mutation authority"
reject_regex "$first_deploy_workflow" 'supabase[[:space:]]+functions[[:space:]]+deploy[[:space:]]+[$"{]' "variable Edge deploy target"
reject_regex "$first_deploy_workflow" 'uses:[[:space:]]+actions/(checkout|upload-artifact|download-artifact)@v[0-9]+' "unpinned first-party action"

require_job_regex "$first_deploy_workflow" "deploy" '^    environment: supabase-production$' "production mutation environment gate"

require_contains "$first_deploy_workflow" 'test "${GITHUB_REF}" = "refs/heads/main"' "protected branch check"
require_contains "$first_deploy_workflow" 'git fetch --quiet origin refs/heads/main:refs/remotes/origin/main' "current-main fetch"
require_contains "$first_deploy_workflow" 'test "$(git rev-parse refs/remotes/origin/main)" = "$GITHUB_SHA"' "current-main equality check"
require_contains "$first_deploy_workflow" 'release_sha:' "exact release SHA input"
require_contains "$first_deploy_workflow" 'inputs.deploy == true' "explicit deploy boolean gate"
require_contains "$first_deploy_workflow" 'verify-gifting-enquiries-production-db-prerequisites.sql' "read-only DB prerequisite SQL"
require_contains "$first_deploy_workflow" '-f scripts/sql/verify-gifting-enquiries-production-db-prerequisites.sql' "read-only DB prerequisite invocation"
require_contains "$first_deploy_workflow" 'secrets.SUPABASE_DB_URL' "read-only production DB credential gate"
require_contains "$first_deploy_workflow" 'target-source-manifest.json' "reviewed source manifest"
require_contains "$first_deploy_workflow" 'live-source-manifest.json' "deployed source manifest"
require_regex "$first_deploy_workflow" 'diff -u[[:space:]\\]*[[:space:]]*target-source-manifest.json[[:space:]\\]*[[:space:]]*live-source-manifest.json' "reviewed/live source equality"
require_contains "$first_deploy_workflow" 'supabase functions download gifting-enquiries' "live source download"
require_contains "$first_deploy_workflow" '--use-api' "API-based source unbundling"
require_contains "$first_deploy_workflow" 'GIFTING_ENQUIRIES_FUNCTION_ABSENT' "absent-function attestation marker"
require_contains "$first_deploy_workflow" 'UNEXPECTED_LIVE_FUNCTION' "fail-closed unexpected live function marker"
require_contains "$first_deploy_workflow" '.verify_jwt == false' "verify_jwt=false metadata assertion"
require_contains "$first_deploy_workflow" 'gifting-enquiries-first-deploy-rollback-plan.json' "first-deploy rollback plan evidence"
require_contains "$first_deploy_workflow" 'Capture failed first-deploy live state and attestation' "failed first-deploy live-state capture"
require_contains "$first_deploy_workflow" 'id: deploy_step' "named deploy step id"
require_contains "$first_deploy_workflow" 'DEPLOY_OUTCOME: ${{ steps.deploy_step.outcome }}' "failed evidence deploy-outcome binding"
require_contains "$first_deploy_workflow" 'status="DEPLOY_NOT_ATTEMPTED"' "pre-deploy failure classification"
require_contains "$first_deploy_workflow" 'status="DEPLOYED_UNVERIFIED"' "failed deployment attestation status"
require_contains "$first_deploy_workflow" 'gifting-enquiries-first-deploy-failure-attestation.json' "failed deployment attestation evidence"
require_contains "$first_deploy_workflow" 'gifting-enquiries-first-deploy-failure-${{ github.sha }}-${{ github.run_attempt }}' "failed deployment evidence artifact"
require_contains "$first_deploy_workflow" 'if: failure()' "failure-path evidence guard"
require_contains "$first_deploy_workflow" 'id: failed_evidence_scan' "failed-evidence scan step id"
require_contains "$first_deploy_workflow" "steps.failed_evidence_scan.outcome == 'success'" "failed-evidence upload gated on the credential scan outcome"
require_contains "$first_deploy_workflow" 'Fail if access credentials leaked into text evidence' "credential evidence scan"
require_contains "$first_deploy_workflow" 'idempotency-key: 00000000-0000-4000-8000-000000000001' "invalid-JWT smoke sends a valid idempotency key"
require_contains "$first_deploy_workflow" 'test "$unauthenticated_code" = "401"' "unauthenticated boundary smoke (401)"
require_contains "$first_deploy_workflow" 'test "$invalid_jwt_code" = "401"' "invalid token boundary smoke (401)"
require_contains "$first_deploy_workflow" 'deno test supabase/functions/_shared/giftingEnquiryReceiver.test.ts' "receiver contract tests"

broad_count="$(grep -Ec 'supabase[[:space:]]+functions[[:space:]]+deploy([[:space:]]|$)' "$first_deploy_workflow" || true)"
named_count="$(grep -Ec 'supabase[[:space:]]+functions[[:space:]]+deploy[[:space:]]+gifting-enquiries([[:space:]]|$)' "$first_deploy_workflow" || true)"
[[ "$broad_count" -eq 1 && "$named_count" -eq 1 ]] || fail "release workflow must contain exactly one literal gifting-enquiries deploy"

require_order "$first_deploy_workflow" \
  "absent function proof" "Prove gifting-enquiries is absent from production" \
  "db prerequisite verification" "Verify read-only gifting enquiry DB prerequisites" \
  "preflight attestation" "Build first-deploy preflight attestation" \
  "preflight evidence upload" "Upload immutable preflight evidence"

require_order "$first_deploy_workflow" \
  "absent recheck" "Recheck function remains absent immediately before deployment" \
  "rollback plan evidence" "Build first-deploy rollback plan evidence" \
  "named production deploy" "Deploy exact named function only" \
  "deployed metadata verification" "Verify deployed function metadata" \
  "deployed source closure verification" "Verify deployed source closure matches reviewed source" \
  "boundary smoke" "Run unauthenticated and invalid-JWT boundary smoke checks" \
  "release attestation" "Build successful first-deploy attestation" \
  "verified evidence upload" "Upload required verified first-deploy evidence"

require_order "$first_deploy_workflow" \
  "named production deploy" "Deploy exact named function only" \
  "failed live-state capture" "Capture failed first-deploy live state and attestation" \
  "failed evidence upload" "Upload failed first-deploy evidence"

assert_runbook_production_only "$runbook"

bash -n "$governance_regression_test"
bash -n "$manifest_test"
python3 -m py_compile "$manifest"
bash "$governance_regression_test"

echo "Gifting enquiries production first-deploy governance passed."

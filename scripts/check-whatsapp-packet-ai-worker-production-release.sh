#!/usr/bin/env bash
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

# shellcheck disable=SC1091
source scripts/check-whatsapp-webhook-production-release.sh

worker_release=".github/workflows/whatsapp-packet-ai-worker-production-release.yml"
runtime_sql="scripts/sql/verify-whatsapp-packet-ai-worker-production-runtime.sql"
rollback_capture_script="scripts/capture-live-edge-function-rollback-artifacts.sh"
deploy_closure_verify_script="scripts/verify-deployed-edge-function-source-closure.sh"
bundle_provenance_script="scripts/download-live-edge-function-bundle-provenance.sh"
source_cert_script="scripts/run-deployed-edge-function-source-certification.sh"
closure_regression_test="scripts/tests/verify-deployed-edge-function-source-closure.sh"
governance_regression_test="scripts/tests/verify-check-whatsapp-packet-ai-worker-production-release.sh"
rollback_capture_regression_test="scripts/tests/verify-capture-live-edge-function-rollback-artifacts.sh"

fail() {
  echo "WHATSAPP PACKET AI WORKER RELEASE GOVERNANCE VIOLATION: $*" >&2
  exit 1
}

for required in "$worker_release" "$runtime_sql" "$rollback_capture_script" "$deploy_closure_verify_script" "$bundle_provenance_script" "$source_cert_script" "$closure_regression_test" "$governance_regression_test" "$rollback_capture_regression_test"; do
  require_file "$required"
done

validate_workflow_on_triggers "$worker_release"
validate_workflow_permissions "$worker_release"

require_contains "$worker_release" "group: whatsapp-packet-ai-worker-production-release" "release concurrency lock"
require_contains "$worker_release" "environment: supabase-production-readonly" "read-only preflight environment"
require_job_regex "$worker_release" "deploy" '^    environment: supabase-production$' "protected production environment gate"
require_contains "$worker_release" "SUPABASE_PROJECT_REF: tcxvcatsqqertcnycuop" "canonical production project binding"
require_contains "$worker_release" 'FUNCTION_NAME: whatsapp-packet-ai-worker' "named function binding"
require_contains "$worker_release" 'EXPECTED_LIVE_VERSION: "18"' "known live version baseline"
require_contains "$worker_release" 'EXPECTED_LIVE_BUNDLE_SHA: c073d30b1f6b64389ef9967aa7e79bd79e975de06af2b1bd46b2638dff645e09' "known live bundle baseline"
require_contains "$worker_release" 'DB_PREREQ_RUN_ID: "39143221217"' "database prerequisite run binding"
require_contains "$worker_release" 'DB_PREREQ_SHA: 6a825ce8818d08b1c7089185cffb76208540c40b' "database prerequisite SHA binding"
require_contains "$worker_release" 'release_sha:' "exact release SHA input"
require_contains "$worker_release" 'inputs.deploy == true' "explicit deploy boolean gate"
require_contains "$worker_release" 'certify_existing:' "read-only recovery certification input"
require_job_regex "$worker_release" "certify-existing" "inputs\\.certify_existing == true && inputs\\.deploy == false" "mutually exclusive recovery certification condition"
require_contains "$worker_release" 'run-deployed-edge-function-source-certification.sh' "deployed source certification orchestration"
require_contains "$worker_release" 'source-certification-status.txt' "explicit source certification status artifact"
require_contains "$deploy_closure_verify_script" 'DEPLOYED_SOURCE_INDETERMINATE' "indeterminate when API omits files without provenance"
require_contains "$deploy_closure_verify_script" 'bundle_provenance_root' "independent bundle provenance tree support"
require_contains "$worker_release" 'sourceCertificationStatus' "source certification status in recovery attestation"
require_contains "$worker_release" 'INDETERMINATE' "fail-closed indeterminate attestation path"
reject_regex "$deploy_closure_verify_script" 'checkout_functions_root' "checkout must not be live-source evidence"
require_contains "$worker_release" 'CERTIFIED_DEPLOY_BUNDLE_SHA: 0f505f46f0d50f96ea63145c350b94db50eb2a7e6b08373934cee8ce85d4df28' "recovery certification live bundle binding"
require_contains "$worker_release" 'verify-whatsapp-packet-ai-worker-production-runtime.sql' "runtime SQL certification"
require_contains "$worker_release" '.verify_jwt == true' "verify_jwt=true metadata assertion"
require_contains "$worker_release" 'target-source-manifest.json' "reviewed source manifest"
require_contains "$worker_release" 'live-source-manifest.json' "deployed source manifest"
require_contains "$worker_release" 'supabase functions download' "live source download"
require_contains "$worker_release" 'capture-live-edge-function-rollback-artifacts.sh' "live rollback capture with bundle-sha fallback"
require_contains "$deploy_closure_verify_script" 'DEPLOYED_SOURCE_MISMATCH' "fail closed on byte mismatch"
require_contains "$rollback_capture_script" 'supabase_management_api_bundle_sha' "incomplete download bundle-sha fallback"
require_contains "$worker_release" '--use-api' "API-based source unbundling"
require_contains "$worker_release" 'whatsapp-packet-ai-worker-release-attestation.json' "release attestation artifact"
require_contains "$worker_release" 'test "$unauthenticated_code" = "401"' "unauthenticated JWT boundary smoke"
require_contains "$worker_release" 'test "$invalid_jwt_code" = "401"' "invalid JWT boundary smoke"
require_contains "$worker_release" 'NON_MUTATING_NO_CLAIM_EXECUTED' "non-mutating worker health smoke"

reject_regex "$worker_release" '--no-verify-jwt' "worker must remain verify_jwt=true at gateway"
reject_regex "$worker_release" 'supabase[[:space:]]+db[[:space:]]+(push|reset)' "schema mutation authority"
reject_regex "$worker_release" 'supabase[[:space:]]+secrets[[:space:]]+(set|unset)' "secret mutation authority"

broad_count="$(grep -Ec 'supabase[[:space:]]+functions[[:space:]]+deploy([[:space:]]|$)' "$worker_release" || true)"
named_count="$(grep -Fc 'supabase functions deploy whatsapp-packet-ai-worker' "$worker_release" || true)"
[[ "$broad_count" -eq 1 && "$named_count" -eq 1 ]] || fail "release workflow must contain exactly one governed worker deploy"

echo "WhatsApp packet AI worker production release governance passed."

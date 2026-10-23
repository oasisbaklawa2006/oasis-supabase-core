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
attestation_predicate_script="scripts/build-worker-deployment-source-attestation-predicate.sh"
attestation_verify_script="scripts/verify-worker-deployment-source-attestation.sh"
closure_regression_test="scripts/tests/verify-deployed-edge-function-source-closure.sh"
attestation_regression_test="scripts/tests/verify-worker-deployment-source-attestation.sh"
governance_regression_test="scripts/tests/verify-check-whatsapp-packet-ai-worker-production-release.sh"
rollback_capture_regression_test="scripts/tests/verify-capture-live-edge-function-rollback-artifacts.sh"
rollback_completion_script="scripts/edge-function-rollback-completion.py"
rollback_completion_pin="scripts/lib/whatsapp-packet-ai-worker-v20-rollback-completion.json"
tool_resolution_regression_test="scripts/tests/verify-certification-wrapper-tool-resolution.sh"
source_evidence_regression_test="scripts/tests/test-certify-existing-source-evidence.py"

fail() {
  echo "WHATSAPP PACKET AI WORKER RELEASE GOVERNANCE VIOLATION: $*" >&2
  exit 1
}

for required in "$worker_release" "$runtime_sql" "$rollback_capture_script" "$deploy_closure_verify_script" "$bundle_provenance_script" "$source_cert_script" "$attestation_predicate_script" "$attestation_verify_script" "$closure_regression_test" "$attestation_regression_test" "$governance_regression_test" "$rollback_capture_regression_test" "$rollback_completion_script" "$rollback_completion_pin" "$tool_resolution_regression_test" "$source_evidence_regression_test"; do
  require_file "$required"
done

require_contains "$source_cert_script" 'verify-worker-deployment-source-attestation.sh' \
  "deployment-time attestation consulted when post-hoc recovery is indeterminate"
require_contains "$source_cert_script" 'VERIFIED_BY_ATTESTATION' \
  "distinct, honestly-labeled attestation-backed verification status"
require_contains "$attestation_verify_script" 'ATTESTATION_NOT_FOUND' \
  "missing attestation must not be treated as a failure or as success"
require_contains "$attestation_verify_script" 'ATTESTATION_VERIFY_FAILED' \
  "invalid signature or wrong workflow identity fails closed"
require_contains "$attestation_verify_script" 'ATTESTATION_PREDICATE_MISMATCH' \
  "predicate fields must independently match the exact release under test"
require_contains "$attestation_verify_script" 'ATTESTATION_RUN_ID_MISMATCH' \
  "verified signing certificate must name the pinned source deployment run"
require_contains "$source_cert_script" 'tools_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"' \
  "nested certification tools resolve from the wrapper's own reviewed checkout"
reject_regex "$source_cert_script" 'bash[[:space:]]+scripts/' \
  "nested tools must not resolve against a possibly older caller checkout"
require_contains "$worker_release" 'SOURCE_EVIDENCE_UNSAFE_ENTRY' \
  "source deployment evidence archives must contain only plain top-level files"
require_contains "$worker_release" 'bash certification-tools/scripts/run-deployed-edge-function-source-certification.sh' \
  "read-only certification executes the reviewed workflow-revision tools"

validate_workflow_on_triggers "$worker_release"
validate_workflow_permissions "$worker_release"

require_contains "$worker_release" "group: whatsapp-packet-ai-worker-production-release" "release concurrency lock"
require_contains "$worker_release" "environment: supabase-production-readonly" "read-only preflight environment"
require_job_regex "$worker_release" "deploy" '^    environment: supabase-production$' "protected production environment gate"
require_contains "$worker_release" "SUPABASE_PROJECT_REF: tcxvcatsqqertcnycuop" "canonical production project binding"
require_contains "$worker_release" 'FUNCTION_NAME: whatsapp-packet-ai-worker' "named function binding"
require_contains "$worker_release" 'EXPECTED_LIVE_VERSION: "20"' "known live version baseline"
require_contains "$worker_release" 'EXPECTED_LIVE_BUNDLE_SHA: 4fa4639f8c0db5e3d1447e3b4d9e2a1f2ea2e8d382ce1adca1e6637a0bec9d99' "known live bundle baseline"
require_contains "$worker_release" 'CANDIDATE_WORKER_CLOSURE_SHA256: b18cd2eb890021295861c2ab7c73ba7adec97221a3651aca6fd62dba10b7863c' "verified reviewed candidate closure"
require_contains "$worker_release" 'jq -e --arg expected "$CANDIDATE_WORKER_CLOSURE_SHA256"' "candidate closure enforced at preflight"
require_contains "$worker_release" '"live-v${EXPECTED_LIVE_VERSION}-source-manifest.json"' "rollback manifest named for the expected live version"
require_contains "$worker_release" '"whatsapp-packet-ai-worker-predeploy-v${EXPECTED_LIVE_VERSION}.tar.gz"' "rollback archive named for the expected live version"
require_contains "$worker_release" 'live-v${{ env.EXPECTED_LIVE_VERSION }}-source-manifest.json' "rollback manifest upload path follows the expected live version"
require_contains "$worker_release" 'whatsapp-packet-ai-worker-predeploy-v${{ env.EXPECTED_LIVE_VERSION }}.tar.gz' "rollback archive upload path follows the expected live version"
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
require_contains "$worker_release" 'capture-live-edge-function-rollback-artifacts.sh' "live rollback capture"
require_contains "$worker_release" 'v${EXPECTED_LIVE_VERSION}-rollback-completion.json' "rollback capture bound to the pinned completion record for the expected live version"
require_contains "$deploy_closure_verify_script" 'DEPLOYED_SOURCE_MISMATCH' "fail closed on byte mismatch"
reject_regex "$rollback_capture_script" 'supabase_management_api_bundle_sha|partialDownloadClosureSha256' \
  "rollback capture must not fall back to reporting the live bundle hash as a source closure"
require_contains "$rollback_capture_script" 'edge-function-source-manifest.py' "rollback closure computed from the recursive import graph"
require_contains "$rollback_capture_script" 'verify-archive' "rollback archive re-extracted and verified before it is published"
require_contains "$rollback_completion_script" 'import type' "completion limited to type-only imports"
require_contains "$rollback_completion_script" 'pinned_historical_git' "completed files labelled as historical, never live evidence"
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

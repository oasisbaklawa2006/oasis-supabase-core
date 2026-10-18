#!/usr/bin/env bash
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

# shellcheck disable=SC1091
source scripts/check-whatsapp-webhook-production-release.sh

worker_release=".github/workflows/whatsapp-packet-ai-worker-production-release.yml"
runtime_sql="scripts/sql/verify-whatsapp-packet-ai-worker-production-runtime.sql"
governance_regression_test="scripts/tests/verify-check-whatsapp-packet-ai-worker-production-release.sh"

fail() {
  echo "WHATSAPP PACKET AI WORKER RELEASE GOVERNANCE VIOLATION: $*" >&2
  exit 1
}

for required in "$worker_release" "$runtime_sql" "$governance_regression_test"; do
  require_file "$required"
done

validate_workflow_on_triggers "$worker_release"
validate_workflow_permissions "$worker_release"

require_contains "$worker_release" "group: whatsapp-packet-ai-worker-production-release" "release concurrency lock"
require_contains "$worker_release" "environment: supabase-production-readonly" "read-only preflight environment"
grep -Eq '^[[:space:]]+environment:[[:space:]]+supabase-production[[:space:]]*$' "$worker_release" \
  || fail "protected production environment missing from $worker_release"
require_contains "$worker_release" "SUPABASE_PROJECT_REF: tcxvcatsqqertcnycuop" "canonical production project binding"
require_contains "$worker_release" 'FUNCTION_NAME: whatsapp-packet-ai-worker' "named function binding"
require_contains "$worker_release" 'EXPECTED_LIVE_VERSION: "18"' "known live version baseline"
require_contains "$worker_release" 'EXPECTED_LIVE_BUNDLE_SHA: acb2f49d3710955d149ccb5bc4161724ab2cec76acdaad42f68d0ed0d7c4c66f' "known live bundle baseline"
require_contains "$worker_release" 'DB_PREREQ_RUN_ID: "39143221217"' "database prerequisite run binding"
require_contains "$worker_release" 'DB_PREREQ_SHA: 6a825ce8818d08b1c7089185cffb76208540c40b' "database prerequisite SHA binding"
require_contains "$worker_release" 'release_sha:' "exact release SHA input"
require_contains "$worker_release" 'inputs.deploy == true' "explicit deploy boolean gate"
require_contains "$worker_release" 'verify-whatsapp-packet-ai-worker-production-runtime.sql' "runtime SQL certification"
require_contains "$worker_release" '.verify_jwt == true' "verify_jwt=true metadata assertion"
require_contains "$worker_release" 'target-source-manifest.json' "reviewed source manifest"
require_contains "$worker_release" 'live-source-manifest.json' "deployed source manifest"
require_contains "$worker_release" 'supabase functions download' "live source download"
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

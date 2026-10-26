#!/usr/bin/env bash
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

# shellcheck disable=SC1091
source scripts/check-whatsapp-webhook-production-release.sh

consumer_release=".github/workflows/whatsapp-packet-ai-consumer-production-release.yml"
consumer_ci=".github/workflows/whatsapp-packet-ai-consumer.yml"
runtime_sql="scripts/sql/verify-whatsapp-packet-ai-consumer-production-runtime.sql"
snapshot_sql="scripts/sql/snapshot-whatsapp-packet-ai-consumer-production-state.sql"
observe_sql="scripts/sql/observe-whatsapp-packet-ai-consumer-production-ticks.sql"
observe_script="scripts/observe-whatsapp-packet-ai-consumer-ticks.sh"
evidence_script="scripts/whatsapp-packet-ai-consumer-release-evidence.py"
evidence_test="scripts/tests/test-whatsapp-packet-ai-consumer-release-evidence.py"
governance_regression_test="scripts/tests/verify-check-whatsapp-packet-ai-consumer-production-release.sh"
rollback_capture_script="scripts/capture-live-edge-function-rollback-artifacts.sh"
rollback_completion_pin="scripts/lib/whatsapp-packet-ai-consumer-v5-rollback-completion.json"
source_cert_script="scripts/run-deployed-edge-function-source-certification.sh"
consumer_tests="supabase/functions/whatsapp-packet-ai-consumer/index.test.ts"

fail() {
  echo "WHATSAPP PACKET AI CONSUMER RELEASE GOVERNANCE VIOLATION: $*" >&2
  exit 1
}

for required in "$consumer_release" "$consumer_ci" "$runtime_sql" "$snapshot_sql" "$observe_sql" "$observe_script" "$evidence_script" "$evidence_test" "$governance_regression_test" "$rollback_capture_script" "$rollback_completion_pin" "$source_cert_script" "$consumer_tests"; do
  require_file "$required"
done

validate_workflow_on_triggers "$consumer_release"
validate_workflow_permissions "$consumer_release"

require_contains "$consumer_release" "group: whatsapp-packet-ai-consumer-production-release" "release concurrency lock"
require_contains "$consumer_release" "environment: supabase-production-readonly" "read-only preflight environment"
require_job_regex "$consumer_release" "deploy" '^    environment: supabase-production$' "protected production environment gate"
require_job_regex "$consumer_release" "deploy" '^    needs: preflight$' "deploy depends on the preflight"
require_job_regex "$consumer_release" "postverify" '^    needs: deploy$' "postverification depends on approved named deploy"
require_job_regex "$consumer_release" "postverify" '^    environment: supabase-production-readonly$' "postverification uses the existing restricted environment"
require_job_regex "$consumer_release" "postverify" "^    if: github\\.ref == 'refs/heads/main' && " "postverification is bound to protected main"
require_job_regex "$consumer_release" "postverify" 'inputs\.deploy == true && inputs\.observe_only != true' "postverification only after explicit deployment"
# The dependent verifier must not bypass GitHub's successful-deploy condition.
postverify_job_body="$(awk '/^  postverify:$/ {p=1; print; next} p && /^  [A-Za-z0-9_-]+:$/ {exit} p {print}' "$consumer_release")"
if grep -Eq '^    if: .*(always|cancelled|failure)\(\)|^    continue-on-error:' <<< "$postverify_job_body"; then
  fail "postverify must not bypass failed deploy with job-level status overrides"
fi
require_job_regex "$consumer_release" "preflight" "^    if: github\\.ref == 'refs/heads/main' && " "preflight runs only from protected main workflow code"
require_job_regex "$consumer_release" "deploy" "^    if: github\\.ref == 'refs/heads/main' && " "deploy runs only from protected main workflow code"
require_job_regex "$consumer_release" "observe" "^    if: github\\.ref == 'refs/heads/main' && " "observation runs only from protected main workflow code"
require_job_regex "$consumer_release" "deploy" 'inputs\.deploy == true && inputs\.observe_only != true' "explicit deploy boolean gate"
require_job_regex "$consumer_release" "observe" 'inputs\.observe_only == true && inputs\.deploy == false' "observation is mutually exclusive with deploy"
require_job_regex "$consumer_release" "inputs-guard" 'inputs\.deploy == true && inputs\.observe_only == true' "contradictory inputs rejected"
require_contains "$consumer_release" "SUPABASE_PROJECT_REF: tcxvcatsqqertcnycuop" "canonical production project binding"
require_contains "$consumer_release" 'FUNCTION_NAME: whatsapp-packet-ai-consumer' "named function binding"
require_contains "$consumer_release" 'EXPECTED_LIVE_VERSION: "5"' "known live version baseline"
require_contains "$consumer_release" 'EXPECTED_LIVE_BUNDLE_SHA: 6132d9ed0591a37a82b05d5bcf11d6c608f188b82254b7e0b331faaa2d461903' "known live bundle baseline"
require_contains "$consumer_release" 'CANDIDATE_CONSUMER_CLOSURE_SHA256:' "reviewed candidate closure pin"
require_contains "$consumer_release" "jq -e --arg expected \"\$CANDIDATE_CONSUMER_CLOSURE_SHA256\"" "candidate closure enforced"
require_exact_count "$consumer_release" 'jq -e --arg expected "\$CANDIDATE_CONSUMER_CLOSURE_SHA256"' 2 "candidate closure enforced at preflight and again at deploy"
require_contains "$consumer_release" 'release_sha:' "exact release SHA input"
require_contains "$consumer_release" 'git merge-base --is-ancestor "$RELEASE_SHA_INPUT" origin/main' "release bound to protected main"
require_contains "$consumer_release" '.verify_jwt == false' "verify_jwt=false metadata assertion (in-body machine secret)"
require_contains "$consumer_release" 'supabase functions download' "live source download"
require_contains "$consumer_release" 'capture-live-edge-function-rollback-artifacts.sh' "live rollback capture"
require_contains "$consumer_release" 'v${EXPECTED_LIVE_VERSION}-rollback-completion.json' "rollback capture bound to the pinned completion record"
require_contains "$consumer_release" '"live-v${EXPECTED_LIVE_VERSION}-source-manifest.json"' "rollback manifest named for the expected live version"
require_contains "$consumer_release" '"whatsapp-packet-ai-consumer-predeploy-v${EXPECTED_LIVE_VERSION}.tar.gz"' "rollback archive named for the expected live version"
require_contains "$consumer_release" 'whatsapp-packet-ai-consumer-predeploy-v${{ env.EXPECTED_LIVE_VERSION }}.tar.gz' "rollback archive uploaded with preflight evidence"
require_contains "$consumer_release" '--use-api' "API-based source unbundling"
require_contains "$consumer_release" 'run-deployed-edge-function-source-certification.sh' "deployed source certification orchestration"
require_contains "$consumer_release" 'VERIFIED_BY_ATTESTATION' "attestation-backed source verification accepted only by name"
require_contains "$consumer_release" 'uses: actions/attest@v4' "deployment-time source attestation"
require_contains "$consumer_release" 'verify-whatsapp-packet-ai-consumer-production-runtime.sql' "runtime SQL certification"
require_contains "$consumer_release" 'snapshot-whatsapp-packet-ai-consumer-production-state.sql' "read-only state snapshots"
require_contains "$consumer_release" 'compare-snapshots' "no-data-change proof"
require_contains "$consumer_release" 'observe-whatsapp-packet-ai-consumer-ticks.sh' "bounded post-release tick observation"
require_job_regex "$consumer_release" "postverify" 'observe-whatsapp-packet-ai-consumer-ticks\.sh' "postverification must observe 15 live ticks"
require_job_regex "$consumer_release" "postverify" 'compare-snapshots' "postverification must compare restricted snapshots"
require_job_regex "$consumer_release" "postverify" 'whatsapp-packet-ai-consumer-release-attestation\.json' "final attestation can only be built by restricted postverification"
require_exact_count "$consumer_release" 'uses: actions/download-artifact@d3f86a106a0bac45b974a628896c90dbdf5c8093' 2 "immutable same-run handoff of preflight and deploy evidence"
require_job_regex "$consumer_release" "deploy" '^ +name: whatsapp-packet-ai-consumer-production-deploy-pending-verification-' "deploy must produce provisional evidence"
require_job_regex "$consumer_release" "postverify" '^ +name: whatsapp-packet-ai-consumer-production-postverification-' "postverify must produce final evidence"
require_contains "$consumer_release" 'production-state-immediate-comparison.json' "preflight to post-deploy state comparison"
require_job_regex "$consumer_release" "postverify" '[.]runId == [$]run and [.]runAttempt == [$]attempt' "postverification checks exact run provenance"
require_job_regex "$consumer_release" "postverify" '[.]projectRef == [$]project and [.]function == [$]fn' "postverification checks exact target identity"
reject_regex "$consumer_release" 'WA_CONSUMER_READONLY_DB_URL' "obsolete cross-environment dedicated secret"
require_job_regex "$consumer_release" "postverify" '^ +-o live-function-postverify[.]json$' "postverify captures initial live metadata"
require_job_regex "$consumer_release" "postverify" '^ +-o live-function-final[.]json$' "postverify captures final live metadata"
require_job_regex "$consumer_release" "postverify" '^ +live-function-final[.]json >/dev/null$' "final live bundle metadata must pass verification"
require_job_regex "$consumer_release" "postverify" '^ +live-function-final[.]json$' "final metadata must be uploaded"
require_job_regex "$consumer_release" "deploy" '^ +date -u .*> deploy-completed-at[.]txt$' "deploy must record timestamp"
# Credential separation: the protected write job must never access a DB URL or run SQL.
deploy_job_body="$(sed -n '/^  deploy:$/,/^  postverify:$/p' "$consumer_release")"
if grep -Eq 'SUPABASE_DB_URL|WA_CONSUMER_READONLY_DB_URL|RELEASE_PRINCIPAL_NOT_READONLY|psql[[:space:]]|scripts/sql/|compare-snapshots|observe-whatsapp-packet-ai-consumer-ticks' <<< "$deploy_job_body"; then
  fail "protected deploy must not accept database credentials or execute SQL"
fi
# Enforce the existing restricted environment's secret mapping independently
# in preflight, postverify, and observation. Cross-job swaps fail closed.
for db_job in preflight postverify observe; do
  db_body="$(awk -v job="$db_job" '$0 == "  " job ":" {p=1; next} p && /^  [A-Za-z0-9_-]+:$/ {exit} p {print}' "$consumer_release")"
  [[ "$(grep -Ec '^      SUPABASE_DB_URL:' <<< "$db_body" || true)" -eq 1 ]] ||
    fail "$db_job must declare exactly one DB URL"
  grep -Fqx '      SUPABASE_DB_URL: ${{ secrets.SUPABASE_DB_URL }}' <<< "$db_body" ||
    fail "$db_job must use the restricted environment DB URL"
done
require_contains "$consumer_release" 'REQUIRED_HEALTHY_TICKS: "15"' "fifteen consecutive healthy ticks required"
require_contains "$consumer_release" 'OBSERVE_EXPECTED_PER_MINUTE: "2"' "pinned expected consumer results per minute"
# One definition only: a job- or step-level redefinition would change the value the observer actually uses.
require_exact_count "$consumer_release" 'OBSERVE_EXPECTED_PER_MINUTE' 1 "single workflow-level definition of the expected-results pin"
# The snapshot emits `tableDml`; a leftover check on the retired `dispatchJobStates` key fails every preflight.
require_exact_count "$consumer_release" "jq -e '\\.tableDml\\.whatsapp_packet_ai_dispatch_jobs\\.relfilenode'" 2 "snapshot shape validated at preflight and before deploy"
reject_regex "$consumer_release" 'dispatchJobStates' "retired snapshot key"
require_contains "$observe_script" '[[ "$expected" == "2" ]]' "runtime observer rejects unsafe effective pin overrides"
require_exact_count "$consumer_release" 'RELEASE_PRINCIPAL_NOT_READONLY' 3 "read-only database principal guarded in preflight, deploy and observe"
require_contains "$consumer_release" 'test "$get_code" = "405"' "non-POST rejection smoke"
require_contains "$consumer_release" 'test "$missing_code" = "401"' "missing worker secret smoke"
require_contains "$consumer_release" 'test "$wrong_code" = "403"' "wrong worker secret smoke"
require_contains "$consumer_release" 'NON_MUTATING_NO_CLAIM_EXECUTED' "no production job claim during smoke"
require_contains "$consumer_release" 'whatsapp-packet-ai-consumer-release-attestation.json' "release attestation artifact"
require_contains "$consumer_release" 'source-certification-status.txt' "explicit source certification status artifact"
require_contains "$consumer_release" '--no-verify-jwt' "gateway JWT check disabled only for this named function"
require_contains "$consumer_release" 'SUPABASE_CLI_VERSION: 2.117.0' "pinned CLI version"

# The consumer secret and the service-role key must never enter this workflow.
reject_regex "$consumer_release" 'x-oasis-worker-secret: \$\{\{' "real worker secret must not be sent by the release workflow"
reject_regex "$consumer_release" 'SUPABASE_SERVICE_ROLE_KEY|whatsapp_packet_ai_consumer_v1|decrypted_secret' "secret material must not be read or forwarded"
reject_regex "$consumer_release" 'supabase[[:space:]]+db[[:space:]]+(push|reset)' "schema mutation authority"
reject_regex "$consumer_release" 'supabase[[:space:]]+secrets[[:space:]]+(set|unset)' "secret mutation authority"
reject_regex "$consumer_release" 'claim_whatsapp_packet_ai_dispatch_job|net\.http_post|cron\.(schedule|unschedule|alter_job)' "production claim or scheduler mutation"
reject_regex "$consumer_release" 'pull_request|push:|schedule:' "non-manual production trigger"

for sql in "$runtime_sql" "$snapshot_sql" "$observe_sql"; do
  # The release role (oasis_drift_watch_ro) has no access to these; the preflight failed on cron.job in production.
  reject_regex "$sql" '(^|[^A-Za-z_])"?(cron|vault)"?[[:space:]]*[.][[:space:]]*"?[A-Za-z_]' "cron or vault access in $sql (not available to the release role)"
  first_statement="$(grep -Ev '^[[:space:]]*(--|$)' "$sql" | head -n 1)"
  [[ "$first_statement" == "BEGIN READ ONLY;" ]] || fail "$sql must begin an explicit read-only transaction"
  reject_regex "$sql" '(^|[^A-Za-z_])(INSERT|UPDATE|DELETE|TRUNCATE|ALTER|DROP|CREATE|GRANT|REVOKE|COPY)[[:space:]]' "mutating SQL"
  reject_regex "$sql" 'decrypted_secret|claim_whatsapp_packet_ai_dispatch_job[(][[:space:]]*([0-9]|p_)|net\.http_' "secret read or side-effecting call"
done
# Scanner-neutral output contract: the JSON-emitting SQL files carry no psql meta-commands; every caller asks psql
# for bare tuples (-t -A) instead, so stdout is exactly one JSON value.
for sql in "$snapshot_sql" "$observe_sql"; do
  reject_regex "$sql" '^[[:space:]]*\\' "psql meta-command in $sql (callers must pass -t -A)"
done
require_exact_count "$consumer_release" '-X -q -t -A -v ON_ERROR_STOP=1' 5 "bare-tuples snapshot callers"
require_exact_count "$consumer_release" 'scripts/sql/snapshot-whatsapp-packet-ai-consumer-production-state\.sql' 5 "snapshot SQL callers"
require_contains "$observe_script" '-X -q -t -A -v ON_ERROR_STOP=1' "observation query returns bare tuples"
# The JSON-emitting SQL is plain SQL with no psql variable interpolation (:name, :'name'); the release instant is applied
# by the evaluator, never spliced into SQL.
for sql in "$snapshot_sql" "$observe_sql" "$runtime_sql"; do
  reject_regex "$sql" "(^|[^:]):[A-Za-z_'\"]" "psql variable interpolation in $sql"
done
reject_regex "$observe_script" '-v[[:space:]]+since=' "release instant must not be passed to SQL"
reject_regex "$observe_script" '"?(cron|vault)"?[[:space:]]*[.][[:space:]]*"?[A-Za-z_]|net\.http_|supabase[[:space:]]+functions' "observation must stay read-only and cron-free"

broad_count="$(grep -Ec 'supabase[[:space:]]+functions[[:space:]]+deploy([[:space:]]|$)' "$consumer_release" || true)"
named_count="$(grep -Fc 'supabase functions deploy whatsapp-packet-ai-consumer' "$consumer_release" || true)"
[[ "$broad_count" -eq 1 && "$named_count" -eq 1 ]] || fail "release workflow must contain exactly one governed consumer deploy"

# The pin must describe exactly the live baseline the workflow asserts.
jq -e '.function == "whatsapp-packet-ai-consumer" and .liveVersion == 5
       and .liveBundleSha256 == "6132d9ed0591a37a82b05d5bcf11d6c608f188b82254b7e0b331faaa2d461903"' \
  "$rollback_completion_pin" >/dev/null || fail "rollback completion pin does not match the pinned live baseline"

# The CI regression suite must keep covering the defect and the auth boundary.
require_contains "$consumer_tests" 'idle queue (all-NULL claim row) is HTTP 200 idle=true' "idle regression"
require_contains "$consumer_tests" 'a partially populated claim row fails closed' "malformed lease regression"
require_contains "$consumer_tests" 'returns 401 for a missing or blank worker secret' "401 regression"
require_contains "$consumer_tests" 'returns 403 for a wrong worker secret' "403 regression"
require_contains "$consumer_ci" '--allow-run --allow-read' "subprocess HTTP contract permitted in CI"

echo "WhatsApp packet AI consumer production release governance passed."

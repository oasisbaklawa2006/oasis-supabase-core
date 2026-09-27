#!/usr/bin/env bash
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

release=".github/workflows/whatsapp-webhook-production-release.yml"
rollback=".github/workflows/whatsapp-webhook-production-rollback.yml"
plan="docs/security/WHATSAPP_WEBHOOK_PRODUCTION_MIGRATION_PLAN_2026-09-27.md"
ownership="FUNCTION_OWNERSHIP.md"
manifest="scripts/edge-function-source-manifest.py"
manifest_test="scripts/tests/verify-edge-function-source-manifest.sh"

fail() {
  echo "WHATSAPP WEBHOOK RELEASE GOVERNANCE VIOLATION: $*" >&2
  exit 1
}

require_file() {
  local path="$1"
  [[ -s "$path" ]] || fail "missing required file: $path"
}

require_contains() {
  local file="$1"
  local needle="$2"
  local label="$3"
  grep -Fq -- "$needle" "$file" || fail "$label missing from $file"
}

require_regex() {
  local file="$1"
  local regex="$2"
  local label="$3"
  grep -Eq -- "$regex" "$file" || fail "$label missing from $file"
}

require_job_regex() {
  local file="$1"
  local job="$2"
  local regex="$3"
  local label="$4"
  awk -v job="$job" -v regex="$regex" '
    $0 == "  " job ":" { in_job=1; next }
    in_job && $0 ~ /^  [A-Za-z0-9_-]+:$/ { exit }
    in_job && $0 ~ regex { found=1 }
    END { exit(found ? 0 : 1) }
  ' "$file" || fail "$label missing from $file job $job"
}

reject_regex() {
  local file="$1"
  local regex="$2"
  local label="$3"
  if grep -Eq -- "$regex" "$file"; then
    fail "$label detected in $file"
  fi
}

require_exact_count() {
  local file="$1"
  local regex="$2"
  local expected="$3"
  local label="$4"
  local actual
  actual="$(grep -Ec -- "$regex" "$file" || true)"
  [[ "$actual" -eq "$expected" ]] || fail "$label count is $actual in $file; expected $expected"
}

line_of() {
  local file="$1"
  local needle="$2"
  local label="$3"
  local lines
  lines="$(grep -nF -- "$needle" "$file" | cut -d: -f1 || true)"
  [[ -n "$lines" ]] || fail "$label missing from $file"
  [[ "$(printf '%s\n' "$lines" | wc -l | tr -d ' ')" -eq 1 ]] || fail "$label must occur exactly once in $file"
  printf '%s' "$lines"
}

require_order() {
  local file="$1"
  shift
  local previous=0
  local label needle current
  while [[ "$#" -gt 0 ]]; do
    label="$1"
    needle="$2"
    shift 2
    current="$(line_of "$file" "$needle" "$label")"
    [[ "$current" -gt "$previous" ]] || fail "$label is out of order in $file"
    previous="$current"
  done
}

for required in "$release" "$rollback" "$plan" "$ownership" "$manifest" "$manifest_test"; do
  require_file "$required"
done

# Structural uniqueness: iterative edits must never leave duplicate production jobs.
require_exact_count "$release" '^  preflight:$' 1 "release preflight job"
require_exact_count "$release" '^  deploy:$' 1 "release deploy job"
require_exact_count "$rollback" '^  preflight:$' 1 "rollback preflight job"
require_exact_count "$rollback" '^  rollback:$' 1 "rollback mutation job"

for workflow in "$release" "$rollback"; do
  require_contains "$workflow" "workflow_dispatch:" "manual workflow trigger"
  reject_regex "$workflow" '^[[:space:]]{2}(push|pull_request|schedule|repository_dispatch):' "automatic production trigger"
  reject_regex "$workflow" '^[[:space:]]+(contents|actions|deployments|id-token):[[:space:]]+write' "write-level GitHub token permission"

  require_contains "$workflow" "group: whatsapp-webhook-production-release" "shared release/rollback concurrency lock"
  require_contains "$workflow" "contents: read" "read-only contents permission"
  require_contains "$workflow" "actions: read" "read-only Actions permission"
  require_contains "$workflow" "environment: supabase-production-readonly" "read-only production environment gate"
  if [[ "$workflow" == "$release" ]]; then
    require_job_regex "$workflow" "deploy" '^    environment: supabase-production$' "production mutation environment gate"
  else
    require_job_regex "$workflow" "rollback" '^    environment: supabase-production$' "production mutation environment gate"
  fi
  require_contains "$workflow" "persist-credentials: false" "checkout credential hardening"
  require_contains "$workflow" "SUPABASE_PROJECT_REF: tcxvcatsqqertcnycuop" "canonical production project binding"
  require_contains "$workflow" "FUNCTION_NAME: whatsapp-webhook" "named function binding"
  require_contains "$workflow" "SUPABASE_CLI_VERSION: 2.117.0" "pinned Supabase CLI"

  reject_regex "$workflow" 'SUPABASE_DB_URL|supabase[[:space:]]+db[[:space:]]+(push|reset|query)|supabase[[:space:]]+migration[[:space:]]+(up|repair)|supabase[[:space:]]+secrets[[:space:]]+(set|unset)' "database or secret mutation authority"
  reject_regex "$workflow" 'supabase[[:space:]]+functions[[:space:]]+deploy[[:space:]]+[$"{]' "variable Edge deploy target"
  reject_regex "$workflow" 'uses:[[:space:]]+actions/(checkout|upload-artifact|download-artifact)@v[0-9]+' "unpinned first-party action"

  broad_count="$(grep -Ec 'supabase[[:space:]]+functions[[:space:]]+deploy([[:space:]]|$)' "$workflow" || true)"
  named_count="$(grep -Ec 'supabase[[:space:]]+functions[[:space:]]+deploy[[:space:]]+whatsapp-webhook([[:space:]]|$)' "$workflow" || true)"
  [[ "$broad_count" -eq 1 && "$named_count" -eq 1 ]] || fail "every deploy in $workflow must be exactly one literal whatsapp-webhook deploy"

  require_contains "$workflow" 'test "${GITHUB_REF}" = "refs/heads/main"' "protected branch check"
  require_contains "$workflow" 'git fetch --quiet origin refs/heads/main:refs/remotes/origin/main' "current-main fetch"
  require_contains "$workflow" 'test "$(git rev-parse refs/remotes/origin/main)" = "$GITHUB_SHA"' "current-main equality check"
  require_contains "$workflow" 'WHATSAPP_WEBHOOK_VERIFY_TOKEN' "verify-token secret-name readiness"
  require_contains "$workflow" 'CLICK2API_API_KEY' "Click2API secret-name readiness"
  require_contains "$workflow" '${{ github.run_attempt }}' "retry-safe evidence naming"
  require_contains "$workflow" 'if-no-files-found: error' "required artifact failure policy"
done

# Forward release baseline, provenance, source attestation, rollback capture and final evidence.
require_contains "$release" 'EXPECTED_LIVE_VERSION: "167"' "known live version baseline"
require_contains "$release" 'EXPECTED_LIVE_BUNDLE_SHA: 8ae1f251335fe0b9fac952ec3444e858a313f2fe6d34f64cb561ca55d93c3426' "known live bundle baseline"
require_contains "$release" 'DB_PREREQ_RUN_ID: "36335058964"' "database prerequisite run binding"
require_contains "$release" 'DB_PREREQ_SHA: f3366a4a99b57e20ec47a4f152af3a7b3661f5c6' "database prerequisite SHA binding"
require_contains "$release" 'supabase functions download whatsapp-webhook' "live source download"
require_contains "$release" '--use-api' "API-based source unbundling"
require_contains "$release" 'target-source-manifest.json' "reviewed source manifest"
require_contains "$release" 'live-source-manifest.json' "deployed source manifest"
require_regex "$release" 'diff -u[[:space:]\\]*[[:space:]]*target-source-manifest.json[[:space:]\\]*[[:space:]]*live-source-manifest.json' "reviewed/live source equality"
require_contains "$release" 'whatsapp-webhook-predeploy-v167.tar.gz' "rollback source archive"
require_contains "$release" 'ROLLBACK_ARCHIVE_SHA256' "rollback archive integrity binding"
require_contains "$release" 'Build successful release attestation' "successful release attestation"
require_contains "$release" 'whatsapp-webhook-release-attestation.json' "release attestation artifact"
require_contains "$release" 'Fail if access credentials leaked into text evidence' "post-deploy credential evidence scan"
require_contains "$release" 'Upload required verified release evidence' "required verified release upload"
require_contains "$release" 'Unexpected browser CORS header' "hardened no-browser-CORS runtime probe"
require_contains "$release" '.error == "verify_token_invalid"' "hardened invalid challenge semantic assertion"
require_contains "$release" '.error == "signature_missing"' "hardened missing signature semantic assertion"
require_contains "$release" 'test "$challenge_code" = "403"' "hardened invalid challenge status"
require_contains "$release" 'test "$post_code" = "401"' "hardened unauthenticated POST status"
require_contains "$release" 'test "$options_code" = "204"' "hardened OPTIONS status"

require_order "$release" \
  "rollback capture" "Capture restorable live source with pinned Supabase CLI" \
  "post-capture live recheck" "Recheck live baseline after rollback capture" \
  "rollback evidence validation" "Require complete rollback evidence before deployment" \
  "rollback evidence upload" "Upload immutable rollback evidence before deployment" \
  "final current-main/live recheck" "Recheck unchanged current main and live baseline immediately before deployment" \
  "named production deploy" "Deploy exact named function only" \
  "deployed metadata verification" "Verify deployed function metadata" \
  "deployed source closure verification" "Verify deployed source closure matches reviewed source" \
  "runtime authentication probes" "Run non-customer authentication and header smoke checks" \
  "release attestation" "Build successful release attestation" \
  "credential evidence scan" "Fail if access credentials leaked into text evidence" \
  "verified evidence upload" "Upload required verified release evidence"

# Rollback must be bound to the originating release evidence and exact current live state.
require_contains "$rollback" 'ROLLBACK_TO_VERSION: "167"' "rollback target version"
require_contains "$rollback" 'ROLLBACK_TO_BUNDLE_SHA: 8ae1f251335fe0b9fac952ec3444e858a313f2fe6d34f64cb561ca55d93c3426' "rollback target bundle baseline"
require_contains "$rollback" 'source_run_id:' "source release run input"
require_contains "$rollback" 'source_run_attempt:' "source release attempt input"
require_contains "$rollback" 'source_release_sha:' "source release SHA input"
require_contains "$rollback" 'expected_current_version:' "current live version input"
require_contains "$rollback" 'expected_current_bundle_sha:' "current live bundle input"
require_contains "$rollback" '.path == ".github/workflows/whatsapp-webhook-production-release.yml"' "forward workflow identity binding"
require_contains "$rollback" '.status == "completed"' "completed forward-run requirement"
require_contains "$rollback" '.run_attempt == $expected_attempt' "forward run-attempt binding"
require_contains "$rollback" 'artifact_name_encoded="$(jq -rn --arg value "$artifact_name" '\''$value | @uri'\'')"' "URL-encoded rollback artifact name"
require_contains "$rollback" '$api/artifacts?name=$artifact_name_encoded&per_page=100' "server-side rollback artifact name filter"
require_contains "$rollback" 'expected-rollback-source-manifest.json' "expected rollback source manifest"
require_contains "$rollback" 'live-rollback-source-manifest.json' "live rollback source manifest"
require_regex "$rollback" 'diff -u[[:space:]\\]*[[:space:]]*rollback-evidence/expected-rollback-source-manifest.json[[:space:]\\]*[[:space:]]*live-rollback-source-manifest.json' "rollback/live source equality"
require_contains "$rollback" 'Confirm stable rollback bundle metadata' "stable rollback bundle metadata confirmation"
require_contains "$rollback" 'deployedRollbackBundleSha256' "deployed rollback bundle hash attestation"
require_contains "$rollback" 'confirmedRollbackBundleSha256' "confirmed rollback bundle hash attestation"
require_contains "$rollback" '.deployedRollbackBundleSha256 == .confirmedRollbackBundleSha256' "rollback bundle hash equality assertion"
require_contains "$rollback" 'Build rollback attestation' "rollback attestation"
require_contains "$rollback" 'whatsapp-webhook-rollback-attestation.json' "rollback attestation artifact"
require_contains "$rollback" 'Fail if access credential leaked into rollback evidence' "rollback credential evidence scan"
require_contains "$rollback" 'Upload verified rollback evidence' "required rollback evidence upload"
require_contains "$rollback" 'Run v167-compatible non-customer rollback smoke checks' "v167-compatible rollback smoke step"
require_contains "$rollback" 'test "$challenge_code" = "403"' "v167 rollback invalid challenge status"
require_contains "$rollback" 'test "$post_code" = "401"' "v167 rollback unauthenticated POST status"
require_contains "$rollback" 'test "$options_code" = "200"' "v167 rollback OPTIONS status"
reject_regex "$rollback" 'verify_token_invalid|signature_missing|Unexpected browser CORS header after webhook rollback' "forward-only hardened response semantics in v167 rollback smoke"

require_order "$rollback" \
  "rollback request identity" "Validate rollback request identity and current main" \
  "source release verification" "Verify source release run and resolve rollback artifact" \
  "immutable rollback package validation" "Download and validate immutable rollback package" \
  "expected rollback source manifest" "Build expected rollback source manifest" \
  "preflight live state validation" "Verify exact live state to be rolled back" \
  "rollback preflight attestation" "Build rollback preflight attestation" \
  "normalized rollback package upload" "Upload normalized rollback package" \
  "rollback package/live-state revalidation" "Revalidate rollback package and exact current live state" \
  "final rollback live-state recheck" "Recheck unchanged current main and live state immediately before rollback" \
  "named rollback deploy" "Execute named rollback only" \
  "rollback metadata verification" "Verify rollback deployment metadata" \
  "rollback bundle metadata confirmation" "Confirm stable rollback bundle metadata" \
  "restored source closure verification" "Verify restored source closure" \
  "rollback compatibility probes" "Run v167-compatible non-customer rollback smoke checks" \
  "rollback attestation" "Build rollback attestation" \
  "rollback credential evidence scan" "Fail if access credential leaked into rollback evidence" \
  "verified rollback evidence upload" "Upload verified rollback evidence"

require_contains "$ownership" "Governed release plan:" "ownership release plan"
require_contains "$ownership" "whatsapp-webhook-production-release.yml" "ownership forward release workflow"
require_contains "$ownership" "whatsapp-webhook-production-rollback.yml" "ownership rollback workflow"

bash -n "$manifest_test"
python3 -m py_compile "$manifest"

echo "WhatsApp webhook production release governance passed."
 "production mutation environment gate"
  else
    require_job_regex "$workflow" "rollback" '^    environment: supabase-production  require_contains "$workflow" "persist-credentials: false" "checkout credential hardening"
  require_contains "$workflow" "SUPABASE_PROJECT_REF: tcxvcatsqqertcnycuop" "canonical production project binding"
  require_contains "$workflow" "FUNCTION_NAME: whatsapp-webhook" "named function binding"
  require_contains "$workflow" "SUPABASE_CLI_VERSION: 2.117.0" "pinned Supabase CLI"

  reject_regex "$workflow" 'SUPABASE_DB_URL|supabase[[:space:]]+db[[:space:]]+(push|reset|query)|supabase[[:space:]]+migration[[:space:]]+(up|repair)|supabase[[:space:]]+secrets[[:space:]]+(set|unset)' "database or secret mutation authority"
  reject_regex "$workflow" 'supabase[[:space:]]+functions[[:space:]]+deploy[[:space:]]+[$"{]' "variable Edge deploy target"
  reject_regex "$workflow" 'uses:[[:space:]]+actions/(checkout|upload-artifact|download-artifact)@v[0-9]+' "unpinned first-party action"

  broad_count="$(grep -Ec 'supabase[[:space:]]+functions[[:space:]]+deploy([[:space:]]|$)' "$workflow" || true)"
  named_count="$(grep -Ec 'supabase[[:space:]]+functions[[:space:]]+deploy[[:space:]]+whatsapp-webhook([[:space:]]|$)' "$workflow" || true)"
  [[ "$broad_count" -eq 1 && "$named_count" -eq 1 ]] || fail "every deploy in $workflow must be exactly one literal whatsapp-webhook deploy"

  require_contains "$workflow" 'test "${GITHUB_REF}" = "refs/heads/main"' "protected branch check"
  require_contains "$workflow" 'git fetch --quiet origin refs/heads/main:refs/remotes/origin/main' "current-main fetch"
  require_contains "$workflow" 'test "$(git rev-parse refs/remotes/origin/main)" = "$GITHUB_SHA"' "current-main equality check"
  require_contains "$workflow" 'WHATSAPP_WEBHOOK_VERIFY_TOKEN' "verify-token secret-name readiness"
  require_contains "$workflow" 'CLICK2API_API_KEY' "Click2API secret-name readiness"
  require_contains "$workflow" '${{ github.run_attempt }}' "retry-safe evidence naming"
  require_contains "$workflow" 'if-no-files-found: error' "required artifact failure policy"
done

# Forward release baseline, provenance, source attestation, rollback capture and final evidence.
require_contains "$release" 'EXPECTED_LIVE_VERSION: "167"' "known live version baseline"
require_contains "$release" 'EXPECTED_LIVE_BUNDLE_SHA: 8ae1f251335fe0b9fac952ec3444e858a313f2fe6d34f64cb561ca55d93c3426' "known live bundle baseline"
require_contains "$release" 'DB_PREREQ_RUN_ID: "36335058964"' "database prerequisite run binding"
require_contains "$release" 'DB_PREREQ_SHA: f3366a4a99b57e20ec47a4f152af3a7b3661f5c6' "database prerequisite SHA binding"
require_contains "$release" 'supabase functions download whatsapp-webhook' "live source download"
require_contains "$release" '--use-api' "API-based source unbundling"
require_contains "$release" 'target-source-manifest.json' "reviewed source manifest"
require_contains "$release" 'live-source-manifest.json' "deployed source manifest"
require_regex "$release" 'diff -u[[:space:]\\]*[[:space:]]*target-source-manifest.json[[:space:]\\]*[[:space:]]*live-source-manifest.json' "reviewed/live source equality"
require_contains "$release" 'whatsapp-webhook-predeploy-v167.tar.gz' "rollback source archive"
require_contains "$release" 'ROLLBACK_ARCHIVE_SHA256' "rollback archive integrity binding"
require_contains "$release" 'Build successful release attestation' "successful release attestation"
require_contains "$release" 'whatsapp-webhook-release-attestation.json' "release attestation artifact"
require_contains "$release" 'Fail if access credentials leaked into text evidence' "post-deploy credential evidence scan"
require_contains "$release" 'Upload required verified release evidence' "required verified release upload"
require_contains "$release" 'Unexpected browser CORS header' "hardened no-browser-CORS runtime probe"
require_contains "$release" '.error == "verify_token_invalid"' "hardened invalid challenge semantic assertion"
require_contains "$release" '.error == "signature_missing"' "hardened missing signature semantic assertion"
require_contains "$release" 'test "$challenge_code" = "403"' "hardened invalid challenge status"
require_contains "$release" 'test "$post_code" = "401"' "hardened unauthenticated POST status"
require_contains "$release" 'test "$options_code" = "204"' "hardened OPTIONS status"

require_order "$release" \
  "rollback capture" "Capture restorable live source with pinned Supabase CLI" \
  "post-capture live recheck" "Recheck live baseline after rollback capture" \
  "rollback evidence validation" "Require complete rollback evidence before deployment" \
  "rollback evidence upload" "Upload immutable rollback evidence before deployment" \
  "final current-main/live recheck" "Recheck unchanged current main and live baseline immediately before deployment" \
  "named production deploy" "Deploy exact named function only" \
  "deployed metadata verification" "Verify deployed function metadata" \
  "deployed source closure verification" "Verify deployed source closure matches reviewed source" \
  "runtime authentication probes" "Run non-customer authentication and header smoke checks" \
  "release attestation" "Build successful release attestation" \
  "credential evidence scan" "Fail if access credentials leaked into text evidence" \
  "verified evidence upload" "Upload required verified release evidence"

# Rollback must be bound to the originating release evidence and exact current live state.
require_contains "$rollback" 'ROLLBACK_TO_VERSION: "167"' "rollback target version"
require_contains "$rollback" 'ROLLBACK_TO_BUNDLE_SHA: 8ae1f251335fe0b9fac952ec3444e858a313f2fe6d34f64cb561ca55d93c3426' "rollback target bundle baseline"
require_contains "$rollback" 'source_run_id:' "source release run input"
require_contains "$rollback" 'source_run_attempt:' "source release attempt input"
require_contains "$rollback" 'source_release_sha:' "source release SHA input"
require_contains "$rollback" 'expected_current_version:' "current live version input"
require_contains "$rollback" 'expected_current_bundle_sha:' "current live bundle input"
require_contains "$rollback" '.path == ".github/workflows/whatsapp-webhook-production-release.yml"' "forward workflow identity binding"
require_contains "$rollback" '.status == "completed"' "completed forward-run requirement"
require_contains "$rollback" '.run_attempt == $expected_attempt' "forward run-attempt binding"
require_contains "$rollback" 'artifact_name_encoded="$(jq -rn --arg value "$artifact_name" '\''$value | @uri'\'')"' "URL-encoded rollback artifact name"
require_contains "$rollback" '$api/artifacts?name=$artifact_name_encoded&per_page=100' "server-side rollback artifact name filter"
require_contains "$rollback" 'expected-rollback-source-manifest.json' "expected rollback source manifest"
require_contains "$rollback" 'live-rollback-source-manifest.json' "live rollback source manifest"
require_regex "$rollback" 'diff -u[[:space:]\\]*[[:space:]]*rollback-evidence/expected-rollback-source-manifest.json[[:space:]\\]*[[:space:]]*live-rollback-source-manifest.json' "rollback/live source equality"
require_contains "$rollback" 'Build rollback attestation' "rollback attestation"
require_contains "$rollback" 'whatsapp-webhook-rollback-attestation.json' "rollback attestation artifact"
require_contains "$rollback" 'Fail if access credential leaked into rollback evidence' "rollback credential evidence scan"
require_contains "$rollback" 'Upload verified rollback evidence' "required rollback evidence upload"
require_contains "$rollback" 'Run v167-compatible non-customer rollback smoke checks' "v167-compatible rollback smoke step"
require_contains "$rollback" 'test "$challenge_code" = "403"' "v167 rollback invalid challenge status"
require_contains "$rollback" 'test "$post_code" = "401"' "v167 rollback unauthenticated POST status"
require_contains "$rollback" 'test "$options_code" = "200"' "v167 rollback OPTIONS status"
reject_regex "$rollback" 'verify_token_invalid|signature_missing|Unexpected browser CORS header after webhook rollback' "forward-only hardened response semantics in v167 rollback smoke"

require_order "$rollback" \
  "rollback request identity" "Validate rollback request identity and current main" \
  "source release verification" "Verify source release run and resolve rollback artifact" \
  "immutable rollback package validation" "Download and validate immutable rollback package" \
  "expected rollback source manifest" "Build expected rollback source manifest" \
  "preflight live state validation" "Verify exact live state to be rolled back" \
  "rollback preflight attestation" "Build rollback preflight attestation" \
  "normalized rollback package upload" "Upload normalized rollback package" \
  "rollback package/live-state revalidation" "Revalidate rollback package and exact current live state" \
  "final rollback live-state recheck" "Recheck unchanged current main and live state immediately before rollback" \
  "named rollback deploy" "Execute named rollback only" \
  "rollback metadata verification" "Verify rollback deployment metadata" \
  "restored source closure verification" "Verify restored source closure" \
  "rollback compatibility probes" "Run v167-compatible non-customer rollback smoke checks" \
  "rollback attestation" "Build rollback attestation" \
  "rollback credential evidence scan" "Fail if access credential leaked into rollback evidence" \
  "verified rollback evidence upload" "Upload verified rollback evidence"

require_contains "$ownership" "Governed release plan:" "ownership release plan"
require_contains "$ownership" "whatsapp-webhook-production-release.yml" "ownership forward release workflow"
require_contains "$ownership" "whatsapp-webhook-production-rollback.yml" "ownership rollback workflow"

bash -n "$manifest_test"
python3 -m py_compile "$manifest"

echo "WhatsApp webhook production release governance passed."
 "production mutation environment gate"
  fi
  require_contains "$workflow" "persist-credentials: false" "checkout credential hardening"
  require_contains "$workflow" "SUPABASE_PROJECT_REF: tcxvcatsqqertcnycuop" "canonical production project binding"
  require_contains "$workflow" "FUNCTION_NAME: whatsapp-webhook" "named function binding"
  require_contains "$workflow" "SUPABASE_CLI_VERSION: 2.117.0" "pinned Supabase CLI"

  reject_regex "$workflow" 'SUPABASE_DB_URL|supabase[[:space:]]+db[[:space:]]+(push|reset|query)|supabase[[:space:]]+migration[[:space:]]+(up|repair)|supabase[[:space:]]+secrets[[:space:]]+(set|unset)' "database or secret mutation authority"
  reject_regex "$workflow" 'supabase[[:space:]]+functions[[:space:]]+deploy[[:space:]]+[$"{]' "variable Edge deploy target"
  reject_regex "$workflow" 'uses:[[:space:]]+actions/(checkout|upload-artifact|download-artifact)@v[0-9]+' "unpinned first-party action"

  broad_count="$(grep -Ec 'supabase[[:space:]]+functions[[:space:]]+deploy([[:space:]]|$)' "$workflow" || true)"
  named_count="$(grep -Ec 'supabase[[:space:]]+functions[[:space:]]+deploy[[:space:]]+whatsapp-webhook([[:space:]]|$)' "$workflow" || true)"
  [[ "$broad_count" -eq 1 && "$named_count" -eq 1 ]] || fail "every deploy in $workflow must be exactly one literal whatsapp-webhook deploy"

  require_contains "$workflow" 'test "${GITHUB_REF}" = "refs/heads/main"' "protected branch check"
  require_contains "$workflow" 'git fetch --quiet origin refs/heads/main:refs/remotes/origin/main' "current-main fetch"
  require_contains "$workflow" 'test "$(git rev-parse refs/remotes/origin/main)" = "$GITHUB_SHA"' "current-main equality check"
  require_contains "$workflow" 'WHATSAPP_WEBHOOK_VERIFY_TOKEN' "verify-token secret-name readiness"
  require_contains "$workflow" 'CLICK2API_API_KEY' "Click2API secret-name readiness"
  require_contains "$workflow" '${{ github.run_attempt }}' "retry-safe evidence naming"
  require_contains "$workflow" 'if-no-files-found: error' "required artifact failure policy"
done

# Forward release baseline, provenance, source attestation, rollback capture and final evidence.
require_contains "$release" 'EXPECTED_LIVE_VERSION: "167"' "known live version baseline"
require_contains "$release" 'EXPECTED_LIVE_BUNDLE_SHA: 8ae1f251335fe0b9fac952ec3444e858a313f2fe6d34f64cb561ca55d93c3426' "known live bundle baseline"
require_contains "$release" 'DB_PREREQ_RUN_ID: "36335058964"' "database prerequisite run binding"
require_contains "$release" 'DB_PREREQ_SHA: f3366a4a99b57e20ec47a4f152af3a7b3661f5c6' "database prerequisite SHA binding"
require_contains "$release" 'supabase functions download whatsapp-webhook' "live source download"
require_contains "$release" '--use-api' "API-based source unbundling"
require_contains "$release" 'target-source-manifest.json' "reviewed source manifest"
require_contains "$release" 'live-source-manifest.json' "deployed source manifest"
require_regex "$release" 'diff -u[[:space:]\\]*[[:space:]]*target-source-manifest.json[[:space:]\\]*[[:space:]]*live-source-manifest.json' "reviewed/live source equality"
require_contains "$release" 'whatsapp-webhook-predeploy-v167.tar.gz' "rollback source archive"
require_contains "$release" 'ROLLBACK_ARCHIVE_SHA256' "rollback archive integrity binding"
require_contains "$release" 'Build successful release attestation' "successful release attestation"
require_contains "$release" 'whatsapp-webhook-release-attestation.json' "release attestation artifact"
require_contains "$release" 'Fail if access credentials leaked into text evidence' "post-deploy credential evidence scan"
require_contains "$release" 'Upload required verified release evidence' "required verified release upload"
require_contains "$release" 'Unexpected browser CORS header' "hardened no-browser-CORS runtime probe"
require_contains "$release" '.error == "verify_token_invalid"' "hardened invalid challenge semantic assertion"
require_contains "$release" '.error == "signature_missing"' "hardened missing signature semantic assertion"
require_contains "$release" 'test "$challenge_code" = "403"' "hardened invalid challenge status"
require_contains "$release" 'test "$post_code" = "401"' "hardened unauthenticated POST status"
require_contains "$release" 'test "$options_code" = "204"' "hardened OPTIONS status"

require_order "$release" \
  "rollback capture" "Capture restorable live source with pinned Supabase CLI" \
  "post-capture live recheck" "Recheck live baseline after rollback capture" \
  "rollback evidence validation" "Require complete rollback evidence before deployment" \
  "rollback evidence upload" "Upload immutable rollback evidence before deployment" \
  "final current-main/live recheck" "Recheck unchanged current main and live baseline immediately before deployment" \
  "named production deploy" "Deploy exact named function only" \
  "deployed metadata verification" "Verify deployed function metadata" \
  "deployed source closure verification" "Verify deployed source closure matches reviewed source" \
  "runtime authentication probes" "Run non-customer authentication and header smoke checks" \
  "release attestation" "Build successful release attestation" \
  "credential evidence scan" "Fail if access credentials leaked into text evidence" \
  "verified evidence upload" "Upload required verified release evidence"

# Rollback must be bound to the originating release evidence and exact current live state.
require_contains "$rollback" 'ROLLBACK_TO_VERSION: "167"' "rollback target version"
require_contains "$rollback" 'ROLLBACK_TO_BUNDLE_SHA: 8ae1f251335fe0b9fac952ec3444e858a313f2fe6d34f64cb561ca55d93c3426' "rollback target bundle baseline"
require_contains "$rollback" 'source_run_id:' "source release run input"
require_contains "$rollback" 'source_run_attempt:' "source release attempt input"
require_contains "$rollback" 'source_release_sha:' "source release SHA input"
require_contains "$rollback" 'expected_current_version:' "current live version input"
require_contains "$rollback" 'expected_current_bundle_sha:' "current live bundle input"
require_contains "$rollback" '.path == ".github/workflows/whatsapp-webhook-production-release.yml"' "forward workflow identity binding"
require_contains "$rollback" '.status == "completed"' "completed forward-run requirement"
require_contains "$rollback" '.run_attempt == $expected_attempt' "forward run-attempt binding"
require_contains "$rollback" 'artifact_name_encoded="$(jq -rn --arg value "$artifact_name" '\''$value | @uri'\'')"' "URL-encoded rollback artifact name"
require_contains "$rollback" '$api/artifacts?name=$artifact_name_encoded&per_page=100' "server-side rollback artifact name filter"
require_contains "$rollback" 'expected-rollback-source-manifest.json' "expected rollback source manifest"
require_contains "$rollback" 'live-rollback-source-manifest.json' "live rollback source manifest"
require_regex "$rollback" 'diff -u[[:space:]\\]*[[:space:]]*rollback-evidence/expected-rollback-source-manifest.json[[:space:]\\]*[[:space:]]*live-rollback-source-manifest.json' "rollback/live source equality"
require_contains "$rollback" 'Build rollback attestation' "rollback attestation"
require_contains "$rollback" 'whatsapp-webhook-rollback-attestation.json' "rollback attestation artifact"
require_contains "$rollback" 'Fail if access credential leaked into rollback evidence' "rollback credential evidence scan"
require_contains "$rollback" 'Upload verified rollback evidence' "required rollback evidence upload"
require_contains "$rollback" 'Run v167-compatible non-customer rollback smoke checks' "v167-compatible rollback smoke step"
require_contains "$rollback" 'test "$challenge_code" = "403"' "v167 rollback invalid challenge status"
require_contains "$rollback" 'test "$post_code" = "401"' "v167 rollback unauthenticated POST status"
require_contains "$rollback" 'test "$options_code" = "200"' "v167 rollback OPTIONS status"
reject_regex "$rollback" 'verify_token_invalid|signature_missing|Unexpected browser CORS header after webhook rollback' "forward-only hardened response semantics in v167 rollback smoke"

require_order "$rollback" \
  "rollback request identity" "Validate rollback request identity and current main" \
  "source release verification" "Verify source release run and resolve rollback artifact" \
  "immutable rollback package validation" "Download and validate immutable rollback package" \
  "expected rollback source manifest" "Build expected rollback source manifest" \
  "preflight live state validation" "Verify exact live state to be rolled back" \
  "rollback preflight attestation" "Build rollback preflight attestation" \
  "normalized rollback package upload" "Upload normalized rollback package" \
  "rollback package/live-state revalidation" "Revalidate rollback package and exact current live state" \
  "final rollback live-state recheck" "Recheck unchanged current main and live state immediately before rollback" \
  "named rollback deploy" "Execute named rollback only" \
  "rollback metadata verification" "Verify rollback deployment metadata" \
  "restored source closure verification" "Verify restored source closure" \
  "rollback compatibility probes" "Run v167-compatible non-customer rollback smoke checks" \
  "rollback attestation" "Build rollback attestation" \
  "rollback credential evidence scan" "Fail if access credential leaked into rollback evidence" \
  "verified rollback evidence upload" "Upload verified rollback evidence"

require_contains "$ownership" "Governed release plan:" "ownership release plan"
require_contains "$ownership" "whatsapp-webhook-production-release.yml" "ownership forward release workflow"
require_contains "$ownership" "whatsapp-webhook-production-rollback.yml" "ownership rollback workflow"

bash -n "$manifest_test"
python3 -m py_compile "$manifest"

echo "WhatsApp webhook production release governance passed."
 "production mutation environment gate"
  else
    require_job_regex "$workflow" "rollback" '^    environment: supabase-production
  require_contains "$workflow" "SUPABASE_PROJECT_REF: tcxvcatsqqertcnycuop" "canonical production project binding"
  require_contains "$workflow" "FUNCTION_NAME: whatsapp-webhook" "named function binding"
  require_contains "$workflow" "SUPABASE_CLI_VERSION: 2.117.0" "pinned Supabase CLI"

  reject_regex "$workflow" 'SUPABASE_DB_URL|supabase[[:space:]]+db[[:space:]]+(push|reset|query)|supabase[[:space:]]+migration[[:space:]]+(up|repair)|supabase[[:space:]]+secrets[[:space:]]+(set|unset)' "database or secret mutation authority"
  reject_regex "$workflow" 'supabase[[:space:]]+functions[[:space:]]+deploy[[:space:]]+[$"{]' "variable Edge deploy target"
  reject_regex "$workflow" 'uses:[[:space:]]+actions/(checkout|upload-artifact|download-artifact)@v[0-9]+' "unpinned first-party action"

  broad_count="$(grep -Ec 'supabase[[:space:]]+functions[[:space:]]+deploy([[:space:]]|$)' "$workflow" || true)"
  named_count="$(grep -Ec 'supabase[[:space:]]+functions[[:space:]]+deploy[[:space:]]+whatsapp-webhook([[:space:]]|$)' "$workflow" || true)"
  [[ "$broad_count" -eq 1 && "$named_count" -eq 1 ]] || fail "every deploy in $workflow must be exactly one literal whatsapp-webhook deploy"

  require_contains "$workflow" 'test "${GITHUB_REF}" = "refs/heads/main"' "protected branch check"
  require_contains "$workflow" 'git fetch --quiet origin refs/heads/main:refs/remotes/origin/main' "current-main fetch"
  require_contains "$workflow" 'test "$(git rev-parse refs/remotes/origin/main)" = "$GITHUB_SHA"' "current-main equality check"
  require_contains "$workflow" 'WHATSAPP_WEBHOOK_VERIFY_TOKEN' "verify-token secret-name readiness"
  require_contains "$workflow" 'CLICK2API_API_KEY' "Click2API secret-name readiness"
  require_contains "$workflow" '${{ github.run_attempt }}' "retry-safe evidence naming"
  require_contains "$workflow" 'if-no-files-found: error' "required artifact failure policy"
done

# Forward release baseline, provenance, source attestation, rollback capture and final evidence.
require_contains "$release" 'EXPECTED_LIVE_VERSION: "167"' "known live version baseline"
require_contains "$release" 'EXPECTED_LIVE_BUNDLE_SHA: 8ae1f251335fe0b9fac952ec3444e858a313f2fe6d34f64cb561ca55d93c3426' "known live bundle baseline"
require_contains "$release" 'DB_PREREQ_RUN_ID: "36335058964"' "database prerequisite run binding"
require_contains "$release" 'DB_PREREQ_SHA: f3366a4a99b57e20ec47a4f152af3a7b3661f5c6' "database prerequisite SHA binding"
require_contains "$release" 'supabase functions download whatsapp-webhook' "live source download"
require_contains "$release" '--use-api' "API-based source unbundling"
require_contains "$release" 'target-source-manifest.json' "reviewed source manifest"
require_contains "$release" 'live-source-manifest.json' "deployed source manifest"
require_regex "$release" 'diff -u[[:space:]\\]*[[:space:]]*target-source-manifest.json[[:space:]\\]*[[:space:]]*live-source-manifest.json' "reviewed/live source equality"
require_contains "$release" 'whatsapp-webhook-predeploy-v167.tar.gz' "rollback source archive"
require_contains "$release" 'ROLLBACK_ARCHIVE_SHA256' "rollback archive integrity binding"
require_contains "$release" 'Build successful release attestation' "successful release attestation"
require_contains "$release" 'whatsapp-webhook-release-attestation.json' "release attestation artifact"
require_contains "$release" 'Fail if access credentials leaked into text evidence' "post-deploy credential evidence scan"
require_contains "$release" 'Upload required verified release evidence' "required verified release upload"
require_contains "$release" 'Unexpected browser CORS header' "hardened no-browser-CORS runtime probe"
require_contains "$release" '.error == "verify_token_invalid"' "hardened invalid challenge semantic assertion"
require_contains "$release" '.error == "signature_missing"' "hardened missing signature semantic assertion"
require_contains "$release" 'test "$challenge_code" = "403"' "hardened invalid challenge status"
require_contains "$release" 'test "$post_code" = "401"' "hardened unauthenticated POST status"
require_contains "$release" 'test "$options_code" = "204"' "hardened OPTIONS status"

require_order "$release" \
  "rollback capture" "Capture restorable live source with pinned Supabase CLI" \
  "post-capture live recheck" "Recheck live baseline after rollback capture" \
  "rollback evidence validation" "Require complete rollback evidence before deployment" \
  "rollback evidence upload" "Upload immutable rollback evidence before deployment" \
  "final current-main/live recheck" "Recheck unchanged current main and live baseline immediately before deployment" \
  "named production deploy" "Deploy exact named function only" \
  "deployed metadata verification" "Verify deployed function metadata" \
  "deployed source closure verification" "Verify deployed source closure matches reviewed source" \
  "runtime authentication probes" "Run non-customer authentication and header smoke checks" \
  "release attestation" "Build successful release attestation" \
  "credential evidence scan" "Fail if access credentials leaked into text evidence" \
  "verified evidence upload" "Upload required verified release evidence"

# Rollback must be bound to the originating release evidence and exact current live state.
require_contains "$rollback" 'ROLLBACK_TO_VERSION: "167"' "rollback target version"
require_contains "$rollback" 'ROLLBACK_TO_BUNDLE_SHA: 8ae1f251335fe0b9fac952ec3444e858a313f2fe6d34f64cb561ca55d93c3426' "rollback target bundle baseline"
require_contains "$rollback" 'source_run_id:' "source release run input"
require_contains "$rollback" 'source_run_attempt:' "source release attempt input"
require_contains "$rollback" 'source_release_sha:' "source release SHA input"
require_contains "$rollback" 'expected_current_version:' "current live version input"
require_contains "$rollback" 'expected_current_bundle_sha:' "current live bundle input"
require_contains "$rollback" '.path == ".github/workflows/whatsapp-webhook-production-release.yml"' "forward workflow identity binding"
require_contains "$rollback" '.status == "completed"' "completed forward-run requirement"
require_contains "$rollback" '.run_attempt == $expected_attempt' "forward run-attempt binding"
require_contains "$rollback" 'artifact_name_encoded="$(jq -rn --arg value "$artifact_name" '\''$value | @uri'\'')"' "URL-encoded rollback artifact name"
require_contains "$rollback" '$api/artifacts?name=$artifact_name_encoded&per_page=100' "server-side rollback artifact name filter"
require_contains "$rollback" 'expected-rollback-source-manifest.json' "expected rollback source manifest"
require_contains "$rollback" 'live-rollback-source-manifest.json' "live rollback source manifest"
require_regex "$rollback" 'diff -u[[:space:]\\]*[[:space:]]*rollback-evidence/expected-rollback-source-manifest.json[[:space:]\\]*[[:space:]]*live-rollback-source-manifest.json' "rollback/live source equality"
require_contains "$rollback" 'Confirm stable rollback bundle metadata' "stable rollback bundle metadata confirmation"
require_contains "$rollback" 'deployedRollbackBundleSha256' "deployed rollback bundle hash attestation"
require_contains "$rollback" 'confirmedRollbackBundleSha256' "confirmed rollback bundle hash attestation"
require_contains "$rollback" '.deployedRollbackBundleSha256 == .confirmedRollbackBundleSha256' "rollback bundle hash equality assertion"
require_contains "$rollback" 'Build rollback attestation' "rollback attestation"
require_contains "$rollback" 'whatsapp-webhook-rollback-attestation.json' "rollback attestation artifact"
require_contains "$rollback" 'Fail if access credential leaked into rollback evidence' "rollback credential evidence scan"
require_contains "$rollback" 'Upload verified rollback evidence' "required rollback evidence upload"
require_contains "$rollback" 'Run v167-compatible non-customer rollback smoke checks' "v167-compatible rollback smoke step"
require_contains "$rollback" 'test "$challenge_code" = "403"' "v167 rollback invalid challenge status"
require_contains "$rollback" 'test "$post_code" = "401"' "v167 rollback unauthenticated POST status"
require_contains "$rollback" 'test "$options_code" = "200"' "v167 rollback OPTIONS status"
reject_regex "$rollback" 'verify_token_invalid|signature_missing|Unexpected browser CORS header after webhook rollback' "forward-only hardened response semantics in v167 rollback smoke"

require_order "$rollback" \
  "rollback request identity" "Validate rollback request identity and current main" \
  "source release verification" "Verify source release run and resolve rollback artifact" \
  "immutable rollback package validation" "Download and validate immutable rollback package" \
  "expected rollback source manifest" "Build expected rollback source manifest" \
  "preflight live state validation" "Verify exact live state to be rolled back" \
  "rollback preflight attestation" "Build rollback preflight attestation" \
  "normalized rollback package upload" "Upload normalized rollback package" \
  "rollback package/live-state revalidation" "Revalidate rollback package and exact current live state" \
  "final rollback live-state recheck" "Recheck unchanged current main and live state immediately before rollback" \
  "named rollback deploy" "Execute named rollback only" \
  "rollback metadata verification" "Verify rollback deployment metadata" \
  "rollback bundle metadata confirmation" "Confirm stable rollback bundle metadata" \
  "restored source closure verification" "Verify restored source closure" \
  "rollback compatibility probes" "Run v167-compatible non-customer rollback smoke checks" \
  "rollback attestation" "Build rollback attestation" \
  "rollback credential evidence scan" "Fail if access credential leaked into rollback evidence" \
  "verified rollback evidence upload" "Upload verified rollback evidence"

require_contains "$ownership" "Governed release plan:" "ownership release plan"
require_contains "$ownership" "whatsapp-webhook-production-release.yml" "ownership forward release workflow"
require_contains "$ownership" "whatsapp-webhook-production-rollback.yml" "ownership rollback workflow"

bash -n "$manifest_test"
python3 -m py_compile "$manifest"

echo "WhatsApp webhook production release governance passed."
 "production mutation environment gate"
  else
    require_job_regex "$workflow" "rollback" '^    environment: supabase-production  require_contains "$workflow" "persist-credentials: false" "checkout credential hardening"
  require_contains "$workflow" "SUPABASE_PROJECT_REF: tcxvcatsqqertcnycuop" "canonical production project binding"
  require_contains "$workflow" "FUNCTION_NAME: whatsapp-webhook" "named function binding"
  require_contains "$workflow" "SUPABASE_CLI_VERSION: 2.117.0" "pinned Supabase CLI"

  reject_regex "$workflow" 'SUPABASE_DB_URL|supabase[[:space:]]+db[[:space:]]+(push|reset|query)|supabase[[:space:]]+migration[[:space:]]+(up|repair)|supabase[[:space:]]+secrets[[:space:]]+(set|unset)' "database or secret mutation authority"
  reject_regex "$workflow" 'supabase[[:space:]]+functions[[:space:]]+deploy[[:space:]]+[$"{]' "variable Edge deploy target"
  reject_regex "$workflow" 'uses:[[:space:]]+actions/(checkout|upload-artifact|download-artifact)@v[0-9]+' "unpinned first-party action"

  broad_count="$(grep -Ec 'supabase[[:space:]]+functions[[:space:]]+deploy([[:space:]]|$)' "$workflow" || true)"
  named_count="$(grep -Ec 'supabase[[:space:]]+functions[[:space:]]+deploy[[:space:]]+whatsapp-webhook([[:space:]]|$)' "$workflow" || true)"
  [[ "$broad_count" -eq 1 && "$named_count" -eq 1 ]] || fail "every deploy in $workflow must be exactly one literal whatsapp-webhook deploy"

  require_contains "$workflow" 'test "${GITHUB_REF}" = "refs/heads/main"' "protected branch check"
  require_contains "$workflow" 'git fetch --quiet origin refs/heads/main:refs/remotes/origin/main' "current-main fetch"
  require_contains "$workflow" 'test "$(git rev-parse refs/remotes/origin/main)" = "$GITHUB_SHA"' "current-main equality check"
  require_contains "$workflow" 'WHATSAPP_WEBHOOK_VERIFY_TOKEN' "verify-token secret-name readiness"
  require_contains "$workflow" 'CLICK2API_API_KEY' "Click2API secret-name readiness"
  require_contains "$workflow" '${{ github.run_attempt }}' "retry-safe evidence naming"
  require_contains "$workflow" 'if-no-files-found: error' "required artifact failure policy"
done

# Forward release baseline, provenance, source attestation, rollback capture and final evidence.
require_contains "$release" 'EXPECTED_LIVE_VERSION: "167"' "known live version baseline"
require_contains "$release" 'EXPECTED_LIVE_BUNDLE_SHA: 8ae1f251335fe0b9fac952ec3444e858a313f2fe6d34f64cb561ca55d93c3426' "known live bundle baseline"
require_contains "$release" 'DB_PREREQ_RUN_ID: "36335058964"' "database prerequisite run binding"
require_contains "$release" 'DB_PREREQ_SHA: f3366a4a99b57e20ec47a4f152af3a7b3661f5c6' "database prerequisite SHA binding"
require_contains "$release" 'supabase functions download whatsapp-webhook' "live source download"
require_contains "$release" '--use-api' "API-based source unbundling"
require_contains "$release" 'target-source-manifest.json' "reviewed source manifest"
require_contains "$release" 'live-source-manifest.json' "deployed source manifest"
require_regex "$release" 'diff -u[[:space:]\\]*[[:space:]]*target-source-manifest.json[[:space:]\\]*[[:space:]]*live-source-manifest.json' "reviewed/live source equality"
require_contains "$release" 'whatsapp-webhook-predeploy-v167.tar.gz' "rollback source archive"
require_contains "$release" 'ROLLBACK_ARCHIVE_SHA256' "rollback archive integrity binding"
require_contains "$release" 'Build successful release attestation' "successful release attestation"
require_contains "$release" 'whatsapp-webhook-release-attestation.json' "release attestation artifact"
require_contains "$release" 'Fail if access credentials leaked into text evidence' "post-deploy credential evidence scan"
require_contains "$release" 'Upload required verified release evidence' "required verified release upload"
require_contains "$release" 'Unexpected browser CORS header' "hardened no-browser-CORS runtime probe"
require_contains "$release" '.error == "verify_token_invalid"' "hardened invalid challenge semantic assertion"
require_contains "$release" '.error == "signature_missing"' "hardened missing signature semantic assertion"
require_contains "$release" 'test "$challenge_code" = "403"' "hardened invalid challenge status"
require_contains "$release" 'test "$post_code" = "401"' "hardened unauthenticated POST status"
require_contains "$release" 'test "$options_code" = "204"' "hardened OPTIONS status"

require_order "$release" \
  "rollback capture" "Capture restorable live source with pinned Supabase CLI" \
  "post-capture live recheck" "Recheck live baseline after rollback capture" \
  "rollback evidence validation" "Require complete rollback evidence before deployment" \
  "rollback evidence upload" "Upload immutable rollback evidence before deployment" \
  "final current-main/live recheck" "Recheck unchanged current main and live baseline immediately before deployment" \
  "named production deploy" "Deploy exact named function only" \
  "deployed metadata verification" "Verify deployed function metadata" \
  "deployed source closure verification" "Verify deployed source closure matches reviewed source" \
  "runtime authentication probes" "Run non-customer authentication and header smoke checks" \
  "release attestation" "Build successful release attestation" \
  "credential evidence scan" "Fail if access credentials leaked into text evidence" \
  "verified evidence upload" "Upload required verified release evidence"

# Rollback must be bound to the originating release evidence and exact current live state.
require_contains "$rollback" 'ROLLBACK_TO_VERSION: "167"' "rollback target version"
require_contains "$rollback" 'ROLLBACK_TO_BUNDLE_SHA: 8ae1f251335fe0b9fac952ec3444e858a313f2fe6d34f64cb561ca55d93c3426' "rollback target bundle baseline"
require_contains "$rollback" 'source_run_id:' "source release run input"
require_contains "$rollback" 'source_run_attempt:' "source release attempt input"
require_contains "$rollback" 'source_release_sha:' "source release SHA input"
require_contains "$rollback" 'expected_current_version:' "current live version input"
require_contains "$rollback" 'expected_current_bundle_sha:' "current live bundle input"
require_contains "$rollback" '.path == ".github/workflows/whatsapp-webhook-production-release.yml"' "forward workflow identity binding"
require_contains "$rollback" '.status == "completed"' "completed forward-run requirement"
require_contains "$rollback" '.run_attempt == $expected_attempt' "forward run-attempt binding"
require_contains "$rollback" 'artifact_name_encoded="$(jq -rn --arg value "$artifact_name" '\''$value | @uri'\'')"' "URL-encoded rollback artifact name"
require_contains "$rollback" '$api/artifacts?name=$artifact_name_encoded&per_page=100' "server-side rollback artifact name filter"
require_contains "$rollback" 'expected-rollback-source-manifest.json' "expected rollback source manifest"
require_contains "$rollback" 'live-rollback-source-manifest.json' "live rollback source manifest"
require_regex "$rollback" 'diff -u[[:space:]\\]*[[:space:]]*rollback-evidence/expected-rollback-source-manifest.json[[:space:]\\]*[[:space:]]*live-rollback-source-manifest.json' "rollback/live source equality"
require_contains "$rollback" 'Build rollback attestation' "rollback attestation"
require_contains "$rollback" 'whatsapp-webhook-rollback-attestation.json' "rollback attestation artifact"
require_contains "$rollback" 'Fail if access credential leaked into rollback evidence' "rollback credential evidence scan"
require_contains "$rollback" 'Upload verified rollback evidence' "required rollback evidence upload"
require_contains "$rollback" 'Run v167-compatible non-customer rollback smoke checks' "v167-compatible rollback smoke step"
require_contains "$rollback" 'test "$challenge_code" = "403"' "v167 rollback invalid challenge status"
require_contains "$rollback" 'test "$post_code" = "401"' "v167 rollback unauthenticated POST status"
require_contains "$rollback" 'test "$options_code" = "200"' "v167 rollback OPTIONS status"
reject_regex "$rollback" 'verify_token_invalid|signature_missing|Unexpected browser CORS header after webhook rollback' "forward-only hardened response semantics in v167 rollback smoke"

require_order "$rollback" \
  "rollback request identity" "Validate rollback request identity and current main" \
  "source release verification" "Verify source release run and resolve rollback artifact" \
  "immutable rollback package validation" "Download and validate immutable rollback package" \
  "expected rollback source manifest" "Build expected rollback source manifest" \
  "preflight live state validation" "Verify exact live state to be rolled back" \
  "rollback preflight attestation" "Build rollback preflight attestation" \
  "normalized rollback package upload" "Upload normalized rollback package" \
  "rollback package/live-state revalidation" "Revalidate rollback package and exact current live state" \
  "final rollback live-state recheck" "Recheck unchanged current main and live state immediately before rollback" \
  "named rollback deploy" "Execute named rollback only" \
  "rollback metadata verification" "Verify rollback deployment metadata" \
  "restored source closure verification" "Verify restored source closure" \
  "rollback compatibility probes" "Run v167-compatible non-customer rollback smoke checks" \
  "rollback attestation" "Build rollback attestation" \
  "rollback credential evidence scan" "Fail if access credential leaked into rollback evidence" \
  "verified rollback evidence upload" "Upload verified rollback evidence"

require_contains "$ownership" "Governed release plan:" "ownership release plan"
require_contains "$ownership" "whatsapp-webhook-production-release.yml" "ownership forward release workflow"
require_contains "$ownership" "whatsapp-webhook-production-rollback.yml" "ownership rollback workflow"

bash -n "$manifest_test"
python3 -m py_compile "$manifest"

echo "WhatsApp webhook production release governance passed."
 "production mutation environment gate"
  fi
  require_contains "$workflow" "persist-credentials: false" "checkout credential hardening"
  require_contains "$workflow" "SUPABASE_PROJECT_REF: tcxvcatsqqertcnycuop" "canonical production project binding"
  require_contains "$workflow" "FUNCTION_NAME: whatsapp-webhook" "named function binding"
  require_contains "$workflow" "SUPABASE_CLI_VERSION: 2.117.0" "pinned Supabase CLI"

  reject_regex "$workflow" 'SUPABASE_DB_URL|supabase[[:space:]]+db[[:space:]]+(push|reset|query)|supabase[[:space:]]+migration[[:space:]]+(up|repair)|supabase[[:space:]]+secrets[[:space:]]+(set|unset)' "database or secret mutation authority"
  reject_regex "$workflow" 'supabase[[:space:]]+functions[[:space:]]+deploy[[:space:]]+[$"{]' "variable Edge deploy target"
  reject_regex "$workflow" 'uses:[[:space:]]+actions/(checkout|upload-artifact|download-artifact)@v[0-9]+' "unpinned first-party action"

  broad_count="$(grep -Ec 'supabase[[:space:]]+functions[[:space:]]+deploy([[:space:]]|$)' "$workflow" || true)"
  named_count="$(grep -Ec 'supabase[[:space:]]+functions[[:space:]]+deploy[[:space:]]+whatsapp-webhook([[:space:]]|$)' "$workflow" || true)"
  [[ "$broad_count" -eq 1 && "$named_count" -eq 1 ]] || fail "every deploy in $workflow must be exactly one literal whatsapp-webhook deploy"

  require_contains "$workflow" 'test "${GITHUB_REF}" = "refs/heads/main"' "protected branch check"
  require_contains "$workflow" 'git fetch --quiet origin refs/heads/main:refs/remotes/origin/main' "current-main fetch"
  require_contains "$workflow" 'test "$(git rev-parse refs/remotes/origin/main)" = "$GITHUB_SHA"' "current-main equality check"
  require_contains "$workflow" 'WHATSAPP_WEBHOOK_VERIFY_TOKEN' "verify-token secret-name readiness"
  require_contains "$workflow" 'CLICK2API_API_KEY' "Click2API secret-name readiness"
  require_contains "$workflow" '${{ github.run_attempt }}' "retry-safe evidence naming"
  require_contains "$workflow" 'if-no-files-found: error' "required artifact failure policy"
done

# Forward release baseline, provenance, source attestation, rollback capture and final evidence.
require_contains "$release" 'EXPECTED_LIVE_VERSION: "167"' "known live version baseline"
require_contains "$release" 'EXPECTED_LIVE_BUNDLE_SHA: 8ae1f251335fe0b9fac952ec3444e858a313f2fe6d34f64cb561ca55d93c3426' "known live bundle baseline"
require_contains "$release" 'DB_PREREQ_RUN_ID: "36335058964"' "database prerequisite run binding"
require_contains "$release" 'DB_PREREQ_SHA: f3366a4a99b57e20ec47a4f152af3a7b3661f5c6' "database prerequisite SHA binding"
require_contains "$release" 'supabase functions download whatsapp-webhook' "live source download"
require_contains "$release" '--use-api' "API-based source unbundling"
require_contains "$release" 'target-source-manifest.json' "reviewed source manifest"
require_contains "$release" 'live-source-manifest.json' "deployed source manifest"
require_regex "$release" 'diff -u[[:space:]\\]*[[:space:]]*target-source-manifest.json[[:space:]\\]*[[:space:]]*live-source-manifest.json' "reviewed/live source equality"
require_contains "$release" 'whatsapp-webhook-predeploy-v167.tar.gz' "rollback source archive"
require_contains "$release" 'ROLLBACK_ARCHIVE_SHA256' "rollback archive integrity binding"
require_contains "$release" 'Build successful release attestation' "successful release attestation"
require_contains "$release" 'whatsapp-webhook-release-attestation.json' "release attestation artifact"
require_contains "$release" 'Fail if access credentials leaked into text evidence' "post-deploy credential evidence scan"
require_contains "$release" 'Upload required verified release evidence' "required verified release upload"
require_contains "$release" 'Unexpected browser CORS header' "hardened no-browser-CORS runtime probe"
require_contains "$release" '.error == "verify_token_invalid"' "hardened invalid challenge semantic assertion"
require_contains "$release" '.error == "signature_missing"' "hardened missing signature semantic assertion"
require_contains "$release" 'test "$challenge_code" = "403"' "hardened invalid challenge status"
require_contains "$release" 'test "$post_code" = "401"' "hardened unauthenticated POST status"
require_contains "$release" 'test "$options_code" = "204"' "hardened OPTIONS status"

require_order "$release" \
  "rollback capture" "Capture restorable live source with pinned Supabase CLI" \
  "post-capture live recheck" "Recheck live baseline after rollback capture" \
  "rollback evidence validation" "Require complete rollback evidence before deployment" \
  "rollback evidence upload" "Upload immutable rollback evidence before deployment" \
  "final current-main/live recheck" "Recheck unchanged current main and live baseline immediately before deployment" \
  "named production deploy" "Deploy exact named function only" \
  "deployed metadata verification" "Verify deployed function metadata" \
  "deployed source closure verification" "Verify deployed source closure matches reviewed source" \
  "runtime authentication probes" "Run non-customer authentication and header smoke checks" \
  "release attestation" "Build successful release attestation" \
  "credential evidence scan" "Fail if access credentials leaked into text evidence" \
  "verified evidence upload" "Upload required verified release evidence"

# Rollback must be bound to the originating release evidence and exact current live state.
require_contains "$rollback" 'ROLLBACK_TO_VERSION: "167"' "rollback target version"
require_contains "$rollback" 'ROLLBACK_TO_BUNDLE_SHA: 8ae1f251335fe0b9fac952ec3444e858a313f2fe6d34f64cb561ca55d93c3426' "rollback target bundle baseline"
require_contains "$rollback" 'source_run_id:' "source release run input"
require_contains "$rollback" 'source_run_attempt:' "source release attempt input"
require_contains "$rollback" 'source_release_sha:' "source release SHA input"
require_contains "$rollback" 'expected_current_version:' "current live version input"
require_contains "$rollback" 'expected_current_bundle_sha:' "current live bundle input"
require_contains "$rollback" '.path == ".github/workflows/whatsapp-webhook-production-release.yml"' "forward workflow identity binding"
require_contains "$rollback" '.status == "completed"' "completed forward-run requirement"
require_contains "$rollback" '.run_attempt == $expected_attempt' "forward run-attempt binding"
require_contains "$rollback" 'artifact_name_encoded="$(jq -rn --arg value "$artifact_name" '\''$value | @uri'\'')"' "URL-encoded rollback artifact name"
require_contains "$rollback" '$api/artifacts?name=$artifact_name_encoded&per_page=100' "server-side rollback artifact name filter"
require_contains "$rollback" 'expected-rollback-source-manifest.json' "expected rollback source manifest"
require_contains "$rollback" 'live-rollback-source-manifest.json' "live rollback source manifest"
require_regex "$rollback" 'diff -u[[:space:]\\]*[[:space:]]*rollback-evidence/expected-rollback-source-manifest.json[[:space:]\\]*[[:space:]]*live-rollback-source-manifest.json' "rollback/live source equality"
require_contains "$rollback" 'Build rollback attestation' "rollback attestation"
require_contains "$rollback" 'whatsapp-webhook-rollback-attestation.json' "rollback attestation artifact"
require_contains "$rollback" 'Fail if access credential leaked into rollback evidence' "rollback credential evidence scan"
require_contains "$rollback" 'Upload verified rollback evidence' "required rollback evidence upload"
require_contains "$rollback" 'Run v167-compatible non-customer rollback smoke checks' "v167-compatible rollback smoke step"
require_contains "$rollback" 'test "$challenge_code" = "403"' "v167 rollback invalid challenge status"
require_contains "$rollback" 'test "$post_code" = "401"' "v167 rollback unauthenticated POST status"
require_contains "$rollback" 'test "$options_code" = "200"' "v167 rollback OPTIONS status"
reject_regex "$rollback" 'verify_token_invalid|signature_missing|Unexpected browser CORS header after webhook rollback' "forward-only hardened response semantics in v167 rollback smoke"

require_order "$rollback" \
  "rollback request identity" "Validate rollback request identity and current main" \
  "source release verification" "Verify source release run and resolve rollback artifact" \
  "immutable rollback package validation" "Download and validate immutable rollback package" \
  "expected rollback source manifest" "Build expected rollback source manifest" \
  "preflight live state validation" "Verify exact live state to be rolled back" \
  "rollback preflight attestation" "Build rollback preflight attestation" \
  "normalized rollback package upload" "Upload normalized rollback package" \
  "rollback package/live-state revalidation" "Revalidate rollback package and exact current live state" \
  "final rollback live-state recheck" "Recheck unchanged current main and live state immediately before rollback" \
  "named rollback deploy" "Execute named rollback only" \
  "rollback metadata verification" "Verify rollback deployment metadata" \
  "restored source closure verification" "Verify restored source closure" \
  "rollback compatibility probes" "Run v167-compatible non-customer rollback smoke checks" \
  "rollback attestation" "Build rollback attestation" \
  "rollback credential evidence scan" "Fail if access credential leaked into rollback evidence" \
  "verified rollback evidence upload" "Upload verified rollback evidence"

require_contains "$ownership" "Governed release plan:" "ownership release plan"
require_contains "$ownership" "whatsapp-webhook-production-release.yml" "ownership forward release workflow"
require_contains "$ownership" "whatsapp-webhook-production-rollback.yml" "ownership rollback workflow"

bash -n "$manifest_test"
python3 -m py_compile "$manifest"

echo "WhatsApp webhook production release governance passed."
 "production mutation environment gate"
  fi
  require_contains "$workflow" "persist-credentials: false" "checkout credential hardening"
  require_contains "$workflow" "SUPABASE_PROJECT_REF: tcxvcatsqqertcnycuop" "canonical production project binding"
  require_contains "$workflow" "FUNCTION_NAME: whatsapp-webhook" "named function binding"
  require_contains "$workflow" "SUPABASE_CLI_VERSION: 2.117.0" "pinned Supabase CLI"

  reject_regex "$workflow" 'SUPABASE_DB_URL|supabase[[:space:]]+db[[:space:]]+(push|reset|query)|supabase[[:space:]]+migration[[:space:]]+(up|repair)|supabase[[:space:]]+secrets[[:space:]]+(set|unset)' "database or secret mutation authority"
  reject_regex "$workflow" 'supabase[[:space:]]+functions[[:space:]]+deploy[[:space:]]+[$"{]' "variable Edge deploy target"
  reject_regex "$workflow" 'uses:[[:space:]]+actions/(checkout|upload-artifact|download-artifact)@v[0-9]+' "unpinned first-party action"

  broad_count="$(grep -Ec 'supabase[[:space:]]+functions[[:space:]]+deploy([[:space:]]|$)' "$workflow" || true)"
  named_count="$(grep -Ec 'supabase[[:space:]]+functions[[:space:]]+deploy[[:space:]]+whatsapp-webhook([[:space:]]|$)' "$workflow" || true)"
  [[ "$broad_count" -eq 1 && "$named_count" -eq 1 ]] || fail "every deploy in $workflow must be exactly one literal whatsapp-webhook deploy"

  require_contains "$workflow" 'test "${GITHUB_REF}" = "refs/heads/main"' "protected branch check"
  require_contains "$workflow" 'git fetch --quiet origin refs/heads/main:refs/remotes/origin/main' "current-main fetch"
  require_contains "$workflow" 'test "$(git rev-parse refs/remotes/origin/main)" = "$GITHUB_SHA"' "current-main equality check"
  require_contains "$workflow" 'WHATSAPP_WEBHOOK_VERIFY_TOKEN' "verify-token secret-name readiness"
  require_contains "$workflow" 'CLICK2API_API_KEY' "Click2API secret-name readiness"
  require_contains "$workflow" '${{ github.run_attempt }}' "retry-safe evidence naming"
  require_contains "$workflow" 'if-no-files-found: error' "required artifact failure policy"
done

# Forward release baseline, provenance, source attestation, rollback capture and final evidence.
require_contains "$release" 'EXPECTED_LIVE_VERSION: "167"' "known live version baseline"
require_contains "$release" 'EXPECTED_LIVE_BUNDLE_SHA: 8ae1f251335fe0b9fac952ec3444e858a313f2fe6d34f64cb561ca55d93c3426' "known live bundle baseline"
require_contains "$release" 'DB_PREREQ_RUN_ID: "36335058964"' "database prerequisite run binding"
require_contains "$release" 'DB_PREREQ_SHA: f3366a4a99b57e20ec47a4f152af3a7b3661f5c6' "database prerequisite SHA binding"
require_contains "$release" 'supabase functions download whatsapp-webhook' "live source download"
require_contains "$release" '--use-api' "API-based source unbundling"
require_contains "$release" 'target-source-manifest.json' "reviewed source manifest"
require_contains "$release" 'live-source-manifest.json' "deployed source manifest"
require_regex "$release" 'diff -u[[:space:]\\]*[[:space:]]*target-source-manifest.json[[:space:]\\]*[[:space:]]*live-source-manifest.json' "reviewed/live source equality"
require_contains "$release" 'whatsapp-webhook-predeploy-v167.tar.gz' "rollback source archive"
require_contains "$release" 'ROLLBACK_ARCHIVE_SHA256' "rollback archive integrity binding"
require_contains "$release" 'Build successful release attestation' "successful release attestation"
require_contains "$release" 'whatsapp-webhook-release-attestation.json' "release attestation artifact"
require_contains "$release" 'Fail if access credentials leaked into text evidence' "post-deploy credential evidence scan"
require_contains "$release" 'Upload required verified release evidence' "required verified release upload"
require_contains "$release" 'Unexpected browser CORS header' "hardened no-browser-CORS runtime probe"
require_contains "$release" '.error == "verify_token_invalid"' "hardened invalid challenge semantic assertion"
require_contains "$release" '.error == "signature_missing"' "hardened missing signature semantic assertion"
require_contains "$release" 'test "$challenge_code" = "403"' "hardened invalid challenge status"
require_contains "$release" 'test "$post_code" = "401"' "hardened unauthenticated POST status"
require_contains "$release" 'test "$options_code" = "204"' "hardened OPTIONS status"

require_order "$release" \
  "rollback capture" "Capture restorable live source with pinned Supabase CLI" \
  "post-capture live recheck" "Recheck live baseline after rollback capture" \
  "rollback evidence validation" "Require complete rollback evidence before deployment" \
  "rollback evidence upload" "Upload immutable rollback evidence before deployment" \
  "final current-main/live recheck" "Recheck unchanged current main and live baseline immediately before deployment" \
  "named production deploy" "Deploy exact named function only" \
  "deployed metadata verification" "Verify deployed function metadata" \
  "deployed source closure verification" "Verify deployed source closure matches reviewed source" \
  "runtime authentication probes" "Run non-customer authentication and header smoke checks" \
  "release attestation" "Build successful release attestation" \
  "credential evidence scan" "Fail if access credentials leaked into text evidence" \
  "verified evidence upload" "Upload required verified release evidence"

# Rollback must be bound to the originating release evidence and exact current live state.
require_contains "$rollback" 'ROLLBACK_TO_VERSION: "167"' "rollback target version"
require_contains "$rollback" 'ROLLBACK_TO_BUNDLE_SHA: 8ae1f251335fe0b9fac952ec3444e858a313f2fe6d34f64cb561ca55d93c3426' "rollback target bundle baseline"
require_contains "$rollback" 'source_run_id:' "source release run input"
require_contains "$rollback" 'source_run_attempt:' "source release attempt input"
require_contains "$rollback" 'source_release_sha:' "source release SHA input"
require_contains "$rollback" 'expected_current_version:' "current live version input"
require_contains "$rollback" 'expected_current_bundle_sha:' "current live bundle input"
require_contains "$rollback" '.path == ".github/workflows/whatsapp-webhook-production-release.yml"' "forward workflow identity binding"
require_contains "$rollback" '.status == "completed"' "completed forward-run requirement"
require_contains "$rollback" '.run_attempt == $expected_attempt' "forward run-attempt binding"
require_contains "$rollback" 'artifact_name_encoded="$(jq -rn --arg value "$artifact_name" '\''$value | @uri'\'')"' "URL-encoded rollback artifact name"
require_contains "$rollback" '$api/artifacts?name=$artifact_name_encoded&per_page=100' "server-side rollback artifact name filter"
require_contains "$rollback" 'expected-rollback-source-manifest.json' "expected rollback source manifest"
require_contains "$rollback" 'live-rollback-source-manifest.json' "live rollback source manifest"
require_regex "$rollback" 'diff -u[[:space:]\\]*[[:space:]]*rollback-evidence/expected-rollback-source-manifest.json[[:space:]\\]*[[:space:]]*live-rollback-source-manifest.json' "rollback/live source equality"
require_contains "$rollback" 'Confirm stable rollback bundle metadata' "stable rollback bundle metadata confirmation"
require_contains "$rollback" 'deployedRollbackBundleSha256' "deployed rollback bundle hash attestation"
require_contains "$rollback" 'confirmedRollbackBundleSha256' "confirmed rollback bundle hash attestation"
require_contains "$rollback" '.deployedRollbackBundleSha256 == .confirmedRollbackBundleSha256' "rollback bundle hash equality assertion"
require_contains "$rollback" 'Build rollback attestation' "rollback attestation"
require_contains "$rollback" 'whatsapp-webhook-rollback-attestation.json' "rollback attestation artifact"
require_contains "$rollback" 'Fail if access credential leaked into rollback evidence' "rollback credential evidence scan"
require_contains "$rollback" 'Upload verified rollback evidence' "required rollback evidence upload"
require_contains "$rollback" 'Run v167-compatible non-customer rollback smoke checks' "v167-compatible rollback smoke step"
require_contains "$rollback" 'test "$challenge_code" = "403"' "v167 rollback invalid challenge status"
require_contains "$rollback" 'test "$post_code" = "401"' "v167 rollback unauthenticated POST status"
require_contains "$rollback" 'test "$options_code" = "200"' "v167 rollback OPTIONS status"
reject_regex "$rollback" 'verify_token_invalid|signature_missing|Unexpected browser CORS header after webhook rollback' "forward-only hardened response semantics in v167 rollback smoke"

require_order "$rollback" \
  "rollback request identity" "Validate rollback request identity and current main" \
  "source release verification" "Verify source release run and resolve rollback artifact" \
  "immutable rollback package validation" "Download and validate immutable rollback package" \
  "expected rollback source manifest" "Build expected rollback source manifest" \
  "preflight live state validation" "Verify exact live state to be rolled back" \
  "rollback preflight attestation" "Build rollback preflight attestation" \
  "normalized rollback package upload" "Upload normalized rollback package" \
  "rollback package/live-state revalidation" "Revalidate rollback package and exact current live state" \
  "final rollback live-state recheck" "Recheck unchanged current main and live state immediately before rollback" \
  "named rollback deploy" "Execute named rollback only" \
  "rollback metadata verification" "Verify rollback deployment metadata" \
  "rollback bundle metadata confirmation" "Confirm stable rollback bundle metadata" \
  "restored source closure verification" "Verify restored source closure" \
  "rollback compatibility probes" "Run v167-compatible non-customer rollback smoke checks" \
  "rollback attestation" "Build rollback attestation" \
  "rollback credential evidence scan" "Fail if access credential leaked into rollback evidence" \
  "verified rollback evidence upload" "Upload verified rollback evidence"

require_contains "$ownership" "Governed release plan:" "ownership release plan"
require_contains "$ownership" "whatsapp-webhook-production-release.yml" "ownership forward release workflow"
require_contains "$ownership" "whatsapp-webhook-production-rollback.yml" "ownership rollback workflow"

bash -n "$manifest_test"
python3 -m py_compile "$manifest"

echo "WhatsApp webhook production release governance passed."
 "production mutation environment gate"
  else
    require_job_regex "$workflow" "rollback" '^    environment: supabase-production  require_contains "$workflow" "persist-credentials: false" "checkout credential hardening"
  require_contains "$workflow" "SUPABASE_PROJECT_REF: tcxvcatsqqertcnycuop" "canonical production project binding"
  require_contains "$workflow" "FUNCTION_NAME: whatsapp-webhook" "named function binding"
  require_contains "$workflow" "SUPABASE_CLI_VERSION: 2.117.0" "pinned Supabase CLI"

  reject_regex "$workflow" 'SUPABASE_DB_URL|supabase[[:space:]]+db[[:space:]]+(push|reset|query)|supabase[[:space:]]+migration[[:space:]]+(up|repair)|supabase[[:space:]]+secrets[[:space:]]+(set|unset)' "database or secret mutation authority"
  reject_regex "$workflow" 'supabase[[:space:]]+functions[[:space:]]+deploy[[:space:]]+[$"{]' "variable Edge deploy target"
  reject_regex "$workflow" 'uses:[[:space:]]+actions/(checkout|upload-artifact|download-artifact)@v[0-9]+' "unpinned first-party action"

  broad_count="$(grep -Ec 'supabase[[:space:]]+functions[[:space:]]+deploy([[:space:]]|$)' "$workflow" || true)"
  named_count="$(grep -Ec 'supabase[[:space:]]+functions[[:space:]]+deploy[[:space:]]+whatsapp-webhook([[:space:]]|$)' "$workflow" || true)"
  [[ "$broad_count" -eq 1 && "$named_count" -eq 1 ]] || fail "every deploy in $workflow must be exactly one literal whatsapp-webhook deploy"

  require_contains "$workflow" 'test "${GITHUB_REF}" = "refs/heads/main"' "protected branch check"
  require_contains "$workflow" 'git fetch --quiet origin refs/heads/main:refs/remotes/origin/main' "current-main fetch"
  require_contains "$workflow" 'test "$(git rev-parse refs/remotes/origin/main)" = "$GITHUB_SHA"' "current-main equality check"
  require_contains "$workflow" 'WHATSAPP_WEBHOOK_VERIFY_TOKEN' "verify-token secret-name readiness"
  require_contains "$workflow" 'CLICK2API_API_KEY' "Click2API secret-name readiness"
  require_contains "$workflow" '${{ github.run_attempt }}' "retry-safe evidence naming"
  require_contains "$workflow" 'if-no-files-found: error' "required artifact failure policy"
done

# Forward release baseline, provenance, source attestation, rollback capture and final evidence.
require_contains "$release" 'EXPECTED_LIVE_VERSION: "167"' "known live version baseline"
require_contains "$release" 'EXPECTED_LIVE_BUNDLE_SHA: 8ae1f251335fe0b9fac952ec3444e858a313f2fe6d34f64cb561ca55d93c3426' "known live bundle baseline"
require_contains "$release" 'DB_PREREQ_RUN_ID: "36335058964"' "database prerequisite run binding"
require_contains "$release" 'DB_PREREQ_SHA: f3366a4a99b57e20ec47a4f152af3a7b3661f5c6' "database prerequisite SHA binding"
require_contains "$release" 'supabase functions download whatsapp-webhook' "live source download"
require_contains "$release" '--use-api' "API-based source unbundling"
require_contains "$release" 'target-source-manifest.json' "reviewed source manifest"
require_contains "$release" 'live-source-manifest.json' "deployed source manifest"
require_regex "$release" 'diff -u[[:space:]\\]*[[:space:]]*target-source-manifest.json[[:space:]\\]*[[:space:]]*live-source-manifest.json' "reviewed/live source equality"
require_contains "$release" 'whatsapp-webhook-predeploy-v167.tar.gz' "rollback source archive"
require_contains "$release" 'ROLLBACK_ARCHIVE_SHA256' "rollback archive integrity binding"
require_contains "$release" 'Build successful release attestation' "successful release attestation"
require_contains "$release" 'whatsapp-webhook-release-attestation.json' "release attestation artifact"
require_contains "$release" 'Fail if access credentials leaked into text evidence' "post-deploy credential evidence scan"
require_contains "$release" 'Upload required verified release evidence' "required verified release upload"
require_contains "$release" 'Unexpected browser CORS header' "hardened no-browser-CORS runtime probe"
require_contains "$release" '.error == "verify_token_invalid"' "hardened invalid challenge semantic assertion"
require_contains "$release" '.error == "signature_missing"' "hardened missing signature semantic assertion"
require_contains "$release" 'test "$challenge_code" = "403"' "hardened invalid challenge status"
require_contains "$release" 'test "$post_code" = "401"' "hardened unauthenticated POST status"
require_contains "$release" 'test "$options_code" = "204"' "hardened OPTIONS status"

require_order "$release" \
  "rollback capture" "Capture restorable live source with pinned Supabase CLI" \
  "post-capture live recheck" "Recheck live baseline after rollback capture" \
  "rollback evidence validation" "Require complete rollback evidence before deployment" \
  "rollback evidence upload" "Upload immutable rollback evidence before deployment" \
  "final current-main/live recheck" "Recheck unchanged current main and live baseline immediately before deployment" \
  "named production deploy" "Deploy exact named function only" \
  "deployed metadata verification" "Verify deployed function metadata" \
  "deployed source closure verification" "Verify deployed source closure matches reviewed source" \
  "runtime authentication probes" "Run non-customer authentication and header smoke checks" \
  "release attestation" "Build successful release attestation" \
  "credential evidence scan" "Fail if access credentials leaked into text evidence" \
  "verified evidence upload" "Upload required verified release evidence"

# Rollback must be bound to the originating release evidence and exact current live state.
require_contains "$rollback" 'ROLLBACK_TO_VERSION: "167"' "rollback target version"
require_contains "$rollback" 'ROLLBACK_TO_BUNDLE_SHA: 8ae1f251335fe0b9fac952ec3444e858a313f2fe6d34f64cb561ca55d93c3426' "rollback target bundle baseline"
require_contains "$rollback" 'source_run_id:' "source release run input"
require_contains "$rollback" 'source_run_attempt:' "source release attempt input"
require_contains "$rollback" 'source_release_sha:' "source release SHA input"
require_contains "$rollback" 'expected_current_version:' "current live version input"
require_contains "$rollback" 'expected_current_bundle_sha:' "current live bundle input"
require_contains "$rollback" '.path == ".github/workflows/whatsapp-webhook-production-release.yml"' "forward workflow identity binding"
require_contains "$rollback" '.status == "completed"' "completed forward-run requirement"
require_contains "$rollback" '.run_attempt == $expected_attempt' "forward run-attempt binding"
require_contains "$rollback" 'artifact_name_encoded="$(jq -rn --arg value "$artifact_name" '\''$value | @uri'\'')"' "URL-encoded rollback artifact name"
require_contains "$rollback" '$api/artifacts?name=$artifact_name_encoded&per_page=100' "server-side rollback artifact name filter"
require_contains "$rollback" 'expected-rollback-source-manifest.json' "expected rollback source manifest"
require_contains "$rollback" 'live-rollback-source-manifest.json' "live rollback source manifest"
require_regex "$rollback" 'diff -u[[:space:]\\]*[[:space:]]*rollback-evidence/expected-rollback-source-manifest.json[[:space:]\\]*[[:space:]]*live-rollback-source-manifest.json' "rollback/live source equality"
require_contains "$rollback" 'Build rollback attestation' "rollback attestation"
require_contains "$rollback" 'whatsapp-webhook-rollback-attestation.json' "rollback attestation artifact"
require_contains "$rollback" 'Fail if access credential leaked into rollback evidence' "rollback credential evidence scan"
require_contains "$rollback" 'Upload verified rollback evidence' "required rollback evidence upload"
require_contains "$rollback" 'Run v167-compatible non-customer rollback smoke checks' "v167-compatible rollback smoke step"
require_contains "$rollback" 'test "$challenge_code" = "403"' "v167 rollback invalid challenge status"
require_contains "$rollback" 'test "$post_code" = "401"' "v167 rollback unauthenticated POST status"
require_contains "$rollback" 'test "$options_code" = "200"' "v167 rollback OPTIONS status"
reject_regex "$rollback" 'verify_token_invalid|signature_missing|Unexpected browser CORS header after webhook rollback' "forward-only hardened response semantics in v167 rollback smoke"

require_order "$rollback" \
  "rollback request identity" "Validate rollback request identity and current main" \
  "source release verification" "Verify source release run and resolve rollback artifact" \
  "immutable rollback package validation" "Download and validate immutable rollback package" \
  "expected rollback source manifest" "Build expected rollback source manifest" \
  "preflight live state validation" "Verify exact live state to be rolled back" \
  "rollback preflight attestation" "Build rollback preflight attestation" \
  "normalized rollback package upload" "Upload normalized rollback package" \
  "rollback package/live-state revalidation" "Revalidate rollback package and exact current live state" \
  "final rollback live-state recheck" "Recheck unchanged current main and live state immediately before rollback" \
  "named rollback deploy" "Execute named rollback only" \
  "rollback metadata verification" "Verify rollback deployment metadata" \
  "restored source closure verification" "Verify restored source closure" \
  "rollback compatibility probes" "Run v167-compatible non-customer rollback smoke checks" \
  "rollback attestation" "Build rollback attestation" \
  "rollback credential evidence scan" "Fail if access credential leaked into rollback evidence" \
  "verified rollback evidence upload" "Upload verified rollback evidence"

require_contains "$ownership" "Governed release plan:" "ownership release plan"
require_contains "$ownership" "whatsapp-webhook-production-release.yml" "ownership forward release workflow"
require_contains "$ownership" "whatsapp-webhook-production-rollback.yml" "ownership rollback workflow"

bash -n "$manifest_test"
python3 -m py_compile "$manifest"

echo "WhatsApp webhook production release governance passed."
 "production mutation environment gate"
  fi
  require_contains "$workflow" "persist-credentials: false" "checkout credential hardening"
  require_contains "$workflow" "SUPABASE_PROJECT_REF: tcxvcatsqqertcnycuop" "canonical production project binding"
  require_contains "$workflow" "FUNCTION_NAME: whatsapp-webhook" "named function binding"
  require_contains "$workflow" "SUPABASE_CLI_VERSION: 2.117.0" "pinned Supabase CLI"

  reject_regex "$workflow" 'SUPABASE_DB_URL|supabase[[:space:]]+db[[:space:]]+(push|reset|query)|supabase[[:space:]]+migration[[:space:]]+(up|repair)|supabase[[:space:]]+secrets[[:space:]]+(set|unset)' "database or secret mutation authority"
  reject_regex "$workflow" 'supabase[[:space:]]+functions[[:space:]]+deploy[[:space:]]+[$"{]' "variable Edge deploy target"
  reject_regex "$workflow" 'uses:[[:space:]]+actions/(checkout|upload-artifact|download-artifact)@v[0-9]+' "unpinned first-party action"

  broad_count="$(grep -Ec 'supabase[[:space:]]+functions[[:space:]]+deploy([[:space:]]|$)' "$workflow" || true)"
  named_count="$(grep -Ec 'supabase[[:space:]]+functions[[:space:]]+deploy[[:space:]]+whatsapp-webhook([[:space:]]|$)' "$workflow" || true)"
  [[ "$broad_count" -eq 1 && "$named_count" -eq 1 ]] || fail "every deploy in $workflow must be exactly one literal whatsapp-webhook deploy"

  require_contains "$workflow" 'test "${GITHUB_REF}" = "refs/heads/main"' "protected branch check"
  require_contains "$workflow" 'git fetch --quiet origin refs/heads/main:refs/remotes/origin/main' "current-main fetch"
  require_contains "$workflow" 'test "$(git rev-parse refs/remotes/origin/main)" = "$GITHUB_SHA"' "current-main equality check"
  require_contains "$workflow" 'WHATSAPP_WEBHOOK_VERIFY_TOKEN' "verify-token secret-name readiness"
  require_contains "$workflow" 'CLICK2API_API_KEY' "Click2API secret-name readiness"
  require_contains "$workflow" '${{ github.run_attempt }}' "retry-safe evidence naming"
  require_contains "$workflow" 'if-no-files-found: error' "required artifact failure policy"
done

# Forward release baseline, provenance, source attestation, rollback capture and final evidence.
require_contains "$release" 'EXPECTED_LIVE_VERSION: "167"' "known live version baseline"
require_contains "$release" 'EXPECTED_LIVE_BUNDLE_SHA: 8ae1f251335fe0b9fac952ec3444e858a313f2fe6d34f64cb561ca55d93c3426' "known live bundle baseline"
require_contains "$release" 'DB_PREREQ_RUN_ID: "36335058964"' "database prerequisite run binding"
require_contains "$release" 'DB_PREREQ_SHA: f3366a4a99b57e20ec47a4f152af3a7b3661f5c6' "database prerequisite SHA binding"
require_contains "$release" 'supabase functions download whatsapp-webhook' "live source download"
require_contains "$release" '--use-api' "API-based source unbundling"
require_contains "$release" 'target-source-manifest.json' "reviewed source manifest"
require_contains "$release" 'live-source-manifest.json' "deployed source manifest"
require_regex "$release" 'diff -u[[:space:]\\]*[[:space:]]*target-source-manifest.json[[:space:]\\]*[[:space:]]*live-source-manifest.json' "reviewed/live source equality"
require_contains "$release" 'whatsapp-webhook-predeploy-v167.tar.gz' "rollback source archive"
require_contains "$release" 'ROLLBACK_ARCHIVE_SHA256' "rollback archive integrity binding"
require_contains "$release" 'Build successful release attestation' "successful release attestation"
require_contains "$release" 'whatsapp-webhook-release-attestation.json' "release attestation artifact"
require_contains "$release" 'Fail if access credentials leaked into text evidence' "post-deploy credential evidence scan"
require_contains "$release" 'Upload required verified release evidence' "required verified release upload"
require_contains "$release" 'Unexpected browser CORS header' "hardened no-browser-CORS runtime probe"
require_contains "$release" '.error == "verify_token_invalid"' "hardened invalid challenge semantic assertion"
require_contains "$release" '.error == "signature_missing"' "hardened missing signature semantic assertion"
require_contains "$release" 'test "$challenge_code" = "403"' "hardened invalid challenge status"
require_contains "$release" 'test "$post_code" = "401"' "hardened unauthenticated POST status"
require_contains "$release" 'test "$options_code" = "204"' "hardened OPTIONS status"

require_order "$release" \
  "rollback capture" "Capture restorable live source with pinned Supabase CLI" \
  "post-capture live recheck" "Recheck live baseline after rollback capture" \
  "rollback evidence validation" "Require complete rollback evidence before deployment" \
  "rollback evidence upload" "Upload immutable rollback evidence before deployment" \
  "final current-main/live recheck" "Recheck unchanged current main and live baseline immediately before deployment" \
  "named production deploy" "Deploy exact named function only" \
  "deployed metadata verification" "Verify deployed function metadata" \
  "deployed source closure verification" "Verify deployed source closure matches reviewed source" \
  "runtime authentication probes" "Run non-customer authentication and header smoke checks" \
  "release attestation" "Build successful release attestation" \
  "credential evidence scan" "Fail if access credentials leaked into text evidence" \
  "verified evidence upload" "Upload required verified release evidence"

# Rollback must be bound to the originating release evidence and exact current live state.
require_contains "$rollback" 'ROLLBACK_TO_VERSION: "167"' "rollback target version"
require_contains "$rollback" 'ROLLBACK_TO_BUNDLE_SHA: 8ae1f251335fe0b9fac952ec3444e858a313f2fe6d34f64cb561ca55d93c3426' "rollback target bundle baseline"
require_contains "$rollback" 'source_run_id:' "source release run input"
require_contains "$rollback" 'source_run_attempt:' "source release attempt input"
require_contains "$rollback" 'source_release_sha:' "source release SHA input"
require_contains "$rollback" 'expected_current_version:' "current live version input"
require_contains "$rollback" 'expected_current_bundle_sha:' "current live bundle input"
require_contains "$rollback" '.path == ".github/workflows/whatsapp-webhook-production-release.yml"' "forward workflow identity binding"
require_contains "$rollback" '.status == "completed"' "completed forward-run requirement"
require_contains "$rollback" '.run_attempt == $expected_attempt' "forward run-attempt binding"
require_contains "$rollback" 'artifact_name_encoded="$(jq -rn --arg value "$artifact_name" '\''$value | @uri'\'')"' "URL-encoded rollback artifact name"
require_contains "$rollback" '$api/artifacts?name=$artifact_name_encoded&per_page=100' "server-side rollback artifact name filter"
require_contains "$rollback" 'expected-rollback-source-manifest.json' "expected rollback source manifest"
require_contains "$rollback" 'live-rollback-source-manifest.json' "live rollback source manifest"
require_regex "$rollback" 'diff -u[[:space:]\\]*[[:space:]]*rollback-evidence/expected-rollback-source-manifest.json[[:space:]\\]*[[:space:]]*live-rollback-source-manifest.json' "rollback/live source equality"
require_contains "$rollback" 'Build rollback attestation' "rollback attestation"
require_contains "$rollback" 'whatsapp-webhook-rollback-attestation.json' "rollback attestation artifact"
require_contains "$rollback" 'Fail if access credential leaked into rollback evidence' "rollback credential evidence scan"
require_contains "$rollback" 'Upload verified rollback evidence' "required rollback evidence upload"
require_contains "$rollback" 'Run v167-compatible non-customer rollback smoke checks' "v167-compatible rollback smoke step"
require_contains "$rollback" 'test "$challenge_code" = "403"' "v167 rollback invalid challenge status"
require_contains "$rollback" 'test "$post_code" = "401"' "v167 rollback unauthenticated POST status"
require_contains "$rollback" 'test "$options_code" = "200"' "v167 rollback OPTIONS status"
reject_regex "$rollback" 'verify_token_invalid|signature_missing|Unexpected browser CORS header after webhook rollback' "forward-only hardened response semantics in v167 rollback smoke"

require_order "$rollback" \
  "rollback request identity" "Validate rollback request identity and current main" \
  "source release verification" "Verify source release run and resolve rollback artifact" \
  "immutable rollback package validation" "Download and validate immutable rollback package" \
  "expected rollback source manifest" "Build expected rollback source manifest" \
  "preflight live state validation" "Verify exact live state to be rolled back" \
  "rollback preflight attestation" "Build rollback preflight attestation" \
  "normalized rollback package upload" "Upload normalized rollback package" \
  "rollback package/live-state revalidation" "Revalidate rollback package and exact current live state" \
  "final rollback live-state recheck" "Recheck unchanged current main and live state immediately before rollback" \
  "named rollback deploy" "Execute named rollback only" \
  "rollback metadata verification" "Verify rollback deployment metadata" \
  "restored source closure verification" "Verify restored source closure" \
  "rollback compatibility probes" "Run v167-compatible non-customer rollback smoke checks" \
  "rollback attestation" "Build rollback attestation" \
  "rollback credential evidence scan" "Fail if access credential leaked into rollback evidence" \
  "verified rollback evidence upload" "Upload verified rollback evidence"

require_contains "$ownership" "Governed release plan:" "ownership release plan"
require_contains "$ownership" "whatsapp-webhook-production-release.yml" "ownership forward release workflow"
require_contains "$ownership" "whatsapp-webhook-production-rollback.yml" "ownership rollback workflow"

bash -n "$manifest_test"
python3 -m py_compile "$manifest"

echo "WhatsApp webhook production release governance passed."

#!/usr/bin/env bash
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

release=".github/workflows/whatsapp-webhook-production-release.yml"
rollback=".github/workflows/whatsapp-webhook-production-rollback.yml"
plan="docs/security/WHATSAPP_WEBHOOK_PRODUCTION_MIGRATION_PLAN_2026-09-27.md"
ownership="FUNCTION_OWNERSHIP.md"
manifest="scripts/edge-function-source-manifest.py"
manifest_test="scripts/tests/verify-edge-function-source-manifest.sh"
governance_regression_test="scripts/tests/verify-check-whatsapp-webhook-production-release.sh"

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

require_job_order() {
  local file="$1"
  local job="$2"
  local first="$3"
  local second="$4"
  local label="$5"
  awk -v job="$job" -v first="$first" -v second="$second" '
    $0 == "  " job ":" { in_job=1; next }
    in_job && $0 ~ /^  [A-Za-z0-9_-]+:$/ { exit }
    in_job && index($0, first) {
      if (first_line) duplicate=1
      first_line=NR
    }
    in_job && index($0, second) {
      if (second_line) duplicate=1
      second_line=NR
    }
    END {
      exit(first_line && second_line && first_line < second_line && !duplicate ? 0 : 1)
    }
  ' "$file" || fail "$label missing, duplicated, or out of order in $file job $job"
}

reject_regex() {
  local file="$1"
  local regex="$2"
  local label="$3"
  if grep -Eq -- "$regex" "$file"; then
    fail "$label detected in $file"
  fi
}

validate_workflow_on_triggers() {
  local file="$1"
  awk '
    BEGIN {
      key_count = 0
    }
    /^on:[[:space:]]*$/ || /^on:[[:space:]]+/ {
      saw_on = 1
      in_on = 1
      next
    }
    in_on && /^[^[:space:]#]/ {
      in_on = 0
    }
    in_on {
      if ($0 ~ /^[[:space:]]*(#|$)/) {
        next
      }
      if (match($0, /^[[:space:]]+/)) {
        indent = RLENGTH
        rest = substr($0, RLENGTH + 1)
        if (match(rest, /^[A-Za-z0-9_-]+:/)) {
          key = substr(rest, 1, RLENGTH - 1)
          key_count++
          indents[key_count] = indent
          keys[key_count] = key
        }
      }
    }
    END {
      if (!saw_on) {
        print "missing top-level on mapping"
        exit 1
      }
      if (key_count == 0) {
        print "empty workflow on mapping"
        exit 1
      }
      min_indent = indents[1]
      for (i = 2; i <= key_count; i++) {
        if (indents[i] < min_indent) {
          min_indent = indents[i]
        }
      }
      has_dispatch = 0
      direct_trigger_count = 0
      for (i = 1; i <= key_count; i++) {
        if (indents[i] != min_indent) {
          continue
        }
        direct_trigger_count++
        if (keys[i] == "workflow_dispatch") {
          has_dispatch = 1
          continue
        }
        printf "disallowed production trigger %s under on mapping; manual workflow_dispatch only\n", keys[i]
        exit 1
      }
      if (!has_dispatch) {
        print "workflow_dispatch missing from on mapping"
        exit 1
      }
      if (direct_trigger_count < 1) {
        print "empty workflow on mapping"
        exit 1
      }
    }
  ' "$file" || fail "invalid workflow trigger structure in $file"
}

validate_authoritative_workflow_permissions_block() {
  local block="$1"
  local label="$2"
  local line scope level
  local seen_contents=0
  local seen_actions=0

  if grep -Eq 'write-all|read-all|:[[:space:]]*write([[:space:]]|$)' <<<"$block"; then
    fail "elevated GitHub token permission in $label"
  fi
  if grep -Eq '^permissions:[[:space:]]+(read-all|write-all|none)' <<<"$block"; then
    fail "inline elevated GitHub token permission in $label"
  fi

  while IFS= read -r line; do
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    [[ "$line" =~ ^[[:space:]]*$ ]] && continue
    [[ "$line" =~ ^permissions:[[:space:]]*$ ]] && continue
    if [[ "$line" =~ ^[[:space:]]*([A-Za-z0-9_-]+):[[:space:]]*(read|write|none)[[:space:]]*$ ]]; then
      scope="${BASH_REMATCH[1]}"
      level="${BASH_REMATCH[2]}"
      case "${scope}:${level}" in
        contents:read)
          seen_contents=1
          ;;
        actions:read)
          seen_actions=1
          ;;
        *)
          fail "disallowed permission scope ${scope}:${level} in $label"
          ;;
      esac
      continue
    fi
    fail "unrecognized permissions syntax in $label: $line"
  done <<<"$block"

  [[ "$seen_contents" -eq 1 ]] || fail "read-only contents permission missing from $label"
  [[ "$seen_actions" -eq 1 ]] || fail "read-only Actions permission missing from $label"
}

reject_job_permissions_overrides() {
  local file="$1"
  if awk '
    BEGIN {
      in_jobs = 0
      found = 0
      key_count = 0
      perm_count = 0
    }
    /^jobs:[[:space:]]*$/ { in_jobs = 1; next }
    in_jobs && /^[^[:space:]#]/ { in_jobs = 0 }
    in_jobs {
      if ($0 ~ /^[[:space:]]*(#|$)/) {
        next
      }
      if (match($0, /^[[:space:]]+/)) {
        indent = RLENGTH
        rest = substr($0, RLENGTH + 1)
        if (rest ~ /^permissions:/) {
          perm_count++
          permissions_indents[perm_count] = indent
        }
        if (match(rest, /^[A-Za-z0-9_-]+:/)) {
          key_count++
          indents[key_count] = indent
        }
      }
    }
    END {
      if (key_count == 0) {
        exit 1
      }
      min_indent = indents[1]
      for (i = 2; i <= key_count; i++) {
        if (indents[i] < min_indent) {
          min_indent = indents[i]
        }
      }
      for (i = 1; i <= perm_count; i++) {
        if (permissions_indents[i] > min_indent) {
          found = 1
          break
        }
      }
      exit(found ? 0 : 1)
    }
  ' "$file" >/dev/null 2>&1; then
    fail "job-level permissions override detected in $file; workflow permissions are authoritative"
  fi
}

validate_workflow_permissions() {
  local file="$1"
  local workflow_block

  workflow_block="$(
    awk '
      /^permissions:/ {
        print $0
        if ($0 ~ /^permissions:[[:space:]]*$/) {
          in_block = 1
        }
        next
      }
      in_block && /^[^[:space:]#]/ { exit }
      in_block { print; next }
    ' "$file"
  )"
  [[ -n "$workflow_block" ]] || fail "workflow-level permissions block missing from $file"
  validate_authoritative_workflow_permissions_block "$workflow_block" "workflow permissions in $file"
  reject_job_permissions_overrides "$file"
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

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
for required in "$release" "$rollback" "$plan" "$ownership" "$manifest" "$manifest_test" "$governance_regression_test"; do
  require_file "$required"
done

# Structural uniqueness: iterative edits must never leave duplicate production jobs.
require_exact_count "$release" '^  preflight:$' 1 "release preflight job"
require_exact_count "$release" '^  deploy:$' 1 "release deploy job"
require_exact_count "$release" '^  certify-existing:$' 1 "release recovery certification job"
require_exact_count "$rollback" '^  preflight:$' 1 "rollback preflight job"
require_exact_count "$rollback" '^  rollback:$' 1 "rollback mutation job"

for workflow in "$release" "$rollback"; do
  validate_workflow_on_triggers "$workflow"
  validate_workflow_permissions "$workflow"

  require_contains "$workflow" "group: whatsapp-webhook-production-release" "shared release/rollback concurrency lock"
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
  require_contains "$workflow" 'Direct Meta callback remains fail-closed without an app secret; Click2API-primary production ingress remains eligible.' "Click2API-primary direct-Meta fail-closed readiness"
  reject_regex "$workflow" 'WhatsApp provider app-secret name is not configured in production' "obsolete mandatory direct-Meta app-secret gate"
  require_contains "$workflow" '${{ github.run_attempt }}' "retry-safe evidence naming"
  require_contains "$workflow" 'if-no-files-found: error' "required artifact failure policy"
done

# Forward release baseline, provenance, source attestation, rollback capture and final evidence.
require_contains "$release" 'certify_existing:' "read-only recovery certification input"
require_job_regex "$release" "certify-existing" '^    environment: supabase-production-readonly$' "read-only recovery certification environment"
require_job_regex "$release" "certify-existing" "inputs\.certify_existing == true && inputs\.deploy == false" "mutually exclusive recovery certification condition"
require_job_regex "$release" "certify-existing" 'SOURCE_DEPLOY_RUN_ID: "36360119159"' "source deployment run binding"
require_job_regex "$release" "certify-existing" 'productionMutationPerformed: false' "explicit no-mutation recovery attestation"
require_job_regex "$release" "certify-existing" 'RECOVERY_CERTIFIED' "recovery certification attestation"
require_job_regex "$release" "certify-existing" 'Run provider-aware non-customer authentication and header certification checks' "provider-aware recovery smoke step"
require_job_regex "$release" "certify-existing" '\?source=click2api&token=definitely-invalid' "Click2API invalid-token recovery probe"
require_job_regex "$release" "certify-existing" 'app_secret_not_configured' "direct-Meta no-secret fail-closed recovery assertion"
require_job_regex "$release" "certify-existing" 'click2apiInvalidToken: \{status: 403, error: "verify_token_invalid"\}' "Click2API recovery attestation semantics"
require_job_regex "$release" "certify-existing" 'directMetaWithoutSecret: \{status: 500, error: "app_secret_not_configured"\}' "direct-Meta recovery attestation semantics"
reject_regex "$release" 'certify-existing[\s\S]*unauthenticatedPost: \{status: 401, error: "signature_missing"\}' "stale Meta-secret-present recovery assumption"
require_job_regex "$release" "preflight" 'Forward deployment from live v168 is blocked until a v168-compatible rollback lane is implemented and governed.' "v168 forward-deploy fail-closed gate"
require_job_regex "$release" "certify-existing" 'Recheck live v168 metadata immediately before recovery attestation' "final live metadata recheck"
require_job_regex "$release" "certify-existing" 'live-function-certification-final.json' "final live metadata evidence"
require_job_regex "$release" "certify-existing" 'finalLiveMetadataRechecked: true' "final live metadata attestation flag"
require_job_order "$release" "certify-existing" \
  'Run non-customer authentication and header certification checks' \
  'Recheck live v168 metadata immediately before recovery attestation' \
  "recovery smoke before final live metadata recheck"
require_job_order "$release" "certify-existing" \
  'Recheck live v168 metadata immediately before recovery attestation' \
  'Build recovery certification attestation' \
  "final live metadata recheck before recovery attestation"
require_contains "$release" 'no-store[[:space:]]*$' "CRLF-safe cache-control smoke matcher"
require_contains "$release" 'nosniff[[:space:]]*$' "CRLF-safe nosniff smoke matcher"
reject_regex "$release" '\\r\?\$' "broken literal-r HTTP header matcher"
require_job_regex "$release" "preflight" '^      - name: Set up Deno for executable webhook recertification$' "named Deno recertification setup step"
require_job_regex "$release" "preflight" '^        uses: denoland/setup-deno@22d081ff2d3a40755e97629de92e3bcbfa7cf2ed$' "pinned Deno setup for executable webhook recertification"
require_job_regex "$release" "preflight" '^          deno-version: v2\.x$' "Deno v2.x recertification setup"
require_job_order "$release" "preflight" \
  'uses: denoland/setup-deno@22d081ff2d3a40755e97629de92e3bcbfa7cf2ed' \
  'bash scripts/check-whatsapp-webhook-recertification.sh' \
  "Deno setup before executable webhook recertification"
require_contains "$release" 'EXPECTED_LIVE_VERSION: "168"' "known live version baseline"
require_contains "$release" 'EXPECTED_LIVE_BUNDLE_SHA: 12329a45a2d46e880764825e88ffe23d4029e7e48f24cac832401312f9a57219' "known live bundle baseline"
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
bash -n "$governance_regression_test"
python3 -m py_compile "$manifest"
bash "$governance_regression_test"

echo "WhatsApp webhook production release governance passed."
fi

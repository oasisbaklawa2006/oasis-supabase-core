#!/usr/bin/env bash
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

release=".github/workflows/whatsapp-webhook-production-release.yml"
rollback=".github/workflows/whatsapp-webhook-production-rollback.yml"
plan="docs/security/WHATSAPP_WEBHOOK_PRODUCTION_MIGRATION_PLAN_2026-09-27.md"

for required in "$release" "$rollback" "$plan" "scripts/edge-function-source-manifest.py"; do
  [[ -s "$required" ]] || {
    echo "WHATSAPP WEBHOOK RELEASE GOVERNANCE VIOLATION: missing $required" >&2
    exit 1
  }
done

for workflow in "$release" "$rollback"; do
  grep -Fq 'workflow_dispatch:' "$workflow" || {
    echo "WHATSAPP WEBHOOK RELEASE GOVERNANCE VIOLATION: $workflow must be manual-dispatch only" >&2
    exit 1
  }
  if grep -Eq '^[[:space:]]{2}(push|pull_request|schedule|repository_dispatch):' "$workflow"; then
    echo "WHATSAPP WEBHOOK RELEASE GOVERNANCE VIOLATION: automatic trigger detected in $workflow" >&2
    exit 1
  fi
  if grep -Eq '^[[:space:]]+(contents|actions|deployments|id-token):[[:space:]]+write' "$workflow"; then
    echo "WHATSAPP WEBHOOK RELEASE GOVERNANCE VIOLATION: write-level workflow token permission detected in $workflow" >&2
    exit 1
  fi
  grep -Fq 'group: whatsapp-webhook-production-release' "$workflow" || {
    echo "WHATSAPP WEBHOOK RELEASE GOVERNANCE VIOLATION: $workflow must share the production concurrency lock" >&2
    exit 1
  }
  grep -Fq 'contents: read' "$workflow" || exit 1
  grep -Fq 'actions: read' "$workflow" || exit 1
  grep -Fq 'environment: supabase-production-readonly' "$workflow" || exit 1
  grep -Fq 'environment: supabase-production' "$workflow" || exit 1
  grep -Fq 'persist-credentials: false' "$workflow" || exit 1
  grep -Fq 'SUPABASE_PROJECT_REF: tcxvcatsqqertcnycuop' "$workflow" || exit 1
  grep -Fq 'FUNCTION_NAME: whatsapp-webhook' "$workflow" || exit 1
  grep -Fq 'SUPABASE_CLI_VERSION: 2.117.0' "$workflow" || exit 1

  if grep -Eq 'SUPABASE_DB_URL|supabase[[:space:]]+db[[:space:]]+(push|reset|query)|supabase[[:space:]]+migration[[:space:]]+(up|repair)|supabase[[:space:]]+secrets[[:space:]]+(set|unset)' "$workflow"; then
    echo "WHATSAPP WEBHOOK RELEASE GOVERNANCE VIOLATION: database/secret mutation authority leaked into $workflow" >&2
    exit 1
  fi

  if grep -Eq 'supabase[[:space:]]+functions[[:space:]]+deploy[[:space:]]+[$"{]' "$workflow"; then
    echo "WHATSAPP WEBHOOK RELEASE GOVERNANCE VIOLATION: deploy target must be a literal function name in $workflow" >&2
    exit 1
  fi

  broad_count="$(grep -Ec 'supabase[[:space:]]+functions[[:space:]]+deploy([[:space:]]|$)' "$workflow" || true)"
  named_count="$(grep -Ec 'supabase[[:space:]]+functions[[:space:]]+deploy[[:space:]]+whatsapp-webhook([[:space:]]|$)' "$workflow" || true)"
  [[ "$broad_count" -eq "$named_count" && "$named_count" -ge 1 ]] || {
    echo "WHATSAPP WEBHOOK RELEASE GOVERNANCE VIOLATION: every deploy must name whatsapp-webhook literally in $workflow" >&2
    exit 1
  }
done

grep -Fq 'EXPECTED_LIVE_VERSION: "167"' "$release" || exit 1
grep -Fq 'EXPECTED_LIVE_BUNDLE_SHA: 8ae1f251335fe0b9fac952ec3444e858a313f2fe6d34f64cb561ca55d93c3426' "$release" || exit 1
grep -Fq 'test "${GITHUB_REF}" = "refs/heads/main"' "$release" || exit 1
grep -Fq 'git fetch --quiet origin refs/heads/main:refs/remotes/origin/main' "$release" || exit 1
grep -Fq 'test "$(git rev-parse refs/remotes/origin/main)" = "$GITHUB_SHA"' "$release" || exit 1
grep -Fq 'supabase functions download whatsapp-webhook' "$release" || exit 1
grep -Fq -- '--use-api' "$release" || exit 1
grep -Fq 'target-source-manifest.json' "$release" || exit 1
grep -Fq 'live-source-manifest.json' "$release" || exit 1
grep -Fq 'diff -u target-source-manifest.json live-source-manifest.json' "$release" || exit 1
grep -Fq 'production-secret-names.txt' "$release" || exit 1
grep -Fq 'WHATSAPP_WEBHOOK_VERIFY_TOKEN' "$release" || exit 1
grep -Fq 'CLICK2API_API_KEY' "$release" || exit 1
grep -Fq 'Build successful release attestation' "$release" || exit 1
grep -Fq 'Fail if access credentials leaked into text evidence' "$release" || exit 1
grep -Fq 'Upload required verified release evidence' "$release" || exit 1
grep -Fq '.error == "verify_token_invalid"' "$release" || exit 1
grep -Fq '.error == "signature_missing"' "$release" || exit 1
grep -Fq 'Unexpected browser CORS header' "$release" || exit 1
grep -Fq 'test "$options_code" = "204"' "$release" || exit 1
grep -Fq 'if-no-files-found: error' "$release" || exit 1
grep -Fq '${{ github.run_attempt }}' "$release" || exit 1

capture_line="$(grep -nF 'Capture restorable live source with pinned Supabase CLI' "$release" | cut -d: -f1)"
rollback_upload_line="$(grep -nF 'Upload immutable rollback evidence before deployment' "$release" | cut -d: -f1)"
final_recheck_line="$(grep -nF 'Recheck unchanged live baseline immediately before deployment' "$release" | cut -d: -f1)"
deploy_line="$(grep -nF 'Deploy exact named function only' "$release" | cut -d: -f1)"
source_verify_line="$(grep -nF 'Verify deployed source closure matches reviewed source' "$release" | cut -d: -f1)"
attest_line="$(grep -nF 'Build successful release attestation' "$release" | cut -d: -f1)"
verified_upload_line="$(grep -nF 'Upload required verified release evidence' "$release" | cut -d: -f1)"

[[ "$capture_line" -lt "$rollback_upload_line" ]] || exit 1
[[ "$rollback_upload_line" -lt "$final_recheck_line" ]] || exit 1
[[ "$final_recheck_line" -lt "$deploy_line" ]] || exit 1
[[ "$deploy_line" -lt "$source_verify_line" ]] || exit 1
[[ "$source_verify_line" -lt "$attest_line" ]] || exit 1
[[ "$attest_line" -lt "$verified_upload_line" ]] || exit 1

grep -Fq 'ROLLBACK_TO_VERSION: "167"' "$rollback" || exit 1
grep -Fq 'ROLLBACK_TO_BUNDLE_SHA: 8ae1f251335fe0b9fac952ec3444e858a313f2fe6d34f64cb561ca55d93c3426' "$rollback" || exit 1
grep -Fq 'source_run_id:' "$rollback" || exit 1
grep -Fq 'git fetch --quiet origin refs/heads/main:refs/remotes/origin/main' "$rollback" || exit 1
grep -Fq 'test "$(git rev-parse refs/remotes/origin/main)" = "$GITHUB_SHA"' "$rollback" || exit 1
grep -Fq 'expected_current_version:' "$rollback" || exit 1
grep -Fq 'expected_current_bundle_sha:' "$rollback" || exit 1
grep -Fq 'expected-rollback-source-manifest.json' "$rollback" || exit 1
grep -Fq 'live-rollback-source-manifest.json' "$rollback" || exit 1
grep -Fq 'diff -u expected-rollback-source-manifest.json live-rollback-source-manifest.json' "$rollback" || exit 1
grep -Fq 'production-secret-names.txt' "$rollback" || exit 1
grep -Fq 'WHATSAPP_WEBHOOK_VERIFY_TOKEN' "$rollback" || exit 1
grep -Fq 'CLICK2API_API_KEY' "$rollback" || exit 1
grep -Fq 'Build rollback attestation' "$rollback" || exit 1
grep -Fq 'Fail if access credentials leaked into rollback evidence' "$rollback" || exit 1
grep -Fq 'Upload verified rollback evidence' "$rollback" || exit 1
grep -Fq '.path == ".github/workflows/whatsapp-webhook-production-release.yml"' "$rollback" || exit 1
grep -Fq '.status == "completed"' "$rollback" || exit 1
grep -Fq '.error == "verify_token_invalid"' "$rollback" || exit 1
grep -Fq '.error == "signature_missing"' "$rollback" || exit 1
grep -Fq 'Unexpected browser CORS header' "$rollback" || exit 1
grep -Fq 'test "$options_code" = "204"' "$rollback" || exit 1
grep -Fq '${{ github.run_attempt }}' "$rollback" || exit 1

grep -Fq 'Governed release plan:' FUNCTION_OWNERSHIP.md || exit 1
grep -Fq 'whatsapp-webhook-production-release.yml' FUNCTION_OWNERSHIP.md || exit 1
grep -Fq 'whatsapp-webhook-production-rollback.yml' FUNCTION_OWNERSHIP.md || exit 1

echo "WhatsApp webhook production release governance passed."

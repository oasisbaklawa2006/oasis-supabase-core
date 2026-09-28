#!/usr/bin/env bash
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

db_prereq_sql="scripts/sql/verify-admin-provision-user-production-db-prerequisites.sql"
manifest="scripts/edge-function-source-manifest.py"
manifest_test="scripts/tests/verify-edge-function-source-manifest.sh"
governance_regression_test="scripts/tests/verify-check-admin-provision-user-production-first-deploy.sh"

# shellcheck disable=SC1091
source scripts/check-whatsapp-webhook-production-release.sh

fail() {
  echo "ADMIN PROVISION USER FIRST DEPLOY GOVERNANCE VIOLATION: $*" >&2
  exit 1
}

first_deploy_workflow=".github/workflows/admin-provision-user-production-first-deploy.yml"
remove_workflow=".github/workflows/admin-provision-user-production-remove.yml"

require_file() {
  local path="$1"
  [[ -s "$path" ]] || fail "missing required file: $path"
}

for required in "$first_deploy_workflow" "$remove_workflow" "$db_prereq_sql" "$manifest" "$manifest_test" "$governance_regression_test"; do
  require_file "$required"
done

require_exact_count "$first_deploy_workflow" '^  preflight:$' 1 "first-deploy preflight job"
require_exact_count "$first_deploy_workflow" '^  deploy:$' 1 "first-deploy deploy job"
require_exact_count "$remove_workflow" '^  preflight:$' 1 "remove preflight job"
require_exact_count "$remove_workflow" '^  remove:$' 1 "remove mutation job"

for workflow in "$first_deploy_workflow" "$remove_workflow"; do
  validate_workflow_on_triggers "$workflow"
  validate_workflow_permissions "$workflow"

  require_contains "$workflow" "group: admin-provision-user-production-first-deploy" "shared first-deploy/remove concurrency lock"
  require_contains "$workflow" "environment: supabase-production-readonly" "read-only production environment gate"
  require_contains "$workflow" "persist-credentials: false" "checkout credential hardening"
  require_contains "$workflow" "SUPABASE_PROJECT_REF: tcxvcatsqqertcnycuop" "canonical production project binding"
  require_contains "$workflow" 'FUNCTION_NAME: admin-provision-user' "named function binding"
  require_contains "$workflow" "SUPABASE_CLI_VERSION: 2.117.0" "pinned Supabase CLI"
  require_contains "$workflow" '${{ github.run_attempt }}' "retry-safe evidence naming"
  require_contains "$workflow" 'if-no-files-found: error' "required artifact failure policy"

  reject_regex "$workflow" 'supabase[[:space:]]+db[[:space:]]+(push|reset|query)|supabase[[:space:]]+migration[[:space:]]+(up|repair)|supabase[[:space:]]+secrets[[:space:]]+(set|unset)' "database or secret mutation authority"
  reject_regex "$workflow" 'supabase[[:space:]]+functions[[:space:]]+deploy[[:space:]]+[$"{]' "variable Edge deploy target"
  reject_regex "$workflow" 'uses:[[:space:]]+actions/(checkout|upload-artifact|download-artifact)@v[0-9]+' "unpinned first-party action"
  reject_regex "$workflow" '--no-verify-jwt' "JWT verification must remain enabled"
done

require_job_regex "$first_deploy_workflow" "deploy" '^    environment: supabase-production$' "production mutation environment gate"
require_job_regex "$remove_workflow" "remove" '^    environment: supabase-production$' "production removal environment gate"

require_contains "$first_deploy_workflow" 'test "${GITHUB_REF}" = "refs/heads/main"' "protected branch check"
require_contains "$first_deploy_workflow" 'git fetch --quiet origin refs/heads/main:refs/remotes/origin/main' "current-main fetch"
require_contains "$first_deploy_workflow" 'test "$(git rev-parse refs/remotes/origin/main)" = "$GITHUB_SHA"' "current-main equality check"
require_contains "$first_deploy_workflow" 'release_sha:' "exact release SHA input"
require_contains "$first_deploy_workflow" 'inputs.deploy == true' "explicit deploy boolean gate"
require_contains "$first_deploy_workflow" 'verify-admin-provision-user-production-db-prerequisites.sql' "read-only DB prerequisite SQL"
require_contains "$first_deploy_workflow" '-f scripts/sql/verify-admin-provision-user-production-db-prerequisites.sql' "read-only DB prerequisite invocation"
require_contains "$first_deploy_workflow" 'secrets.SUPABASE_DB_URL' "read-only production DB credential gate"
reject_regex "$remove_workflow" 'secrets\.SUPABASE_DB_URL|psql[[:space:]]' "remove workflow must not connect to production database"
require_contains "$first_deploy_workflow" 'target-source-manifest.json' "reviewed source manifest"
require_contains "$first_deploy_workflow" 'live-source-manifest.json' "deployed source manifest"
require_regex "$first_deploy_workflow" 'diff -u[[:space:]\\]*[[:space:]]*target-source-manifest.json[[:space:]\\]*[[:space:]]*live-source-manifest.json' "reviewed/live source equality"
require_contains "$first_deploy_workflow" 'supabase functions download admin-provision-user' "live source download"
require_contains "$first_deploy_workflow" '--use-api' "API-based source unbundling"
require_contains "$first_deploy_workflow" 'ADMIN_PROVISION_USER_FUNCTION_ABSENT' "absent-function attestation marker"
require_contains "$first_deploy_workflow" 'UNEXPECTED_LIVE_FUNCTION' "fail-closed unexpected live function marker"
require_contains "$first_deploy_workflow" '.verify_jwt == true' "verify_jwt=true metadata assertion"
require_contains "$first_deploy_workflow" 'admin-provision-user-first-deploy-rollback-plan.json' "first-deploy rollback plan evidence"
require_contains "$first_deploy_workflow" 'admin-provision-user-production-remove.yml' "paired remove workflow binding"
require_contains "$first_deploy_workflow" 'Fail if access credentials leaked into text evidence' "credential evidence scan"
require_contains "$first_deploy_workflow" 'test "$unauthenticated_code" = "401"' "unauthenticated JWT boundary smoke"
require_contains "$first_deploy_workflow" 'test "$invalid_jwt_code" = "401"' "invalid JWT boundary smoke"
require_contains "$first_deploy_workflow" 'deno test supabase/functions/_shared/adminProvisionUser.test.ts' "admin provisioning contract tests"

broad_count="$(grep -Ec 'supabase[[:space:]]+functions[[:space:]]+deploy([[:space:]]|$)' "$first_deploy_workflow" || true)"
named_count="$(grep -Ec 'supabase[[:space:]]+functions[[:space:]]+deploy[[:space:]]+admin-provision-user([[:space:]]|$)' "$first_deploy_workflow" || true)"
[[ "$broad_count" -eq 1 && "$named_count" -eq 1 ]] || fail "release workflow must contain exactly one literal admin-provision-user deploy"

delete_broad="$(grep -Ec 'supabase[[:space:]]+functions[[:space:]]+delete([[:space:]]|$)' "$remove_workflow" || true)"
delete_named="$(grep -Ec 'supabase[[:space:]]+functions[[:space:]]+delete[[:space:]]+admin-provision-user([[:space:]]|$)' "$remove_workflow" || true)"
[[ "$delete_broad" -eq 1 && "$delete_named" -eq 1 ]] || fail "remove workflow must contain exactly one literal admin-provision-user delete"

require_contains "$remove_workflow" 'inputs.remove == true' "explicit remove boolean gate"
require_contains "$remove_workflow" '.path == ".github/workflows/admin-provision-user-production-first-deploy.yml"' "forward workflow identity binding"
require_contains "$remove_workflow" 'source_deploy_run_id:' "source deploy run input"
require_contains "$remove_workflow" 'source_deploy_run_attempt:' "source deploy run attempt input"
require_contains "$remove_workflow" 'source_release_sha:' "source release SHA input"
require_contains "$remove_workflow" 'expected_deployed_version:' "expected deployed version input"
require_contains "$remove_workflow" 'expected_deployed_bundle_sha:' "expected deployed bundle SHA input"
require_contains "$remove_workflow" 'admin-provision-user-remove-attestation.json' "remove attestation artifact"
require_contains "$remove_workflow" 'FUNCTION_REMOVED' "removed-function attestation marker"

require_order "$first_deploy_workflow" \
  "absent function proof" "Prove admin-provision-user is absent from production" \
  "db prerequisite verification" "Verify read-only staff provisioning DB prerequisites" \
  "preflight attestation" "Build first-deploy preflight attestation" \
  "preflight evidence upload" "Upload immutable preflight evidence"

require_order "$first_deploy_workflow" \
  "absent recheck" "Recheck function remains absent immediately before deployment" \
  "rollback plan evidence" "Build first-deploy rollback/remove plan evidence" \
  "named production deploy" "Deploy exact named function only" \
  "deployed metadata verification" "Verify deployed function metadata" \
  "deployed source closure verification" "Verify deployed source closure matches reviewed source" \
  "jwt boundary smoke" "Run unauthenticated and invalid-JWT boundary smoke checks" \
  "release attestation" "Build successful first-deploy attestation" \
  "verified evidence upload" "Upload required verified first-deploy evidence"

require_order "$remove_workflow" \
  "source deploy verification" "Verify source first-deploy run and resolve deployment evidence" \
  "preflight live state validation" "Verify exact live function state before removal" \
  "named function removal" "Delete exact named function only" \
  "post-removal absence proof" "Prove admin-provision-user is absent after removal" \
  "remove attestation" "Build remove attestation" \
  "verified remove evidence upload" "Upload required verified remove evidence"

bash -n "$governance_regression_test"
bash -n "$manifest_test"
python3 -m py_compile "$manifest"
bash "$governance_regression_test"

echo "Admin provision user production first-deploy governance passed."

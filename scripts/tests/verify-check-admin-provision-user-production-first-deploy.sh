#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$root"

# shellcheck disable=SC1091
source scripts/check-whatsapp-webhook-production-release.sh

fixture_dir="$(mktemp -d)"
trap 'rm -rf "$fixture_dir"' EXIT

write_fixture() {
  local path="$1"
  cat >"$path" <<'YAML'
name: Admin provision first deploy lane fixture
on:
  workflow_dispatch:
    inputs:
      deploy:
        type: boolean
permissions:
  contents: read
  actions: read
jobs:
  preflight:
    runs-on: ubuntu-latest
  deploy:
    runs-on: ubuntu-latest
YAML
}

expect_validator_failure() {
  local label="$1"
  shift
  if ( "$@" ) >/dev/null 2>&1; then
    echo "Expected validator failure: $label" >&2
    exit 1
  fi
}

baseline="$fixture_dir/baseline.yml"
write_fixture "$baseline"
validate_workflow_on_triggers "$baseline"
validate_workflow_permissions "$baseline"

extra_trigger="$fixture_dir/extra-trigger.yml"
cat >"$extra_trigger" <<'YAML'
name: Admin provision first deploy lane fixture
on:
  workflow_dispatch:
    inputs:
      deploy:
        type: boolean
  push:
permissions:
  contents: read
  actions: read
jobs:
  preflight:
    runs-on: ubuntu-latest
YAML
expect_validator_failure "non-manual on: trigger push" \
  validate_workflow_on_triggers "$extra_trigger"

release_workflow=".github/workflows/admin-provision-user-production-first-deploy.yml"
remove_workflow=".github/workflows/admin-provision-user-production-remove.yml"

for workflow in "$release_workflow" "$remove_workflow"; do
  if grep -Fq '--no-verify-jwt' "$workflow"; then
    echo "verify_jwt disable flag must not appear in $workflow" >&2
    exit 1
  fi
done

grep -Fq 'tcxvcatsqqertcnycuop' "$release_workflow"
grep -Fq 'admin-provision-user' "$release_workflow"
grep -Fq 'UNEXPECTED_LIVE_FUNCTION' "$release_workflow"
grep -Fq 'admin-provision-user-production-remove.yml' "$release_workflow"
grep -Fq 'supabase functions delete admin-provision-user' "$remove_workflow"
grep -Fq 'actions/artifacts/$artifact_id/zip' "$remove_workflow"
grep -Fq 'source-deploy-evidence/admin-provision-user-first-deploy-attestation.json' "$remove_workflow"
grep -Fq '.deployedBundleSha256 == $expected_bundle' "$remove_workflow"
grep -Fq '(.deployedVersion | tostring) == ($expected_version | tostring)' "$remove_workflow"
grep -Fq '.releaseSha == $expected_release_sha' "$remove_workflow"

echo "Admin provision user production first-deploy governance regression passed."

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
name: WhatsApp webhook production lane fixture
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
name: WhatsApp webhook production lane fixture
on:
  workflow_dispatch:
    inputs:
      deploy:
        type: boolean
  workflow_call:
permissions:
  contents: read
  actions: read
jobs:
  preflight:
    runs-on: ubuntu-latest
YAML
expect_validator_failure "non-manual on: trigger workflow_call"   validate_workflow_on_triggers "$extra_trigger"

nested_dispatch_ok="$fixture_dir/nested-dispatch-inputs.yml"
write_fixture "$nested_dispatch_ok"
validate_workflow_on_triggers "$nested_dispatch_ok"

inline_job_permissions="$fixture_dir/inline-job-permissions.yml"
write_fixture "$inline_job_permissions"
sed -i '/^  deploy:/a\    permissions: write-all' "$inline_job_permissions"
expect_validator_failure "inline job permissions override"   validate_workflow_permissions "$inline_job_permissions"

deep_job_permissions="$fixture_dir/deep-job-permissions.yml"
cat >"$deep_job_permissions" <<'YAML'
name: WhatsApp webhook production lane fixture
on:
  workflow_dispatch:
    inputs:
      deploy:
        type: boolean
permissions:
  contents: read
  actions: read
jobs:
  deploy:
      permissions: write-all
      runs-on: ubuntu-latest
YAML
expect_validator_failure "deep-indented job permissions override"   validate_workflow_permissions "$deep_job_permissions"

extra_workflow_scope="$fixture_dir/extra-workflow-scope.yml"
cat >"$extra_workflow_scope" <<'YAML'
name: WhatsApp webhook production lane fixture
on:
  workflow_dispatch:
    inputs:
      deploy:
        type: boolean
permissions:
  contents: read
  actions: read
  metadata: read
jobs:
  preflight:
    runs-on: ubuntu-latest
YAML
expect_validator_failure "extra workflow permission scope"   validate_workflow_permissions "$extra_workflow_scope"

inline_workflow_permissions="$fixture_dir/inline-workflow-permissions.yml"
cat >"$inline_workflow_permissions" <<'YAML'
name: WhatsApp webhook production lane fixture
on:
  workflow_dispatch:
    inputs:
      deploy:
        type: boolean
permissions: write-all
jobs:
  preflight:
    runs-on: ubuntu-latest
YAML
expect_validator_failure "inline workflow write-all permissions"   validate_workflow_permissions "$inline_workflow_permissions"

echo "WhatsApp webhook production release governance regression passed."

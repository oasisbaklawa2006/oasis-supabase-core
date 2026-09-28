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

deno_order_ok="$fixture_dir/deno-order-ok.yml"
cat >"$deno_order_ok" <<'YAML'
jobs:
  preflight:
    steps:
      - name: Set up Deno for executable webhook recertification
        uses: denoland/setup-deno@22d081ff2d3a40755e97629de92e3bcbfa7cf2ed
        with:
          deno-version: v2.x
      - name: Re-run webhook and Edge governance
        run: |
          bash scripts/check-whatsapp-webhook-recertification.sh
  deploy:
    runs-on: ubuntu-latest
YAML
require_job_order "$deno_order_ok" "preflight" \
  'uses: denoland/setup-deno@22d081ff2d3a40755e97629de92e3bcbfa7cf2ed' \
  'bash scripts/check-whatsapp-webhook-recertification.sh' \
  "Deno setup before executable webhook recertification"

deno_order_bad="$fixture_dir/deno-order-bad.yml"
cat >"$deno_order_bad" <<'YAML'
jobs:
  preflight:
    steps:
      - name: Re-run webhook and Edge governance
        run: |
          bash scripts/check-whatsapp-webhook-recertification.sh
      - name: Set up Deno for executable webhook recertification
        uses: denoland/setup-deno@22d081ff2d3a40755e97629de92e3bcbfa7cf2ed
        with:
          deno-version: v2.x
  deploy:
    runs-on: ubuntu-latest
YAML
expect_validator_failure "Deno setup after webhook recertification" \
  require_job_order "$deno_order_bad" "preflight" \
    'uses: denoland/setup-deno@22d081ff2d3a40755e97629de92e3bcbfa7cf2ed' \
    'bash scripts/check-whatsapp-webhook-recertification.sh' \
    "Deno setup before executable webhook recertification"

crlf_headers="$fixture_dir/crlf-headers.txt"
printf 'cache-control: no-store\r\nx-content-type-options: nosniff\r\n' >"$crlf_headers"
grep -Eiq '^cache-control:[[:space:]]*no-store[[:space:]]*$' "$crlf_headers"
grep -Eiq '^x-content-type-options:[[:space:]]*nosniff[[:space:]]*$' "$crlf_headers"
if grep -Eiq '^cache-control:[[:space:]]*no-store\r?$' "$crlf_headers"; then
  echo "Broken literal-r matcher unexpectedly accepted CRLF header" >&2
  exit 1
fi

echo "WhatsApp webhook production release governance regression passed."

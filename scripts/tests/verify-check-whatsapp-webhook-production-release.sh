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

release_workflow=".github/workflows/whatsapp-webhook-production-release.yml"
rollback_v168_workflow=".github/workflows/whatsapp-webhook-production-rollback-v168.yml"
rollback_v173_workflow=".github/workflows/whatsapp-webhook-production-rollback-v173.yml"
rollback_v174_workflow=".github/workflows/whatsapp-webhook-production-rollback-v174.yml"
rollback_v175_workflow=".github/workflows/whatsapp-webhook-production-rollback-v175.yml"

# Active lane: the forward release captures live v175 source; the independently approved v175 rollback restores only that captured source.
for workflow in "$release_workflow" "$rollback_v175_workflow"; do
  if grep -Fq 'click2apiWebhookAuth.ts' "$workflow"; then
    echo "Legacy rollback dependency filename assertion reintroduced in $workflow" >&2
    exit 1
  fi
  grep -Fq 'whatsapp-webhook-predeploy-v175-source-manifest.json' "$workflow"
  grep -Fq 'ROLLBACK_SOURCE_CLOSURE_SHA256' "$workflow"
  grep -Fq 'whatsapp-webhook-predeploy-v175-archive-files.txt' "$workflow"
  if grep -Eq 'predeploy-v173|predeploy-v174' "$workflow"; then
    echo "Stale pre-v175 rollback capture name reintroduced in $workflow" >&2
    exit 1
  fi
  if grep -E 'tar -tzf .*\|[[:space:]]*grep' "$workflow" \
      | grep -E 'grep([[:space:]]+-[^[:space:]]*)*[[:space:]]+-[^[:space:]]*q' >/dev/null; then
    echo "SIGPIPE-prone tar archive membership check reintroduced in $workflow" >&2
    exit 1
  fi
done


# Historical v174 lane is immutable and must remain rollback-capable for its original release.
for workflow in "$rollback_v174_workflow"; do
  if grep -Fq 'click2apiWebhookAuth.ts' "$workflow"; then
    echo "Legacy v174 rollback dependency filename assertion reintroduced in $workflow" >&2
    exit 1
  fi
  grep -Fq 'whatsapp-webhook-predeploy-v174-source-manifest.json' "$workflow"
  grep -Fq 'ROLLBACK_SOURCE_CLOSURE_SHA256' "$workflow"
  grep -Fq 'whatsapp-webhook-predeploy-v174-archive-files.txt' "$workflow"
done

# Historical lane: the v173 rollback keeps its own v173 capture names untouched.
for workflow in "$rollback_v173_workflow"; do
  if grep -Fq 'click2apiWebhookAuth.ts' "$workflow"; then
    echo "Legacy v173 rollback dependency filename assertion reintroduced in $workflow" >&2
    exit 1
  fi
  grep -Fq 'whatsapp-webhook-predeploy-v173-source-manifest.json' "$workflow"
  grep -Fq 'ROLLBACK_SOURCE_CLOSURE_SHA256' "$workflow"
  grep -Fq 'whatsapp-webhook-predeploy-v173-archive-files.txt' "$workflow"
  if grep -E 'tar -tzf .*\|[[:space:]]*grep' "$workflow" \
      | grep -E 'grep([[:space:]]+-[^[:space:]]*)*[[:space:]]+-[^[:space:]]*q' >/dev/null; then
    echo "SIGPIPE-prone tar archive membership check reintroduced in $workflow" >&2
    exit 1
  fi
done

for workflow in "$rollback_v168_workflow"; do
  if grep -Fq 'click2apiWebhookAuth.ts' "$workflow"; then
    echo "Legacy v168 rollback dependency filename assertion reintroduced in $workflow" >&2
    exit 1
  fi
  grep -Fq 'whatsapp-webhook-predeploy-v168-source-manifest.json' "$workflow"
  grep -Fq 'ROLLBACK_SOURCE_CLOSURE_SHA256' "$workflow"
  grep -Fq 'whatsapp-webhook-predeploy-v168-archive-files.txt' "$workflow"
  if grep -E 'tar -tzf .*\|[[:space:]]*grep' "$workflow" \
      | grep -E 'grep([[:space:]]+-[^[:space:]]*)*[[:space:]]+-[^[:space:]]*q' >/dev/null; then
    echo "SIGPIPE-prone tar archive membership check reintroduced in $workflow" >&2
    exit 1
  fi
done

# Negative cases: the guard primitives reject stale v173/v174 pins and wrong v175 release baselines.
stale_release_fixture="$fixture_dir/stale-release.yml"
cat >"$stale_release_fixture" <<'YAML'
env:
  EXPECTED_LIVE_VERSION: "173"
  EXPECTED_LIVE_BUNDLE_SHA: 53ad71aa519a6a654bf88e8718b08f3a06039b71fa78d28481efd64e1342651c
  DB_PREREQ_RUN_ID: "40356978870"
          tar -C "$rollback_root/supabase" -czf whatsapp-webhook-predeploy-v173.tar.gz functions
YAML
expect_validator_failure "stale v173 live version pin" \
  require_contains "$stale_release_fixture" 'EXPECTED_LIVE_VERSION: "175"' "known live version baseline"
expect_validator_failure "stale v173 live bundle pin" \
  require_contains "$stale_release_fixture" 'EXPECTED_LIVE_BUNDLE_SHA: 7ee2d17f3cc3a55788c061737015d8dc484bdafa4d31709cf3fd853322e980d4' "known live bundle baseline"
expect_validator_failure "stale database prerequisite pin" \
  require_contains "$stale_release_fixture" 'DB_PREREQ_RUN_ID: "40670202741"' "database prerequisite run binding"
expect_validator_failure "stale v173 rollback capture name in forward lane" \
  reject_regex "$stale_release_fixture" 'predeploy-v173|predeploy-v174' "stale v173/v174 capture names in the v175 forward release lane"

loose_rollback_fixture="$fixture_dir/loose-v174-rollback.yml"
cat >"$loose_rollback_fixture" <<'YAML'
            500:app_secret_not_configured|401:signature_missing) ;;
YAML
expect_validator_failure "v174 rollback must not tolerate the v173-only unauthenticated POST profile" \
  reject_regex "$loose_rollback_fixture" 'app_secret_not_configured' "v173-only unauthenticated POST tolerance in the v174 rollback"


# The just-superseded v174 release is likewise invalid as a new forward baseline.
old_v174_fixture="$fixture_dir/old-v174-release.yml"
cat >"$old_v174_fixture" <<'YAML'
env:
  EXPECTED_LIVE_VERSION: "174"
  EXPECTED_LIVE_BUNDLE_SHA: c3fea9d3f817bea59ba5e69b342c44a44d92f1323d3bad171002e06a8a6b8a9e
YAML
expect_validator_failure "prior v174 version is not current v175" \
  require_contains "$old_v174_fixture" 'EXPECTED_LIVE_VERSION: "175"' "current live version"
expect_validator_failure "prior v174 source bundle is not current v175" \
  require_contains "$old_v174_fixture" 'EXPECTED_LIVE_BUNDLE_SHA: 7ee2d17f3cc3a55788c061737015d8dc484bdafa4d31709cf3fd853322e980d4' "current live bundle"

loose_v175_rollback_fixture="$fixture_dir/loose-v175-rollback.yml"
cat >"$loose_v175_rollback_fixture" <<'YAML'
            500:app_secret_not_configured|401:signature_missing) ;;
YAML
expect_validator_failure "v175 rollback cannot tolerate older unsigned POST profile" \
  reject_regex "$loose_v175_rollback_fixture" 'app_secret_not_configured' "forbidden unsigned status profile"

echo "WhatsApp webhook production release governance regression passed."

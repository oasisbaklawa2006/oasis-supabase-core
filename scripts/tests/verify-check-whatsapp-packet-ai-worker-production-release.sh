#!/usr/bin/env bash
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

bash scripts/check-whatsapp-packet-ai-worker-production-release.sh

# Test actual validator behavior against isolated workflow mutations.
source <(sed -n '1,/^require_exact_count() {/p' scripts/check-whatsapp-webhook-production-release.sh | sed '$d')
workflow=".github/workflows/whatsapp-packet-ai-worker-production-release.yml"
tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT
mkdir -p "$tmpdir/.github/workflows"
fixture="$tmpdir/.github/workflows/whatsapp-packet-ai-worker-production-release.yml"
cp "$workflow" "$fixture"
# The validator checks the canonical relative path: run in isolated root.
(
  cd "$tmpdir"
  validate_workflow_permissions ".github/workflows/whatsapp-packet-ai-worker-production-release.yml"
)
# Mutate the isolated fixture and require fail-closed rejection.
reject_fixture() {
  local label="$1"
  if (cd "$tmpdir" && validate_workflow_permissions ".github/workflows/whatsapp-packet-ai-worker-production-release.yml") >/dev/null 2>&1; then
    echo "FAIL: accepted invalid worker permissions: $label" >&2
    exit 1
  fi
  cp "$workflow" "$fixture"
}
sed -i '/^      attestations: write$/a\      contents: write' "$fixture"
reject_fixture "extra scope"
sed -i 's/^      id-token: write$/      id-token: read/' "$fixture"
reject_fixture "incorrect permission level"
sed -i '/^  deploy:$/i\  injected:\n    permissions:\n      id-token: write' "$fixture"
reject_fixture "override on other job"
sed -i '/^      attestations: write$/d' "$fixture"
reject_fixture "missing signing scope"
echo "WhatsApp packet AI worker production release governance regression passed."

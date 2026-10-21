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
echo "WhatsApp packet AI worker production release governance regression passed."

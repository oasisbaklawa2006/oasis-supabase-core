#!/usr/bin/env bash
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

bash scripts/check-whatsapp-packet-ai-worker-production-release.sh

# Exercise the actual validator with an isolated worker workflow fixture.
source <(sed -n '1,/^require_exact_count() {/p' scripts/check-whatsapp-webhook-production-release.sh | sed '$d')
original=".github/workflows/whatsapp-packet-ai-worker-production-release.yml"
tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT
cp "$original" "$tmpdir/worker.yml"
# The validator binds the canonical path; test via a temporary working directory
# with the same relative workflow name.
mkdir -p "$tmpdir/.github/workflows"
cp "$original" "$tmpdir/.github/workflows/whatsapp-packet-ai-worker-production-release.yml"
fixture="$tmpdir/.github/workflows/whatsapp-packet-ai-worker-production-release.yml"
validate_workflow_permissions "$original"
echo "WhatsApp packet AI worker production release governance regression passed."

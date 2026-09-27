#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$root"

first="$(mktemp)"
second="$(mktemp)"
trap 'rm -f "$first" "$second"' EXIT

python3 scripts/edge-function-source-manifest.py   supabase/functions whatsapp-webhook --output "$first"
python3 scripts/edge-function-source-manifest.py   supabase/functions whatsapp-webhook --output "$second"

cmp -s "$first" "$second"
jq -e '.function == "whatsapp-webhook"' "$first" >/dev/null
jq -e '.entrypoint == "whatsapp-webhook/index.ts"' "$first" >/dev/null
jq -e '.fileCount > 5' "$first" >/dev/null
jq -e '.closureSha256 | test("^[0-9a-f]{64}$")' "$first" >/dev/null
jq -e '.files | any(.path == "_shared/whatsappWebhookBoundary.ts")' "$first" >/dev/null
jq -e '.files | any(.path == "_shared/whatsappOperatorReplyStatus.ts")' "$first" >/dev/null

echo "Edge Function source manifest regression passed."

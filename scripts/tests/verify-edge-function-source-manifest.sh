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

fixture_root="$(mktemp -d)"
trap 'rm -f "$first" "$second"; rm -rf "$fixture_root"' EXIT
mkdir -p "$fixture_root/functions/demo"
cat > "$fixture_root/functions/demo/index.ts" <<'TS'
import { hidden } from "@shared/hidden";
console.log(hidden);
TS

if python3 scripts/edge-function-source-manifest.py   "$fixture_root/functions" demo >/dev/null 2>&1; then
  echo "Expected hidden import-map alias to fail source attestation" >&2
  exit 1
fi

echo "Edge Function source manifest regression passed."

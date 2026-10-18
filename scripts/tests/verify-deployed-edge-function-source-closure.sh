#!/usr/bin/env bash
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

checkout="$tmpdir/checkout/supabase/functions"
download="$tmpdir/download/supabase/functions"
mkdir -p "$checkout/whatsapp-packet-ai-worker" "$checkout/whatsapp-content-interpret" \
  "$checkout/_shared" "$download/whatsapp-packet-ai-worker" "$download/_shared" \
  "$download/whatsapp-content-interpret"

cp supabase/functions/whatsapp-packet-ai-worker/index.ts "$checkout/whatsapp-packet-ai-worker/"
cp supabase/functions/whatsapp-content-interpret/sanitize.ts "$checkout/whatsapp-content-interpret/"
cp supabase/functions/whatsapp-content-interpret/types.ts "$checkout/whatsapp-content-interpret/"
cp supabase/functions/_shared/geminiProvider.ts "$checkout/_shared/"
cp supabase/functions/_shared/integrationRetryContract.ts "$checkout/_shared/"
cp supabase/functions/_shared/whatsappGovernedMediaFetch.ts "$checkout/_shared/"

python3 scripts/edge-function-source-manifest.py \
  "$checkout" whatsapp-packet-ai-worker \
  --output "$tmpdir/target-source-manifest.json"

# Simulate API download omitting types.ts only.
cp "$checkout/whatsapp-packet-ai-worker/index.ts" "$download/whatsapp-packet-ai-worker/"
cp "$checkout/whatsapp-content-interpret/sanitize.ts" "$download/whatsapp-content-interpret/"
cp "$checkout/_shared/"*.ts "$download/_shared/"

bash scripts/verify-deployed-edge-function-source-closure.sh \
  "$checkout" "$download" whatsapp-packet-ai-worker \
  "$tmpdir/target-source-manifest.json" "$tmpdir/live-source-manifest.json"

echo "verify-deployed-edge-function-source-closure regression passed."

#!/usr/bin/env bash
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

functions_root="$tmpdir/supabase/functions"
mkdir -p \
  "$functions_root/whatsapp-packet-ai-worker" \
  "$functions_root/whatsapp-content-interpret" \
  "$functions_root/_shared"

cp supabase/functions/whatsapp-packet-ai-worker/index.ts \
  "$functions_root/whatsapp-packet-ai-worker/"
cp supabase/functions/whatsapp-content-interpret/sanitize.ts \
  "$functions_root/whatsapp-content-interpret/"
cp supabase/functions/_shared/geminiProvider.ts "$functions_root/_shared/"
cp supabase/functions/_shared/whatsappGovernedMediaFetch.ts "$functions_root/_shared/"

bundle_sha="c073d30b1f6b64389ef9967aa7e79bd79e975de06af2b1bd46b2638dff645e09"
jq -n --arg bundle "$bundle_sha" '{ezbr_sha256:$bundle,version:18}' \
  >"$tmpdir/live-function-before.json"

manifest="$tmpdir/live-v18-source-manifest.json"
tarball="$tmpdir/whatsapp-packet-ai-worker-predeploy-v18.tar.gz"

bash scripts/capture-live-edge-function-rollback-artifacts.sh \
  "$functions_root" whatsapp-packet-ai-worker \
  "$tmpdir/live-function-before.json" "$manifest" "$tarball"

jq -e \
  --arg bundle "$bundle_sha" \
  '.captureMode == "supabase_management_api_bundle_sha"
   and .closureSha256 == $bundle
   and .bundleSha256 == $bundle
   and .downloadedFileCount == 4' \
  "$manifest" >/dev/null

test -s "$tarball"
tar -tzf "$tarball" | grep -Fq 'functions/whatsapp-packet-ai-worker/index.ts'

echo "capture-live-edge-function-rollback-artifacts regression passed."

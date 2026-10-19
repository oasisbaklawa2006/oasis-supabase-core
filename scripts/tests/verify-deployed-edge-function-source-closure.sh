#!/usr/bin/env bash
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

checkout="$tmpdir/checkout/supabase/functions"
api="$tmpdir/api/supabase/functions"
prov="$tmpdir/prov/supabase/functions"
mkdir -p "$checkout/whatsapp-packet-ai-worker" "$checkout/whatsapp-content-interpret" \
  "$checkout/_shared" "$api/whatsapp-packet-ai-worker" "$api/_shared" \
  "$api/whatsapp-content-interpret" "$prov/whatsapp-packet-ai-worker" \
  "$prov/_shared" "$prov/whatsapp-content-interpret"

cp supabase/functions/whatsapp-packet-ai-worker/index.ts "$checkout/whatsapp-packet-ai-worker/"
cp supabase/functions/whatsapp-content-interpret/sanitize.ts "$checkout/whatsapp-content-interpret/"
cp supabase/functions/whatsapp-content-interpret/types.ts "$checkout/whatsapp-content-interpret/"
cp supabase/functions/_shared/geminiProvider.ts "$checkout/_shared/"
cp supabase/functions/_shared/integrationRetryContract.ts "$checkout/_shared/"
cp supabase/functions/_shared/whatsappGovernedMediaFetch.ts "$checkout/_shared/"

python3 scripts/edge-function-source-manifest.py \
  "$checkout" whatsapp-packet-ai-worker \
  --output "$tmpdir/target-source-manifest.json"

# --- PASS: complete API download ---
cp -a "$checkout/." "$api/"
bash scripts/verify-deployed-edge-function-source-closure.sh \
  "$api" whatsapp-packet-ai-worker \
  "$tmpdir/target-source-manifest.json" "$tmpdir/live-complete.json"

# --- INDETERMINATE: API omits types.ts without provenance ---
rm -rf "$api"
mkdir -p "$api/whatsapp-packet-ai-worker" "$api/whatsapp-content-interpret" "$api/_shared"
cp "$checkout/whatsapp-packet-ai-worker/index.ts" "$api/whatsapp-packet-ai-worker/"
cp "$checkout/whatsapp-content-interpret/sanitize.ts" "$api/whatsapp-content-interpret/"
cp "$checkout/_shared/"*.ts "$api/_shared/"
set +e
bash scripts/verify-deployed-edge-function-source-closure.sh \
  "$api" whatsapp-packet-ai-worker \
  "$tmpdir/target-source-manifest.json" "$tmpdir/live-partial.json"
rc=$?
set -e
[[ "$rc" -eq 3 ]] || {
  echo "expected INDETERMINATE (exit 3) for omitted types.ts without provenance, got $rc" >&2
  exit 1
}

# --- PASS: omitted types.ts satisfied from independent provenance tree ---
cp "$checkout/whatsapp-content-interpret/types.ts" "$prov/whatsapp-content-interpret/"
bash scripts/verify-deployed-edge-function-source-closure.sh \
  "$api" whatsapp-packet-ai-worker \
  "$tmpdir/target-source-manifest.json" "$tmpdir/live-provenance.json" \
  "$prov"

# --- FAIL: altered downloaded dependency ---
echo '// tamper' >> "$api/whatsapp-packet-ai-worker/index.ts"
set +e
bash scripts/verify-deployed-edge-function-source-closure.sh \
  "$api" whatsapp-packet-ai-worker \
  "$tmpdir/target-source-manifest.json" "$tmpdir/live-bad.json" \
  "$prov"
rc=$?
set -e
[[ "$rc" -eq 1 ]] || {
  echo "expected FAIL (exit 1) for altered download, got $rc" >&2
  exit 1
}

# --- FAIL: wrong provenance bytes ---
rm -rf "$api" "$prov"
mkdir -p "$api/whatsapp-packet-ai-worker" "$api/whatsapp-content-interpret" "$api/_shared"
mkdir -p "$prov/whatsapp-content-interpret"
cp "$checkout/whatsapp-packet-ai-worker/index.ts" "$api/whatsapp-packet-ai-worker/"
cp "$checkout/whatsapp-content-interpret/sanitize.ts" "$api/whatsapp-content-interpret/"
cp "$checkout/_shared/"*.ts "$api/_shared/"
echo 'export type SourceKind = "tampered";' > "$prov/whatsapp-content-interpret/types.ts"
set +e
bash scripts/verify-deployed-edge-function-source-closure.sh \
  "$api" whatsapp-packet-ai-worker \
  "$tmpdir/target-source-manifest.json" "$tmpdir/live-bad-prov.json" \
  "$prov"
rc=$?
set -e
[[ "$rc" -eq 1 ]] || {
  echo "expected FAIL (exit 1) for provenance mismatch, got $rc" >&2
  exit 1
}

echo "verify-deployed-edge-function-source-closure regression passed."

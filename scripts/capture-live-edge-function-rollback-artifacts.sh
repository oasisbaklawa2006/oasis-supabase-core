#!/usr/bin/env bash
# Build rollback tarball + manifest for a live Edge Function download tree.
# Supabase `functions download --use-api` can omit source files that remain bundled
# at runtime; when the deterministic source manifest cannot be resolved, fall back
# to the already-pinned Management API bundle SHA from live-function metadata.
set -euo pipefail

usage() {
  echo "usage: $0 <functions_root> <function_name> <live_metadata.json> <manifest_out> <tarball_out>" >&2
}

if [[ $# -ne 5 ]]; then
  usage
  exit 2
fi

functions_root="$1"
function_name="$2"
live_metadata_json="$3"
manifest_out="$4"
tarball_out="$5"

cd "$(git rev-parse --show-toplevel)"

test -d "$functions_root/$function_name"
test -f "$live_metadata_json"

bundle_sha="$(jq -er '.ezbr_sha256' "$live_metadata_json")"
[[ "$bundle_sha" =~ ^[0-9a-f]{64}$ ]]

if python3 scripts/edge-function-source-manifest.py \
  "$functions_root" "$function_name" \
  --output "$manifest_out"; then
  jq -e \
    --arg fn "$function_name" \
    '.function == $fn and (.closureSha256 | test("^[0-9a-f]{64}$"))' \
    "$manifest_out" >/dev/null
else
  mapfile -t rel_paths < <(
    find "$functions_root" -type f \
      | sed "s#^${functions_root%/}/##" \
      | LC_ALL=C sort
  )
  files_json="$(python3 - "$functions_root" "${rel_paths[@]}" <<'PY'
import hashlib
import json
import sys
from pathlib import Path

root = Path(sys.argv[1])
paths = sys.argv[2:]
files = []
lines = []
for rel in paths:
    path = root / rel
    digest = hashlib.sha256(path.read_bytes()).hexdigest()
    size = path.stat().st_size
    files.append({"path": rel, "sha256": digest, "size": size})
    lines.append(f"{digest}  {size}  {rel}\n")
partial_closure = hashlib.sha256("".join(lines).encode("utf-8")).hexdigest()
print(json.dumps({"files": files, "partialClosureSha256": partial_closure}))
PY
)"
  jq -n \
    --arg fn "$function_name" \
    --arg bundle "$bundle_sha" \
    --argjson version "$(jq -r '.version' "$live_metadata_json")" \
    --argjson files "$(jq -c '.files' <<<"$files_json")" \
    --arg partial "$(jq -r '.partialClosureSha256' <<<"$files_json")" \
    '{
      function: $fn,
      entrypoint: ($fn + "/index.ts"),
      captureMode: "supabase_management_api_bundle_sha",
      bundleSha256: $bundle,
      closureSha256: $bundle,
      liveVersion: ($version | tonumber),
      downloadedFileCount: ($files | length),
      partialDownloadClosureSha256: $partial,
      files: $files
    }' >"$manifest_out"
  jq -e \
    --arg fn "$function_name" \
    --arg bundle "$bundle_sha" \
    '.function == $fn
     and .captureMode == "supabase_management_api_bundle_sha"
     and .closureSha256 == $bundle
     and (.files | length) > 0' \
    "$manifest_out" >/dev/null
fi

tarball_parent="$(dirname "$tarball_out")"
mkdir -p "$tarball_parent"
supabase_parent="$(cd "$functions_root/.." && pwd)"
tar -C "$supabase_parent" -czf "$tarball_out" functions
test -s "$tarball_out"

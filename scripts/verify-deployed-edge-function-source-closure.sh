#!/usr/bin/env bash
# Verify a live Edge Function download matches the reviewed target manifest.
# Supabase `functions download --use-api` may omit source files that are still
# part of the deployed bundle; hydrate missing paths from the approved checkout
# only when on-disk bytes match the reviewed target SHA-256.
set -euo pipefail

usage() {
  echo "usage: $0 <checkout_functions_root> <download_functions_root> <function_name> <target_manifest.json> <live_manifest_out>" >&2
}

if [[ $# -ne 5 ]]; then
  usage
  exit 2
fi

checkout_functions_root="$1"
download_functions_root="$2"
function_name="$3"
target_manifest="$4"
live_manifest_out="$5"

cd "$(git rev-parse --show-toplevel)"

test -d "$checkout_functions_root/$function_name"
test -d "$download_functions_root/$function_name"
test -f "$target_manifest"

sha256_file() {
  sha256sum "$1" | awk '{print $1}'
}

while IFS= read -r file_json; do
  rel="$(jq -r '.path' <<<"$file_json")"
  expected="$(jq -r '.sha256' <<<"$file_json")"
  [[ "$expected" =~ ^[0-9a-f]{64}$ ]]

  dest="$download_functions_root/$rel"
  mkdir -p "$(dirname "$dest")"

  if [[ -f "$dest" ]]; then
    actual="$(sha256_file "$dest")"
    if [[ "$actual" != "$expected" ]]; then
      echo "DEPLOYED_SOURCE_MISMATCH: $rel (download bytes do not match reviewed target)" >&2
      exit 1
    fi
    continue
  fi

  src="$checkout_functions_root/$rel"
  if [[ ! -f "$src" ]]; then
    echo "DEPLOYED_SOURCE_MISSING: $rel (absent from download and checkout)" >&2
    exit 1
  fi
  actual="$(sha256_file "$src")"
  if [[ "$actual" != "$expected" ]]; then
    echo "DEPLOYED_SOURCE_MISMATCH: $rel (checkout bytes do not match reviewed target)" >&2
    exit 1
  fi
  cp "$src" "$dest"
done < <(jq -c '.files[]' "$target_manifest")

python3 scripts/edge-function-source-manifest.py \
  "$download_functions_root" "$function_name" \
  --output "$live_manifest_out"

target_closure="$(jq -r '.closureSha256' "$target_manifest")"
live_closure="$(jq -r '.closureSha256' "$live_manifest_out")"
if [[ "$target_closure" != "$live_closure" ]]; then
  diff -u "$target_manifest" "$live_manifest_out" || true
  echo "DEPLOYED_SOURCE_CLOSURE_MISMATCH: expected $target_closure got $live_closure" >&2
  exit 1
fi

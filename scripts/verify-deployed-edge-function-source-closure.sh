#!/usr/bin/env bash
# Verify a live Edge Function download matches the reviewed target manifest.
#
# Files present in the API download must match the reviewed SHA-256 bytes exactly.
# Files omitted from the API download may only be satisfied from an optional
# independent bundle-provenance tree (for example CLI Docker unbundle). Checkout
# bytes are never used as live-source evidence.
#
# Exit codes:
#   0 — full source closure verified
#   1 — fail closed (byte mismatch, missing provenance file with wrong hash, etc.)
#   3 — indeterminate (omitted download paths without independent provenance)
set -euo pipefail

usage() {
  echo "usage: $0 <api_download_functions_root> <function_name> <target_manifest.json> <live_manifest_out> [bundle_provenance_functions_root]" >&2
}

if [[ $# -lt 4 || $# -gt 5 ]]; then
  usage
  exit 2
fi

api_download_root="$1"
function_name="$2"
target_manifest="$3"
live_manifest_out="$4"
bundle_provenance_root="${5:-}"

cd "$(git rev-parse --show-toplevel)"

test -d "$api_download_root/$function_name"
test -f "$target_manifest"
if [[ -n "$bundle_provenance_root" ]]; then
  test -d "$bundle_provenance_root/$function_name"
fi

sha256_file() {
  sha256sum "$1" | awk '{print $1}'
}

merged_root="$(mktemp -d)"
trap 'rm -rf "$merged_root"' EXIT
mkdir -p "$merged_root"
cp -a "$api_download_root/." "$merged_root/"

omitted_without_provenance=()

while IFS= read -r file_json; do
  rel="$(jq -r '.path' <<<"$file_json")"
  expected="$(jq -r '.sha256' <<<"$file_json")"
  [[ "$expected" =~ ^[0-9a-f]{64}$ ]]

  api_path="$api_download_root/$rel"
  merged_path="$merged_root/$rel"

  if [[ -f "$api_path" ]]; then
    actual="$(sha256_file "$api_path")"
    if [[ "$actual" != "$expected" ]]; then
      echo "DEPLOYED_SOURCE_MISMATCH: $rel (API download bytes do not match reviewed target)" >&2
      exit 1
    fi
    continue
  fi

  if [[ -z "$bundle_provenance_root" ]]; then
    omitted_without_provenance+=("$rel")
    continue
  fi

  prov_path="$bundle_provenance_root/$rel"
  if [[ ! -f "$prov_path" ]]; then
    omitted_without_provenance+=("$rel")
    continue
  fi
  actual="$(sha256_file "$prov_path")"
  if [[ "$actual" != "$expected" ]]; then
    echo "DEPLOYED_SOURCE_MISMATCH: $rel (bundle provenance bytes do not match reviewed target)" >&2
    exit 1
  fi
  mkdir -p "$(dirname "$merged_path")"
  cp "$prov_path" "$merged_path"
done < <(jq -c '.files[]' "$target_manifest")

if [[ ${#omitted_without_provenance[@]} -gt 0 ]]; then
  printf 'DEPLOYED_SOURCE_INDETERMINATE: omitted from API download without independent provenance:\n' >&2
  printf '  %s\n' "${omitted_without_provenance[@]}" >&2
  exit 3
fi

python3 scripts/edge-function-source-manifest.py \
  "$merged_root" "$function_name" \
  --output "$live_manifest_out"

target_closure="$(jq -r '.closureSha256' "$target_manifest")"
live_closure="$(jq -r '.closureSha256' "$live_manifest_out")"
if [[ "$target_closure" != "$live_closure" ]]; then
  diff -u "$target_manifest" "$live_manifest_out" || true
  echo "DEPLOYED_SOURCE_CLOSURE_MISMATCH: expected $target_closure got $live_closure" >&2
  exit 1
fi

echo "DEPLOYED_SOURCE_CLOSURE_VERIFIED"

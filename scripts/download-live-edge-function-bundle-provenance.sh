#!/usr/bin/env bash
# Download live Edge Function sources via the Supabase CLI Docker unbundle path.
# This is independent of the git checkout and of `functions download --use-api`.
set -euo pipefail

usage() {
  echo "usage: $0 <project_ref> <function_name> <live_metadata.json> <out_functions_root>" >&2
}

if [[ $# -ne 4 ]]; then
  usage
  exit 2
fi

project_ref="$1"
function_name="$2"
live_metadata_json="$3"
out_functions_root="$4"

cd "$(git rev-parse --show-toplevel)"

test -f "$live_metadata_json"
[[ "$project_ref" =~ ^[a-z0-9]+$ ]]

expected_bundle="$(jq -er '.ezbr_sha256' "$live_metadata_json")"
[[ "$expected_bundle" =~ ^[0-9a-f]{64}$ ]]

if ! command -v docker >/dev/null 2>&1; then
  echo "BUNDLE_PROVENANCE_DOCKER_UNAVAILABLE" >&2
  exit 4
fi

if ! docker info >/dev/null 2>&1; then
  echo "BUNDLE_PROVENANCE_DOCKER_UNAVAILABLE" >&2
  exit 4
fi

work_root="$(mktemp -d)"
trap 'rm -rf "$work_root"' EXIT

(
  cd "$work_root"
  supabase functions download "$function_name" \
    --project-ref "$project_ref"
)

src="$work_root/supabase/functions"
test -d "$src/$function_name"

mkdir -p "$out_functions_root"
cp -a "$src/." "$out_functions_root/"

# Re-bind to the same Management API bundle digest we certified before download.
fresh_meta="$(mktemp)"
trap 'rm -rf "$work_root" "$fresh_meta"' EXIT
curl -fsS \
  -H "Authorization: Bearer ${SUPABASE_ACCESS_TOKEN:?SUPABASE_ACCESS_TOKEN required}" \
  "https://api.supabase.com/v1/projects/${project_ref}/functions/${function_name}" \
  -o "$fresh_meta"
actual_bundle="$(jq -er '.ezbr_sha256' "$fresh_meta")"
if [[ "$actual_bundle" != "$expected_bundle" ]]; then
  echo "BUNDLE_PROVENANCE_LIVE_DRIFT: expected $expected_bundle got $actual_bundle" >&2
  exit 1
fi

echo "BUNDLE_PROVENANCE_DOWNLOAD_OK"

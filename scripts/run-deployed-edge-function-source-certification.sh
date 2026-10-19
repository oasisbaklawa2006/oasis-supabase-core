#!/usr/bin/env bash
# Orchestrate API download + optional Docker bundle provenance + closure verify.
# Writes source-certification-status.txt (VERIFIED|INDETERMINATE|FAILED).
set -euo pipefail

usage() {
  echo "usage: $0 <project_ref> <function_name> <target_manifest.json> <live_metadata.json> <live_manifest_out> <status_out>" >&2
}

if [[ $# -ne 6 ]]; then
  usage
  exit 2
fi

project_ref="$1"
function_name="$2"
target_manifest="$3"
live_metadata_json="$4"
live_manifest_out="$5"
status_out="$6"

cd "$(git rev-parse --show-toplevel)"

api_root="$(mktemp -d)"
prov_root="$(mktemp -d)"
trap 'rm -rf "$api_root" "$prov_root"' EXIT

api_work="$(mktemp -d)"
(
  cd "$api_work"
  supabase functions download "$function_name" \
    --project-ref "$project_ref" \
    --use-api
)
mkdir -p "$api_root"
cp -a "$api_work/supabase/functions/." "$api_root/"
rm -rf "$api_work"

# Keep the independent download's diagnostic evidence. It must never be
# interpreted as source verification unless the download actually succeeds.
provenance_available=false
provenance_log="bundle-provenance-diagnostics.txt"
if bash scripts/download-live-edge-function-bundle-provenance.sh \
  "$project_ref" \
  "$function_name" \
  "$live_metadata_json" \
  "$prov_root" >"$provenance_log" 2>&1; then
  provenance_available=true
  echo "BUNDLE_PROVENANCE_AVAILABLE"
else
  provenance_rc=$?
  echo "BUNDLE_PROVENANCE_UNAVAILABLE: exit=$provenance_rc"
  cat "$provenance_log"
fi

set +e
if [[ "$provenance_available" == true ]]; then
  bash scripts/verify-deployed-edge-function-source-closure.sh \
    "$api_root" \
    "$function_name" \
    "$target_manifest" \
    "$live_manifest_out" \
    "$prov_root"
else
  bash scripts/verify-deployed-edge-function-source-closure.sh \
    "$api_root" \
    "$function_name" \
    "$target_manifest" \
    "$live_manifest_out"
fi
verify_rc=$?
set -e

case "$verify_rc" in
  0)
    printf '%s\n' VERIFIED >"$status_out"
    ;;
  3)
    printf '%s\n' INDETERMINATE >"$status_out"
    exit 0
    ;;
  *)
    printf '%s\n' FAILED >"$status_out"
    exit "$verify_rc"
    ;;
esac

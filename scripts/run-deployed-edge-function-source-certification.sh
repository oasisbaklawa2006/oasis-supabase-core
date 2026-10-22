#!/usr/bin/env bash
# Orchestrate API download + optional Docker bundle provenance + closure verify
# + optional deployment-time attestation.
# Writes source-certification-status.txt (VERIFIED|VERIFIED_BY_ATTESTATION|
# INDETERMINATE|FAILED).
set -euo pipefail

usage() {
  echo "usage: $0 <project_ref> <function_name> <target_manifest.json> <live_metadata.json> <live_manifest_out> <status_out> [repo release_sha source_deploy_run_id]" >&2
}

if [[ $# -ne 6 && $# -ne 8 && $# -ne 9 ]]; then
  usage
  exit 2
fi

project_ref="$1"
function_name="$2"
target_manifest="$3"
live_metadata_json="$4"
live_manifest_out="$5"
status_out="$6"
repo="${7:-}"
release_sha="${8:-}"
source_deploy_run_id="${9:-}"

# Nested tools come from this script's own checkout (the reviewed workflow
# revision in certify-existing), never from the caller's working tree, which
# may be an older pinned release checkout. Inputs stay relative to the caller.
tools_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

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
if bash "$tools_dir/download-live-edge-function-bundle-provenance.sh" \
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
  bash "$tools_dir/verify-deployed-edge-function-source-closure.sh" \
    "$api_root" \
    "$function_name" \
    "$target_manifest" \
    "$live_manifest_out" \
    "$prov_root"
else
  bash "$tools_dir/verify-deployed-edge-function-source-closure.sh" \
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
    # Independent post-hoc recovery left the closure incomplete (e.g. a
    # type-only import erased by the bundler). That evidence class is
    # structurally unable to recover such files; consult the distinct
    # deployment-time attestation evidence class before giving up.
    if [[ -n "$repo" && -n "$release_sha" ]]; then
      if ! deployed_bundle_sha256="$(jq -er '.ezbr_sha256' "$live_metadata_json")"; then
        echo "DEPLOYED_SOURCE_INDETERMINATE: attestation fallback could not read the deployed bundle digest" >&2
        printf '%s\n' FAILED >"$status_out"
        exit 1
      fi
      set +e
      bash "$tools_dir/verify-worker-deployment-source-attestation.sh" \
        "$repo" "$release_sha" "$project_ref" "$function_name" \
        "$target_manifest" "$deployed_bundle_sha256" \
        "$source_deploy_run_id"
      attestation_rc=$?
      set -e
      if [[ "$attestation_rc" -eq 0 ]]; then
        printf '%s\n' VERIFIED_BY_ATTESTATION >"$status_out"
        exit 0
      elif [[ "$attestation_rc" -ne 3 ]]; then
        printf '%s\n' FAILED >"$status_out"
        exit 1
      fi
    fi
    printf '%s\n' INDETERMINATE >"$status_out"
    exit 0
    ;;
  *)
    printf '%s\n' FAILED >"$status_out"
    exit "$verify_rc"
    ;;
esac

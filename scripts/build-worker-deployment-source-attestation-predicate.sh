#!/usr/bin/env bash
# Build the in-toto predicate for the WhatsApp Packet AI Worker deployment-time
# source-closure attestation.
#
# This predicate is the "deployment-time attestation" evidence class: it binds
# the pre-deploy reviewed source-closure hash (computed from the exact checked
# out commit, in the same job, before any upload) to the post-deploy live
# bundle digest returned by the Supabase Management API in that same job.
#
# It does not itself prove anything until it is signed (via `gh attestation
# verify`'s counterpart signing step, e.g. actions/attest) under the running
# job's GitHub Actions OIDC identity and published to GitHub's Attestations
# API. This script only assembles the unsigned predicate body.
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
usage: build-worker-deployment-source-attestation-predicate.sh \
  <release_sha> <project_ref> <function_name> \
  <target_manifest.json> <deployed_bundle_sha256> <output.json>
EOF
}

if [[ $# -ne 6 ]]; then
  usage
  exit 2
fi

release_sha="$1"
project_ref="$2"
function_name="$3"
target_manifest="$4"
deployed_bundle_sha256="$5"
output="$6"

[[ "$release_sha" =~ ^[0-9a-f]{40}$ ]]
[[ "$project_ref" =~ ^[a-z0-9]+$ ]]
[[ "$deployed_bundle_sha256" =~ ^[0-9a-f]{64}$ ]]
test -f "$target_manifest"

source_closure_sha256="$(jq -er '.closureSha256' "$target_manifest")"
[[ "$source_closure_sha256" =~ ^[0-9a-f]{64}$ ]]
manifest_function="$(jq -er '.function' "$target_manifest")"
test "$manifest_function" = "$function_name"

jq -n \
  --arg release_sha "$release_sha" \
  --arg project_ref "$project_ref" \
  --arg function_name "$function_name" \
  --arg source_closure_sha256 "$source_closure_sha256" \
  --arg deployed_bundle_sha256 "$deployed_bundle_sha256" \
  --arg predicate_type "https://appverse.dev/attestations/edge-function-source-closure/v1" \
  '{
    predicateType: $predicate_type,
    predicate: {
      releaseSha: $release_sha,
      supabaseProjectRef: $project_ref,
      function: $function_name,
      reviewedSourceClosureSha256: $source_closure_sha256,
      deployedBundleSha256: $deployed_bundle_sha256
    }
  }' > "$output"

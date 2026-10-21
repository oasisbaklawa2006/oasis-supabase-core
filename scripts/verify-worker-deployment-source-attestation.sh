#!/usr/bin/env bash
# Independently verify a GitHub build-provenance attestation for the deployed
# WhatsApp Packet AI Worker bundle, and check that its predicate matches the
# exact release under certification.
#
# This is a distinct evidence class from both existing recovery paths
# (`functions download --use-api`, CLI Docker unbundle): those read the
# already-built bundle and can never recover a type-erased source file. This
# script instead checks a signed statement produced *before* the bundle was
# built, in the deploying job itself, under that job's GitHub Actions OIDC
# identity.
#
# Trust root: GitHub's Sigstore-backed Artifact Attestations (Fulcio-issued
# certificate bound to the OIDC token of the exact workflow run that produced
# it; Rekor transparency log inclusion). `gh attestation verify` independently
# validates the signature, the certificate's SourceRepositoryURI (must be
# this repository) and the workflow identity -- this script does not
# second-guess that cryptographic verification, it only additionally checks
# that the verified predicate's own fields match the release under test.
#
# Exit codes:
#   0 -- attestation present, signature/identity verified, predicate matches
#   1 -- attestation present but signature invalid, wrong identity, or
#        predicate fields do not match (fail closed)
#   3 -- no attestation found for this digest (treat as no additional
#        evidence, not as a failure -- the caller falls back to whatever the
#        post-hoc recovery path already determined)
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
usage: verify-worker-deployment-source-attestation.sh \
  <owner/repo> <release_sha> <project_ref> <function_name> \
  <expected_source_closure_sha256> <deployed_bundle_sha256>
EOF
}

if [[ $# -ne 6 ]]; then
  usage
  exit 2
fi

repo="$1"
release_sha="$2"
project_ref="$3"
function_name="$4"
expected_source_closure_sha256="$5"
deployed_bundle_sha256="$6"

[[ "$release_sha" =~ ^[0-9a-f]{40}$ ]]
[[ "$expected_source_closure_sha256" =~ ^[0-9a-f]{64}$ ]]
[[ "$deployed_bundle_sha256" =~ ^[0-9a-f]{64}$ ]]
[[ "$repo" == */* ]]
owner="${repo%%/*}"

# Dependency injection point for tests only: production always uses the real
# `gh attestation verify` against GitHub's Sigstore-backed Attestations API.
# Tests substitute a fixture script so this file's own field-comparison logic
# (the part that is actually ours to get right) can be exercised
# deterministically without network access or a real signed attestation.
verify_cmd="${ATTESTATION_VERIFY_CMD:-gh attestation verify}"

digest="sha256:${deployed_bundle_sha256}"

verify_output="$(mktemp)"
trap 'rm -f "$verify_output"' EXIT

set +e
# shellcheck disable=SC2086
$verify_cmd "$digest" --owner "$owner" --repo "$repo" --format json >"$verify_output" 2>&1
verify_rc=$?
set -e

if [[ "$verify_rc" -ne 0 ]]; then
  if grep -qi 'no attestations found' "$verify_output"; then
    echo "ATTESTATION_NOT_FOUND: no deployment attestation for digest $digest" >&2
    exit 3
  fi
  echo "ATTESTATION_VERIFY_FAILED: signature, certificate, or workflow identity rejected" >&2
  cat "$verify_output" >&2
  exit 1
fi

# `gh attestation verify --format json` returns an array; take the most
# recent entry's DSSE statement predicate.
predicate="$(jq -er '
  if (type == "array") then (sort_by(.verificationResult.verifiedTimestamps[0].timestamp // "") | last)
  else . end
  | (.verificationResult.statement // .statement).predicate
' "$verify_output" 2>/dev/null)" || {
  echo "ATTESTATION_MALFORMED: could not extract predicate from verified statement" >&2
  exit 1
}

check_field() {
  local label="$1" expected="$2" actual="$3"
  if [[ "$actual" != "$expected" ]]; then
    echo "ATTESTATION_PREDICATE_MISMATCH: $label expected=$expected actual=$actual" >&2
    exit 1
  fi
}

check_field "releaseSha" "$release_sha" "$(jq -er '.releaseSha' <<<"$predicate")"
check_field "supabaseProjectRef" "$project_ref" "$(jq -er '.supabaseProjectRef' <<<"$predicate")"
check_field "function" "$function_name" "$(jq -er '.function' <<<"$predicate")"
check_field "reviewedSourceClosureSha256" "$expected_source_closure_sha256" \
  "$(jq -er '.reviewedSourceClosureSha256' <<<"$predicate")"
check_field "deployedBundleSha256" "$deployed_bundle_sha256" \
  "$(jq -er '.deployedBundleSha256' <<<"$predicate")"

echo "ATTESTATION_VERIFIED: signed deployment-time provenance matches release $release_sha" >&2

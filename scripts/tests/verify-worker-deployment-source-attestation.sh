#!/usr/bin/env bash
# Regression coverage for the deployment-time source-closure attestation
# verifier. Production always calls the real `gh attestation verify`
# (Sigstore/OIDC trust root); these tests inject a fixture in its place via
# ATTESTATION_VERIFY_CMD so the verifier's own field-comparison logic -- the
# part this repository actually owns -- is exercised deterministically.
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

repo="oasisbaklawa2006/oasis-supabase-core"
release_sha="c3ae931d1919fdf88b4270fb108595e4ab1c9c26"
project_ref="tcxvcatsqqertcnycuop"
function_name="whatsapp-packet-ai-worker"
closure_sha="a220be24c6f233c92f1e5e16d21fe593071fe58d3d071e169c733d5564ab1b82"
bundle_sha="0f505f46f0d50f96ea63145c350b94db50eb2a7e6b08373934cee8ce85d4df28"

write_fixture_cmd() {
  # Writes a fake "gh attestation verify" that ignores its real arguments and
  # emits the JSON this test controls, then stores a marker so we can also
  # assert the real CLI would have been invoked with the right digest/owner.
  local body="$1"
  local script="$tmpdir/fake-gh-attestation-verify.sh"
  cat >"$script" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$tmpdir/invocations.log"
cat <<'JSON'
$body
JSON
EOF
  chmod +x "$script"
  printf '%s' "$script"
}

write_failing_fixture_cmd() {
  local message="$1"
  local script="$tmpdir/fake-gh-attestation-verify-fail.sh"
  cat >"$script" <<EOF
#!/usr/bin/env bash
echo "$message" >&2
exit 1
EOF
  chmod +x "$script"
  printf '%s' "$script"
}

valid_statement() {
  jq -n \
    --arg release_sha "$release_sha" \
    --arg project_ref "$project_ref" \
    --arg function_name "$function_name" \
    --arg closure_sha "${1:-$closure_sha}" \
    --arg bundle_sha "${2:-$bundle_sha}" \
    '[{
      verificationResult: {
        statement: {
          predicate: {
            releaseSha: $release_sha,
            supabaseProjectRef: $project_ref,
            function: $function_name,
            reviewedSourceClosureSha256: $closure_sha,
            deployedBundleSha256: $bundle_sha
          }
        }
      }
    }]'
}

run_verify() {
  set +e
  ATTESTATION_VERIFY_CMD="$1" bash scripts/verify-worker-deployment-source-attestation.sh \
    "$repo" "$release_sha" "$project_ref" "$function_name" "$closure_sha" "$bundle_sha"
  echo $?
  set -e
}

# --- 1. missing attestation (exit 3, not a failure) ---
rc="$(run_verify "$(write_failing_fixture_cmd 'no attestations found for subject')")"
[[ "$rc" -eq 3 ]] || { echo "expected 3 for missing attestation, got $rc" >&2; exit 1; }

# --- 2. invalid signature / wrong signing identity (exit 1) ---
rc="$(run_verify "$(write_failing_fixture_cmd 'Loading trust root... FAILED: signature verification failed')")"
[[ "$rc" -eq 1 ]] || { echo "expected 1 for invalid signature, got $rc" >&2; exit 1; }

# --- 3. valid signature, matching predicate (exit 0) ---
valid_json="$(valid_statement)"
rc="$(run_verify "$(write_fixture_cmd "$valid_json")")"
[[ "$rc" -eq 0 ]] || { echo "expected 0 for matching predicate, got $rc" >&2; exit 1; }

# --- 4. valid signature, wrong source-closure hash (exit 1) ---
wrong_closure="$(valid_statement 0000000000000000000000000000000000000000000000000000000000000000)"
rc="$(run_verify "$(write_fixture_cmd "$wrong_closure")")"
[[ "$rc" -eq 1 ]] || { echo "expected 1 for wrong closure hash, got $rc" >&2; exit 1; }

# --- 5. valid signature, wrong (stale/replayed) bundle digest (exit 1) ---
wrong_bundle="$(valid_statement "$closure_sha" 1111111111111111111111111111111111111111111111111111111111111111)"
rc="$(run_verify "$(write_fixture_cmd "$wrong_bundle")")"
[[ "$rc" -eq 1 ]] || { echo "expected 1 for wrong/stale bundle digest, got $rc" >&2; exit 1; }

# --- 6. valid signature, wrong release SHA in predicate (exit 1) ---
wrong_release="$(jq -n \
  --arg release_sha "0000000000000000000000000000000000000000" \
  --arg project_ref "$project_ref" \
  --arg function_name "$function_name" \
  --arg closure_sha "$closure_sha" \
  --arg bundle_sha "$bundle_sha" \
  '[{verificationResult: {statement: {predicate: {
    releaseSha: $release_sha, supabaseProjectRef: $project_ref,
    function: $function_name, reviewedSourceClosureSha256: $closure_sha,
    deployedBundleSha256: $bundle_sha}}}}]')"
rc="$(run_verify "$(write_fixture_cmd "$wrong_release")")"
[[ "$rc" -eq 1 ]] || { echo "expected 1 for wrong release SHA, got $rc" >&2; exit 1; }

# --- 7. valid signature, wrong Supabase project (exit 1) ---
wrong_project="$(jq -n \
  --arg release_sha "$release_sha" \
  --arg project_ref "someotherproject" \
  --arg function_name "$function_name" \
  --arg closure_sha "$closure_sha" \
  --arg bundle_sha "$bundle_sha" \
  '[{verificationResult: {statement: {predicate: {
    releaseSha: $release_sha, supabaseProjectRef: $project_ref,
    function: $function_name, reviewedSourceClosureSha256: $closure_sha,
    deployedBundleSha256: $bundle_sha}}}}]')"
rc="$(run_verify "$(write_fixture_cmd "$wrong_project")")"
[[ "$rc" -eq 1 ]] || { echo "expected 1 for wrong Supabase project, got $rc" >&2; exit 1; }

# --- 8. valid signature, wrong function name (exit 1) ---
wrong_function="$(jq -n \
  --arg release_sha "$release_sha" \
  --arg project_ref "$project_ref" \
  --arg function_name "some-other-function" \
  --arg closure_sha "$closure_sha" \
  --arg bundle_sha "$bundle_sha" \
  '[{verificationResult: {statement: {predicate: {
    releaseSha: $release_sha, supabaseProjectRef: $project_ref,
    function: $function_name, reviewedSourceClosureSha256: $closure_sha,
    deployedBundleSha256: $bundle_sha}}}}]')"
rc="$(run_verify "$(write_fixture_cmd "$wrong_function")")"
[[ "$rc" -eq 1 ]] || { echo "expected 1 for wrong function name, got $rc" >&2; exit 1; }

# --- 9. malformed verifier output (exit 1, not silently VERIFIED) ---
rc="$(run_verify "$(write_fixture_cmd '{"not": "a recognizable shape"}')")"
[[ "$rc" -eq 1 ]] || { echo "expected 1 for malformed predicate, got $rc" >&2; exit 1; }

# --- 10. the fixture is actually invoked with the exact digest/owner/repo ---
fixture_cmd="$(write_fixture_cmd "$valid_json")"
: "$(run_verify "$fixture_cmd")"
grep -Fq "sha256:${bundle_sha} --owner oasisbaklawa2006 --repo $repo" "$tmpdir/invocations.log" || {
  echo "verifier did not invoke the attestation check with the expected digest/owner/repo" >&2
  cat "$tmpdir/invocations.log" >&2
  exit 1
}

echo "verify-worker-deployment-source-attestation regression passed."

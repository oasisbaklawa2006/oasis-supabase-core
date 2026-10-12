#!/usr/bin/env bash
# Regression test: the "Preview Edge Runtime readiness" (runtime-governance)
# job in edge-function-governance.yml must always resolve its checkout ref
# to an authoritative, immutable PR head SHA -- never to an empty string
# that makes actions/checkout silently fall back to the mutable
# pull-request merge-ref commit.
#
# Root cause this guards against: provision-preview-dotenv is skipped
# (via its own implicit success() gating on `needs: [path-scope,
# static-governance]`) whenever static-governance fails. A skipped job's
# outputs are empty strings, so a bare
# `ref: ${{ needs.provision-preview-dotenv.outputs.provisioned_sha }}`
# resolves to an empty ref, and actions/checkout then checks out
# refs/pull/<n>/merge instead of the real PR head -- causing the
# downstream exact-head assertion in scripts/ensure-supabase-preview-branch.py
# / its wrapper to fail before Supabase preview provisioning ever executes.
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

WORKFLOW='.github/workflows/edge-function-governance.yml'
fail() { echo "PREVIEW-CHECKOUT-FALLBACK REGRESSION FAILED: $*" >&2; exit 1; }

[[ -f "$WORKFLOW" ]] || fail "$WORKFLOW is missing"

runtime_job="$(awk '/^  runtime-governance:/{in_job=1; next} in_job && /^  [A-Za-z0-9_-]+:/{exit} in_job{print}' "$WORKFLOW")"
[[ -n "$runtime_job" ]] || fail "runtime-governance job not found in $WORKFLOW"

# The job's second checkout step (the one gated on edge_runtime == 'true',
# distinct from the earlier no-op "Skip when..." informational step) must
# resolve ref through the full three-way fallback chain.
checkout_ref_line="$(grep -E '^\s*ref:\s*\$\{\{ needs\.provision-preview-dotenv\.outputs\.provisioned_sha' <<< "$runtime_job" || true)"
[[ -n "$checkout_ref_line" ]] \
  || fail "runtime-governance checkout no longer references provisioned_sha at all"

grep -Fq 'needs.provision-preview-dotenv.outputs.provisioned_sha || github.event.pull_request.head.sha || github.sha' <<< "$checkout_ref_line" \
  || fail "runtime-governance checkout ref must fall back through provisioned_sha || github.event.pull_request.head.sha || github.sha, in that order"

# Negative check: must not be a bare provisioned_sha-only expression (no
# fallback operators at all), which is exactly the regression this test
# exists to catch.
if grep -qE '^\s*ref:\s*\$\{\{\s*needs\.provision-preview-dotenv\.outputs\.provisioned_sha\s*\}\}\s*$' <<< "$runtime_job"; then
  fail "runtime-governance checkout ref is a bare provisioned_sha expression with no fallback"
fi

# The downstream exact-head assertion must still independently re-verify
# the resolved checkout, so fail-closed behavior holds even if the
# fallback chain above is ever wrong.
grep -Fq 'test "$(git rev-parse HEAD)" = "$GITHUB_PR_HEAD_SHA"' <<< "$runtime_job" \
  || fail "runtime-governance no longer independently re-asserts the exact PR head after checkout"

# The SHA checked by the downstream runtime job must be the same immutable
# SHA its checkout selected. Before this guard, the provisioning job committed
# new dotenvx ciphertext, then readiness checked the new checkout against the
# event's old PR SHA and failed before probing the Supabase preview.
grep -Fq 'GITHUB_PR_HEAD_SHA: ${{ needs.provision-preview-dotenv.outputs.provisioned_sha || github.event.pull_request.head.sha || github.sha }}' <<< "$runtime_job" \
  || fail "runtime-governance expected head must equal its immutable checkout ref"

# Ordinary pull_request governance MUST NOT create new dotenvx keys, upload a
# production-held private key, or push a new commit. These actions previously
# rotated production authority repeatedly and invalidated main ciphertext.
provision_job="$(awk '/^  provision-preview-dotenv:/{in_job=1; next} in_job && /^  [A-Za-z0-9_-]+:/{exit} in_job{print}' "$WORKFLOW")"
[[ -n "$provision_job" ]] || fail "provision-preview-dotenv job missing"
grep -Fq 'persist-credentials: false' <<< "$provision_job" \
  || fail "PR preview verification checkout must not persist write credentials"
grep -Fq 'bash scripts/verify-preview-dotenv-crypto-authority.sh' <<< "$provision_job" \
  || fail "PR preview verifier must prove decrypt authority"
grep -Fq 'PREVIEW_DOTENV_CRYPTO_AUTHORITY_MISMATCH' <<< "$provision_job" \
  || fail "PR preview verification must fail closed on mismatch"
grep -Fq 'echo "pushed=false" >> "$GITHUB_OUTPUT"' <<< "$provision_job" \
  || fail "PR preview verification must not claim it pushed a new SHA"
if grep -Eq 'git[[:space:]]+(push|commit)|scripts/(materialize-supabase-env-preview|upload-preview-dotenvx-keys)\\.sh|persist-credentials:[[:space:]]*true' <<< "$provision_job"; then
  fail "PR preview verification contains an automatic key rotation, upload or Git push"
fi
grep -A2 '^permissions:
 "$WORKFLOW" | grep -Fq 'contents: read' \
  || fail "Edge Function Governance must have read-only contents permission"

# Regression fixture: reject the former old-event-SHA binding even if a later
# step still contains a generic exact-head comparison.
if grep -Fq 'GITHUB_PR_HEAD_SHA: ${{ github.event.pull_request.head.sha || github.sha }}' <<< "$runtime_job"; then
  fail "runtime-governance reverted to old event SHA instead of checked-out SHA"
fi

echo "OK: preview runtime uses one immutable SHA; PR checks cannot auto-rotate production dotenvx authority."

echo "OK: Preview Edge Runtime readiness checkout always resolves to an authoritative immutable PR head, with fail-closed re-verification preserved."

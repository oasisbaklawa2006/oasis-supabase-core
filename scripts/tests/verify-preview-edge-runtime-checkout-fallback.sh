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

echo "OK: Preview Edge Runtime readiness checkout always resolves to an authoritative immutable PR head, with fail-closed re-verification preserved."

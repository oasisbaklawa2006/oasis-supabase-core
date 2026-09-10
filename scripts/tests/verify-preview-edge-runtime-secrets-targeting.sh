#!/usr/bin/env bash
# Regression coverage for current/dynamic PR-preview targeting.
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$repo_root"

fail() {
  echo "PREVIEW TARGETING REGRESSION FAILED: $*" >&2
  exit 1
}

readiness='scripts/check-preview-edge-runtime-secrets-readiness.sh'
resolver='scripts/resolve-current-pr-preview-ref.sh'
workflow='.github/workflows/edge-function-governance.yml'

[[ -f "$readiness" ]] || fail "$readiness is missing"
[[ -f "$resolver" ]] || fail "$resolver is missing"
[[ -f "$workflow" ]] || fail "$workflow is missing"

grep -Fq 'scripts/resolve-current-pr-preview-ref.sh' "$readiness" \
  || fail 'readiness does not resolve an absent preview ref dynamically'
if grep -Fq 'jyezfiehhfgnvhzzffxr' "$readiness"; then
  fail 'readiness still contains the stale historical preview ref'
fi
grep -Fq 'GITHUB_PR_HEAD_SHA' "$workflow" \
  || fail 'workflow does not bind resolution to the PR head SHA'
if grep -Fq 'commits/${GITHUB_SHA}/check-runs' "$workflow"; then
  fail 'workflow resolves check-runs from the pull-request merge SHA'
fi
grep -Fq 'tcxvcatsqqertcnycuop' "$resolver" \
  || fail 'resolver does not carry the production-ref rejection'
grep -Fq 'WA_STAGE1B_CERT_SECRET' "$readiness" \
  || fail 'readiness no longer requires the independent certification secret'

test_root="$(mktemp -d)"
trap 'rm -rf "$test_root"' EXIT
mock_bin="$test_root/bin"
mkdir -p "$mock_bin"
cat > "$mock_bin/curl" <<'MOCK_CURL'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "${MOCK_CURL_LOG:-/dev/null}"
cat "$MOCK_GITHUB_RESPONSE"
MOCK_CURL
chmod +x "$mock_bin/curl"

run_resolver() {
  PATH="$mock_bin:$PATH" \
  MOCK_GITHUB_RESPONSE="$test_root/response.json" \
  GITHUB_REPOSITORY='oasisbaklawa2006/oasis-supabase-core' \
  GITHUB_PR_HEAD_SHA='current-pr-head' \
  GITHUB_API_URL='https://api.github.test' \
  GH_TOKEN='test-token' \
    bash "$resolver"
}

cat > "$test_root/response.json" <<'JSON'
{"check_runs":[
  {"name":"Unrelated check","status":"completed","conclusion":"success","details_url":"https://example.test/run"},
  {"name":"Supabase Preview","status":"completed","conclusion":"success","details_url":"https://supabase.com/dashboard/project/evmeoljyrvfiidxqzpya"}
]}
JSON
[[ "$(run_resolver)" == 'evmeoljyrvfiidxqzpya' ]] \
  || fail 'resolver did not select the current successful Supabase Preview authority'

cat > "$test_root/response.json" <<'JSON'
{"check_runs":[{"name":"Supabase Preview","status":"completed","conclusion":"success","details_url":"https://supabase.com/dashboard/project/tcxvcatsqqertcnycuop"}]}
JSON
if run_resolver >/dev/null 2>&1; then
  fail 'resolver accepted the production project ref'
fi

cat > "$test_root/response.json" <<'JSON'
{"check_runs":[
  {"name":"Supabase Preview","status":"completed","conclusion":"success","details_url":"https://supabase.com/dashboard/project/evmeoljyrvfiidxqzpya"},
  {"name":"Supabase Preview","status":"completed","conclusion":"success","details_url":"https://supabase.com/dashboard/project/abcdefghijklmnopqrst"}
]}
JSON
if run_resolver >/dev/null 2>&1; then
  fail 'resolver accepted ambiguous preview authorities'
fi

cat > "$test_root/response.json" <<'JSON'
{"runtime_secret_readiness":{"GEMINI_API_KEY_EDGE_RUNTIME":true}}
JSON
: > "$test_root/curl.log"
PATH="$mock_bin:$PATH" \
MOCK_CURL_LOG="$test_root/curl.log" \
MOCK_GITHUB_RESPONSE="$test_root/response.json" \
WA_STAGE1B_CERT_SECRET='independent-cert-secret' \
WA_STAGE1B_PREVIEW_REF='evmeoljyrvfiidxqzpya' \
  bash "$readiness" >/dev/null
grep -Fq 'https://evmeoljyrvfiidxqzpya.supabase.co/functions/v1/whatsapp-stage1b-cert-runner' "$test_root/curl.log" \
  || fail 'readiness did not probe the supplied current PR preview authority'
if grep -Fq 'jyezfiehhfgnvhzzffxr' "$test_root/curl.log"; then
  fail 'readiness attempted the stale historical preview authority'
fi

echo 'verify-preview-edge-runtime-secrets-targeting.sh: all cases passed'

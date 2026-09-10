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
materialize='scripts/materialize-supabase-env-preview.sh'
upload_keys="$repo_root/scripts/upload-preview-dotenvx-keys.sh"
upload_py="$repo_root/scripts/upload-production-dotenvx-key.py"
list_py="$repo_root/scripts/list-production-secret-names.py"
workflow='.github/workflows/edge-function-governance.yml'
sync_workflow='.github/workflows/sync-preview-cert-edge-secrets.yml'

[[ -f "$readiness" ]] || fail "$readiness is missing"
[[ -f "$resolver" ]] || fail "$resolver is missing"
[[ -f "$materialize" ]] || fail "$materialize is missing"
[[ -f "$upload_keys" ]] || fail "$upload_keys is missing"
[[ -f "$upload_py" ]] || fail "$upload_py is missing"
[[ -f "$list_py" ]] || fail "$list_py is missing"
[[ -f "$workflow" ]] || fail "$workflow is missing"
[[ -f "$sync_workflow" ]] || fail "$sync_workflow is missing"

grep -Fq 'scripts/resolve-current-pr-preview-ref.sh' "$readiness" \
  || fail 'readiness does not resolve an absent preview ref dynamically'
if grep -Fq 'jyezfiehhfgnvhzzffxr' "$readiness"; then
  fail 'readiness still contains the stale historical preview ref'
fi
grep -Fq 'GITHUB_PR_HEAD_SHA' "$sync_workflow" \
  || fail 'preview secret sync does not bind resolution to the PR head SHA'
grep -Fq 'scripts/resolve-current-pr-preview-ref.sh' "$sync_workflow" \
  || fail 'preview secret sync does not resolve the current PR preview authority'
grep -Fq 'scripts/materialize-supabase-env-preview.sh' "$sync_workflow" \
  || fail 'preview secret sync does not materialize encrypted supabase/.env.preview'
grep -Fq 'scripts/upload-preview-dotenvx-keys.sh' "$sync_workflow" \
  || fail 'preview secret sync does not upload dotenvx keys via production authority'
if grep -Eq 'supabase secrets set.*--project-ref "\$PREVIEW_REF"' "$sync_workflow"; then
  fail 'preview secret sync still writes secrets to ephemeral preview refs via Management API'
fi
if grep -Fq 'DEFAULT_CERT_PREVIEW_REF' "$sync_workflow"; then
  fail 'preview secret sync still pins a stale default preview ref'
fi
if awk '/^  provision-preview-dotenv:/{in_job=1; next} in_job && /^  [A-Za-z0-9_-]+:/{exit} in_job{print}' "$workflow" | grep -q '^[[:space:]]*environment:'; then
  fail 'governance provision job still overrides repository secrets with a GitHub environment token'
fi
if awk '/^  sync:/{in_job=1; next} in_job && /^  [A-Za-z0-9_-]+:/{exit} in_job{print}' "$sync_workflow" | grep -q '^[[:space:]]*environment:'; then
  fail 'preview secret sync still overrides repository secrets with a GitHub environment token'
fi
grep -Fq 'tcxvcatsqqertcnycuop' "$resolver" \
  || fail 'resolver does not carry the production-ref rejection'
grep -Fq "trusted_app_id='330661'" "$resolver" \
  || fail 'resolver does not pin the trusted Supabase GitHub App ID'
grep -Fq "trusted_app_slug='supabase'" "$resolver" \
  || fail 'resolver does not pin the trusted Supabase GitHub App slug'
verify_decrypt="$repo_root/scripts/verify-preview-env-decryptable.sh"
[[ -f "$verify_decrypt" ]] || fail "$verify_decrypt is missing"
grep -Fq 'scripts/verify-preview-env-decryptable.sh' "$workflow" \
  || fail 'governance workflow does not verify preview env decryptability'
grep -Fq 'get GEMINI_API_KEY' "$verify_decrypt" \
  || fail 'decrypt verifier no longer performs a real dotenvx secret decrypt check'

test_root="$(mktemp -d)"
trap 'rm -rf "$test_root"' EXIT
mock_bin="$test_root/bin"
mkdir -p "$mock_bin"
cat > "$mock_bin/curl" <<'MOCK_CURL'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "${MOCK_CURL_LOG:-/dev/null}"
url="${*: -1}"
if [[ "$url" == *'/check-runs?'* && -n "${MOCK_GITHUB_PAGE1:-}" ]]; then
  if [[ "$url" == *'page=2'* ]]; then
    cat "${MOCK_GITHUB_PAGE2:?}"
  else
    cat "$MOCK_GITHUB_PAGE1"
  fi
  exit 0
fi
cat "$MOCK_GITHUB_RESPONSE"
MOCK_CURL
chmod +x "$mock_bin/curl"

cat > "$mock_bin/supabase" <<'MOCK_SUPABASE'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "${MOCK_SUPABASE_LOG:-/dev/null}"
if [[ "$*" == *"--project-ref evmeoljyrvfiidxqzpya"* && "$*" == *"secrets set"* ]]; then
  echo "Your account does not have the necessary privileges to access this endpoint." >&2
  exit 1
fi
if [[ "$*" == *"--project-ref tcxvcatsqqertcnycuop"* && "$*" == *"secrets set --env-file"* ]]; then
  exit 1
fi
echo "unexpected supabase invocation: $*" >&2
exit 1
MOCK_SUPABASE
chmod +x "$mock_bin/supabase"

cat > "$mock_bin/python3" <<'MOCK_PYTHON'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "${MOCK_PYTHON_LOG:-/dev/null}"
if [[ "${1:-}" == *"list-production-secret-names.py" ]]; then
  printf '%s\n' 'DOTENV_PRIVATE_KEY_PREVIEW'
  exit 0
fi
exec /usr/bin/python3 "$@"
MOCK_PYTHON
chmod +x "$mock_bin/python3"

printf '{"check_runs":[]}\n' > "$test_root/empty.json"
run_resolver() {
  local page1="${1:-$test_root/response.json}"
  local page2="${2:-$test_root/empty.json}"
  PATH="$mock_bin:$PATH" \
  MOCK_GITHUB_RESPONSE="$test_root/response.json" \
  MOCK_GITHUB_PAGE1="$page1" \
  MOCK_GITHUB_PAGE2="$page2" \
  MOCK_CURL_LOG="$test_root/curl.log" \
  GITHUB_REPOSITORY='oasisbaklawa2006/oasis-supabase-core' \
  GITHUB_PR_HEAD_SHA='current-pr-head' \
  GITHUB_API_URL='https://api.github.test' \
  GH_TOKEN='test-token' \
    bash "$resolver"
}

/usr/bin/python3 - <<'PY' > "$test_root/page1.json"
import json
print(json.dumps({"check_runs": [
    {"name": f"Unrelated check {i}", "status": "completed", "conclusion": "success"}
    for i in range(100)
]}))
PY
cat > "$test_root/page2.json" <<'JSON'
{"check_runs":[
  {"name":"Supabase Preview","status":"completed","conclusion":"success","details_url":"https://supabase.com/dashboard/project/evmeoljyrvfiidxqzpya","app":{"id":330661,"slug":"supabase"}}
]}
JSON
: > "$test_root/curl.log"
[[ "$(run_resolver "$test_root/page1.json" "$test_root/page2.json")" == 'evmeoljyrvfiidxqzpya' ]] \
  || fail 'resolver did not select the trusted current Supabase Preview authority from page two'
grep -Fq 'page=2' "$test_root/curl.log" \
  || fail 'resolver did not request the second check-run page'

cat > "$test_root/response.json" <<'JSON'
{"check_runs":[{"name":"Supabase Preview","status":"completed","conclusion":"success","details_url":"https://supabase.com/dashboard/project/evmeoljyrvfiidxqzpya"}]}
JSON
if run_resolver >/dev/null 2>&1; then
  fail 'resolver accepted a preview check with missing app identity'
fi

cat > "$test_root/response.json" <<'JSON'
{"check_runs":[{"name":"Supabase Preview","status":"completed","conclusion":"success","details_url":"https://supabase.com/dashboard/project/evmeoljyrvfiidxqzpya","app":{"id":15368,"slug":"github-actions"}}]}
JSON
if run_resolver >/dev/null 2>&1; then
  fail 'resolver accepted an untrusted preview check publisher'
fi

production_ref='tcxvcatsqqertcnycuop'
cat > "$test_root/response.json" <<JSON
{"check_runs":[{"name":"Supabase Preview","status":"completed","conclusion":"success","details_url":"https://supabase.com/dashboard/project/$production_ref","app":{"id":330661,"slug":"supabase"}}]}
JSON
if run_resolver >/dev/null 2>&1; then
  fail 'resolver accepted the production project ref'
fi

cat > "$test_root/response.json" <<'JSON'
{"check_runs":[
  {"name":"Supabase Preview","status":"completed","conclusion":"success","details_url":"https://supabase.com/dashboard/project/evmeoljyrvfiidxqzpya","app":{"id":330661,"slug":"supabase"}},
  {"name":"Supabase Preview","status":"completed","conclusion":"success","details_url":"https://supabase.com/dashboard/project/abcdefghijklmnopqrst","app":{"id":330661,"slug":"supabase"}}
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

if GEMINI_API_KEY= WA_STAGE1B_CERT_SECRET= bash "$materialize" >/dev/null 2>&1; then
  fail 'materialize did not fail closed when preview secret inputs were absent'
fi

unreadable_root="$test_root/unreadable"
mkdir -p "$unreadable_root/supabase" "$test_root/unreadable-bin"
cat > "$test_root/unreadable-bin/python3" <<'UNREADABLE_PYTHON'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == *"list-production-secret-names.py" ]]; then
  printf '%s\n' 'DOTENV_PRIVATE_KEY_PREVIEW'
  exit 0
fi
if [[ "${1:-}" == *"fetch-production-dotenv-private-key.py" ]]; then
  exit 1
fi
exec /usr/bin/python3 "$@"
UNREADABLE_PYTHON
chmod +x "$test_root/unreadable-bin/python3"
cat > "$test_root/unreadable-bin/supabase" <<'UNREADABLE_SUPABASE'
#!/usr/bin/env bash
set -euo pipefail
if [[ "$*" == *"secrets list --project-ref tcxvcatsqqertcnycuop"* ]]; then
  printf '%s\n' 'DOTENV_PRIVATE_KEY_PREVIEW'
  exit 0
fi
echo "unexpected supabase invocation: $*" >&2
exit 1
UNREADABLE_SUPABASE
chmod +x "$test_root/unreadable-bin/supabase"
unreadable_output="$(SUPABASE_ACCESS_TOKEN='test-token' \
  PRODUCTION_PROJECT_REF='tcxvcatsqqertcnycuop' \
  GEMINI_API_KEY='gemini-test' \
  WA_STAGE1B_CERT_SECRET='cert-test' \
  PATH="$test_root/unreadable-bin:$PATH" \
  bash -c "cd '$unreadable_root' && bash '$repo_root/scripts/materialize-supabase-env-preview.sh'" 2>&1)" \
  || fail 'materialize must not hard fail when production dotenv key exists but is unreadable'
grep -Eq 'generated_new_dotenvx_keys|materialized_encrypted_preview_env' <<<"$unreadable_output" \
  || fail 'materialize did not continue after unreadable production dotenv key'

existing_root="$test_root/existing"
mkdir -p "$existing_root/supabase" "$test_root/existing-bin"
cat > "$existing_root/supabase/.env.preview" <<'PREVIEW'
GEMINI_API_KEY="encrypted:bootstrap"
WA_STAGE1B_CERT_SECRET="encrypted:bootstrap"
PREVIEW
cat > "$test_root/existing-bin/python3" <<'EXISTING_PYTHON'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == *"fetch-production-dotenv-private-key.py" ]]; then
  printf '%s\n' 'mock-readable-production-key'
  exit 0
fi
exec /usr/bin/python3 "$@"
EXISTING_PYTHON
chmod +x "$test_root/existing-bin/python3"
cat > "$test_root/existing-bin/npx" <<'EXISTING_NPX'
#!/usr/bin/env bash
set -euo pipefail
if [[ "$*" == *"@dotenvx/dotenvx@1.44.1"* && "$*" == *"get GEMINI_API_KEY"* ]]; then
  exit 0
fi
echo "unexpected npx invocation in decrypt-orchestration fixture: $*" >&2
exit 1
EXISTING_NPX
chmod +x "$test_root/existing-bin/npx"
existing_output="$(SUPABASE_ACCESS_TOKEN='test-token' \
  PRODUCTION_PROJECT_REF='tcxvcatsqqertcnycuop' \
  GEMINI_API_KEY='gemini-test' \
  WA_STAGE1B_CERT_SECRET='cert-test' \
  PATH="$test_root/existing-bin:$PATH" \
  bash -c "cd '$existing_root' && bash '$repo_root/scripts/materialize-supabase-env-preview.sh'")"
grep -Fq 'existing_encrypted_preview_env' <<<"$existing_output" \
  || fail 'materialize must reuse committed encrypted preview env when production key passes decrypt verification'

stale_root="$test_root/stale"
mkdir -p "$stale_root/supabase"
cp "$existing_root/supabase/.env.preview" "$stale_root/supabase/.env.preview"
stale_output="$(SUPABASE_ACCESS_TOKEN='test-token' \
  PRODUCTION_PROJECT_REF='tcxvcatsqqertcnycuop' \
  GEMINI_API_KEY='gemini-test' \
  WA_STAGE1B_CERT_SECRET='cert-test' \
  PATH="$test_root/unreadable-bin:$PATH" \
  bash -c "cd '$stale_root' && bash '$repo_root/scripts/materialize-supabase-env-preview.sh'" 2>&1)" \
  || fail 'materialize must refresh stale encrypted preview env when production key is unreadable'
grep -Eq 'generated_new_dotenvx_keys|materialized_encrypted_preview_env' <<<"$stale_output" \
  || fail 'materialize did not regenerate after unreadable production dotenv key'
[[ ! -f "$stale_root/supabase/.env.preview" || -s "$stale_root/supabase/.env.preview" ]] \
  || fail 'materialize removed stale preview env without replacement'

upload_root="$test_root/upload"
mkdir -p "$upload_root/supabase"
cat > "$upload_root/supabase/.env.keys" <<'KEYS'
DOTENV_PRIVATE_KEY_PREVIEW="dotenv://:key@test@/env.preview?environment=preview"
KEYS
: > "$test_root/upload.log"
if ! SUPABASE_ACCESS_TOKEN='test-token' \
  PRODUCTION_PROJECT_REF='tcxvcatsqqertcnycuop' \
  PATH="$mock_bin:$PATH" \
  MOCK_PYTHON_LOG="$test_root/upload.log" \
  PREVIEW_DOTENVX_UPLOAD_REQUIRED=false \
  bash -c "cd '$upload_root' && bash '$upload_keys'" >/dev/null; then
  fail 'dotenvx authority verification did not succeed against production'
fi
grep -Fq 'list-production-secret-names.py' "$test_root/upload.log" \
  || fail 'dotenvx authority verification did not inspect production secret names'

orphan_root="$test_root/orphan"
mkdir -p "$orphan_root/supabase" "$test_root/orphan-bin"
cat > "$test_root/orphan-bin/python3" <<'ORPHAN_PYTHON'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == *"list-production-secret-names.py" ]]; then
  echo "production secrets list failed: HTTP 403" >&2
  exit 1
fi
exec /usr/bin/python3 "$@"
ORPHAN_PYTHON
chmod +x "$test_root/orphan-bin/python3"
cat > "$orphan_root/supabase/.env.preview" <<'PREVIEW'
GEMINI_API_KEY="encrypted:orphaned"
WA_STAGE1B_CERT_SECRET="encrypted:orphaned"
PREVIEW
set +e
defer_output="$(SUPABASE_ACCESS_TOKEN='test-token' \
  PRODUCTION_PROJECT_REF='tcxvcatsqqertcnycuop' \
  PATH="$test_root/orphan-bin:$PATH" \
  PREVIEW_DOTENVX_UPLOAD_REQUIRED=false \
  bash -c "cd '$orphan_root' && bash '$upload_keys'" 2>&1)"
defer_status=$?
set -e
[[ "$defer_status" -ne 0 ]] \
  || fail 'upload must fail closed when encrypted preview env has no production dotenv authority'
grep -Fq 'preview dotenvx authority is not confirmed for the encrypted preview environment' <<<"$defer_output" \
  || fail 'upload fail-closed path did not report missing production dotenv authority'
[[ ! -f "$orphan_root/supabase/.env.preview" ]] \
  || fail 'upload fail-closed path must remove orphaned encrypted preview env without authority'

bootstrap_root="$test_root/bootstrap"
mkdir -p "$bootstrap_root/supabase" "$test_root/bootstrap-bin"
cat > "$bootstrap_root/supabase/.env.preview" <<'PREVIEW'
GEMINI_API_KEY="encrypted:bootstrap"
WA_STAGE1B_CERT_SECRET="encrypted:bootstrap"
PREVIEW
cat > "$test_root/bootstrap-bin/python3" <<'BOOTSTRAP_PYTHON'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == *"upload-production-dotenvx-key.py" ]]; then
  [[ "${PREVIEW_DOTENV_PRIVATE_KEY:-}" == 'bootstrap-key' ]] || exit 1
  printf '%s\n' 'uploaded_dotenvx_preview_key_to_production'
  exit 0
fi
if [[ "${1:-}" == *"list-production-secret-names.py" ]]; then
  printf '%s\n' 'DOTENV_PRIVATE_KEY_PREVIEW'
  exit 0
fi
exec /usr/bin/python3 "$@"
BOOTSTRAP_PYTHON
chmod +x "$test_root/bootstrap-bin/python3"
cat > "$test_root/bootstrap-bin/npx" <<'BOOTSTRAP_NPX'
#!/usr/bin/env bash
set -euo pipefail
if [[ "$*" == *"@dotenvx/dotenvx@1.44.1"* && "$*" == *"get GEMINI_API_KEY"* ]]; then
  exit 0
fi
echo "unexpected npx invocation in bootstrap fixture: $*" >&2
exit 1
BOOTSTRAP_NPX
chmod +x "$test_root/bootstrap-bin/npx"
bootstrap_output="$(PREVIEW_DOTENV_PRIVATE_KEY='bootstrap-key' \
  SUPABASE_ACCESS_TOKEN='test-token' \
  PRODUCTION_PROJECT_REF='tcxvcatsqqertcnycuop' \
  PREVIEW_DOTENVX_UPLOAD_REQUIRED=true \
  PATH="$test_root/bootstrap-bin:$PATH" \
  bash -c "cd '$bootstrap_root' && bash '$upload_keys'")"
grep -Fq 'uploaded_dotenvx_keys_to_production' <<<"$bootstrap_output" \
  || fail 'upload must allow owner-provisioned PREVIEW_DOTENV_PRIVATE_KEY bootstrap authority'

if PATH="$mock_bin:$PATH" \
  MOCK_SUPABASE_LOG="$test_root/preview-write.log" \
  supabase secrets set GEMINI_API_KEY=test --project-ref evmeoljyrvfiidxqzpya >/dev/null 2>&1; then
  fail 'ephemeral preview Management API writes must remain unavailable'
fi

echo 'verify-preview-edge-runtime-secrets-targeting.sh: all cases passed'

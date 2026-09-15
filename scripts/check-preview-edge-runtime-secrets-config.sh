#!/usr/bin/env bash
# Preview Edge Runtime secret governance config gate. Dotenvx resolver Codacy
# exclusions are maintained in .codacy.yml alongside resolve-production-gemini-secret.py.
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

config="supabase/config.toml"
workflow=".github/workflows/sync-preview-cert-edge-secrets.yml"
governance_workflow=".github/workflows/edge-function-governance.yml"
doc="supabase/PREVIEW_EDGE_SECRETS.md"
cert_runner="supabase/functions/whatsapp-stage1b-cert-runner/index.ts"
readiness="scripts/check-preview-edge-runtime-secrets-readiness.sh"
resolver="scripts/resolve-current-pr-preview-ref.sh"
branch_resolver="scripts/resolve-current-pr-preview-ref-from-branches.py"
ensure_preview="scripts/ensure-supabase-preview-branch.sh"
waiter="scripts/wait-for-current-pr-preview-ref.sh"
materialize="scripts/materialize-supabase-env-preview.sh"
upload_keys="scripts/upload-preview-dotenvx-keys.sh"
upload_py="scripts/upload-production-dotenvx-key.py"
list_py="scripts/list-production-secret-names.py"
verify_authority="scripts/verify-production-dotenvx-authority.sh"

for file in "$config" "$workflow" "$governance_workflow" "$doc" "$readiness" "$resolver" "$branch_resolver" "$ensure_preview" "$waiter" "$materialize" "$upload_keys" "$upload_py" "$list_py" "$verify_authority"; do
  [[ -f "$file" ]] || {
    echo "PREVIEW EDGE SECRETS CONFIG VIOLATION: missing $file" >&2
    exit 1
  }
done

grep -Fq 'scripts/upload-preview-dotenvx-keys.sh' "$governance_workflow" \
  || {
    echo 'PREVIEW EDGE SECRETS CONFIG VIOLATION: governance workflow must upload dotenvx keys via production authority' >&2
    exit 1
  }

if ! grep -Fq 'scripts/resolve-current-pr-preview-ref.sh' "$governance_workflow" \
  && ! grep -Fq 'scripts/wait-for-current-pr-preview-ref.sh' "$governance_workflow"; then
  echo 'PREVIEW EDGE SECRETS CONFIG VIOLATION: governance workflow must use the current PR preview resolver' >&2
  exit 1
fi

grep -Fq 'scripts/ensure-supabase-preview-branch.sh' "$governance_workflow" \
  || {
    echo 'PREVIEW EDGE SECRETS CONFIG VIOLATION: governance workflow must ensure preview branch participation' >&2
    exit 1
  }

if awk '/^  provision-preview-dotenv:/,/^  runtime-governance:/' "$governance_workflow" | grep -q '^[[:space:]]*environment:'; then
  echo 'PREVIEW EDGE SECRETS CONFIG VIOLATION: governance provision job must use repository secrets without GitHub environment token override' >&2
  exit 1
fi

if awk '/^  sync:/,/^$/' "$workflow" | grep -q '^[[:space:]]*environment:'; then
  echo 'PREVIEW EDGE SECRETS CONFIG VIOLATION: sync workflow must use repository secrets without GitHub environment token override' >&2
  exit 1
fi

if grep -Fq 'environment: supabase-production-readonly' "$governance_workflow" "$workflow"; then
  echo 'PREVIEW EDGE SECRETS CONFIG VIOLATION: supabase-production-readonly token cannot upload dotenvx preview authority' >&2
  exit 1
fi

grep -Fq 'list-production-secret-names.py' "$verify_authority" \
  || {
    echo 'PREVIEW EDGE SECRETS CONFIG VIOLATION: dotenvx authority verification must use production secret name listing' >&2
    exit 1
  }

grep -Fq 'scripts/materialize-supabase-env-preview.sh' "$workflow" \
  || {
    echo 'PREVIEW EDGE SECRETS CONFIG VIOLATION: sync workflow must materialize encrypted supabase/.env.preview' >&2
    exit 1
  }

grep -Fq 'scripts/upload-preview-dotenvx-keys.sh' "$workflow" \
  || {
    echo 'PREVIEW EDGE SECRETS CONFIG VIOLATION: sync workflow must upload dotenvx keys to production' >&2
    exit 1
  }

if grep -Eq 'supabase secrets set.*--project-ref "\$PREVIEW_REF"|supabase secrets set.*--project-ref "\$\{\{ steps\.target\.outputs\.preview_ref \}\}"' "$workflow"; then
  echo 'PREVIEW EDGE SECRETS CONFIG VIOLATION: sync workflow must not write secrets to ephemeral preview refs via Management API' >&2
  exit 1
fi

if grep -Fq 'jyezfiehhfgnvhzzffxr' "$workflow" "$doc"; then
  echo 'PREVIEW EDGE SECRETS CONFIG VIOLATION: stale historical preview ref remains in sync workflow or docs' >&2
  exit 1
fi

if [[ -f scripts/derive-preview-cert-secret.sh ]]; then
  echo 'PREVIEW EDGE SECRETS CONFIG VIOLATION: derive-preview-cert-secret.sh must not exist' >&2
  exit 1
fi

grep -Fq '[edge_runtime.secrets]' "$config" \
  || {
    echo 'PREVIEW EDGE SECRETS CONFIG VIOLATION: supabase/config.toml must declare [edge_runtime.secrets]' >&2
    exit 1
  }

grep -Fq 'GEMINI_API_KEY = "env(GEMINI_API_KEY)"' "$config" \
  || {
    echo 'PREVIEW EDGE SECRETS CONFIG VIOLATION: GEMINI_API_KEY must be declared for preview Edge Runtime' >&2
    exit 1
  }

grep -Fq 'WA_STAGE1B_CERT_SECRET = "env(WA_STAGE1B_CERT_SECRET)"' "$config" \
  || {
    echo 'PREVIEW EDGE SECRETS CONFIG VIOLATION: config.toml must declare WA_STAGE1B_CERT_SECRET for preview Edge Runtime' >&2
    exit 1
  }

grep -Fq 'supabase/.env.preview' "$workflow" \
  || {
    echo 'PREVIEW EDGE SECRETS CONFIG VIOLATION: sync workflow must track encrypted supabase/.env.preview' >&2
    exit 1
  }

grep -Fq 'secrets.GEMINI_API_KEY' "$workflow" \
  || {
    echo 'PREVIEW EDGE SECRETS CONFIG VIOLATION: sync workflow must reference secrets.GEMINI_API_KEY' >&2
    exit 1
  }

grep -Fq 'WA_STAGE1B_CERT_SECRET: ${{ secrets.WA_STAGE1B_CERT_SECRET }}' "$workflow" \
  || {
    echo 'PREVIEW EDGE SECRETS CONFIG VIOLATION: sync workflow must source WA_STAGE1B_CERT_SECRET from a protected GitHub secret' >&2
    exit 1
  }

grep -Fq 'if [[ -z "${WA_STAGE1B_CERT_SECRET:-}" ]]; then' "$workflow" \
  || {
    echo 'PREVIEW EDGE SECRETS CONFIG VIOLATION: sync workflow must fail closed when WA_STAGE1B_CERT_SECRET is absent' >&2
    exit 1
  }

grep -Fq 'WA_STAGE1B_CERT_SECRET_REQUIRED' "$workflow" \
  || {
    echo 'PREVIEW EDGE SECRETS CONFIG VIOLATION: sync workflow must report WA_STAGE1B_CERT_SECRET_REQUIRED' >&2
    exit 1
  }

grep -Fq 'WA_STAGE1B_CERT_SECRET_REQUIRED' "$readiness" \
  || {
    echo 'PREVIEW EDGE SECRETS CONFIG VIOLATION: readiness probe must report WA_STAGE1B_CERT_SECRET_REQUIRED' >&2
    exit 1
  }

if grep -Riq 'derive-preview-cert-secret' "$workflow" "$readiness" supabase/functions/_shared/stage1bCert/previewCertAuth.ts; then
  echo 'PREVIEW EDGE SECRETS CONFIG VIOLATION: certification auth must not derive WA_STAGE1B_CERT_SECRET' >&2
  exit 1
fi

grep -Fq 'PRODUCTION_PROJECT_REF: tcxvcatsqqertcnycuop' "$workflow" \
  || {
    echo 'PREVIEW EDGE SECRETS CONFIG VIOLATION: sync workflow must pin and refuse production ref' >&2
    exit 1
  }

if [[ -f "$cert_runner" ]]; then
  grep -Fq 'Deno.env.get("GEMINI_API_KEY")' supabase/functions/whatsapp-packet-ai-worker/index.ts \
    || {
      echo 'PREVIEW EDGE SECRETS CONFIG VIOLATION: packet AI worker must read GEMINI_API_KEY' >&2
      exit 1
    }
fi

if ! output="$(WA_STAGE1B_CERT_SECRET= bash "$readiness" 2>&1)"; then
  grep -Fq 'WA_STAGE1B_CERT_SECRET_REQUIRED' <<<"$output" \
    || {
      echo 'PREVIEW EDGE SECRETS CONFIG VIOLATION: readiness probe must fail closed without sending a request' >&2
      exit 1
    }
else
  echo 'PREVIEW EDGE SECRETS CONFIG VIOLATION: readiness probe must exit non-zero when WA_STAGE1B_CERT_SECRET is absent' >&2
  exit 1
fi

if ! output="$(GEMINI_API_KEY= WA_STAGE1B_CERT_SECRET= bash "$materialize" 2>&1)"; then
  grep -Fq 'MATERIALIZE PREVIEW ENV FAILED' <<<"$output" \
    || {
      echo 'PREVIEW EDGE SECRETS CONFIG VIOLATION: materialize script must fail closed without secret inputs' >&2
      exit 1
    }
else
  echo 'PREVIEW EDGE SECRETS CONFIG VIOLATION: materialize script must exit non-zero when secret inputs are absent' >&2
  exit 1
fi

grep -Fq 'PREVIEW_NOT_PROVISIONED' "$waiter" \
  || {
    echo 'PREVIEW EDGE SECRETS CONFIG VIOLATION: preview waiter must report PREVIEW_NOT_PROVISIONED for a skipped trusted preview' >&2
    exit 1
  }

wait_test_root="$(mktemp -d)"
wait_test_bin="$wait_test_root/bin"
mkdir -p "$wait_test_bin"
cat > "$wait_test_bin/curl" <<'MOCK_CURL'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "${MOCK_CURL_LOG:?}"
cat <<'JSON'
{"check_runs":[{"id":9001,"name":"Supabase Preview","status":"completed","conclusion":"skipped","details_url":"https://supabase.com/dashboard/project/evmeoljyrvfiidxqzpya","app":{"id":330661,"slug":"supabase"}}]}
JSON
MOCK_CURL
chmod +x "$wait_test_bin/curl"
: > "$wait_test_root/curl.log"
if wait_output="$(PATH="$wait_test_bin:$PATH" \
  MOCK_CURL_LOG="$wait_test_root/curl.log" \
  GITHUB_REPOSITORY='oasisbaklawa2006/oasis-supabase-core' \
  GITHUB_PR_HEAD_SHA='skipped-preview-head' \
  GITHUB_API_URL='https://api.github.test' \
  GH_TOKEN='test-token' \
  PREVIEW_REF_WAIT_ATTEMPTS=20 \
  PREVIEW_REF_WAIT_SECONDS=0 \
  bash "$waiter" 2>&1)"; then
  rm -rf "$wait_test_root"
  echo 'PREVIEW EDGE SECRETS CONFIG VIOLATION: preview waiter treated a skipped Supabase Preview as success' >&2
  exit 1
fi
grep -Fq 'PREVIEW_NOT_PROVISIONED' <<<"$wait_output" \
  || {
    rm -rf "$wait_test_root"
    echo 'PREVIEW EDGE SECRETS CONFIG VIOLATION: preview waiter did not fail explicitly for a skipped Supabase Preview' >&2
    exit 1
  }
wait_curl_count="$(wc -l < "$wait_test_root/curl.log" | tr -d ' ')"
rm -rf "$wait_test_root"
[[ "$wait_curl_count" == '2' ]] \
  || {
    echo "PREVIEW EDGE SECRETS CONFIG VIOLATION: skipped preview must fail on first attempt (expected 2 check-run lookups, saw $wait_curl_count)" >&2
    exit 1
  }

echo 'Preview Edge Runtime secrets configuration gate passed.'

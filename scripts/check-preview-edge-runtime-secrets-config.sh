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
crypto_authority="scripts/verify-preview-dotenv-crypto-authority.sh"
load_keys="scripts/load-preview-dotenvx-keys.sh"

violation() {
  echo "PREVIEW EDGE SECRETS CONFIG VIOLATION: $*" >&2
  exit 1
}

hosted_preconditions="scripts/check-preview-hosted-proof-preconditions.sh"

for file in "$config" "$workflow" "$governance_workflow" "$doc" "$readiness" "$resolver" "$branch_resolver" "$ensure_preview" "$waiter" "$materialize" "$upload_keys" "$upload_py" "$list_py" "$verify_authority" "$crypto_authority" "$hosted_preconditions" "$load_keys"; do
  [[ -f "$file" ]] || {
    echo "PREVIEW EDGE SECRETS CONFIG VIOLATION: missing $file" >&2
    exit 1
  }
done

# --- Shared preview dotenvx key custody invariants -------------------------
# Ordinary PR workflows hold NO key authority. Only the protected, manually
# dispatched sync workflow may verify the private key, generate, rotate or
# upload it; nothing may read it back from the Supabase Management API (which
# returns no stored value).
[[ ! -e scripts/fetch-production-dotenv-private-key.py ]] \
  || violation 'Management API private-key readback script must not exist'
[[ ! -e scripts/verify-preview-dotenv-attestation.py && ! -e supabase/.env.preview.attestations.json ]] \
  || violation 'the key-free attestation bypass must not exist: hosted proof at the PR head replaces it'
if grep -rIl 'fetch-production-dotenv-private-key' .github scripts supabase docs .codacy.yml 2>/dev/null \
  | grep -v '^scripts/check-preview-edge-runtime-secrets-config.sh$' \
  | grep -v '^scripts/tests/verify-preview-edge-runtime-secrets-targeting.sh$' \
  | grep -v '^scripts/tests/verify-preview-dotenv-authority-hardening.sh$' | grep -q .; then
  violation 'a reference to the Management API private-key readback script remains'
fi
if grep -Eq 'api\.supabase\.com|secrets list|fetch-production|curl|urllib' "$load_keys"; then
  violation 'load-preview-dotenvx-keys.sh must stay local-only and never contact Supabase'
fi

# --- Credential isolation: pull-request and branch-controlled workflows -----
# Pull-request workflows can be edited by the PR author, so they may hold no
# privileged Supabase credential, no dotenvx private key and no production
# secret. A privileged secret may be referenced only by a job bound to a
# protected GitHub environment. (These static checks are review-enforced; the
# enforced boundary is that privileged secrets exist only as environment
# secrets, never as repository-level secrets - see supabase/PREVIEW_EDGE_SECRETS.md.)
privileged_secret_re='^(SUPABASE_|PREVIEW_DOTENV|DOTENV_|GEMINI_API_KEY$)|DB_URL|SERVICE_ROLE|ACCESS_TOKEN'
pr_secret_allowlist=' WA_STAGE1B_CERT_SECRET GITHUB_TOKEN '
pr_trigger_re='^(  pull_request(_target)?:|on:.*pull_request)'
privileged_script_re='ensure-supabase-preview-branch|upload-preview-dotenvx-keys|upload-production-dotenvx-key|materialize-supabase-env-preview|verify-preview-dotenv-crypto-authority|list-production-secret-names|verify-production-dotenvx-authority|resolve-preview-gemini-credential|resolve-production-gemini-secret|supabase[[:space:]]+(secrets|branches)|api\.supabase\.com'

unbound_privileged_secrets() {
  awk -v re="$privileged_secret_re" -v wf="$1" '
    function flush(   name) {
      if (!has_env) for (name in refs) if (name ~ re) { print wf ": " job " references privileged secret " name " without a protected environment"; bad = 1 }
      delete refs; has_env = 0
    }
    BEGIN { job = "(workflow level)" }
    /^jobs:/ { flush(); injobs = 1; job = ""; next }
    injobs && /^  [A-Za-z0-9_-]+:[[:space:]]*$/ { flush(); job = "job " $1; sub(/:$/, "", job); next }
    injobs && /^    environment:/ { has_env = 1 }
    { line = $0; while (match(line, /secrets\.[A-Z][A-Z0-9_]+/)) { refs[substr(line, RSTART + 8, RLENGTH - 8)] = 1; line = substr(line, RSTART + RLENGTH) } }
    END { flush(); exit bad }
  ' "$1"
}

for wf in .github/workflows/*.yml .github/workflows/*.yaml; do
  [[ -f "$wf" ]] || continue
  unbound="$(unbound_privileged_secrets "$wf")" || violation "$unbound"
  grep -Eq 'pull_request_target' "$wf" \
    && violation "$wf must not use pull_request_target (it runs untrusted code with repository secrets)"
  grep -Eq '^  workflow_call:|secrets:[[:space:]]*inherit|toJSON\(secrets\)|secrets\[' "$wf" \
    && violation "$wf must not expose secrets through reusable workflows, secrets: inherit or dynamic secret access"
  if grep -Eq '^  workflow_run:' "$wf" && grep -Eq 'secrets\.[A-Z]' "$wf"; then
    violation "$wf is workflow_run-triggered and must not reference repository secrets"
  fi
  if grep -Eq "$pr_trigger_re" "$wf"; then
    grep -Eq '^    environment:' "$wf" \
      && violation "pull-request workflow $wf must not bind a GitHub environment"
    for name in $(grep -Eo 'secrets\.[A-Z][A-Z0-9_]+' "$wf" | sed 's/^secrets\.//' | sort -u); do
      [[ "$pr_secret_allowlist" == *" $name "* ]] \
        || violation "pull-request workflow $wf references secret $name; only the cert-runner probe secret is allowed"
    done
    if grep -Eq "$privileged_script_re" "$wf"; then
      violation "pull-request workflow $wf must not invoke privileged Supabase/key scripts or the Management API"
    fi
  fi
done

provision_job="$(awk '/^  provision-preview-dotenv:/{in_job=1; print; next} in_job && /^  [A-Za-z0-9_-]+:/{exit} in_job{print}' "$governance_workflow")"
[[ -n "$provision_job" ]] || violation 'governance workflow must define the provision-preview-dotenv job (required check name)'
grep -Fq 'scripts/check-preview-hosted-proof-preconditions.sh' <<<"$provision_job" \
  || violation 'governance provision job must run the offline hosted-proof preconditions'
if grep -Eq 'git[[:space:]]+(push|commit|add|config)|persist-credentials:[[:space:]]*true|secrets\.[A-Z]|^[[:space:]]*environment:' <<<"$provision_job"; then
  violation 'governance provision job must be credential-free and read-only: no Git write, no secrets, no environment'
fi
runtime_job="$(awk '/^  runtime-governance:/{in_job=1; print; next} in_job && /^  [A-Za-z0-9_-]+:/{exit} in_job{print}' "$governance_workflow")"
[[ -n "$runtime_job" ]] || violation 'governance workflow must define the runtime-governance job (Preview Edge Runtime readiness)'
grep -Fq 'scripts/wait-for-current-pr-preview-ref.sh' <<<"$runtime_job" \
  || violation 'readiness must resolve the preview ref from the trusted hosted Supabase Preview check'
grep -Fq 'scripts/check-preview-edge-runtime-secrets-readiness.sh' <<<"$runtime_job" \
  || violation 'readiness must run the hosted Edge Runtime secret probe'
if grep -Eq 'SUPABASE_|PREVIEW_DOTENV|GEMINI_API_KEY|GITHUB_HEAD_REF|ensure-supabase-preview-branch|upload-|materialize-|git[[:space:]]+(push|commit)' <<<"$runtime_job"; then
  violation 'readiness must hold no Supabase credential, dotenvx key or branch-creation path'
fi
for name in $(grep -Eo 'secrets\.[A-Z][A-Z0-9_]+' <<<"$runtime_job" | sed 's/^secrets\.//' | sort -u); do
  [[ "$name" == WA_STAGE1B_CERT_SECRET ]] || violation "readiness may reference only the cert-runner probe secret (found $name)"
done
top_permissions="$(awk '/^permissions:/{flag=1; next} flag && /^[^[:space:]]/{exit} flag{print}' "$governance_workflow")"
grep -Eq '^[[:space:]]+contents:[[:space:]]*read[[:space:]]*$' <<<"$top_permissions" \
  || violation 'governance workflow must grant contents: read only'
if grep -Eq '^[[:space:]]+contents:[[:space:]]*write' <<<"$top_permissions"; then
  violation 'governance workflow must not grant contents: write'
fi
grep -Fq "needs.path-scope.outputs.edge_runtime != 'true' || needs.provision-preview-dotenv.result == 'success'" "$governance_workflow" \
  || violation 'Preview Edge Runtime readiness must run only after the offline hosted-proof preconditions succeed'

writer_files="$(grep -rIlE 'upload-preview-dotenvx-keys\.sh|upload-production-dotenvx-key\.py|materialize-supabase-env-preview\.sh|verify-preview-dotenv-crypto-authority\.sh' .github/workflows | sort | tr '\n' ' ')"
[[ "$writer_files" == ".github/workflows/sync-preview-cert-edge-secrets.yml " ]] \
  || violation "only the protected sync workflow may invoke key custody/generation/upload scripts (found: ${writer_files:-none})"

sync_job="$(awk '/^  sync:/{in_job=1; print; next} in_job && /^  [A-Za-z0-9_-]+:/{exit} in_job{print}' "$workflow")"
grep -Eq "^[[:space:]]+github\.event_name == 'workflow_dispatch'" <<<"$sync_job" \
  || violation 'sync workflow job must run only on workflow_dispatch'
grep -Fq "AUTHORIZE-PREVIEW-DOTENVX-KEY-ROTATION" <<<"$sync_job" \
  || violation 'sync workflow job must require the explicit rotation authorization phrase'
grep -Fq 'inputs.change_reference' <<<"$sync_job" \
  || violation 'sync workflow job must require a change reference'
grep -Eq '^    environment:[[:space:]]*supabase-preview-key-authority[[:space:]]*$' <<<"$sync_job" \
  || violation 'sync workflow job must run in the protected supabase-preview-key-authority environment'
grep -Eq '^[[:space:]]+PREVIEW_KEY_ROTATION_AUTHORIZED:[[:space:]]*"true"' <<<"$sync_job" \
  || violation 'sync workflow job must set PREVIEW_KEY_ROTATION_AUTHORIZED for the guarded key writer'
grep -Fq 'scripts/verify-preview-dotenv-crypto-authority.sh' <<<"$sync_job" \
  || violation 'sync workflow job must verify the independent key authority before publishing'
sync_permissions="$(awk '/^permissions:/{flag=1; next} flag && /^[^[:space:]]/{exit} flag{print}' "$workflow")"
grep -Eq '^[[:space:]]+contents:[[:space:]]*read[[:space:]]*$' <<<"$sync_permissions" \
  || violation 'sync workflow must grant contents: read only'
grep -Eq "^[[:space:]]+&& github\.ref == 'refs/heads/main'" <<<"$sync_job" \
  || violation 'sync workflow job must run only from the main branch'
grep -Fq 'NEW_PREVIEW_DOTENVX_KEY_REQUIRES_PERSISTED_CIPHERTEXT' <<<"$sync_job" \
  || violation 'sync workflow must refuse to publish a newly generated key whose ciphertext it cannot persist'
grep -Fq 'PREVIEW_KEY_ROTATION_AUTHORIZED' "$upload_py" \
  || violation 'key writer must refuse to run without explicit protected rotation authorization'
grep -Fq 'pull_request_target' "$upload_py" \
  || violation 'key writer must refuse pull-request contexts'
grep -Fq 'PRODUCTION_PROJECT_REF' "$upload_py" \
  || violation 'key writer must pin the production project ref'

if ! grep -Fq 'scripts/resolve-current-pr-preview-ref.sh' "$governance_workflow" \
  && ! grep -Fq 'scripts/wait-for-current-pr-preview-ref.sh' "$governance_workflow"; then
  echo 'PREVIEW EDGE SECRETS CONFIG VIOLATION: governance workflow must use the current PR preview resolver' >&2
  exit 1
fi

# The protected sync environment must not override the repository token with a
# different one: it carries required reviewers only (verified by owner config).

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

stale_skip_test_root="$(mktemp -d)"
stale_skip_test_bin="$stale_skip_test_root/bin"
mkdir -p "$stale_skip_test_bin"
cat > "$stale_skip_test_bin/curl" <<'MOCK_CURL'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "${MOCK_CURL_LOG:?}"
cat <<'JSON'
{"check_runs":[{"id":9001,"name":"Supabase Preview","status":"completed","conclusion":"skipped","details_url":"https://supabase.com/dashboard/project/evmeoljyrvfiidxqzpya","app":{"id":330661,"slug":"supabase"}},{"id":9002,"name":"Supabase Preview","status":"in_progress","conclusion":null,"details_url":"https://supabase.com/dashboard/project/evmeoljyrvfiidxqzpya","app":{"id":330661,"slug":"supabase"}}]}
JSON
MOCK_CURL
chmod +x "$stale_skip_test_bin/curl"
: > "$stale_skip_test_root/curl.log"
if stale_skip_output="$(PATH="$stale_skip_test_bin:$PATH" \
  MOCK_CURL_LOG="$stale_skip_test_root/curl.log" \
  GITHUB_REPOSITORY='oasisbaklawa2006/oasis-supabase-core' \
  GITHUB_PR_HEAD_SHA='stale-skipped-preview-head' \
  GITHUB_API_URL='https://api.github.test' \
  GH_TOKEN='test-token' \
  PREVIEW_REF_WAIT_ATTEMPTS=20 \
  PREVIEW_REF_WAIT_SECONDS=0 \
  bash "$waiter" 2>&1)"; then
  rm -rf "$stale_skip_test_root"
  echo 'PREVIEW EDGE SECRETS CONFIG VIOLATION: preview waiter ignored a completed skipped check behind a newer in-progress check' >&2
  exit 1
fi
grep -Fq 'PREVIEW_NOT_PROVISIONED' <<<"$stale_skip_output" \
  || {
    rm -rf "$stale_skip_test_root"
    echo 'PREVIEW EDGE SECRETS CONFIG VIOLATION: preview waiter did not fail explicitly when a completed skipped check predates an in-progress rerun' >&2
    exit 1
  }
rm -rf "$stale_skip_test_root"

echo 'Preview Edge Runtime secrets configuration gate passed.'

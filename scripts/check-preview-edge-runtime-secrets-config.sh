#!/usr/bin/env bash
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

config="supabase/config.toml"
workflow=".github/workflows/sync-preview-cert-edge-secrets.yml"
governance_workflow=".github/workflows/edge-function-governance.yml"
doc="supabase/PREVIEW_EDGE_SECRETS.md"
cert_runner="supabase/functions/whatsapp-stage1b-cert-runner/index.ts"
readiness="scripts/check-preview-edge-runtime-secrets-readiness.sh"
resolver="scripts/resolve-current-pr-preview-ref.sh"
materialize="scripts/materialize-supabase-env-preview.sh"
upload_keys="scripts/upload-preview-dotenvx-keys.sh"
upload_py="scripts/upload-production-dotenvx-key.py"
list_py="scripts/list-production-secret-names.py"
verify_authority="scripts/verify-production-dotenvx-authority.sh"

for file in "$config" "$workflow" "$governance_workflow" "$doc" "$readiness" "$resolver" "$materialize" "$upload_keys" "$upload_py" "$list_py" "$verify_authority"; do
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

grep -Fq 'scripts/resolve-current-pr-preview-ref.sh' "$governance_workflow" \
  || {
    echo 'PREVIEW EDGE SECRETS CONFIG VIOLATION: governance workflow must use the current PR preview resolver' >&2
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

echo 'Preview Edge Runtime secrets configuration gate passed.'

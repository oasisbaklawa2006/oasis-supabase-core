#!/usr/bin/env bash
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

config="supabase/config.toml"
workflow=".github/workflows/sync-preview-cert-edge-secrets.yml"
doc="supabase/PREVIEW_EDGE_SECRETS.md"
cert_runner="supabase/functions/whatsapp-stage1b-cert-runner/index.ts"
readiness="scripts/check-preview-edge-runtime-secrets-readiness.sh"

for file in "$config" "$workflow" "$doc" "$readiness"; do
  [[ -f "$file" ]] || {
    echo "PREVIEW EDGE SECRETS CONFIG VIOLATION: missing $file" >&2
    exit 1
  }
done

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

grep -Fq 'WHATSAPP_MEDIA_ALLOWED_HOSTS = "env(WHATSAPP_MEDIA_ALLOWED_HOSTS)"' "$config" \
  || {
    echo 'PREVIEW EDGE SECRETS CONFIG VIOLATION: WHATSAPP_MEDIA_ALLOWED_HOSTS must be declared for preview Edge Runtime' >&2
    exit 1
  }

grep -Fq 'WHATSAPP_MEDIA_ALLOWED_HOSTS=' "$workflow" \
  || {
    echo 'PREVIEW EDGE SECRETS CONFIG VIOLATION: sync workflow must set WHATSAPP_MEDIA_ALLOWED_HOSTS on preview' >&2
    exit 1
  }

grep -Fq 'secrets.GEMINI_API_KEY' "$workflow" \
  || {
    echo 'PREVIEW EDGE SECRETS CONFIG VIOLATION: sync workflow must reference secrets.GEMINI_API_KEY' >&2
    exit 1
  }
grep -Fq 'secrets.GOOGLE_GENERATIVE_AI_API_KEY' "$workflow" \
  || {
    echo 'PREVIEW EDGE SECRETS CONFIG VIOLATION: sync workflow must reference GOOGLE_GENERATIVE_AI_API_KEY fallback' >&2
    exit 1
  }

grep -Fq 'WA_STAGE1B_CERT_SECRET: ${{ secrets.WA_STAGE1B_CERT_SECRET }}' "$workflow" \
  || {
    echo 'PREVIEW EDGE SECRETS CONFIG VIOLATION: sync workflow must source WA_STAGE1B_CERT_SECRET from a protected GitHub secret' >&2
    exit 1
  }

grep -Fq 'WA_STAGE1B_CERT_SECRET = "env(WA_STAGE1B_CERT_SECRET)"' "$config" \
  || {
    echo 'PREVIEW EDGE SECRETS CONFIG VIOLATION: config.toml must declare WA_STAGE1B_CERT_SECRET for preview Edge Runtime' >&2
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

echo 'Preview Edge Runtime secrets configuration gate passed.'

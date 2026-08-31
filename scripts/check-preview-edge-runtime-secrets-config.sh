#!/usr/bin/env bash
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

config="supabase/config.toml"
workflow=".github/workflows/sync-preview-cert-edge-secrets.yml"
doc="supabase/PREVIEW_EDGE_SECRETS.md"
cert_runner="supabase/functions/whatsapp-stage1b-cert-runner/index.ts"

for file in "$config" "$workflow" "$doc"; do
  [[ -f "$file" ]] || {
    echo "PREVIEW EDGE SECRETS CONFIG VIOLATION: missing $file" >&2
    exit 1
  }
done

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

grep -Fq 'WA_STAGE1B_CERT_SECRET' "$workflow" \
  || {
    echo 'PREVIEW EDGE SECRETS CONFIG VIOLATION: sync workflow must provision WA_STAGE1B_CERT_SECRET on preview' >&2
    exit 1
  }

grep -Fq 'secrets.WA_STAGE1B_CERT_SECRET' "$workflow" \
  || {
    echo 'PREVIEW EDGE SECRETS CONFIG VIOLATION: sync workflow must reference secrets.WA_STAGE1B_CERT_SECRET' >&2
    exit 1
  }

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

echo 'Preview Edge Runtime secrets configuration gate passed.'

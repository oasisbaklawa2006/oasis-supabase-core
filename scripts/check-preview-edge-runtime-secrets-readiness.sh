#!/usr/bin/env bash
# Fail closed when preview Edge Runtime lacks required Stage-1B secrets.
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

PREVIEW_REF="${WA_STAGE1B_PREVIEW_REF:-jyezfiehhfgnvhzzffxr}"
PREVIEW_URL="https://${PREVIEW_REF}.supabase.co"
RUNNER_URL="${PREVIEW_URL}/functions/v1/whatsapp-stage1b-cert-runner"

if [[ -z "${WA_STAGE1B_CERT_SECRET:-}" ]]; then
  echo "PREVIEW EDGE RUNTIME SECRETS VIOLATION: WA_STAGE1B_CERT_SECRET must be configured for readiness probe" >&2
  exit 1
fi

response="$(curl -sS -X POST "$RUNNER_URL" \
  -H "Authorization: Bearer ${WA_STAGE1B_CERT_SECRET}" \
  -H "Content-Type: application/json" \
  -H "X-WA-Cert-Preview-Url: ${PREVIEW_URL}" \
  -d '{"probe_runtime_secrets":true}')"
echo "$response" | grep -Fq '"GEMINI_API_KEY_EDGE_RUNTIME":true' || {
  echo "PREVIEW EDGE RUNTIME SECRETS VIOLATION: GEMINI_API_KEY unavailable on preview ${PREVIEW_REF}" >&2
  echo "$response" >&2
  exit 1
}
echo "Preview Edge Runtime secret readiness verified for ${PREVIEW_REF}."

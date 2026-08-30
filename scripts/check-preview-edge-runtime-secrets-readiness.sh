#!/usr/bin/env bash
# Fail closed when preview Edge Runtime lacks required Stage-1B secrets.
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

PREVIEW_REF="${WA_STAGE1B_PREVIEW_REF:-jyezfiehhfgnvhzzffxr}"
PREVIEW_URL="https://${PREVIEW_REF}.supabase.co"
SALT="wa-stage1b-preview-runner/v1-NON-PRODUCTION"
TOKEN="$(python3 -c "import hashlib; print(hashlib.sha256('${SALT}:${PREVIEW_REF}'.encode()).hexdigest())")"
RUNNER_URL="${PREVIEW_URL}/functions/v1/whatsapp-stage1b-cert-runner"

response="$(curl -sS -X POST "$RUNNER_URL" \
  -H "Authorization: Bearer ${TOKEN}" \
  -H "Content-Type: application/json" \
  -H "X-WA-Cert-Preview-Url: ${PREVIEW_URL}" \
  -d '{"probe_runtime_secrets":true}')"
echo "$response" | grep -Fq '"GEMINI_API_KEY_EDGE_RUNTIME":true' || {
  echo "PREVIEW EDGE RUNTIME SECRETS VIOLATION: GEMINI_API_KEY unavailable on preview ${PREVIEW_REF}" >&2
  echo "$response" >&2
  exit 1
}
echo "Preview Edge Runtime secret readiness verified for ${PREVIEW_REF}."

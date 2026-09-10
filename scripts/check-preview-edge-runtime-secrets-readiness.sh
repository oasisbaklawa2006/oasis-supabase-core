#!/usr/bin/env bash
# Fail closed when preview Edge Runtime lacks required Stage-1B secrets.
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

PRODUCTION_PROJECT_REF='tcxvcatsqqertcnycuop'

cert_secret="${WA_STAGE1B_CERT_SECRET:-}"
if [[ -z "$cert_secret" ]]; then
  echo "WA_STAGE1B_CERT_SECRET_REQUIRED" >&2
  exit 1
fi

# Governance supplies the current PR preview ref. The sync workflow supplies
# its explicitly selected preview ref as PREVIEW_REF. If neither is available,
# resolve the current PR head from the Supabase Preview check-run; never fall
# back to a historical Stage-1B project.
PREVIEW_REF="${WA_STAGE1B_PREVIEW_REF:-${PREVIEW_REF:-}}"
if [[ -z "$PREVIEW_REF" ]]; then
  PREVIEW_REF="$(bash scripts/resolve-current-pr-preview-ref.sh)"
fi

if [[ ! "$PREVIEW_REF" =~ ^[a-z0-9]{20}$ ]]; then
  echo "PREVIEW EDGE RUNTIME SECRETS VIOLATION: invalid preview ref" >&2
  exit 1
fi
if [[ "$PREVIEW_REF" == "$PRODUCTION_PROJECT_REF" ]]; then
  echo "PREVIEW EDGE RUNTIME SECRETS VIOLATION: production project ref forbidden" >&2
  exit 1
fi

PREVIEW_URL="https://${PREVIEW_REF}.supabase.co"
RUNNER_URL="${PREVIEW_URL}/functions/v1/whatsapp-stage1b-cert-runner"

for attempt in 1 2 3 4 5 6 7 8; do
  if ! response="$(curl -sS --connect-timeout 15 --max-time 30 -X POST "$RUNNER_URL" \
    -H "Authorization: Bearer ${cert_secret}" \
    -H "Content-Type: application/json" \
    -H "X-WA-Cert-Preview-Url: ${PREVIEW_URL}" \
    -d '{"probe_runtime_secrets":true}')"; then
    if (( attempt < 8 )); then
      sleep 30
      continue
    fi
    echo "PREVIEW EDGE RUNTIME SECRETS VIOLATION: readiness probe transport failure on preview ${PREVIEW_REF}" >&2
    exit 1
  fi
  if echo "$response" | grep -Fq '"GEMINI_API_KEY_EDGE_RUNTIME":true'; then
    echo "Preview Edge Runtime secret readiness verified for ${PREVIEW_REF}."
    exit 0
  fi
  if echo "$response" | grep -Fq '"error":"unauthorized"' && (( attempt < 8 )); then
    sleep 30
    continue
  fi
  if echo "$response" | grep -Eiq 'internal server error|502|503|504' && (( attempt < 8 )); then
    sleep 30
    continue
  fi
  echo "PREVIEW EDGE RUNTIME SECRETS VIOLATION: GEMINI_API_KEY unavailable on preview ${PREVIEW_REF}" >&2
  echo "$response" >&2
  exit 1
done

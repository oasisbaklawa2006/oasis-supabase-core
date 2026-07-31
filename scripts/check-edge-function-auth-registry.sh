#!/usr/bin/env bash
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

registry='docs/security/edge-function-auth-registry-2026-07-31.csv'
[[ -f "$registry" ]] || { echo 'EDGE AUTH REGISTRY VIOLATION: registry missing' >&2; exit 1; }

expected_header='function,live_version,verify_jwt,exposure_class,required_auth_boundary,source_status,disposition,closure_status'
[[ "$(head -n1 "$registry")" == "$expected_header" ]] \
  || { echo 'EDGE AUTH REGISTRY VIOLATION: unexpected header' >&2; exit 1; }

row_count="$(tail -n +2 "$registry" | sed '/^[[:space:]]*$/d' | wc -l | tr -d ' ')"
[[ "$row_count" == '26' ]] \
  || { echo "EDGE AUTH REGISTRY VIOLATION: expected 26 live functions, found $row_count" >&2; exit 1; }

function_count="$(tail -n +2 "$registry" | cut -d, -f1 | sort -u | wc -l | tr -d ' ')"
[[ "$function_count" == '26' ]] \
  || { echo 'EDGE AUTH REGISTRY VIOLATION: duplicate function names detected' >&2; exit 1; }

jwt_true="$(tail -n +2 "$registry" | awk -F, '$3 == "true" {count++} END {print count+0}')"
jwt_false="$(tail -n +2 "$registry" | awk -F, '$3 == "false" {count++} END {print count+0}')"
[[ "$jwt_true" == '5' && "$jwt_false" == '21' ]] \
  || { echo "EDGE AUTH REGISTRY VIOLATION: expected JWT split 5/21, found $jwt_true/$jwt_false" >&2; exit 1; }

grep -Fq 'generate-product-attributes,96,false,unsafe-public-or-internal,none-accepted,live-repo-drift,retire-or-rebuild,quarantined' "$registry" \
  || { echo 'EDGE AUTH REGISTRY VIOLATION: unsafe attribute generator is not quarantined' >&2; exit 1; }

grep -Fq 'whatsapp-webhook,121,false,provider-webhook,meta-verification-plus-signature-plus-replay,repository-present,dedicated-recertification,pending' "$registry" \
  || { echo 'EDGE AUTH REGISTRY VIOLATION: WhatsApp webhook dedicated recertification requirement missing' >&2; exit 1; }

if grep -E ',closed$' "$registry" >/dev/null; then
  echo 'EDGE AUTH REGISTRY VIOLATION: closure cannot be declared before runtime evidence is committed' >&2
  exit 1
fi

echo 'Edge Function authentication registry check passed: 26 live functions accounted for; unsafe closure claims blocked.'

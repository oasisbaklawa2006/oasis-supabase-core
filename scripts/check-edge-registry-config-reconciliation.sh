#!/usr/bin/env bash
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

registry='docs/security/edge-function-auth-registry-2026-07-31.csv'
config='supabase/config.toml'
doc='docs/security/EDGE_FUNCTION_REGISTRY_CONFIG_RECONCILIATION_2026-07-31.md'

for file in "$registry" "$config" "$doc"; do
  [[ -f "$file" ]] || { echo "EDGE REGISTRY CONFIG VIOLATION: missing $file" >&2; exit 1; }
done

expected=(catalogue-ai-copy test-integration whatsapp-content-interpret whatsapp-studio-inbox-bridge)
for fn in "${expected[@]}"; do
  grep -Fxq "[functions.${fn}]" "$config" \
    || { echo "EDGE REGISTRY CONFIG VIOLATION: ${fn} missing from config" >&2; exit 1; }
done

# The authentication registry is the 26-function live production inventory.
# test-integration and whatsapp-content-interpret are repository-managed preview
# functions and are intentionally outside that live inventory until a separately
# approved production activation updates the live registry. Their source and JWT
# modes are checked directly here.
for fn in catalogue-ai-copy whatsapp-studio-inbox-bridge; do
  grep -Eq "^${fn}," "$registry" \
    || { echo "EDGE REGISTRY CONFIG VIOLATION: live function ${fn} missing from registry" >&2; exit 1; }
done
for fn in test-integration whatsapp-content-interpret; do
  [[ -f "supabase/functions/${fn}/index.ts" ]] \
    || { echo "EDGE REGISTRY CONFIG VIOLATION: ${fn} source missing" >&2; exit 1; }
done

count=$(grep -c '^\[functions\.' "$config")
[[ "$count" -eq 4 ]] \
  || { echo "EDGE REGISTRY CONFIG VIOLATION: config must declare exactly 4 functions, found $count" >&2; exit 1; }

grep -A1 -Fx '[functions.catalogue-ai-copy]' "$config" | grep -Fxq 'verify_jwt = true' \
  || { echo 'EDGE REGISTRY CONFIG VIOLATION: catalogue-ai-copy JWT mismatch' >&2; exit 1; }
grep -Eq '^catalogue-ai-copy,[^,]+,true,' "$registry" \
  || { echo 'EDGE REGISTRY CONFIG VIOLATION: catalogue-ai-copy registry JWT mismatch' >&2; exit 1; }

grep -A1 -Fx '[functions.test-integration]' "$config" | grep -Fxq 'verify_jwt = true' \
  || { echo 'EDGE REGISTRY CONFIG VIOLATION: test-integration JWT mismatch' >&2; exit 1; }

grep -A1 -Fx '[functions.whatsapp-content-interpret]' "$config" | grep -Fxq 'verify_jwt = true' \
  || { echo 'EDGE REGISTRY CONFIG VIOLATION: whatsapp-content-interpret JWT mismatch' >&2; exit 1; }
if grep -Eq '^whatsapp-content-interpret,' "$registry"; then
  echo 'EDGE REGISTRY CONFIG VIOLATION: preview-only whatsapp-content-interpret must not be added to the live registry before approved production activation' >&2
  exit 1
fi

grep -A1 -Fx '[functions.whatsapp-studio-inbox-bridge]' "$config" | grep -Fxq 'verify_jwt = false' \
  || { echo 'EDGE REGISTRY CONFIG VIOLATION: bridge custom-auth mode mismatch' >&2; exit 1; }
grep -Eq '^whatsapp-studio-inbox-bridge,[^,]+,false,controlled-service,custom-secret-plus-disabled-by-default,repository-present,certified-controlled-manual-only,repository-certified$' "$registry" \
  || { echo 'EDGE REGISTRY CONFIG VIOLATION: bridge certification disposition mismatch' >&2; exit 1; }

for prohibited in whatsapp-webhook generate-product-attributes; do
  if grep -Fxq "[functions.${prohibited}]" "$config"; then
    echo "EDGE REGISTRY CONFIG VIOLATION: ${prohibited} must remain absent from preview config" >&2
    exit 1
  fi
done

grep -Eq '^generate-product-attributes,[^,]+,false,retired-endpoint,none-accepted,repository-tombstone,retired-runtime-removal-pending,repository-closed$' "$registry" \
  || { echo 'EDGE REGISTRY CONFIG VIOLATION: retired generator disposition mismatch' >&2; exit 1; }
grep -Eq '^whatsapp-webhook,[^,]+,false,provider-webhook,meta-verification-plus-signature-plus-replay,repository-present,failed-certification-continued-quarantine,review-complete$' "$registry" \
  || { echo 'EDGE REGISTRY CONFIG VIOLATION: webhook quarantine disposition mismatch' >&2; exit 1; }

rows=$(( $(wc -l < "$registry") - 1 ))
[[ "$rows" -eq 26 ]] \
  || { echo "EDGE REGISTRY CONFIG VIOLATION: registry must contain 26 live functions, found $rows" >&2; exit 1; }

grep -Fq 'Procedure 7 is complete at repository level.' "$doc" \
  || { echo 'EDGE REGISTRY CONFIG VIOLATION: procedure disposition missing' >&2; exit 1; }
grep -Fq 'Procedure 8 is the only phase permitted to record runtime certification' "$doc" \
  || { echo 'EDGE REGISTRY CONFIG VIOLATION: runtime boundary missing' >&2; exit 1; }

echo 'Edge Function registry/config reconciliation check passed.'

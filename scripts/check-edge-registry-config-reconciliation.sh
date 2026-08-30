#!/usr/bin/env bash
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

registry='docs/security/edge-function-auth-registry-2026-07-31.csv'
config='supabase/config.toml'
doc='docs/security/EDGE_FUNCTION_REGISTRY_CONFIG_RECONCILIATION_2026-07-31.md'
interpreter='supabase/functions/whatsapp-content-interpret/index.ts'
worker='supabase/functions/whatsapp-packet-ai-worker/index.ts'
shared_provider='supabase/functions/_shared/geminiProvider.ts'

for file in "$registry" "$config" "$doc" "$shared_provider" "$interpreter" "$worker"; do
  [[ -f "$file" ]] || { echo "EDGE REGISTRY CONFIG VIOLATION: missing $file" >&2; exit 1; }
done

expected=(catalogue-ai-copy test-integration whatsapp-content-interpret whatsapp-packet-ai-worker whatsapp-studio-inbox-bridge admin-provision-user)
for fn in "${expected[@]}"; do
  grep -Fxq "[functions.${fn}]" "$config" \
    || { echo "EDGE REGISTRY CONFIG VIOLATION: ${fn} missing from config" >&2; exit 1; }
done

# The authentication registry is the 26-function LIVE production inventory.
# test-integration, whatsapp-content-interpret and whatsapp-packet-ai-worker
# are repository-managed preview tooling, and admin-provision-user is
# repository-ready but not yet deployed. Their source and JWT mode are
# checked directly against config instead.
for fn in catalogue-ai-copy whatsapp-studio-inbox-bridge; do
  grep -Eq "^${fn}," "$registry" \
    || { echo "EDGE REGISTRY CONFIG VIOLATION: live function ${fn} missing from registry" >&2; exit 1; }
done
for fn in test-integration whatsapp-content-interpret whatsapp-packet-ai-worker admin-provision-user; do
  [[ -f "supabase/functions/${fn}/index.ts" ]] \
    || { echo "EDGE REGISTRY CONFIG VIOLATION: ${fn} source missing" >&2; exit 1; }
done
if grep -Eq '^admin-provision-user,' "$registry"; then
  echo 'EDGE REGISTRY CONFIG VIOLATION: admin-provision-user must not appear in the live-inventory registry until it is actually deployed' >&2
  exit 1
fi

count=$(grep -c '^\[functions\.' "$config")
[[ "$count" -eq 6 ]] \
  || { echo "EDGE REGISTRY CONFIG VIOLATION: config must declare exactly 6 functions, found $count" >&2; exit 1; }

grep -A1 -Fx '[functions.catalogue-ai-copy]' "$config" | grep -Fxq 'verify_jwt = true' \
  || { echo 'EDGE REGISTRY CONFIG VIOLATION: catalogue-ai-copy JWT mismatch' >&2; exit 1; }
grep -Eq '^catalogue-ai-copy,[^,]+,true,' "$registry" \
  || { echo 'EDGE REGISTRY CONFIG VIOLATION: catalogue-ai-copy registry JWT mismatch' >&2; exit 1; }

grep -A1 -Fx '[functions.test-integration]' "$config" | grep -Fxq 'verify_jwt = true' \
  || { echo 'EDGE REGISTRY CONFIG VIOLATION: test-integration JWT mismatch' >&2; exit 1; }

grep -A1 -Fx '[functions.whatsapp-content-interpret]' "$config" | grep -Fxq 'verify_jwt = true' \
  || { echo 'EDGE REGISTRY CONFIG VIOLATION: whatsapp-content-interpret JWT mismatch' >&2; exit 1; }
grep -A1 -Fx '[functions.whatsapp-packet-ai-worker]' "$config" | grep -Fxq 'verify_jwt = true' \
  || { echo 'EDGE REGISTRY CONFIG VIOLATION: whatsapp-packet-ai-worker JWT mismatch' >&2; exit 1; }
for fn in test-integration whatsapp-content-interpret whatsapp-packet-ai-worker; do
  if grep -Eq "^${fn}," "$registry"; then
    echo "EDGE REGISTRY CONFIG VIOLATION: preview-only ${fn} must not be added to the live registry before approved production activation" >&2
    exit 1
  fi
done

# Both WhatsApp AI functions use the shared direct Gemini provider adapter.
grep -Fq '../_shared/geminiProvider.ts' "$interpreter" \
  || { echo "EDGE REGISTRY CONFIG VIOLATION: content-interpret shared Gemini adapter import missing" >&2; exit 1; }
grep -Fq '../_shared/geminiProvider.ts' "$worker" \
  || { echo 'EDGE REGISTRY CONFIG VIOLATION: packet AI worker shared Gemini adapter import missing' >&2; exit 1; }
grep -Fq 'Deno.env.get("GEMINI_API_KEY")' "$interpreter" \
  || { echo "EDGE REGISTRY CONFIG VIOLATION: content-interpret must read GEMINI_API_KEY" >&2; exit 1; }
grep -Fq 'Deno.env.get("GEMINI_API_KEY")' "$worker" \
  || { echo 'EDGE REGISTRY CONFIG VIOLATION: packet AI worker must read GEMINI_API_KEY' >&2; exit 1; }
grep -Fq 'generativelanguage.googleapis.com/v1beta/models/' "$shared_provider" \
  || { echo 'EDGE REGISTRY CONFIG VIOLATION: direct Gemini GenerateContent endpoint missing' >&2; exit 1; }
grep -Fq '"x-goog-api-key": apiKey' "$shared_provider" \
  || { echo 'EDGE REGISTRY CONFIG VIOLATION: direct Gemini credential header missing' >&2; exit 1; }
grep -Fq 'gemini-3.6-flash' "$shared_provider" \
  || { echo 'EDGE REGISTRY CONFIG VIOLATION: direct Gemini model contract mismatch' >&2; exit 1; }
for source in "$interpreter" "$worker" "$shared_provider"; do
  if grep -Fq 'LOVABLE_API_KEY' "$source" || grep -Fq 'ai.gateway.lovable.dev' "$source" || grep -Fq 'openai/gpt-4o-mini-transcribe' "$source" || grep -Fq 'openrouter.ai' "$source"; then
    echo "EDGE REGISTRY CONFIG VIOLATION: WhatsApp AI direct-provider path must not retain Lovable/OpenRouter runtime dependencies in $source" >&2
    exit 1
  fi
done

grep -Fq 'inlineMediaPart' "$interpreter" \
  || { echo 'EDGE REGISTRY CONFIG VIOLATION: content-interpret inline multimodal evidence contract missing' >&2; exit 1; }
# The packet worker remains service-role-only behind verify_jwt=true. The
# handler must enforce the gateway-validated service_role JWT gate and must
# not regress to byte-for-byte comparison with the runtime admin secret.
grep -Fq 'trustedServiceRoleAuthorization(authorization)' "$worker" \
  || { echo 'EDGE REGISTRY CONFIG VIOLATION: packet AI worker service-role JWT authorization gate missing' >&2; exit 1; }
if grep -Fq 'authorization !== `Bearer ${serviceRoleKey}`' "$worker"; then
  echo 'EDGE REGISTRY CONFIG VIOLATION: packet AI worker must not compare caller JWT to runtime service-role secret' >&2
  exit 1
fi
grep -Fq 'whatsapp_packet_ai_interpretations' "$worker" \
  || { echo 'EDGE REGISTRY CONFIG VIOLATION: packet AI worker persistence contract missing' >&2; exit 1; }

grep -A1 -Fx '[functions.whatsapp-studio-inbox-bridge]' "$config" | grep -Fxq 'verify_jwt = false' \
  || { echo 'EDGE REGISTRY CONFIG VIOLATION: bridge custom-auth mode mismatch' >&2; exit 1; }
grep -Eq '^whatsapp-studio-inbox-bridge,[^,]+,false,controlled-service,custom-secret-plus-disabled-by-default,repository-present,certified-controlled-manual-only,repository-certified$' "$registry" \
  || { echo 'EDGE REGISTRY CONFIG VIOLATION: bridge certification disposition mismatch' >&2; exit 1; }

grep -A1 -Fx '[functions.admin-provision-user]' "$config" | grep -Fxq 'verify_jwt = true' \
  || { echo 'EDGE REGISTRY CONFIG VIOLATION: admin-provision-user JWT mismatch' >&2; exit 1; }

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

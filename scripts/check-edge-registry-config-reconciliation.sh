#!/usr/bin/env bash
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

registry='docs/security/edge-function-auth-registry-2026-07-31.csv'
config='supabase/config.toml'
doc='docs/security/EDGE_FUNCTION_REGISTRY_CONFIG_RECONCILIATION_2026-07-31.md'
interpreter='supabase/functions/whatsapp-content-interpret/index.ts'
worker='supabase/functions/whatsapp-packet-ai-worker/index.ts'
consumer='supabase/functions/whatsapp-packet-ai-consumer/index.ts'
operatorReplyConsumer='supabase/functions/whatsapp-operator-reply-consumer/index.ts'
shared_provider='supabase/functions/_shared/geminiProvider.ts'
financial_authority='supabase/functions/_shared/financialLedgerAuthority.ts'
bi_monthly_ledger='supabase/functions/generate-bi-monthly-ledger/index.ts'
rescue_ledger='supabase/functions/generate-rescue-ledger/index.ts'
oasis_ai_chat='supabase/functions/oasis-ai-chat/index.ts'

for file in "$registry" "$config" "$doc" "$shared_provider" "$interpreter" "$worker" "$consumer" "$operatorReplyConsumer" "$financial_authority" "$bi_monthly_ledger" "$rescue_ledger" "$oasis_ai_chat"; do
  [[ -f "$file" ]] || { echo "EDGE REGISTRY CONFIG VIOLATION: missing $file" >&2; exit 1; }
done

expected=(
  catalogue-ai-copy
  test-integration
  whatsapp-content-interpret
  whatsapp-packet-ai-worker
  whatsapp-packet-ai-consumer
  whatsapp-operator-reply-consumer
  whatsapp-studio-inbox-bridge
  admin-provision-user
  notify-event
  generate-bi-monthly-ledger
  generate-rescue-ledger
)
cert_runner='supabase/functions/whatsapp-stage1b-cert-runner/index.ts'
if [[ -f "$cert_runner" ]]; then expected+=(whatsapp-stage1b-cert-runner); fi
for fn in "${expected[@]}"; do
  grep -Fxq "[functions.${fn}]" "$config" || { echo "EDGE REGISTRY CONFIG VIOLATION: ${fn} missing from config" >&2; exit 1; }
done

# The authentication registry is the LIVE production inventory. Repository
# config may also declare preview/candidate sources that are not yet live in
# their hardened form. Such candidates must remain truthfully marked pending
# in the registry until governed production deployment/runtime certification.
for fn in catalogue-ai-copy whatsapp-studio-inbox-bridge notify-event generate-bi-monthly-ledger generate-rescue-ledger oasis-ai-chat; do
  grep -Eq "^${fn}," "$registry" \
    || { echo "EDGE REGISTRY CONFIG VIOLATION: live function ${fn} missing from registry" >&2; exit 1; }
done
for fn in test-integration whatsapp-content-interpret whatsapp-packet-ai-worker whatsapp-packet-ai-consumer whatsapp-operator-reply-consumer admin-provision-user notify-event oasis-ai-chat; do
  [[ -f "supabase/functions/${fn}/index.ts" ]] \
    || { echo "EDGE REGISTRY CONFIG VIOLATION: ${fn} source missing" >&2; exit 1; }
done
for candidate in admin-provision-user whatsapp-packet-ai-consumer whatsapp-operator-reply-consumer; do
  if grep -Eq "^${candidate}," "$registry"; then
    echo "EDGE REGISTRY CONFIG VIOLATION: ${candidate} must not appear in the live-inventory registry until governed deployment and runtime certification" >&2; exit 1
  fi
done

count=$(grep -c '^\[functions\.' "$config")
expected_count=${#expected[@]}
[[ "$count" -eq "$expected_count" ]] \
  || { echo "EDGE REGISTRY CONFIG VIOLATION: config must declare exactly ${expected_count} functions, found $count" >&2; exit 1; }

grep -A1 -Fx '[functions.catalogue-ai-copy]' "$config" | grep -Fxq 'verify_jwt = true' || { echo 'EDGE REGISTRY CONFIG VIOLATION: catalogue-ai-copy JWT mismatch' >&2; exit 1; }
grep -Eq '^catalogue-ai-copy,[^,]+,true,' "$registry" || { echo 'EDGE REGISTRY CONFIG VIOLATION: catalogue-ai-copy registry JWT mismatch' >&2; exit 1; }
grep -A1 -Fx '[functions.test-integration]' "$config" | grep -Fxq 'verify_jwt = true' || { echo 'EDGE REGISTRY CONFIG VIOLATION: test-integration JWT mismatch' >&2; exit 1; }
grep -A1 -Fx '[functions.whatsapp-content-interpret]' "$config" | grep -Fxq 'verify_jwt = true' || { echo 'EDGE REGISTRY CONFIG VIOLATION: whatsapp-content-interpret JWT mismatch' >&2; exit 1; }
grep -A1 -Fx '[functions.whatsapp-packet-ai-worker]' "$config" | grep -Fxq 'verify_jwt = true' || { echo 'EDGE REGISTRY CONFIG VIOLATION: whatsapp-packet-ai-worker JWT mismatch' >&2; exit 1; }
for fn in test-integration whatsapp-content-interpret whatsapp-packet-ai-worker; do
  if grep -Eq "^${fn}," "$registry"; then echo "EDGE REGISTRY CONFIG VIOLATION: preview-only ${fn} must not be added to the live registry before approved production activation" >&2; exit 1; fi
done

grep -A1 -Fx '[functions.whatsapp-packet-ai-consumer]' "$config" | grep -Fxq 'verify_jwt = false' \
  || { echo 'EDGE REGISTRY CONFIG VIOLATION: packet AI consumer custom-auth mode mismatch' >&2; exit 1; }
grep -Fq 'x-oasis-worker-secret' "$consumer" \
  || { echo 'EDGE REGISTRY CONFIG VIOLATION: packet AI consumer machine credential header missing' >&2; exit 1; }
grep -Fq 'verify_whatsapp_packet_ai_consumer_secret' "$consumer" \
  || { echo 'EDGE REGISTRY CONFIG VIOLATION: packet AI consumer Vault verifier missing' >&2; exit 1; }
grep -Fq 'processWorkerRequest(admin, { claim_next: true })' "$consumer" \
  || { echo 'EDGE REGISTRY CONFIG VIOLATION: packet AI consumer durable claim path missing' >&2; exit 1; }

grep -A1 -Fx '[functions.whatsapp-operator-reply-consumer]' "$config" | grep -Fxq 'verify_jwt = false' \
  || { echo 'EDGE REGISTRY CONFIG VIOLATION: operator-reply consumer custom-auth mode mismatch' >&2; exit 1; }
grep -Fq 'x-oasis-worker-secret' "$operatorReplyConsumer" \
  || { echo 'EDGE REGISTRY CONFIG VIOLATION: operator-reply consumer machine credential header missing' >&2; exit 1; }
grep -Fq 'verify_whatsapp_operator_reply_consumer_secret' "$operatorReplyConsumer" \
  || { echo 'EDGE REGISTRY CONFIG VIOLATION: operator-reply consumer Vault verifier missing' >&2; exit 1; }
grep -Fq 'consumeAvailableReplies' "$operatorReplyConsumer" \
  || { echo 'EDGE REGISTRY CONFIG VIOLATION: operator-reply consumer durable claim path missing' >&2; exit 1; }
if grep -Eq 'Authorization.*serviceRoleKey|Bearer.*serviceRoleKey' "$operatorReplyConsumer"; then
  echo 'EDGE REGISTRY CONFIG VIOLATION: operator-reply consumer must not accept caller service-role credentials' >&2; exit 1
fi

if grep -Eq 'Authorization.*serviceRoleKey|Bearer.*serviceRoleKey' "$consumer"; then
  echo 'EDGE REGISTRY CONFIG VIOLATION: packet AI consumer must not accept caller service-role credentials' >&2; exit 1
fi

# notify-event is already a live legacy function. This branch supplies its
# hardened canonical source and future verify_jwt=true configuration, while
# the live registry must remain false/pending until production deployment is
# actually performed and certified.
grep -A1 -Fx '[functions.notify-event]' "$config" | grep -Fxq 'verify_jwt = true' \
  || { echo 'EDGE REGISTRY CONFIG VIOLATION: notify-event hardened JWT mode missing from config' >&2; exit 1; }
grep -Eq '^notify-event,[^,]+,false,internal-service,service-secret-or-jwt,repository-present,hardening-pending-production-deploy,pending$' "$registry" \
  || { echo 'EDGE REGISTRY CONFIG VIOLATION: notify-event pre-deploy registry disposition mismatch' >&2; exit 1; }
grep -Eq '^oasis-ai-chat,87,false,internal-staff-ai,manual-bearer-auth-getUser-plus-internal-staff,repository-present,contained-live-source-captured,pending$' "$registry" \
  || { echo 'EDGE REGISTRY CONFIG VIOLATION: oasis-ai-chat live v86 registry disposition mismatch' >&2; exit 1; }
verify_oasis_ai_chat_authorization_structure() {
  local source="$1"
  python3 - "$source" <<'PY'
import pathlib, re, sys

path = pathlib.Path(sys.argv[1])
text = path.read_text()

def pos(pattern):
    match = re.search(pattern, text, re.MULTILINE)
    return -1 if match is None else match.start()

bearer_call = pos(r'^\s*const \{ data: authData, error: authError \} = await admin\.auth\.getUser\(token\);')
user_id = pos(r'^\s*const userId = authData\.user\?\.id \?\? null;')
bearer_gate = pos(r'^\s*if \(authError \|\| !userId\) return json\(401, \{ error: "unauthorized" \}\);')
staff_call = pos(r'^\s*const \{ data: isStaff, error: staffError \} = await admin\.rpc\("is_internal_staff", \{ _user_id: userId \}\);')
staff_gate = pos(r'^\s*if \(isStaff !== true\) return json\(403, \{ error: "forbidden" \}\);')
provider_request = pos(r'^\s*const resp = await fetch\("https://ai\.gateway\.lovable\.dev/v1/chat/completions", \{')

required = {
    "bearer verification": bearer_call,
    "user id derivation": user_id,
    "401 fail-closed bearer gate": bearer_gate,
    "internal-staff lookup": staff_call,
    "403 fail-closed staff gate": staff_gate,
    "paid provider request": provider_request,
}
missing = [label for label, offset in required.items() if offset < 0]
if missing:
    raise SystemExit(
        f"EDGE REGISTRY CONFIG VIOLATION: {path} oasis-ai-chat authorization structure missing: {', '.join(missing)}"
    )

if not bearer_call < user_id < bearer_gate < staff_call < staff_gate < provider_request:
    raise SystemExit(
        f"EDGE REGISTRY CONFIG VIOLATION: {path} paid provider request is not strictly gated by bearer and internal-staff authorization"
    )
PY
}

verify_oasis_ai_chat_authorization_structure "$oasis_ai_chat"
if grep -Fxq '[functions.oasis-ai-chat]' "$config"; then
  echo 'EDGE REGISTRY CONFIG VIOLATION: oasis-ai-chat is production-captured and must not be preview auto-deployed' >&2
  exit 1
fi


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
for source in "$interpreter" "$worker" "$shared_provider" "$consumer"; do
  if grep -Fq 'LOVABLE_API_KEY' "$source" || grep -Fq 'ai.gateway.lovable.dev' "$source" || grep -Fq 'openai/gpt-4o-mini-transcribe' "$source" || grep -Fq 'openrouter.ai' "$source"; then
    echo "EDGE REGISTRY CONFIG VIOLATION: WhatsApp AI direct-provider path must not retain Lovable/OpenRouter runtime dependencies in $source" >&2; exit 1
  fi
done

grep -Fq 'inlineMediaPart' "$interpreter" || { echo 'EDGE REGISTRY CONFIG VIOLATION: content-interpret inline multimodal evidence contract missing' >&2; exit 1; }
grep -Fq 'trustedServiceRoleAuthorization(authorization)' "$worker" || { echo 'EDGE REGISTRY CONFIG VIOLATION: packet AI worker service-role JWT authorization gate missing' >&2; exit 1; }
if grep -Fq 'authorization !== `Bearer ${serviceRoleKey}`' "$worker"; then echo 'EDGE REGISTRY CONFIG VIOLATION: packet AI worker must not compare caller JWT to runtime service-role secret' >&2; exit 1; fi
grep -Fq 'whatsapp_packet_ai_interpretations' "$worker" || { echo 'EDGE REGISTRY CONFIG VIOLATION: packet AI worker persistence contract missing' >&2; exit 1; }

grep -A1 -Fx '[functions.whatsapp-studio-inbox-bridge]' "$config" | grep -Fxq 'verify_jwt = false' || { echo 'EDGE REGISTRY CONFIG VIOLATION: bridge custom-auth mode mismatch' >&2; exit 1; }
grep -Eq '^whatsapp-studio-inbox-bridge,[^,]+,false,controlled-service,custom-secret-plus-disabled-by-default,repository-present,certified-controlled-manual-only,repository-certified$' "$registry" || { echo 'EDGE REGISTRY CONFIG VIOLATION: bridge certification disposition mismatch' >&2; exit 1; }
grep -A1 -Fx '[functions.admin-provision-user]' "$config" | grep -Fxq 'verify_jwt = true' || { echo 'EDGE REGISTRY CONFIG VIOLATION: admin-provision-user JWT mismatch' >&2; exit 1; }

verify_financial_handler_structure() {
  local source="$1"
  python3 - "$source" <<'PY'
import pathlib, re, sys
path = pathlib.Path(sys.argv[1])
text = path.read_text()
def pos(pattern):
    m = re.search(pattern, text, re.MULTILINE)
    return -1 if m is None else m.start()
authority = pos(r'^\s*const authority = await requireFinancialLedgerAuthority\(')
gate = pos(r'^\s*if \(!authority\.ok\) return jsonResponse\(')
admin = pos(r'^\s*const admin = createAdminClient\(')
claim = pos(r'^\s*const \{ data: claimed, error: claimError \} = await admin\.rpc\(')
delivery = pos(r'^\s*const delivery = await (?:sendWhatsAppPdf|sendSoftWhatsApp)\(')
if min(authority, gate, admin, claim, delivery) < 0:
    raise SystemExit(f"EDGE REGISTRY CONFIG VIOLATION: {path} structural financial authority/delivery contract missing")
if not authority < gate < admin:
    raise SystemExit(f"EDGE REGISTRY CONFIG VIOLATION: {path} authority does not gate business execution")
if not claim < delivery:
    raise SystemExit(f"EDGE REGISTRY CONFIG VIOLATION: {path} provider delivery can execute before atomic claim")
PY
}

for fn in generate-bi-monthly-ledger generate-rescue-ledger; do
  grep -A1 -Fx "[functions.${fn}]" "$config" | grep -Fxq 'verify_jwt = false' || { echo "EDGE REGISTRY CONFIG VIOLATION: ${fn} custom-auth mode mismatch" >&2; exit 1; }
  verify_financial_handler_structure "supabase/functions/${fn}/index.ts"
done
grep -Fq 'x-oasis-cron-secret' "$financial_authority" || { echo 'EDGE REGISTRY CONFIG VIOLATION: financial ledger machine credential header missing' >&2; exit 1; }
grep -Fq 'verify_financial_ledger_cron_secret' "$financial_authority" || { echo 'EDGE REGISTRY CONFIG VIOLATION: financial ledger Vault secret verifier missing' >&2; exit 1; }
grep -Fq 'is_financial_ledger_operator' "$financial_authority" || { echo 'EDGE REGISTRY CONFIG VIOLATION: financial ledger Finance/Admin role gate missing' >&2; exit 1; }
if grep -Eq 'Authorization.*serviceRoleKey|Bearer.*serviceRoleKey' "$financial_authority" "$bi_monthly_ledger" "$rescue_ledger"; then echo 'EDGE REGISTRY CONFIG VIOLATION: financial ledger functions must not accept caller service-role secrets' >&2; exit 1; fi

if [[ -f "$cert_runner" ]]; then
  grep -A1 -Fx '[functions.whatsapp-stage1b-cert-runner]' "$config" | grep -Fxq 'verify_jwt = false' || { echo 'EDGE REGISTRY CONFIG VIOLATION: whatsapp-stage1b-cert-runner must use custom cert auth (verify_jwt=false)' >&2; exit 1; }
  grep -Fq 'NON-PRODUCTION' "$cert_runner" || { echo 'EDGE REGISTRY CONFIG VIOLATION: whatsapp-stage1b-cert-runner must be labeled NON-PRODUCTION' >&2; exit 1; }
  grep -Fq 'PREVIEW_PIN_FAILED' 'supabase/functions/_shared/stage1bCert/previewPin.ts' || { echo 'EDGE REGISTRY CONFIG VIOLATION: stage1b preview pin guard missing' >&2; exit 1; }
  if grep -Eq '^whatsapp-stage1b-cert-runner,' "$registry"; then echo 'EDGE REGISTRY CONFIG VIOLATION: whatsapp-stage1b-cert-runner must not appear in live production registry' >&2; exit 1; fi
fi

for prohibited in whatsapp-webhook generate-product-attributes; do
  if grep -Fxq "[functions.${prohibited}]" "$config"; then echo "EDGE REGISTRY CONFIG VIOLATION: ${prohibited} must remain absent from preview config" >&2; exit 1; fi
done

grep -Eq '^generate-product-attributes,[^,]+,false,retired-endpoint,none-accepted,repository-tombstone,retired-runtime-removal-pending,repository-closed$' "$registry" || { echo 'EDGE REGISTRY CONFIG VIOLATION: retired generator disposition mismatch' >&2; exit 1; }
grep -Eq '^whatsapp-webhook,[^,]+,false,provider-webhook,meta-verification-plus-signature-plus-replay,repository-present,failed-certification-continued-quarantine,review-complete$' "$registry" || { echo 'EDGE REGISTRY CONFIG VIOLATION: webhook quarantine disposition mismatch' >&2; exit 1; }

rows=$(( $(wc -l < "$registry") - 1 ))
[[ "$rows" -eq 26 ]] || { echo "EDGE REGISTRY CONFIG VIOLATION: registry must contain 26 live functions, found $rows" >&2; exit 1; }
grep -Fq 'Procedure 7 is complete at repository level.' "$doc" || { echo 'EDGE REGISTRY CONFIG VIOLATION: procedure disposition missing' >&2; exit 1; }
grep -Fq 'Procedure 8 is the only phase permitted to record runtime certification' "$doc" || { echo 'EDGE REGISTRY CONFIG VIOLATION: runtime boundary missing' >&2; exit 1; }

echo 'Edge Function registry/config reconciliation check passed.'

#!/usr/bin/env bash
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

doc='docs/security/WHATSAPP_WEBHOOK_RECERTIFICATION_2026-07-31.md'
runtime_doc='docs/security/WHATSAPP_CLICK2API_RUNTIME_EVIDENCE_2026-08-01.md'
config='supabase/config.toml'
ownership='FUNCTION_OWNERSHIP.md'
source='supabase/functions/whatsapp-webhook/index.ts'
boundary='supabase/functions/_shared/whatsappWebhookBoundary.ts'
boundary_test='supabase/functions/_shared/whatsappWebhookBoundary.test.ts'
security_test='supabase/functions/_shared/whatsappWebhookSecurity.test.ts'

for file in "$doc" "$runtime_doc" "$config" "$ownership" "$source" "$boundary" "$boundary_test" "$security_test"; do
  [[ -f "$file" ]] || { echo "WHATSAPP WEBHOOK RECERTIFICATION VIOLATION: missing $file" >&2; exit 1; }
done

# WA-1 permanent quarantine: no environment switch may restore webhook order writes,
# and ambiguous quantities may never become executable quantity 1.
if grep -q 'isWaWebhookAutoOrderWritesEnabled' "$source"; then
  echo 'WA-1 failure: legacy webhook auto-order flag remains executable' >&2
  exit 1
fi
if grep -Eq 'quantity:[[:space:]]*item\.quantity[[:space:]]*\|\|[[:space:]]*1|return[[:space:]]+1;.*quantity|qty:[[:space:]]*i\.qty[[:space:]]*\|\|[[:space:]]*1' "$source"; then
  echo 'WA-1 failure: executable WhatsApp quantity default remains' >&2
  exit 1
fi
grep -Fq 'const waAutoOrderWritesEnabled = false;' "$source" || {
  echo 'WA-1 failure: legacy webhook order-write quarantine missing' >&2
  exit 1
}

grep -Fq '**NOT CERTIFIED FOR DEPLOYMENT.**' "$doc" \
  || { echo 'WHATSAPP WEBHOOK RECERTIFICATION VIOLATION: failed certification outcome missing' >&2; exit 1; }
grep -Fq 'continued quarantine' "$doc" \
  || { echo 'WHATSAPP WEBHOOK RECERTIFICATION VIOLATION: quarantine disposition missing' >&2; exit 1; }

if grep -Fxq '[functions.whatsapp-webhook]' "$config"; then
  echo 'WHATSAPP WEBHOOK RECERTIFICATION VIOLATION: high-risk webhook declared for preview deployment' >&2
  exit 1
fi

grep -Fq 'Do not deploy unless there is an explicit approved ERP webhook migration plan.' "$ownership" \
  || { echo 'WHATSAPP WEBHOOK RECERTIFICATION VIOLATION: legacy ownership deployment guard missing' >&2; exit 1; }

command -v deno >/dev/null 2>&1 \
  || { echo 'WHATSAPP WEBHOOK RECERTIFICATION VIOLATION: deno required for executable boundary certification' >&2; exit 1; }

deno check "$boundary"
deno test "$security_test" "$boundary_test"

# Supplemental structural safeguards. Behavioral trust comes from the executable tests above.
grep -Fq 'authenticateAndParseWebhook(' "$source" \
  || { echo 'WHATSAPP WEBHOOK RECERTIFICATION VIOLATION: executable request boundary not wired into handler' >&2; exit 1; }
grep -Fq 'WHATSAPP_WEBHOOK_VERIFY_TOKEN' "$source" \
  || { echo 'WHATSAPP WEBHOOK RECERTIFICATION VIOLATION: verify-token secret boundary missing' >&2; exit 1; }
if grep -Fq 'Handshake Token Candidates:' "$source"; then
  echo 'WHATSAPP WEBHOOK RECERTIFICATION VIOLATION: secret-bearing handshake logging reintroduced' >&2
  exit 1
fi
if grep -Fq 'Incoming WhatsApp webhook:' "$source"; then
  echo 'WHATSAPP WEBHOOK RECERTIFICATION VIOLATION: raw webhook runtime logging reintroduced' >&2
  exit 1
fi
if grep -Fq 'const payload = await req.json();' "$source"; then
  echo 'WHATSAPP WEBHOOK RECERTIFICATION VIOLATION: unauthenticated JSON parsing reintroduced' >&2
  exit 1
fi

if grep -Eiq '^\*\*CERTIFIED FOR DEPLOYMENT\.\*\*$|^certification passed$|^runtime certified$' "$doc" "$runtime_doc"; then
  echo 'WHATSAPP WEBHOOK RECERTIFICATION VIOLATION: unsupported positive certification claim detected' >&2
  exit 1
fi

grep -Fq 'Production sign-off remains withheld' "$runtime_doc" \
  || { echo 'WHATSAPP WEBHOOK RECERTIFICATION VIOLATION: runtime evidence gate must remain withheld' >&2; exit 1; }

echo 'WhatsApp webhook recertification guard passed (executable hardened boundary verified; production sign-off still withheld).'

#!/usr/bin/env bash
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

doc='docs/security/WHATSAPP_WEBHOOK_RECERTIFICATION_2026-07-31.md'
config='supabase/config.toml'
ownership='FUNCTION_OWNERSHIP.md'
source='supabase/functions/whatsapp-webhook/index.ts'

for file in "$doc" "$config" "$ownership" "$source"; do
  [[ -f "$file" ]] || { echo "WHATSAPP WEBHOOK RECERTIFICATION VIOLATION: missing $file" >&2; exit 1; }
done

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

# Until a dedicated hardening tranche replaces these patterns, their presence
# proves that certification must remain failed rather than silently upgraded.
grep -Fq 'Handshake Token Candidates:' "$source" \
  || { echo 'WHATSAPP WEBHOOK RECERTIFICATION VIOLATION: source changed; rerun dedicated recertification' >&2; exit 1; }
grep -Fq 'const payload = await req.json();' "$source" \
  || { echo 'WHATSAPP WEBHOOK RECERTIFICATION VIOLATION: request boundary changed; rerun dedicated recertification' >&2; exit 1; }

if grep -Eiq 'CERTIFIED FOR DEPLOYMENT|certification passed|runtime certified' "$doc"; then
  echo 'WHATSAPP WEBHOOK RECERTIFICATION VIOLATION: unsupported positive certification claim detected' >&2
  exit 1
fi

echo 'WhatsApp webhook recertification guard passed (deployment remains blocked).'

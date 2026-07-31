#!/usr/bin/env bash
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

doc='docs/security/WHATSAPP_STUDIO_INBOX_BRIDGE_CERTIFICATION_2026-07-31.md'
source='supabase/functions/whatsapp-studio-inbox-bridge/index.ts'
config='supabase/config.toml'

for file in "$doc" "$source" "$config"; do
  [[ -f "$file" ]] || { echo "STUDIO BRIDGE CERTIFICATION VIOLATION: missing $file" >&2; exit 1; }
done

grep -Fq '**CERTIFIED FOR CONTROLLED, MANUAL EXECUTION ONLY.**' "$doc" \
  || { echo 'STUDIO BRIDGE CERTIFICATION VIOLATION: controlled certification outcome missing' >&2; exit 1; }
grep -Fq 'Recurring scheduling remains prohibited until Procedure 8 runtime certification.' "$doc" \
  || { echo 'STUDIO BRIDGE CERTIFICATION VIOLATION: runtime restriction missing' >&2; exit 1; }

grep -A1 -Fx '[functions.whatsapp-studio-inbox-bridge]' "$config" | grep -Fxq 'verify_jwt = false' \
  || { echo 'STUDIO BRIDGE CERTIFICATION VIOLATION: custom-auth configuration changed' >&2; exit 1; }

grep -Fq 'BRIDGE_CRON_SECRET' "$source" \
  || { echo 'STUDIO BRIDGE CERTIFICATION VIOLATION: bridge secret boundary missing' >&2; exit 1; }
grep -Fq 'auth === `Bearer ${secret}`' "$source" \
  || { echo 'STUDIO BRIDGE CERTIFICATION VIOLATION: exact bearer check missing' >&2; exit 1; }
grep -Fq 'BRIDGE_ENABLED' "$source" \
  || { echo 'STUDIO BRIDGE CERTIFICATION VIOLATION: disabled-by-default gate missing' >&2; exit 1; }
grep -Fq 'Math.min(Math.max' "$source" \
  || { echo 'STUDIO BRIDGE CERTIFICATION VIOLATION: bounded batch control missing' >&2; exit 1; }
grep -Fq '.eq("direction", "inbound")' "$source" \
  || { echo 'STUDIO BRIDGE CERTIFICATION VIOLATION: inbound-only filter missing' >&2; exit 1; }

if grep -Eiq 'CERTIFIED FOR PUBLIC USE|UNATTENDED SCHEDULING APPROVED|RUNTIME CERTIFIED' "$doc"; then
  echo 'STUDIO BRIDGE CERTIFICATION VIOLATION: unsupported readiness claim detected' >&2
  exit 1
fi

echo 'Studio inbox bridge repository certification guard passed.'

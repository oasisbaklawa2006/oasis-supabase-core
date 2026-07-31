#!/usr/bin/env bash
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

source='supabase/functions/test-integration/index.ts'
doc='docs/security/INTEGRATION_HEALTH_VERIFICATION_2026-07-31.md'
config='supabase/config.toml'

for file in "$source" "$doc" "$config"; do
  [[ -f "$file" ]] || { echo "INTEGRATION HEALTH VIOLATION: missing $file" >&2; exit 1; }
done

grep -A1 -Fx '[functions.test-integration]' "$config" | grep -Fxq 'verify_jwt = true' \
  || { echo 'INTEGRATION HEALTH VIOLATION: test-integration must verify JWT' >&2; exit 1; }

grep -Fq 'get_current_user_roles' "$source" \
  || { echo 'INTEGRATION HEALTH VIOLATION: role boundary missing' >&2; exit 1; }
grep -Fq 'Owner or admin role required' "$source" \
  || { echo 'INTEGRATION HEALTH VIOLATION: owner/admin enforcement missing' >&2; exit 1; }
grep -Fq 'Credentials present but live connectivity test not implemented' "$source" \
  || { echo 'INTEGRATION HEALTH VIOLATION: truthful no-connectivity result missing' >&2; exit 1; }
grep -Fq 'No automated test defined yet' "$source" \
  || { echo 'INTEGRATION HEALTH VIOLATION: undefined integration failure missing' >&2; exit 1; }

if grep -Eq 'ok:[[:space:]]*true|result\.ok[[:space:]]*=[[:space:]]*true' "$source"; then
  echo 'INTEGRATION HEALTH VIOLATION: unverified integration success path detected' >&2
  exit 1
fi

grep -Fq 'no external integration is runtime-certified' "$doc" \
  || { echo 'INTEGRATION HEALTH VIOLATION: runtime limitation missing' >&2; exit 1; }

echo 'Integration health verification guard passed (provider runtime health remains unverified).'

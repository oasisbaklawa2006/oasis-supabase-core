#!/usr/bin/env bash
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

doc='docs/security/EDGE_FUNCTION_RUNTIME_CERTIFICATION_2026-07-31.md'
registry='docs/security/edge-function-auth-registry-2026-07-31.csv'
config='supabase/config.toml'

for file in "$doc" "$registry" "$config"; do
  [[ -f "$file" ]] || { echo "EDGE RUNTIME CERTIFICATION VIOLATION: missing $file" >&2; exit 1; }
done

grep -Fq '**PRODUCTION SIGN-OFF WITHHELD.**' "$doc" \
  || { echo 'EDGE RUNTIME CERTIFICATION VIOLATION: truthful sign-off decision missing' >&2; exit 1; }
grep -Fq 'Production certification: **blocked pending live evidence**.' "$doc" \
  || { echo 'EDGE RUNTIME CERTIFICATION VIOLATION: live-evidence blocker missing' >&2; exit 1; }
grep -Fq 'Overall remediation closure: **not complete**.' "$doc" \
  || { echo 'EDGE RUNTIME CERTIFICATION VIOLATION: premature remediation closure detected' >&2; exit 1; }

# Runtime closure cannot be inferred from repository state.
if grep -Eiq 'production (is )?certified|runtime certification passed|8 of 8 procedures complete|overall remediation closure: \*\*complete\*\*' "$doc"; then
  echo 'EDGE RUNTIME CERTIFICATION VIOLATION: unsupported runtime success claim detected' >&2
  exit 1
fi

# High-risk functions must remain outside preview deployment configuration.
for prohibited in whatsapp-webhook generate-product-attributes; do
  if grep -Fxq "[functions.${prohibited}]" "$config"; then
    echo "EDGE RUNTIME CERTIFICATION VIOLATION: ${prohibited} cannot enter preview deployment config" >&2
    exit 1
  fi
done

# No registry row may claim runtime closure before an evidence-backed follow-up.
if grep -E ',runtime-certified$|,production-closed$|,closed$' "$registry" >/dev/null; then
  echo 'EDGE RUNTIME CERTIFICATION VIOLATION: registry contains unsupported runtime closure' >&2
  exit 1
fi

for required in \
  'Confirm whether production version 96 is still callable.' \
  'Do not deploy the repository source.' \
  'Invoke one authenticated dry run with a small explicit limit.' \
  'Capture pre-change function versions and configuration.'; do
  grep -Fq "$required" "$doc" \
    || { echo "EDGE RUNTIME CERTIFICATION VIOLATION: required evidence gate missing: $required" >&2; exit 1; }
done

echo 'Edge Function runtime certification gate passed (production sign-off remains withheld).'

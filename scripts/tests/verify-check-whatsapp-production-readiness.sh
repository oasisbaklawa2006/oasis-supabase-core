#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
script="$repo_root/scripts/check-whatsapp-production-readiness.sh"

bash -n "$script"

if grep -Eq 'whatsapp_run_packet_ai_consumer_tick\(\)' "$script" \
  && ! grep -Fq 'ALLOW_CONSUMER_TICK' "$script"; then
  echo 'readiness script must gate consumer tick behind ALLOW_CONSUMER_TICK' >&2
  exit 1
fi

grep -Fq 'skipped(read-only)' "$script"
grep -Fq 'if [[ "${ALLOW_CONSUMER_TICK:-0}" == "1" ]]; then' "$script"

# Default path must not invoke the consumer tick RPC.
default_source="$(
  awk '
    /^if \[\[ "\$\{ALLOW_CONSUMER_TICK:-0\}" == "1" \]\]; then/ { in_branch=1; next }
    in_branch && /^[[:space:]]*fi[[:space:]]*$/ { in_branch=0; next }
    in_branch { next }
    { print }
  ' "$script"
)"
if printf '%s\n' "$default_source" | grep -Fq 'whatsapp_run_packet_ai_consumer_tick()'; then
  echo 'default readiness path still invokes whatsapp_run_packet_ai_consumer_tick()' >&2
  exit 1
fi

echo 'verify-check-whatsapp-production-readiness.sh: all cases passed'

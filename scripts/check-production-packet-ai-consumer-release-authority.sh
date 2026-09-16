#!/usr/bin/env bash
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

workflow='.github/workflows/production-whatsapp-packet-ai-consumer-release.yml'
activate_sql='scripts/sql/activate-whatsapp-packet-ai-consumer-production.sql'
rollback_sql='scripts/sql/deactivate-whatsapp-packet-ai-consumer-production.sql'
deploy_phrase='supabase functions deploy'
consumer_slug='whatsapp-packet-ai-consumer'

fail() { echo "PACKET-AI PRODUCTION RELEASE AUTHORITY VIOLATION: $*" >&2; exit 1; }

for file in "$workflow" "$activate_sql" "$rollback_sql"; do
  [[ -f "$file" ]] || fail "missing governed release artifact: $file"
done

# Workflow must remain manual, exact-SHA bound, and protected by the two existing
# production environments. A merge alone must never deploy or activate anything.
grep -Fq 'workflow_dispatch:' "$workflow" || fail 'workflow is not manual-dispatch only'
if grep -Eq '^[[:space:]]+(push|pull_request|schedule|workflow_run):' "$workflow"; then
  fail 'automatic trigger added to production consumer release'
fi
grep -Fq 'release_sha:' "$workflow" || fail 'exact release SHA input missing'
grep -Fq 'test "$(git rev-parse origin/main)" = "$RELEASE_SHA_INPUT"' "$workflow" \
  || fail 'current-main binding missing'
grep -Fq 'environment: supabase-production-readonly' "$workflow" \
  || fail 'read-only preflight environment missing'
grep -Fq 'environment: supabase-production' "$workflow" \
  || fail 'protected production environment missing'
grep -Fq 'if: inputs.activate == true' "$workflow" \
  || fail 'explicit activation boolean gate missing'

# Only the single consumer may be deployed. Broad function deployment is never
# acceptable on the production project. Build the phrase dynamically so this
# guard script itself cannot false-trigger the repository deployment scanner.
specific_command="${deploy_phrase} ${consumer_slug}"
count_specific="$(grep -Fc "$specific_command" "$workflow" || true)"
[[ "$count_specific" = '1' ]] || fail 'expected exactly one explicit consumer deployment command'
while IFS= read -r line; do
  [[ "$line" == *"$deploy_phrase"* ]] || continue
  [[ "$line" == *"$specific_command"* ]] \
    || fail 'release workflow contains a broad or non-consumer Edge Function deployment command'
done < "$workflow"
grep -Fq -- '--no-verify-jwt' "$workflow" \
  || fail 'consumer custom-auth deployment mode is missing'

# The custom-auth boundary must be probed before the scheduler URL becomes live.
grep -Fq "test \"\$status\" = '401'" "$workflow" \
  || fail 'pre-activation unauthorized probe is missing'
activate_line="$(grep -n 'Activate governed scheduler URL' "$workflow" | cut -d: -f1)"
probe_line="$(grep -n 'Prove custom-auth boundary before scheduler activation' "$workflow" | cut -d: -f1)"
[[ -n "$activate_line" && -n "$probe_line" && "$probe_line" -lt "$activate_line" ]] \
  || fail 'custom-auth probe must precede activation'

# Activation and rollback must be confined to the two reviewed SQL files.
grep -Fq -- '-f scripts/sql/activate-whatsapp-packet-ai-consumer-production.sql' "$workflow" \
  || fail 'activation SQL invocation missing'
grep -Fq -- '-f scripts/sql/deactivate-whatsapp-packet-ai-consumer-production.sql' "$workflow" \
  || fail 'fail-closed rollback SQL invocation missing'
grep -Fq "if: steps.activate.outcome == 'failure'" "$workflow" \
  || fail 'runtime failure rollback gate missing'

for sql in "$activate_sql" "$rollback_sql"; do
  grep -Eq '^[[:space:]]*begin;' "$sql" || fail "$sql must use an explicit transaction"
  grep -Eq '^[[:space:]]*commit;' "$sql" || fail "$sql must commit explicitly"
  if grep -Eiq '^[[:space:]]*(create|alter|drop|truncate|insert|update|delete|grant|revoke)[[:space:]]' "$sql"; then
    fail "$sql contains direct schema/DML authority outside Vault helper calls"
  fi
  if grep -Eiq '\b(execute|dblink|copy|lo_import|pg_read_file|pg_write_file)\b' "$sql"; then
    fail "$sql contains dynamic/file execution authority"
  fi
done

grep -Fq 'vault.update_secret(' "$activate_sql" || fail 'activation does not update existing URL authority'
grep -Fq 'vault.create_secret(' "$activate_sql" || fail 'activation does not create URL authority when absent'
grep -Fq "'whatsapp_packet_ai_consumer_url_v1'" "$activate_sql" || fail 'activation URL secret name changed'
grep -Fq "'whatsapp_packet_ai_consumer_url_v1'" "$rollback_sql" || fail 'rollback URL secret name changed'
if grep -Fq 'whatsapp_packet_ai_consumer_v1' "$rollback_sql"; then
  fail 'rollback must never mutate the machine credential'
fi

# Runtime certification must prove durable lease execution reached governed AI
# materialization and must reject expired leases.
grep -Fq 'attempt_count > 0' "$activate_sql" || fail 'queue movement assertion missing'
grep -Fq 'whatsapp_packet_ai_interpretations' "$activate_sql" || fail 'governed interpretation assertion missing'
grep -Fq 'PACKET_AI_RELEASE_NO_GOVERNED_INTERPRETATION' "$activate_sql" \
  || fail 'interpretation failure must fail the release'
grep -Fq 'PACKET_AI_RELEASE_EXPIRED_LEASE_DETECTED' "$activate_sql" \
  || fail 'expired lease assertion missing'
grep -Fq "'runtime_certified'" "$activate_sql" || fail 'runtime evidence marker missing'

echo 'Production WhatsApp packet AI consumer release authority check passed.'

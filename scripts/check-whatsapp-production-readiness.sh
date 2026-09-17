#!/usr/bin/env bash
# Read-only WhatsApp module production reconciliation checks.
# Does not mutate production. Exit non-zero when critical gates fail.
set -euo pipefail

PROJECT_REF="${SUPABASE_PROJECT_REF:-tcxvcatsqqertcnycuop}"
DB_URL="${DATABASE_URL:-}"

if [[ -z "$DB_URL" ]]; then
  echo "Set DATABASE_URL to a read-only production connection (oasis_drift_watch_ro or owner-approved RO)." >&2
  exit 2
fi

run_sql() {
  psql "$DB_URL" -v ON_ERROR_STOP=1 -Atqc "$1"
}

echo "WhatsApp production reconciliation (read-only)"
echo "project_ref=${PROJECT_REF}"

queued="$(run_sql "select count(*) from public.whatsapp_packet_ai_dispatch_jobs where state = 'QUEUED';")"
leased_expired="$(run_sql "select count(*) from public.whatsapp_packet_ai_dispatch_jobs where state = 'LEASED' and lease_expires_at < now();")"
orphan_queued_with_interp="$(run_sql "
  select count(*)
  from public.whatsapp_packet_ai_dispatch_jobs j
  where j.state in ('QUEUED','RETRY','BLOCKED_KNOWLEDGE_AUTHORITY')
    and exists (
      select 1 from public.whatsapp_packet_ai_interpretations i
      where i.packet_id = j.packet_id
    );")"
if [[ "${ALLOW_CONSUMER_TICK:-0}" == "1" ]]; then
  consumer_tick="$(run_sql "select public.whatsapp_run_packet_ai_consumer_tick();")"
else
  consumer_tick="skipped(read-only)"
fi
consumer_url_present="$(run_sql "
  select case when exists (
    select 1 from vault.secrets where name = 'whatsapp_packet_ai_consumer_url_v1'
  ) then 'yes' else 'no' end;")"
messages_without_packet="$(run_sql "
  select count(*) from public.whatsapp_messages
  where packet_id is null and direction = 'inbound'
    and created_at > now() - interval '30 days';")"

echo "queued_dispatch_jobs=${queued}"
echo "expired_leased_jobs=${leased_expired}"
echo "orphan_queued_jobs_with_interpretation=${orphan_queued_with_interp}"
echo "consumer_url_vault_secret_present=${consumer_url_present}"
echo "consumer_tick=${consumer_tick}"
echo "recent_inbound_without_packet=${messages_without_packet}"

classification="$(run_sql "
WITH queued AS (
  SELECT j.packet_id FROM public.whatsapp_packet_ai_dispatch_jobs j WHERE j.state = 'QUEUED'
), c AS (
  SELECT q.packet_id,
    EXISTS (SELECT 1 FROM public.whatsapp_packet_ai_interpretations i WHERE i.packet_id = q.packet_id) AS hi,
    EXISTS (SELECT 1 FROM public.whatsapp_communication_cases cc WHERE cc.packet_id = q.packet_id) AS hc,
    EXISTS (SELECT 1 FROM public.whatsapp_order_autonomy_decisions ad WHERE ad.packet_id = q.packet_id) AS ha
  FROM queued q
)
SELECT
  COUNT(*) FILTER (WHERE hi AND (hc OR ha)) AS cat_a_completed,
  COUNT(*) FILTER (WHERE NOT hi AND hc) AS cat_b_partial_case_no_interp,
  COUNT(*) FILTER (WHERE NOT hi AND NOT hc AND NOT ha) AS cat_c_never_processed,
  COUNT(*) AS total
FROM c;")"
echo "queued_job_classification=${classification}"

oldest_queued="$(run_sql "SELECT min(created_at)::text FROM public.whatsapp_packet_ai_dispatch_jobs WHERE state='QUEUED';")"
echo "oldest_queued_job=${oldest_queued}"

fail=0
if [[ "$messages_without_packet" != "0" ]]; then
  echo "FAIL: inbound messages missing packet assignment in last 30 days" >&2
  fail=1
fi
if [[ "$leased_expired" != "0" ]]; then
  echo "FAIL: stranded expired leases detected" >&2
  fail=1
fi
if [[ "$consumer_url_present" != "yes" ]]; then
  echo "BLOCKED: whatsapp_packet_ai_consumer_url_v1 vault secret missing (scheduler disabled)" >&2
  fail=1
fi
if [[ "$orphan_queued_with_interp" != "0" ]]; then
  echo "WARN: queued dispatch jobs exist despite interpretation evidence (direct-path reconcile pending deploy)" >&2
fi

if [[ "$fail" -ne 0 ]]; then
  exit 1
fi

echo "Read-only reconciliation checks completed."

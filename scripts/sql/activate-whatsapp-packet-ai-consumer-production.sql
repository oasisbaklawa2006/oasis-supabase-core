\set ON_ERROR_STOP on

-- Production control-plane activation only. This script is permitted solely from
-- the approval-gated Production WhatsApp Packet AI Consumer Release workflow.
-- It changes one Vault URL secret, then proves the scheduler actually consumes
-- a governed dispatch lease. It performs no schema DDL and never reads or emits
-- the machine secret value.

begin;

select vault.update_secret(
  secret_id,
  :'consumer_url',
  'whatsapp_packet_ai_consumer_url_v1',
  'Exact production URL for the governed WhatsApp packet AI consumer',
  null
)
from (
  select id as secret_id
  from vault.decrypted_secrets
  where name = 'whatsapp_packet_ai_consumer_url_v1'
  order by created_at desc
  limit 1
) existing;

select vault.create_secret(
  :'consumer_url',
  'whatsapp_packet_ai_consumer_url_v1',
  'Exact production URL for the governed WhatsApp packet AI consumer',
  null
)
where not exists (
  select 1
  from vault.decrypted_secrets
  where name = 'whatsapp_packet_ai_consumer_url_v1'
);

commit;

-- Give the existing once-per-minute cron enough time for at least one bounded tick.
select pg_sleep(95);

do $$
declare
  v_url_count bigint;
  v_active_cron_count bigint;
  v_attempted bigint;
  v_attempted_with_interpretation bigint;
  v_expired_leases bigint;
begin
  select count(*) into v_url_count
  from vault.decrypted_secrets
  where name = 'whatsapp_packet_ai_consumer_url_v1'
    and decrypted_secret ~ '^https://[^[:space:]]+/functions/v1/whatsapp-packet-ai-consumer$';

  if v_url_count <> 1 then
    raise exception 'PACKET_AI_RELEASE_URL_AUTHORITY_INVALID';
  end if;

  select count(*) into v_active_cron_count
  from cron.job
  where jobname = 'whatsapp-packet-ai-consumer-minute'
    and schedule = '* * * * *'
    and active = true
    and command = 'select public.whatsapp_run_packet_ai_consumer_tick();';

  if v_active_cron_count <> 1 then
    raise exception 'PACKET_AI_RELEASE_CRON_AUTHORITY_INVALID';
  end if;

  select count(*) into v_attempted
  from public.whatsapp_packet_ai_dispatch_jobs
  where attempt_count > 0;

  select count(*) into v_attempted_with_interpretation
  from public.whatsapp_packet_ai_dispatch_jobs j
  join public.whatsapp_packet_ai_interpretations i on i.packet_id = j.packet_id
  where j.execution_kind = 'PACKET'
    and j.attempt_count > 0;

  select count(*) into v_expired_leases
  from public.whatsapp_packet_ai_dispatch_jobs
  where state = 'LEASED'
    and lease_expires_at < statement_timestamp();

  if v_attempted = 0 then
    raise exception 'PACKET_AI_RELEASE_QUEUE_DID_NOT_MOVE';
  end if;
  if v_attempted_with_interpretation = 0 then
    raise exception 'PACKET_AI_RELEASE_NO_GOVERNED_INTERPRETATION';
  end if;
  if v_expired_leases <> 0 then
    raise exception 'PACKET_AI_RELEASE_EXPIRED_LEASE_DETECTED';
  end if;
end
$$;

select json_build_object(
  'status', 'runtime_certified',
  'attempted_jobs', (select count(*) from public.whatsapp_packet_ai_dispatch_jobs where attempt_count > 0),
  'attempted_packet_jobs_with_interpretation', (
    select count(*)
    from public.whatsapp_packet_ai_dispatch_jobs j
    join public.whatsapp_packet_ai_interpretations i on i.packet_id = j.packet_id
    where j.execution_kind = 'PACKET' and j.attempt_count > 0
  ),
  'queued_jobs', (select count(*) from public.whatsapp_packet_ai_dispatch_jobs where state = 'QUEUED'),
  'retry_jobs', (select count(*) from public.whatsapp_packet_ai_dispatch_jobs where state = 'RETRY'),
  'blocked_knowledge_jobs', (select count(*) from public.whatsapp_packet_ai_dispatch_jobs where state = 'BLOCKED_KNOWLEDGE_AUTHORITY'),
  'completed_jobs', (select count(*) from public.whatsapp_packet_ai_dispatch_jobs where state = 'COMPLETED')
) as packet_ai_runtime_evidence;

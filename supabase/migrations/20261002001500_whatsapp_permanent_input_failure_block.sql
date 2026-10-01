-- Final certification repair: stop deterministic oversized WhatsApp packets from retrying forever.
-- The durable record is preserved in a terminal blocked state for operator/reconciliation visibility.

begin;

alter table public.whatsapp_packet_ai_dispatch_jobs
  drop constraint whatsapp_packet_ai_dispatch_jobs_state_check;

alter table public.whatsapp_packet_ai_dispatch_jobs
  add constraint whatsapp_packet_ai_dispatch_jobs_state_check
  check (
    state = any (
      array[
        'QUEUED'::text,
        'LEASED'::text,
        'RETRY'::text,
        'BLOCKED_KNOWLEDGE_AUTHORITY'::text,
        'BLOCKED_INPUT_VALIDATION'::text,
        'COMPLETED'::text
      ]
    )
  );

create or replace function public.retry_whatsapp_packet_ai_dispatch_job(
  p_job_id uuid,
  p_lease_token uuid,
  p_packet_revision bigint,
  p_error_code text,
  p_error_detail text default null,
  p_knowledge_authority_failure boolean default false
)
returns boolean
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  v_updated integer;
  v_code text := left(btrim(coalesce(p_error_code,'')),120);
  v_detail text := left(btrim(coalesce(p_error_detail,'')),500);
  v_permanent_input_failure boolean;
begin
  if v_code='' then
    raise exception 'error code required' using errcode='22023';
  end if;

  -- Oversized packet evidence is deterministic for the claimed packet revision.
  -- Retrying it cannot heal the input and only creates an infinite poison-job loop.
  -- Preserve the job and error evidence, but stop autonomous retries until governed
  -- operator correction/splitting creates a new packet revision.
  v_permanent_input_failure := v_code = 'INTERPRETATION_PACKET_TOO_LARGE';

  update public.whatsapp_packet_ai_dispatch_jobs j
  set state = case
        when p_knowledge_authority_failure then 'BLOCKED_KNOWLEDGE_AUTHORITY'
        when v_permanent_input_failure then 'BLOCKED_INPUT_VALIDATION'
        else 'RETRY'
      end,
      claimed_at = null,
      lease_expires_at = null,
      lease_token = null,
      last_error_code = v_code,
      last_error_detail = nullif(v_detail,''),
      next_retry_at = case
        when v_permanent_input_failure then null
        else statement_timestamp()
          + make_interval(secs=>least(900,15*power(2,least(j.attempt_count,5))::integer))
      end,
      updated_at = statement_timestamp()
  where j.id = p_job_id
    and j.state = 'LEASED'
    and j.lease_token = p_lease_token
    and j.packet_revision = p_packet_revision
    and (
      j.execution_kind='PACKET'
      or exists(
        select 1
        from public.whatsapp_communication_cases c
        where c.id=j.case_id
          and c.context_revision=j.context_revision
      )
    );

  get diagnostics v_updated = row_count;
  return v_updated = 1;
end
$$;

revoke all on function public.retry_whatsapp_packet_ai_dispatch_job(uuid,uuid,bigint,text,text,boolean)
  from public, anon, authenticated;
grant execute on function public.retry_whatsapp_packet_ai_dispatch_job(uuid,uuid,bigint,text,text,boolean)
  to service_role;

comment on function public.retry_whatsapp_packet_ai_dispatch_job(uuid,uuid,bigint,text,text,boolean) is
  'Lease-bound packet AI failure handling. Transient failures retry with bounded backoff; deterministic oversized-packet input is preserved as BLOCKED_INPUT_VALIDATION and does not poison the retry queue.';

commit;

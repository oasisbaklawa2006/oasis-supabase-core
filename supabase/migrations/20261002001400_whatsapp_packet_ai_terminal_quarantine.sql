-- Final certification repair: terminate deterministic WhatsApp packet-AI retries.
-- Confirmed live defect: INTERPRETATION_PACKET_TOO_LARGE retried >1,500 times.
-- New inbound evidence still increments packet_revision and the existing enqueue
-- trigger re-queues the same packet, so quarantine is revision-scoped, not permanent.

begin;

alter table public.whatsapp_packet_ai_dispatch_jobs
  drop constraint if exists whatsapp_packet_ai_dispatch_jobs_state_check;

alter table public.whatsapp_packet_ai_dispatch_jobs
  add constraint whatsapp_packet_ai_dispatch_jobs_state_check
  check (state = any (array[
    'QUEUED'::text,
    'LEASED'::text,
    'RETRY'::text,
    'BLOCKED_KNOWLEDGE_AUTHORITY'::text,
    'QUARANTINED'::text,
    'COMPLETED'::text
  ]));

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
  v_permanent boolean;
  v_packet_id uuid;
  v_attempt_count integer;
  v_execution_kind text;
  v_case_id uuid;
begin
  if v_code='' then
    raise exception 'error code required' using errcode='22023';
  end if;

  -- Same packet revision can never become smaller by retrying it. New inbound
  -- evidence generates a new revision and the existing enqueue trigger moves
  -- the job back to QUEUED, so this terminal state is fail-safe and recoverable.
  v_permanent := upper(v_code) = 'INTERPRETATION_PACKET_TOO_LARGE';

  update public.whatsapp_packet_ai_dispatch_jobs j
  set state = case
        when v_permanent then 'QUARANTINED'
        when p_knowledge_authority_failure then 'BLOCKED_KNOWLEDGE_AUTHORITY'
        else 'RETRY'
      end,
      claimed_at=null,
      lease_expires_at=null,
      lease_token=null,
      last_error_code=v_code,
      last_error_detail=nullif(v_detail,''),
      next_retry_at=case
        when v_permanent then statement_timestamp()
        else statement_timestamp()+make_interval(secs=>least(900,15*power(2,least(j.attempt_count,5))::integer))
      end,
      updated_at=statement_timestamp()
  where j.id=p_job_id
    and j.state='LEASED'
    and j.lease_token=p_lease_token
    and j.packet_revision=p_packet_revision
    and (
      j.execution_kind='PACKET'
      or exists(
        select 1 from public.whatsapp_communication_cases c
        where c.id=j.case_id and c.context_revision=j.context_revision
      )
    )
  returning j.packet_id,j.attempt_count,j.execution_kind,j.case_id
  into v_packet_id,v_attempt_count,v_execution_kind,v_case_id;

  get diagnostics v_updated=row_count;

  if v_updated=1 and v_permanent then
    perform public.append_operational_event_v1(
      p_event_type := 'whatsapp_packet_ai_quarantined',
      p_entity_type := 'whatsapp_packet_ai_dispatch_job',
      p_entity_id := p_job_id,
      p_title := 'WhatsApp packet AI job quarantined',
      p_source_application := 'whatsapp',
      p_correlation_id := 'wa-packet-ai-quarantine:'||p_job_id::text||':'||p_packet_revision::text,
      p_metadata := jsonb_build_object(
        'packet_id',v_packet_id,
        'packet_revision',p_packet_revision,
        'attempt_count',v_attempt_count,
        'execution_kind',v_execution_kind,
        'case_id',v_case_id,
        'error_code',v_code
      ),
      p_visibility := 'internal',
      p_severity := 'warning',
      p_message := 'Deterministic packet-AI failure stopped from repeated automatic retry; new packet evidence will requeue a new revision.',
      p_reason_code := v_code,
      p_reason_text := nullif(v_detail,''),
      p_idempotency_key := 'wa-packet-ai-quarantine:'||p_job_id::text||':'||p_packet_revision::text
    );
  end if;

  return v_updated=1;
end;
$$;

revoke all on function public.retry_whatsapp_packet_ai_dispatch_job(uuid,uuid,bigint,text,text,boolean)
  from public, anon, authenticated;
grant execute on function public.retry_whatsapp_packet_ai_dispatch_job(uuid,uuid,bigint,text,text,boolean)
  to service_role;

comment on function public.retry_whatsapp_packet_ai_dispatch_job(uuid,uuid,bigint,text,text,boolean) is
  'Lease-bound retry/quarantine authority. Deterministic oversized packet revisions are quarantined and surfaced; new packet revisions remain requeueable.';

commit;

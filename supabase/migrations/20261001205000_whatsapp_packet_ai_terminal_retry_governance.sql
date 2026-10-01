-- Final certification: bound packet-AI retries and preserve terminal failure evidence.
-- This closes deterministic/infinite retry loops without deleting packets or interpretations.
begin;

-- destructive-change-approved: replace the dispatch state check with the same
-- states plus one terminal, non-claimable BLOCKED_PERMANENT state.
-- rollback-plan: only safe after all BLOCKED_PERMANENT rows are dispositioned;
-- restore the prior five-state check and prior retry function.
alter table public.whatsapp_packet_ai_dispatch_jobs
  drop constraint if exists whatsapp_packet_ai_dispatch_jobs_state_check;

alter table public.whatsapp_packet_ai_dispatch_jobs
  add constraint whatsapp_packet_ai_dispatch_jobs_state_check
  check (
    state in (
      'QUEUED',
      'LEASED',
      'RETRY',
      'BLOCKED_KNOWLEDGE_AUTHORITY',
      'BLOCKED_PERMANENT',
      'COMPLETED'
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
begin
  if v_code='' then
    raise exception 'error code required' using errcode='22023';
  end if;

  update public.whatsapp_packet_ai_dispatch_jobs j
  set
    state = case
      -- Knowledge authority is intentionally recoverable when governed
      -- knowledge becomes available again.
      when p_knowledge_authority_failure then 'BLOCKED_KNOWLEDGE_AUTHORITY'
      -- This failure is structural for the pinned packet revision. Re-running
      -- the same evidence can never make a >16-message packet smaller.
      when v_code = 'INTERPRETATION_PACKET_TOO_LARGE' then 'BLOCKED_PERMANENT'
      -- Match the established operator-reply retry budget: a non-knowledge
      -- failure gets at most five claimed attempts before terminal disposition.
      when j.attempt_count >= 5 then 'BLOCKED_PERMANENT'
      else 'RETRY'
    end,
    claimed_at = null,
    lease_expires_at = null,
    lease_token = null,
    last_error_code = v_code,
    last_error_detail = nullif(v_detail,''),
    next_retry_at = case
      when p_knowledge_authority_failure then
        statement_timestamp()+make_interval(secs=>least(900,15*power(2,least(j.attempt_count,5))::integer))
      when v_code = 'INTERPRETATION_PACKET_TOO_LARGE' or j.attempt_count >= 5 then
        'infinity'::timestamptz
      else
        statement_timestamp()+make_interval(secs=>least(900,15*power(2,least(j.attempt_count,5))::integer))
    end,
    updated_at = statement_timestamp()
  where j.id=p_job_id
    and j.state='LEASED'
    and j.lease_token=p_lease_token
    and j.packet_revision=p_packet_revision
    and (
      j.execution_kind='PACKET'
      or exists(
        select 1
        from public.whatsapp_communication_cases c
        where c.id=j.case_id and c.context_revision=j.context_revision
      )
    );

  get diagnostics v_updated=row_count;
  return v_updated=1;
end
$$;

comment on function public.retry_whatsapp_packet_ai_dispatch_job(uuid,uuid,bigint,text,text,boolean) is
  'Lease-bound packet-AI failure disposition. Knowledge blocks remain recoverable; deterministic oversize failures and non-knowledge failures at attempt 5+ become terminal BLOCKED_PERMANENT with evidence retained.';

commit;

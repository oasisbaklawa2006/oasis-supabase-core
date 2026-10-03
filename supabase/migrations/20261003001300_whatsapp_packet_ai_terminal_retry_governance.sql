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
  v_job public.whatsapp_packet_ai_dispatch_jobs%rowtype;
  v_case_id uuid;
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
    )
  returning j.* into v_job;

  if not found then
    return false;
  end if;

  if v_job.state='BLOCKED_PERMANENT' then
    v_case_id := v_job.case_id;

    if v_case_id is null then
      insert into public.whatsapp_communication_cases (
        packet_id,
        case_type,
        status,
        accountable_team,
        accountability_status,
        next_action,
        next_action_due_at,
        source_channel,
        rule_version
      ) values (
        v_job.packet_id,
        'UNCLASSIFIED',
        'NEEDS_IDENTITY',
        'OPERATIONS',
        'UNASSIGNED',
        'Manual review required: packet AI processing blocked (' || v_code || ').',
        statement_timestamp() + interval '1 hour',
        'WHATSAPP',
        'packet-ai-terminal-v1'
      )
      on conflict (packet_id) do nothing
      returning id into v_case_id;

      if v_case_id is null then
        select c.id into v_case_id
        from public.whatsapp_communication_cases c
        where c.packet_id=v_job.packet_id;
      end if;
    end if;

    if v_case_id is not null then
      update public.whatsapp_communication_cases c
      set
        next_action = case
          when c.status in ('CLOSED','CANCELLED') then c.next_action
          else 'Manual review required: packet AI processing blocked (' || v_code || ').'
        end,
        next_action_due_at = case
          when c.status in ('CLOSED','CANCELLED') then c.next_action_due_at
          else least(
            coalesce(c.next_action_due_at, statement_timestamp() + interval '1 hour'),
            statement_timestamp() + interval '1 hour'
          )
        end,
        updated_at = statement_timestamp()
      where c.id=v_case_id;

      insert into public.whatsapp_case_events (
        case_id,
        event_type,
        actor_id,
        actor_type,
        correlation_key,
        resulting_state,
        metadata
      ) values (
        v_case_id,
        'PACKET_AI_TERMINAL_BLOCKED',
        null,
        'SYSTEM',
        'packet-ai-terminal:' || p_job_id::text || ':' || p_packet_revision::text,
        jsonb_build_object(
          'packet_ai_state','BLOCKED_PERMANENT',
          'human_review_required',true
        ),
        jsonb_build_object(
          'packet_id',v_job.packet_id,
          'dispatch_job_id',v_job.id,
          'error_code',v_code,
          'error_detail',nullif(v_detail,''),
          'attempt_count',v_job.attempt_count,
          'automatic_commercial_action',false
        )
      )
      on conflict (case_id, correlation_key) do nothing;
    end if;
  end if;

  return true;
end
$$;

revoke all on function public.retry_whatsapp_packet_ai_dispatch_job(uuid,uuid,bigint,text,text,boolean)
  from public, anon, authenticated;
grant execute on function public.retry_whatsapp_packet_ai_dispatch_job(uuid,uuid,bigint,text,text,boolean)
  to service_role;

comment on function public.retry_whatsapp_packet_ai_dispatch_job(uuid,uuid,bigint,text,text,boolean) is
  'Lease-bound packet-AI failure disposition. Knowledge blocks remain recoverable; deterministic oversize failures and non-knowledge failures at attempt 5+ become terminal BLOCKED_PERMANENT with evidence retained and a governed Operations human-review case/event.';

commit;

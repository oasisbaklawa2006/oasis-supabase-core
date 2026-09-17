-- Harden direct-path vs canonical consumer concurrency by requiring packet-scoped
-- lease acquisition before trusted worker processing, and tightening reconcile guards.
begin;

create or replace function public.claim_whatsapp_packet_ai_dispatch_job_for_packet(
  p_packet_id uuid,
  p_lease_seconds integer default 120
)
returns public.whatsapp_packet_ai_dispatch_jobs
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  v_job public.whatsapp_packet_ai_dispatch_jobs%rowtype;
begin
  if p_packet_id is null then
    raise exception 'packet id required' using errcode = '22023';
  end if;
  if p_lease_seconds < 30 or p_lease_seconds > 900 then
    raise exception 'lease duration must be between 30 and 900 seconds' using errcode = '22023';
  end if;

  update public.whatsapp_packet_ai_dispatch_jobs j
  set
    state = 'LEASED',
    attempt_count = j.attempt_count + 1,
    claimed_at = statement_timestamp(),
    last_attempt_at = statement_timestamp(),
    lease_expires_at = statement_timestamp() + make_interval(secs => p_lease_seconds),
    lease_token = gen_random_uuid(),
    next_retry_at = statement_timestamp(),
    updated_at = statement_timestamp()
  where j.id = (
    select id
    from public.whatsapp_packet_ai_dispatch_jobs
    where packet_id = p_packet_id
      and (
        (
          state in ('QUEUED', 'RETRY', 'BLOCKED_KNOWLEDGE_AUTHORITY')
          and next_retry_at <= statement_timestamp()
        )
        or (
          state = 'LEASED'
          and lease_expires_at <= statement_timestamp()
        )
      )
    order by next_retry_at, created_at
    for update skip locked
    limit 1
  )
  returning j.* into v_job;

  return v_job;
end;
$$;

revoke all on function public.claim_whatsapp_packet_ai_dispatch_job_for_packet(uuid, integer)
  from public, anon, authenticated;
grant execute on function public.claim_whatsapp_packet_ai_dispatch_job_for_packet(uuid, integer)
  to service_role;

create or replace function public.reconcile_whatsapp_packet_ai_dispatch_after_outcome(
  p_packet_id uuid
)
returns boolean
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  v_updated integer;
  v_revision bigint;
begin
  if p_packet_id is null then
    raise exception 'packet id required' using errcode = '22023';
  end if;

  if not exists (
    select 1
    from public.whatsapp_packet_ai_interpretations
    where packet_id = p_packet_id
  ) then
    return false;
  end if;

  select ai_dispatch_revision
    into v_revision
  from public.whatsapp_message_packets
  where id = p_packet_id;

  if v_revision is null then
    return false;
  end if;

  update public.whatsapp_packet_ai_dispatch_jobs
  set
    state = 'COMPLETED',
    claimed_at = null,
    lease_expires_at = null,
    lease_token = null,
    completed_at = coalesce(completed_at, statement_timestamp()),
    last_error_code = null,
    last_error_detail = null,
    updated_at = statement_timestamp()
  where packet_id = p_packet_id
    and state in ('QUEUED', 'RETRY', 'BLOCKED_KNOWLEDGE_AUTHORITY')
    and packet_revision = v_revision;

  get diagnostics v_updated = row_count;
  return v_updated >= 1 or exists (
    select 1
    from public.whatsapp_packet_ai_dispatch_jobs
    where packet_id = p_packet_id
      and state = 'COMPLETED'
      and packet_revision = v_revision
  );
end;
$$;

comment on function public.claim_whatsapp_packet_ai_dispatch_job_for_packet(uuid, integer) is
  'Claims the dispatch job for one packet when eligible. Returns null when another worker holds a live lease.';

commit;

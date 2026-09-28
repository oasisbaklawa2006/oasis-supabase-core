-- Reconcile durable dispatch outbox when legacy/direct worker callers finish
-- packet AI without claiming a lease (e.g. whatsapp-message-stitcher bypass).
-- Without this, QUEUED jobs accumulate even after successful interpretation.
begin;

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
    and state in ('QUEUED', 'RETRY', 'BLOCKED_KNOWLEDGE_AUTHORITY');

  get diagnostics v_updated = row_count;
  return v_updated >= 1 or exists (
    select 1
    from public.whatsapp_packet_ai_dispatch_jobs
    where packet_id = p_packet_id
      and state = 'COMPLETED'
  );
end;
$$;

revoke all on function public.reconcile_whatsapp_packet_ai_dispatch_after_outcome(uuid)
  from public, anon, authenticated;
grant execute on function public.reconcile_whatsapp_packet_ai_dispatch_after_outcome(uuid)
  to service_role;

comment on function public.reconcile_whatsapp_packet_ai_dispatch_after_outcome(uuid) is
  'Marks a packet dispatch job COMPLETED after a trusted direct worker outcome when interpretation evidence already exists. Idempotent for completed jobs.';

commit;

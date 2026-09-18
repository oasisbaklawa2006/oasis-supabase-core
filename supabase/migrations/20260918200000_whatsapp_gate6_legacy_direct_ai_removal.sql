-- Gate 6: retire legacy direct packet-AI dispatch authority; canonical consumer owns inbound AI.
-- Contract coverage: supabase/tests/20260918200000_whatsapp_gate6_legacy_direct_ai_removal.sql
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
begin
  if p_packet_id is null then
    raise exception 'packet id required' using errcode = '22023';
  end if;
  -- Gate 6: legacy stitcher/direct worker bypass is retired. Only the durable
  -- whatsapp-packet-ai-consumer may claim dispatch jobs.
  return null;
end;
$$;

revoke all on function public.claim_whatsapp_packet_ai_dispatch_job_for_packet(uuid, integer)
  from public, anon, authenticated;
grant execute on function public.claim_whatsapp_packet_ai_dispatch_job_for_packet(uuid, integer)
  to service_role;

comment on function public.claim_whatsapp_packet_ai_dispatch_job_for_packet(uuid, integer) is
  'Retired in Gate 6. Returns null so legacy direct callers cannot bypass the canonical packet-AI consumer.';

commit;

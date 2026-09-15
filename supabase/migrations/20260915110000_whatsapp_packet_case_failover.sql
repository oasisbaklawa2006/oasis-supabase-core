-- CERT-WA-001: fail closed when packet AI dispatch is delayed or unavailable.
--
-- Zero-loss rule: a stitched inbound packet must never depend on AI availability
-- to become visible as governed operational work. This creates an UNCLASSIFIED,
-- human-review case for stale packets that still have no communication case.
-- The normal AI materializer is intentionally compatible with this fallback:
-- whatsapp_materialize_packet_ai_case() uses ON CONFLICT(packet_id) and may later
-- enrich an unassigned OPEN/NEEDS_IDENTITY/NEEDS_CLARIFICATION/READY_FOR_DRAFT case.

create or replace function public.whatsapp_materialize_stale_packet_case_failover(
  p_min_age_seconds integer default 600,
  p_limit integer default 250
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public, auth
as $$
declare
  v_role text := coalesce(auth.jwt() ->> 'role', '');
  v_system_actor uuid;
  v_created integer := 0;
  v_resolved_exceptions integer := 0;
  v_case_id uuid;
  v_resolved integer;
  r record;
begin
  if v_role <> 'service_role' then
    raise exception 'trusted WhatsApp failover processor required' using errcode = '42501';
  end if;
  if p_min_age_seconds is null or p_min_age_seconds < 60 or p_min_age_seconds > 86400 then
    raise exception 'packet failover age must be between 60 and 86400 seconds';
  end if;
  if p_limit is null or p_limit < 1 or p_limit > 1000 then
    raise exception 'packet failover limit must be between 1 and 1000';
  end if;

  -- Existing governed system principal; never impersonate a human employee.
  v_system_actor := public.whatsapp_core_c_ensure_system_principal();

  for r in
    select p.id as packet_id
    from public.whatsapp_message_packets p
    where lower(coalesce(p.status, 'open')) = 'open'
      and p.last_message_at is not null
      and p.last_message_at <=
        (statement_timestamp() at time zone 'UTC') - make_interval(secs => p_min_age_seconds)
      and exists (
        select 1
        from public.whatsapp_messages m
        where m.packet_id = p.id
          and lower(m.direction) = 'inbound'
      )
      and not exists (
        select 1
        from public.whatsapp_communication_cases c
        where c.packet_id = p.id
      )
    order by p.last_message_at, p.id
    limit p_limit
    for update skip locked
  loop
    v_case_id := null;
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
      r.packet_id,
      'UNCLASSIFIED',
      'NEEDS_IDENTITY',
      'OPERATIONS',
      'UNASSIGNED',
      'Manual triage required: automated interpretation has not produced a governed case.',
      statement_timestamp() + interval '1 hour',
      'WHATSAPP',
      'packet-ai-failover-v1'
    )
    on conflict (packet_id) do nothing
    returning id into v_case_id;

    if v_case_id is null then
      continue;
    end if;

    v_created := v_created + 1;

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
      'PACKET_AI_FAILOVER_MATERIALIZED',
      v_system_actor,
      'SYSTEM',
      'packet-ai-failover:' || r.packet_id::text,
      jsonb_build_object(
        'case_type', 'UNCLASSIFIED',
        'case_status', 'NEEDS_IDENTITY',
        'accountability_status', 'UNASSIGNED'
      ),
      jsonb_build_object(
        'packet_id', r.packet_id,
        'reason', 'PACKET_WITHOUT_CASE_AFTER_GRACE_PERIOD',
        'min_age_seconds', p_min_age_seconds,
        'automatic_commercial_action', false,
        'human_review_required', true
      )
    )
    on conflict (case_id, correlation_key) do nothing;

    update public.whatsapp_reconciliation_exceptions e
    set resolved_at = statement_timestamp(),
        resolved_by = v_system_actor,
        resolution = 'FALLBACK_CASE_CREATED'
    where e.resolved_at is null
      and e.exception_type = 'PACKET_WITHOUT_CASE'
      and e.business_object_type = 'whatsapp_message_packets'
      and e.business_object_id = r.packet_id;
    get diagnostics v_resolved = row_count;
    v_resolved_exceptions := v_resolved_exceptions + v_resolved;
  end loop;

  return jsonb_build_object(
    'cases_created', v_created,
    'reconciliation_exceptions_resolved', v_resolved_exceptions,
    'human_review_required', true,
    'automatic_commercial_action', false
  );
end;
$$;

revoke all on function public.whatsapp_materialize_stale_packet_case_failover(integer, integer)
  from public, anon, authenticated;
grant execute on function public.whatsapp_materialize_stale_packet_case_failover(integer, integer)
  to service_role;

comment on function public.whatsapp_materialize_stale_packet_case_failover(integer, integer) is
  'Fail-closed zero-loss recovery for stale inbound WhatsApp packets without a governed communication case. Creates only an UNCLASSIFIED human-review case; never creates an order, verifies payment, sends a reply, or completes the AI dispatch job.';

-- The existing production cron already invokes this wrapper hourly. Keep the
-- reconciliation contract and append failover materialization after the normal
-- audit pass so the same run records then resolves PACKET_WITHOUT_CASE evidence.
create or replace function public.whatsapp_run_scheduled_reconciliation()
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  v_end timestamptz := statement_timestamp();
  v_start timestamptz := v_end - interval '70 minutes';
  v_due timestamptz := v_end + interval '4 hours';
  v_key text := 'cron:' || to_char(date_trunc('hour', v_end at time zone 'UTC'), 'YYYYMMDDHH24');
  v_prior_claims text := current_setting('request.jwt.claims', true);
  v_result jsonb;
  v_failover jsonb;
begin
  perform set_config('request.jwt.claims', '{"role":"service_role"}', true);
  v_result := public.whatsapp_run_system_reconciliation(
    v_start,
    v_end,
    'SYSTEM_ROLLING',
    v_due,
    v_key
  );
  v_failover := public.whatsapp_materialize_stale_packet_case_failover(600, 250);
  perform set_config('request.jwt.claims', coalesce(v_prior_claims, ''), true);
  return v_result || jsonb_build_object('case_failover', v_failover);
exception
  when others then
    perform set_config('request.jwt.claims', coalesce(v_prior_claims, ''), true);
    raise;
end;
$$;

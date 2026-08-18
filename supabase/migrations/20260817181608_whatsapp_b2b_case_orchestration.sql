-- Recovered historical migration: reproduces the production semantics applied to
-- production (tcxvcatsqqertcnycuop) under this version, per
-- docs/reconciliation/production-migration-ledger-remote-history-2026-08-18.csv:
-- represented by Core PR #84 branch feat/wa-b2b-case-orchestration-closure supabase/migrations/20260817180000_whatsapp_b2b_case_orchestration.sql (head 3b013b4); full diff = COMMENT ON FUNCTION + whitespace-around-operators only. Content below is the git-sourced candidate (already diff-verified against schema_migrations.statements for this version); this session additionally re-fetched the live production statement for this version directly and confirmed the same functions/logic, differing only in whitespace-around-commas and comment placement.
-- This file exists so a clean zero-state replay creates the same schema/functions
-- production already has, under the version production already recognizes as
-- applied -- it must not execute a second time against production.

-- Wire advisory packet AI into the pre-existing governed WhatsApp communication-case
-- programme without fabricating human authority. The service-role processor may create
-- or refresh an unassigned pre-decision case and append a SYSTEM event. Human operators
-- remain responsible for accepting routing/ownership and every customer/commercial
-- commitment.

create or replace function public.whatsapp_materialize_packet_ai_case(
  p_packet_id uuid,
  p_interpretation_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public, auth
as $$
declare
  v_role text := coalesce(auth.jwt() ->> 'role', '');
  v_packet public.whatsapp_message_packets%rowtype;
  v_contact public.whatsapp_contacts%rowtype;
  v_ai public.whatsapp_packet_ai_interpretations%rowtype;
  v_conclusion jsonb;
  v_intent text;
  v_case_type text;
  v_case public.whatsapp_communication_cases%rowtype;
  v_recommended_action text;
  v_primary_department text;
  v_contributors jsonb;
  v_reply_clearance text;
  v_draft_reply text;
  v_ambiguity_count integer := 0;
  v_event_key text;
begin
  if v_role <> 'service_role' then
    raise exception 'trusted packet processor required' using errcode = '42501';
  end if;

  select * into v_packet
  from public.whatsapp_message_packets
  where id = p_packet_id;

  if not found then
    raise exception 'WhatsApp packet not found';
  end if;

  select * into v_ai
  from public.whatsapp_packet_ai_interpretations
  where id = p_interpretation_id
    and packet_id = p_packet_id;

  if not found then
    raise exception 'packet AI interpretation not found for packet';
  end if;

  select * into v_contact
  from public.whatsapp_contacts
  where id = v_packet.contact_id;

  if not found then
    raise exception 'WhatsApp packet contact not found';
  end if;

  v_conclusion := case
    when jsonb_typeof(v_ai.interpretation -> 'conclusion') = 'object'
      then v_ai.interpretation -> 'conclusion'
    else '{}'::jsonb
  end;

  v_intent := upper(coalesce(nullif(btrim(v_conclusion ->> 'intent'), ''), 'UNCLEAR'));
  v_case_type := case v_intent
    when 'NEW_ORDER' then 'ORDER'
    when 'ORDER' then 'ORDER'
    when 'AMENDMENT' then 'ORDER_CHANGE'
    when 'ORDER_CHANGE' then 'ORDER_CHANGE'
    when 'CANCELLATION' then 'CANCELLATION'
    when 'ENQUIRY' then 'ENQUIRY'
    when 'COMPLAINT' then 'COMPLAINT'
    when 'PAYMENT_ADVICE' then 'PAYMENT_ADVICE'
    when 'ACCOUNT_QUERY' then 'ACCOUNT_QUERY'
    when 'FINANCE' then 'ACCOUNT_QUERY'
    when 'DELIVERY_QUERY' then 'DISPATCH'
    when 'DISPATCH' then 'DISPATCH'
    when 'SPECIFICATION_QUERY' then 'SPECIFICATION'
    when 'SPECIFICATION' then 'SPECIFICATION'
    else 'UNCLASSIFIED'
  end;

  v_recommended_action := nullif(btrim(coalesce(v_conclusion ->> 'recommended_action', '')), '');
  v_primary_department := nullif(upper(btrim(coalesce(v_conclusion ->> 'primary_department', ''))), '');
  v_contributors := case
    when jsonb_typeof(v_conclusion -> 'contributor_departments') = 'array'
      then v_conclusion -> 'contributor_departments'
    else '[]'::jsonb
  end;
  v_reply_clearance := nullif(upper(btrim(coalesce(v_conclusion ->> 'reply_clearance', ''))), '');
  v_draft_reply := nullif(btrim(coalesce(v_conclusion ->> 'draft_reply', '')), '');
  v_ambiguity_count := case
    when jsonb_typeof(v_conclusion -> 'ambiguities') = 'array'
      then jsonb_array_length(v_conclusion -> 'ambiguities')
    else 0
  end;

  insert into public.whatsapp_communication_cases (
    packet_id,
    case_type,
    status,
    next_action,
    source_channel,
    rule_version
  ) values (
    p_packet_id,
    v_case_type,
    'NEEDS_IDENTITY',
    v_recommended_action,
    'WHATSAPP',
    'packet-ai-b2b-v1'
  )
  on conflict (packet_id) do update
  set case_type = case
        when public.whatsapp_communication_cases.accountability_status = 'UNASSIGNED'
          and public.whatsapp_communication_cases.status in ('OPEN', 'NEEDS_IDENTITY', 'NEEDS_CLARIFICATION')
          then excluded.case_type
        else public.whatsapp_communication_cases.case_type
      end,
      next_action = case
        when public.whatsapp_communication_cases.accountability_status = 'UNASSIGNED'
          and public.whatsapp_communication_cases.status in ('OPEN', 'NEEDS_IDENTITY', 'NEEDS_CLARIFICATION')
          then excluded.next_action
        else public.whatsapp_communication_cases.next_action
      end,
      rule_version = case
        when public.whatsapp_communication_cases.accountability_status = 'UNASSIGNED'
          and public.whatsapp_communication_cases.status in ('OPEN', 'NEEDS_IDENTITY', 'NEEDS_CLARIFICATION')
          then excluded.rule_version
        else public.whatsapp_communication_cases.rule_version
      end,
      updated_at = statement_timestamp()
  returning * into v_case;

  insert into public.whatsapp_case_identities (
    case_id,
    identity_role,
    party_type,
    party_id,
    display_label,
    phone_e164,
    resolution_status,
    confidence,
    evidence
  ) values (
    v_case.id,
    'SUBMITTING_SENDER',
    'CONTACT',
    v_contact.id,
    coalesce(nullif(v_contact.customer_name, ''), nullif(v_contact.company_name, ''), v_contact.phone_number),
    v_contact.phone_number,
    'SUGGESTED',
    1.0,
    jsonb_build_array(jsonb_build_object(
      'source', 'WHATSAPP_PACKET',
      'packet_id', p_packet_id,
      'contact_id', v_contact.id
    ))
  )
  on conflict (case_id, identity_role) do update
  set party_type = excluded.party_type,
      party_id = excluded.party_id,
      display_label = excluded.display_label,
      phone_e164 = excluded.phone_e164,
      confidence = excluded.confidence,
      evidence = excluded.evidence
  where public.whatsapp_case_identities.resolution_status <> 'CONFIRMED';

  v_event_key := 'packet-ai:' || p_interpretation_id::text;

  insert into public.whatsapp_case_events (
    case_id,
    event_type,
    actor_id,
    actor_type,
    correlation_key,
    resulting_state,
    metadata
  ) values (
    v_case.id,
    'AI_CONCLUSION_READY',
    null,
    'SYSTEM',
    v_event_key,
    jsonb_build_object(
      'case_type', v_case_type,
      'case_status', v_case.status,
      'human_decision_required', true
    ),
    jsonb_build_object(
      'packet_id', p_packet_id,
      'packet_ai_interpretation_id', p_interpretation_id,
      'content_fingerprint', v_ai.content_fingerprint,
      'model_version', v_ai.model_version,
      'intent', v_intent,
      'summary', coalesce(v_conclusion ->> 'summary', ''),
      'confidence', v_ai.interpretation -> 'confidence',
      'ambiguity_count', v_ambiguity_count,
      'recommended_action', v_recommended_action,
      'primary_department', v_primary_department,
      'contributor_departments', v_contributors,
      'reply_clearance', v_reply_clearance,
      'draft_reply', v_draft_reply,
      'human_review_required', true,
      'conclusion', v_conclusion
    )
  )
  on conflict (case_id, correlation_key) do nothing;

  return jsonb_build_object(
    'case_id', v_case.id,
    'packet_id', p_packet_id,
    'case_type', v_case.case_type,
    'status', v_case.status,
    'accountability_status', v_case.accountability_status,
    'ai_event_correlation_key', v_event_key,
    'human_decision_required', true
  );
end;
$$;

comment on function public.whatsapp_materialize_packet_ai_case(uuid, uuid) is
  'Service-role-only bridge from append-only packet AI interpretation to the governed B2B communication-case programme. Creates advisory case/event state only; it cannot assign a human, approve customer communication, create a live Sales Order, approve payment/credit, reserve stock, or make a commercial commitment.';

revoke all on function public.whatsapp_materialize_packet_ai_case(uuid, uuid) from public, anon, authenticated;
grant execute on function public.whatsapp_materialize_packet_ai_case(uuid, uuid) to service_role;


create or replace function public.whatsapp_get_case_decision_snapshot(
  p_packet_id uuid
)
returns jsonb
language plpgsql
stable
security definer
set search_path = pg_catalog, public, auth
as $$
declare
  v_actor uuid := auth.uid();
  v_case public.whatsapp_communication_cases%rowtype;
  v_ai jsonb;
  v_identities jsonb;
  v_tasks jsonb;
  v_events jsonb;
begin
  if v_actor is null or not public.is_whatsapp_inbox_reader(v_actor) then
    raise exception 'WhatsApp inbox read permission required' using errcode = '42501';
  end if;

  select * into v_case
  from public.whatsapp_communication_cases
  where packet_id = p_packet_id;

  if not found then
    return jsonb_build_object('packet_id', p_packet_id, 'case', null);
  end if;

  select to_jsonb(candidate)
  into v_ai
  from (
    select id, content_fingerprint, provider_message_ids, interpretation, model_version, created_at
    from public.whatsapp_packet_ai_interpretations
    where packet_id = p_packet_id
    order by created_at desc, id desc
    limit 1
  ) candidate;

  select coalesce(jsonb_agg(to_jsonb(candidate) order by candidate.created_at, candidate.id), '[]'::jsonb)
  into v_identities
  from (
    select id, identity_role, party_type, party_id, display_label, phone_e164,
           resolution_status, confidence, evidence, created_at
    from public.whatsapp_case_identities
    where case_id = v_case.id
  ) candidate;

  select coalesce(jsonb_agg(to_jsonb(candidate) order by candidate.created_at, candidate.id), '[]'::jsonb)
  into v_tasks
  from (
    select id, department, assigned_user_id, task_type, instructions, status,
           due_at, response_payload, completed_by, completed_at, correlation_key,
           created_by, created_at, updated_at
    from public.whatsapp_case_department_tasks
    where case_id = v_case.id
  ) candidate;

  select coalesce(jsonb_agg(to_jsonb(candidate) order by candidate.occurred_at desc, candidate.id desc), '[]'::jsonb)
  into v_events
  from (
    select id, event_type, actor_id, actor_type, correlation_key, prior_state,
           resulting_state, metadata, occurred_at, recorded_at
    from public.whatsapp_case_events
    where case_id = v_case.id
    order by occurred_at desc, id desc
    limit 50
  ) candidate;

  return jsonb_build_object(
    'packet_id', p_packet_id,
    'case', to_jsonb(v_case),
    'latest_ai', v_ai,
    'identities', v_identities,
    'department_tasks', v_tasks,
    'events', v_events
  );
end;
$$;

comment on function public.whatsapp_get_case_decision_snapshot(uuid) is
  'Read-only governed snapshot for the WhatsApp B2B Decision Desk. Requires inbox-reader authority and exposes no mutation capability.';

revoke all on function public.whatsapp_get_case_decision_snapshot(uuid) from public, anon;
grant execute on function public.whatsapp_get_case_decision_snapshot(uuid) to authenticated;


create or replace function public.whatsapp_accept_ai_case_routing(
  p_case_id uuid,
  p_accountable_team text,
  p_next_action text,
  p_due_at timestamptz,
  p_contributor_departments text[] default '{}'::text[],
  p_idempotency_key text default null
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public, auth
as $$
declare
  v_actor uuid := auth.uid();
  v_case public.whatsapp_communication_cases%rowtype;
  v_team text := upper(btrim(coalesce(p_accountable_team, '')));
  v_action text := btrim(coalesce(p_next_action, ''));
  v_key text := btrim(coalesce(p_idempotency_key, ''));
  v_department text;
  v_primary_task_id uuid;
begin
  if v_actor is null
     or not public.has_whatsapp_permission('wa.intake.triage')
     or not public.has_whatsapp_permission('wa.intake.assign') then
    raise exception 'WhatsApp triage and assignment permissions required' using errcode = '42501';
  end if;

  if v_team = '' or length(v_team) > 80 then
    raise exception 'accountable team required';
  end if;
  if v_action = '' or length(v_action) > 1000 then
    raise exception 'next action required';
  end if;
  if p_due_at is null or p_due_at <= statement_timestamp() then
    raise exception 'future due time required';
  end if;
  if v_key = '' or length(v_key) > 160 then
    raise exception 'idempotency key required';
  end if;
  if coalesce(cardinality(p_contributor_departments), 0) > 12 then
    raise exception 'too many contributor departments';
  end if;

  select * into v_case
  from public.whatsapp_communication_cases
  where id = p_case_id
  for update;

  if not found then
    raise exception 'WhatsApp communication case not found';
  end if;
  if v_case.status in ('CLOSED', 'CANCELLED') then
    raise exception 'closed WhatsApp case cannot be assigned';
  end if;

  if exists (
    select 1 from public.whatsapp_case_events
    where case_id = p_case_id
      and correlation_key = 'ai-routing-accept:' || v_key
  ) then
    return jsonb_build_object(
      'case_id', v_case.id,
      'idempotent_replay', true,
      'accountable_team', v_case.accountable_team,
      'accountable_owner_id', v_case.accountable_owner_id,
      'status', v_case.status
    );
  end if;

  update public.whatsapp_communication_cases
  set accountable_team = v_team,
      accountable_owner_id = v_actor,
      accountability_status = 'ASSIGNED',
      assigned_at = statement_timestamp(),
      assigned_by = v_actor,
      next_action = v_action,
      next_action_due_at = p_due_at,
      updated_at = statement_timestamp()
  where id = p_case_id
  returning * into v_case;

  insert into public.whatsapp_case_department_tasks (
    case_id,
    department,
    assigned_user_id,
    task_type,
    instructions,
    status,
    due_at,
    correlation_key,
    created_by
  ) values (
    p_case_id,
    v_team,
    v_actor,
    'ACCOUNTABLE_RESPONSE_OWNER',
    v_action,
    'OPEN',
    p_due_at,
    'ai-routing-primary:' || v_key,
    v_actor
  )
  on conflict (case_id, correlation_key) do nothing
  returning id into v_primary_task_id;

  foreach v_department in array coalesce(p_contributor_departments, '{}'::text[]) loop
    v_department := upper(btrim(v_department));
    if v_department <> '' and v_department <> v_team and length(v_department) <= 80 then
      insert into public.whatsapp_case_department_tasks (
        case_id,
        department,
        assigned_user_id,
        task_type,
        instructions,
        status,
        due_at,
        correlation_key,
        created_by
      ) values (
        p_case_id,
        v_department,
        null,
        'CASE_CONTRIBUTOR',
        'Contribute facts/action required for accountable response: ' || v_action,
        'OPEN',
        p_due_at,
        'ai-routing-contributor:' || v_key || ':' || lower(v_department),
        v_actor
      )
      on conflict (case_id, correlation_key) do nothing;
    end if;
  end loop;

  insert into public.whatsapp_case_events (
    case_id,
    event_type,
    actor_id,
    actor_type,
    correlation_key,
    prior_state,
    resulting_state,
    metadata
  ) values (
    p_case_id,
    'AI_ROUTING_ACCEPTED',
    v_actor,
    'OPERATOR',
    'ai-routing-accept:' || v_key,
    jsonb_build_object(
      'accountable_team', null,
      'accountable_owner_id', null
    ),
    jsonb_build_object(
      'accountable_team', v_team,
      'accountable_owner_id', v_actor,
      'next_action', v_action,
      'due_at', p_due_at
    ),
    jsonb_build_object(
      'source', 'AI_DECISION_DESK',
      'primary_task_id', v_primary_task_id,
      'contributor_departments', to_jsonb(coalesce(p_contributor_departments, '{}'::text[]))
    )
  );

  return jsonb_build_object(
    'case_id', v_case.id,
    'idempotent_replay', false,
    'accountable_team', v_case.accountable_team,
    'accountable_owner_id', v_case.accountable_owner_id,
    'next_action', v_case.next_action,
    'next_action_due_at', v_case.next_action_due_at,
    'primary_task_id', v_primary_task_id
  );
end;
$$;

comment on function public.whatsapp_accept_ai_case_routing(uuid, text, text, timestamptz, text[], text) is
  'Human-authorised acceptance of advisory AI case routing. Requires both wa.intake.triage and wa.intake.assign; creates accountable/contributor tasks and an immutable operator decision event. AI/service_role cannot invoke it as a human decision.';

revoke all on function public.whatsapp_accept_ai_case_routing(uuid, text, text, timestamptz, text[], text) from public, anon, service_role;
grant execute on function public.whatsapp_accept_ai_case_routing(uuid, text, text, timestamptz, text[], text) to authenticated;

-- CORE-C review hardening: session claim restoration, fail-soft resolve, human-review routing,
-- preserve existing assignments, and restore finalize access controls.
begin;

-- -----------------------------------------------------------------------------
-- 1. Restore request.jwt.claims unconditionally after temporary elevation
-- -----------------------------------------------------------------------------

create or replace function public.whatsapp_process_inbound_whatsapp_continuation_v1(
  p_inbound_whatsapp_message_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public, auth
as $$
declare
  v_evidence public.whatsapp_clarification_answer_evidence%rowtype;
  v_resolve jsonb;
  v_prior_claims text := nullif(current_setting('request.jwt.claims', true), '');
begin
  if coalesce(auth.jwt() ->> 'role', '') <> 'service_role' and pg_trigger_depth() = 0 then
    raise exception 'CORE_C_SERVICE_ROLE_REQUIRED' using errcode = '42501';
  end if;

  if pg_trigger_depth() > 0 then
    perform set_config('request.jwt.claims', '{"role":"service_role"}', true);
  end if;

  begin
    v_evidence := public.whatsapp_correlate_clarification_answer(p_inbound_whatsapp_message_id);
  exception
    when others then
      if pg_trigger_depth() > 0 then
        perform set_config('request.jwt.claims', coalesce(v_prior_claims, ''), true);
      end if;
      return jsonb_build_object('correlated', false, 'reason', sqlerrm);
  end;

  begin
    v_resolve := public.whatsapp_core_c_resolve_correlated_clarification_v1(v_evidence.id);
  exception
    when others then
      if pg_trigger_depth() > 0 then
        perform set_config('request.jwt.claims', coalesce(v_prior_claims, ''), true);
      end if;
      return jsonb_build_object(
        'correlated', true,
        'answer_evidence_id', v_evidence.id,
        'resolved', false,
        'reason', sqlerrm
      );
  end;

  if pg_trigger_depth() > 0 then
    perform set_config('request.jwt.claims', coalesce(v_prior_claims, ''), true);
  end if;

  return jsonb_build_object(
    'correlated', true,
    'answer_evidence_id', v_evidence.id,
    'clarification_resolution', v_resolve,
    'case_context_dispatched', true
  );
end;
$$;

create or replace function public.stitch_whatsapp_messages_atomic(
  p_contact_id uuid,
  p_message_ids uuid[],
  p_window_seconds integer default 300
)
returns uuid
language plpgsql
security definer
set search_path = pg_catalog, public, pg_temp
as $$
declare
  v_ids uuid[];
  v_requested integer;
  v_found integer;
  v_existing_packet_count integer;
  v_existing_packet uuid;
  v_packet_id uuid;
  v_fragment_count integer;
  v_first_at timestamp without time zone;
  v_last_at timestamp without time zone;
  v_text text;
  v_msg_id uuid;
  v_prior_claims text;
begin
  if p_contact_id is null then raise exception 'WA_PACKET_CONTACT_REQUIRED' using errcode='P0001'; end if;
  if p_window_seconds is null or p_window_seconds < 1 or p_window_seconds > 3600 then
    raise exception 'WA_PACKET_WINDOW_INVALID' using errcode='P0001';
  end if;

  select coalesce(array_agg(distinct x order by x), '{}'::uuid[]) into v_ids
  from unnest(coalesce(p_message_ids,'{}'::uuid[])) x where x is not null;
  v_requested := cardinality(v_ids);
  if v_requested=0 then raise exception 'WA_PACKET_MESSAGES_REQUIRED' using errcode='P0001'; end if;

  perform pg_advisory_xact_lock(hashtextextended(p_contact_id::text,0));
  perform 1 from public.whatsapp_messages m where m.id=any(v_ids) order by m.id for update;

  select count(*),min(coalesce(m.message_timestamp,m.created_at)),max(coalesce(m.message_timestamp,m.created_at)),
         string_agg(coalesce(m.content,''),E'\n' order by coalesce(m.message_timestamp,m.created_at),m.created_at,m.id)
    into v_found,v_first_at,v_last_at,v_text
  from public.whatsapp_messages m
  where m.id=any(v_ids) and m.contact_id=p_contact_id and m.direction='inbound';
  if v_found<>v_requested then raise exception 'WA_PACKET_MESSAGE_SCOPE_MISMATCH' using errcode='P0001'; end if;
  if v_last_at - v_first_at > make_interval(secs=>p_window_seconds) then
    raise exception 'WA_PACKET_BATCH_WINDOW_EXCEEDED' using errcode='P0001';
  end if;

  select count(distinct m.packet_id),(array_agg(distinct m.packet_id) filter(where m.packet_id is not null))[1]
    into v_existing_packet_count,v_existing_packet
  from public.whatsapp_messages m where m.id=any(v_ids);

  if v_existing_packet_count>0 then
    if v_existing_packet_count=1
       and not exists(select 1 from public.whatsapp_messages m where m.id=any(v_ids) and m.packet_id is null)
       and not exists(select 1 from public.whatsapp_messages m where m.id=any(v_ids) and m.packet_id<>v_existing_packet) then
      return v_existing_packet;
    end if;
    raise exception 'WA_PACKET_PARTIAL_OR_CONFLICTING_REPLAY' using errcode='P0001';
  end if;

  select p.id,p.fragment_count into v_packet_id,v_fragment_count
  from public.whatsapp_message_packets p
  where p.contact_id=p_contact_id and p.status='open'
    and p.last_message_at>=v_first_at-make_interval(secs=>p_window_seconds)
    and p.last_message_at>=v_last_at-make_interval(secs=>p_window_seconds)
    and p.first_message_at<=v_first_at+make_interval(secs=>p_window_seconds)
  order by p.last_message_at desc,p.id limit 1 for update;

  if v_packet_id is null then
    insert into public.whatsapp_message_packets(contact_id,stitched_content,fragment_count,first_message_at,last_message_at,status,created_at,updated_at)
    values(p_contact_id,jsonb_build_object('summary',v_requested::text||' messages stitched','text',coalesce(v_text,'')),v_requested,v_first_at,v_last_at,'open',statement_timestamp(),statement_timestamp())
    returning id into v_packet_id;
    v_fragment_count:=0;
  else
    update public.whatsapp_message_packets p
    set fragment_count=p.fragment_count+v_requested,
        first_message_at=least(p.first_message_at,v_first_at),
        last_message_at=greatest(p.last_message_at,v_last_at),
        stitched_content=jsonb_build_object('summary',(p.fragment_count+v_requested)::text||' messages stitched','text',concat_ws(E'\n',nullif(p.stitched_content->>'text',''),nullif(v_text,''))),
        updated_at=statement_timestamp()
    where p.id=v_packet_id and p.status='open';
    if not found then raise exception 'WA_PACKET_CLOSED_DURING_STITCH' using errcode='P0001'; end if;
  end if;

  with ranked as (
    select m.id,v_fragment_count+row_number() over(order by coalesce(m.message_timestamp,m.created_at),m.created_at,m.id) as seq
    from public.whatsapp_messages m where m.id=any(v_ids)
  )
  update public.whatsapp_messages m
  set packet_id=v_packet_id,packet_sequence=ranked.seq,packet_status='open',is_raw=false,stitched_at=statement_timestamp()
  from ranked where m.id=ranked.id and m.packet_id is null;
  if not found then raise exception 'WA_PACKET_FRAGMENT_LINK_FAILED' using errcode='P0001'; end if;

  v_prior_claims := nullif(current_setting('request.jwt.claims', true), '');
  perform set_config('request.jwt.claims', '{"role":"service_role"}', true);
  begin
    for v_msg_id in
      select m.id
      from public.whatsapp_messages m
      where m.id = any(v_ids)
        and lower(m.direction) = 'inbound'
        and m.provider_message_id is not null
        and nullif(btrim(m.provider_message_id), '') is not null
    loop
      perform public.whatsapp_process_inbound_whatsapp_continuation_v1(v_msg_id);
    end loop;
  exception
    when others then
      perform set_config('request.jwt.claims', coalesce(v_prior_claims, ''), true);
      raise;
  end;
  perform set_config('request.jwt.claims', coalesce(v_prior_claims, ''), true);

  return v_packet_id;
end;
$$;

-- -----------------------------------------------------------------------------
-- 2. Route unresolved blocking reasons to human review without aborting materialization
-- -----------------------------------------------------------------------------

create or replace function public.whatsapp_core_c_derive_clarification_field(
  p_blocking_reasons text[]
)
returns text
language plpgsql
immutable
set search_path = pg_catalog, public
as $$
declare
  v_field text;
begin
  if exists (
    select 1 from unnest(coalesce(p_blocking_reasons, '{}'::text[])) r
    where r like 'ambiguous_customer%' or r = 'ambiguous_customer_match'
  ) then return 'CUSTOMER'; end if;
  if exists (
    select 1 from unnest(coalesce(p_blocking_reasons, '{}'::text[])) r
    where r like '%branch%'
  ) then return 'BRANCH'; end if;
  if exists (
    select 1 from unnest(coalesce(p_blocking_reasons, '{}'::text[])) r
    where r like '%quantity%'
  ) then return 'QUANTITY'; end if;
  if exists (
    select 1 from unnest(coalesce(p_blocking_reasons, '{}'::text[])) r
    where r like '%unit%' or r like '%uom%' or r like '%pack%'
  ) then return 'UOM_PACK'; end if;
  if exists (
    select 1 from unnest(coalesce(p_blocking_reasons, '{}'::text[])) r
    where r like '%product%' or r like '%sku%'
  ) then return 'PRODUCT'; end if;
  if exists (
    select 1 from unnest(coalesce(p_blocking_reasons, '{}'::text[])) r
    where r like '%conflict%' or r like '%contradict%'
  ) then return 'CORRECTION'; end if;

  raise exception 'CORE_C_UNRESOLVED_BLOCKING_REASON' using errcode = 'CR001';
end;
$$;

create or replace function public.whatsapp_enqueue_autonomy_clarification_v1(
  p_autonomy_decision_id uuid,
  p_draft_reply text default null
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public, auth
as $$
declare
  v_decision public.whatsapp_order_autonomy_decisions%rowtype;
  v_case public.whatsapp_communication_cases%rowtype;
  v_packet public.whatsapp_message_packets%rowtype;
  v_contact public.whatsapp_contacts%rowtype;
  v_auth public.whatsapp_case_recipient_authorizations%rowtype;
  v_field text;
  v_question text;
  v_key text;
  v_clarification public.whatsapp_case_clarifications%rowtype;
  v_reply public.whatsapp_operator_reply_outbox%rowtype;
  v_revision bigint;
  v_principal uuid;
begin
  if coalesce(auth.jwt() ->> 'role', '') <> 'service_role' then
    raise exception 'CORE_C_SERVICE_ROLE_REQUIRED' using errcode = '42501';
  end if;

  v_principal := public.whatsapp_core_c_ensure_system_principal();

  select * into v_decision
  from public.whatsapp_order_autonomy_decisions
  where id = p_autonomy_decision_id;
  if not found or v_decision.autonomy_outcome <> 'CLARIFICATION_REQUIRED' then
    raise exception 'CORE_C_CLARIFICATION_DECISION_REQUIRED';
  end if;
  if v_decision.case_id is null then
    raise exception 'CORE_C_CASE_REQUIRED';
  end if;

  select * into v_case from public.whatsapp_communication_cases where id = v_decision.case_id for update;
  select * into v_packet from public.whatsapp_message_packets where id = v_decision.packet_id;
  select * into v_contact from public.whatsapp_contacts where id = v_packet.contact_id;

  if v_case.case_type <> 'ORDER' then
    return jsonb_build_object(
      'case_id', v_case.id,
      'skipped', true,
      'reason', 'CORE_C_CLARIFICATION_ORDER_PATH_ONLY'
    );
  end if;

  v_revision := coalesce(v_case.context_revision, 0);
  v_key := 'core-c:clarification:' || v_decision.interpretation_id::text || ':rev:' || v_revision::text;

  if exists (
    select 1 from public.whatsapp_case_events
    where case_id = v_case.id and correlation_key = 'core-c-clarification-blocked:' || v_key
  ) then
    return jsonb_build_object(
      'case_id', v_case.id,
      'routed_to_human_review', true,
      'reason', 'CORE_C_UNRESOLVED_BLOCKING_REASON',
      'blocking_reasons', to_jsonb(v_decision.blocking_reasons),
      'idempotent_replay', true
    );
  end if;

  if exists (
    select 1 from public.whatsapp_case_events
    where case_id = v_case.id and correlation_key = 'core-c-clarification:' || v_key
  ) then
    select * into v_clarification
    from public.whatsapp_case_clarifications
    where case_id = v_case.id and correlation_key = 'core-c:' || v_key;
    select * into v_reply
    from public.whatsapp_operator_reply_outbox
    where packet_id = v_decision.packet_id and idempotency_key = v_key;
    return jsonb_build_object(
      'case_id', v_case.id,
      'clarification_id', v_clarification.id,
      'reply_id', v_reply.id,
      'idempotent_replay', true
    );
  end if;

  v_auth := public.whatsapp_core_c_ensure_submitting_sender_authorization(v_case.id);

  begin
    v_field := public.whatsapp_core_c_derive_clarification_field(v_decision.blocking_reasons);
  exception
    when sqlstate 'CR001' then
      update public.whatsapp_communication_cases
      set status = case
            when status in ('OPEN', 'NEEDS_IDENTITY') then 'OPEN'
            else status
          end,
          next_action = coalesce(
            nullif(btrim(next_action), ''),
            'Human or department review required: unresolved blocking reason'
          ),
          next_action_due_at = coalesce(
            next_action_due_at,
            statement_timestamp() + interval '1 day'
          ),
          updated_at = statement_timestamp()
      where id = v_case.id;

      insert into public.whatsapp_case_events(
        case_id, event_type, actor_type, correlation_key, resulting_state, metadata
      ) values (
        v_case.id, 'AUTONOMOUS_CLARIFICATION_BLOCKED', 'SYSTEM',
        'core-c-clarification-blocked:' || v_key,
        jsonb_build_object(
          'status', 'OPEN',
          'blocking_reasons', v_decision.blocking_reasons,
          'context_revision', v_revision
        ),
        jsonb_build_object(
          'autonomy_decision_id', v_decision.id,
          'reason', 'CORE_C_UNRESOLVED_BLOCKING_REASON',
          'automatic_action_authority', 'HUMAN_OR_DEPARTMENT_REVIEW_REQUIRED'
        )
      )
      on conflict (case_id, correlation_key) do nothing;

      return jsonb_build_object(
        'case_id', v_case.id,
        'routed_to_human_review', true,
        'reason', 'CORE_C_UNRESOLVED_BLOCKING_REASON',
        'blocking_reasons', to_jsonb(v_decision.blocking_reasons),
        'idempotent_replay', false
      );
  end;

  v_question := public.whatsapp_core_c_minimum_clarification_question(v_field);

  insert into public.whatsapp_case_clarifications(
    case_id, field_name, question, recipient_authorization_id, status,
    due_at, next_follow_up_at, asked_by, correlation_key
  ) values (
    v_case.id, v_field, v_question, v_auth.id, 'OPEN',
    statement_timestamp() + interval '1 day',
    statement_timestamp() + interval '1 day',
    v_principal,
    'core-c:' || v_key
  ) returning * into v_clarification;

  v_reply := public.enqueue_governed_whatsapp_autonomous_reply(
    v_decision.packet_id, v_contact.id,
    '+' || regexp_replace(v_contact.phone_number, '\D', '', 'g'),
    v_question, v_key, 'AUTONOMY_CLARIFICATION',
    v_decision.potential_order_id, v_case.id, v_clarification.id, '{}'::text[]
  );

  update public.whatsapp_case_clarifications
  set source_outbound_message_id = v_reply.id
  where id = v_clarification.id;

  update public.whatsapp_communication_cases
  set status = 'AWAITING_CUSTOMER',
      next_action = 'Await customer clarification: ' || v_field,
      next_action_due_at = statement_timestamp() + interval '1 day',
      updated_at = statement_timestamp()
  where id = v_case.id;

  insert into public.whatsapp_case_events(
    case_id, event_type, actor_type, correlation_key, resulting_state, metadata
  ) values (
    v_case.id, 'AUTONOMOUS_CLARIFICATION_RELEASED', 'SYSTEM',
    'core-c-clarification:' || v_key,
    jsonb_build_object(
      'status', 'AWAITING_CUSTOMER',
      'field_name', v_field,
      'context_revision', v_revision
    ),
    jsonb_build_object(
      'autonomy_decision_id', v_decision.id,
      'clarification_id', v_clarification.id,
      'reply_id', v_reply.id,
      'question', v_question,
      'verification_method', v_auth.verification_method
    )
  );

  return jsonb_build_object(
    'case_id', v_case.id,
    'clarification_id', v_clarification.id,
    'reply_id', v_reply.id,
    'field_name', v_field,
    'idempotent_replay', false
  );
end;
$$;

-- -----------------------------------------------------------------------------
-- 3. Preserve existing human assignment on non-order routing replays
-- -----------------------------------------------------------------------------

create or replace function public.whatsapp_apply_non_order_case_governance_v1(
  p_case_id uuid,
  p_interpretation_id uuid,
  p_intent text,
  p_primary_department text,
  p_reply_clearance text default null,
  p_draft_reply text default null
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public, auth
as $$
declare
  v_case public.whatsapp_communication_cases%rowtype;
  v_packet public.whatsapp_message_packets%rowtype;
  v_contact public.whatsapp_contacts%rowtype;
  v_principal uuid;
  v_team text;
  v_due timestamptz;
  v_key text;
  v_body text;
  v_reply public.whatsapp_operator_reply_outbox%rowtype;
  v_allow_receipt boolean := false;
  v_owner_preserved boolean := false;
begin
  if coalesce(auth.jwt() ->> 'role', '') <> 'service_role' and pg_trigger_depth() = 0 then
    raise exception 'CORE_C_SERVICE_ROLE_REQUIRED' using errcode = '42501';
  end if;

  v_principal := public.whatsapp_core_c_ensure_system_principal();

  select * into v_case from public.whatsapp_communication_cases where id = p_case_id for update;
  if not found or v_case.status in ('CLOSED', 'CANCELLED') then
    raise exception 'CORE_C_ACTIVE_CASE_REQUIRED';
  end if;
  if v_case.case_type in ('ORDER') and upper(btrim(p_intent)) in ('ORDER', 'NEW_ORDER') then
    return jsonb_build_object('skipped', true, 'reason', 'commercial_order_path');
  end if;

  v_owner_preserved := v_case.accountable_owner_id is not null;

  v_team := coalesce(
    nullif(upper(btrim(p_primary_department)), ''),
    case v_case.case_type
      when 'COMPLAINT' then 'QUALITY'
      when 'PAYMENT_ADVICE' then 'FINANCE'
      when 'ACCOUNT_QUERY' then 'FINANCE'
      when 'DISPATCH' then 'DISPATCH'
      when 'ENQUIRY' then 'SALES'
      when 'SPECIFICATION' then 'SALES'
      else 'CUSTOMER_SERVICE'
    end
  );
  v_due := statement_timestamp() + public.whatsapp_core_c_non_order_sla_interval(v_case.case_type);

  update public.whatsapp_communication_cases
  set accountable_team = v_team,
      accountability_status = case
        when accountable_owner_id is null then 'UNASSIGNED'
        else accountability_status
      end,
      next_action = coalesce(
        nullif(btrim(v_case.next_action), ''),
        'Accountable ' || v_team || ' review required'
      ),
      next_action_due_at = coalesce(v_case.next_action_due_at, v_due),
      status = case when status = 'NEEDS_IDENTITY' then 'OPEN' else status end,
      updated_at = statement_timestamp()
  where id = p_case_id
  returning * into v_case;

  insert into public.whatsapp_case_department_tasks(
    case_id, department, task_type, instructions, status, due_at, correlation_key, created_by
  ) values (
    p_case_id, v_team, 'ACCOUNTABLE_RESPONSE_OWNER',
    'Governed non-order case requires accountable department action.',
    'OPEN', v_due, 'core-c-non-order:' || p_interpretation_id::text,
    v_principal
  )
  on conflict (case_id, correlation_key) do nothing;

  v_allow_receipt := v_case.case_type in (
    'ENQUIRY', 'COMPLAINT', 'PAYMENT_ADVICE', 'ACCOUNT_QUERY',
    'DISPATCH', 'SPECIFICATION', 'UNCLASSIFIED'
  );

  if v_allow_receipt then
    v_key := 'core-c:non-order-receipt:' || p_interpretation_id::text;
    if not exists (
      select 1 from public.whatsapp_case_events
      where case_id = p_case_id and correlation_key = 'core-c-receipt:' || v_key
    ) then
      select * into v_packet from public.whatsapp_message_packets where id = v_case.packet_id;
      select * into v_contact from public.whatsapp_contacts where id = v_packet.contact_id;
      v_body := public.whatsapp_core_c_safe_non_order_receipt(v_case.case_type, v_team, v_case.id);
      if coalesce(public.wa6_infer_commercial_disclosure(v_body), '{}'::text[]) = '{}'::text[] then
        v_reply := public.enqueue_governed_whatsapp_autonomous_reply(
          v_case.packet_id, v_contact.id,
          '+' || regexp_replace(v_contact.phone_number, '\D', '', 'g'),
          v_body, v_key, 'NON_ORDER_RECEIPT',
          null, v_case.id, null, '{}'::text[]
        );
        insert into public.whatsapp_case_events(
          case_id, event_type, actor_type, correlation_key, metadata
        ) values (
          p_case_id, 'AUTONOMOUS_NON_ORDER_RECEIPT_SENT', 'SYSTEM',
          'core-c-receipt:' || v_key,
          jsonb_build_object('reply_id', v_reply.id, 'case_type', v_case.case_type)
        )
        on conflict (case_id, correlation_key) do nothing;
      end if;
    end if;
  end if;

  insert into public.whatsapp_case_events(
    case_id, event_type, actor_type, correlation_key, resulting_state, metadata
  ) values (
    p_case_id, 'NON_ORDER_TEAM_ROUTED', 'SYSTEM',
    'core-c-non-order-governance:' || p_interpretation_id::text,
    jsonb_build_object(
      'accountable_team', v_team,
      'accountability_status', v_case.accountability_status,
      'case_type', v_case.case_type,
      'intent', upper(btrim(p_intent))
    ),
    jsonb_build_object('due_at', v_due, 'interpretation_id', p_interpretation_id)
  )
  on conflict (case_id, correlation_key) do nothing;

  return jsonb_build_object(
    'case_id', p_case_id,
    'accountable_team', v_team,
    'accountability_status', v_case.accountability_status,
    'owner_preserved', v_owner_preserved,
    'next_action_due_at', v_due,
    'receipt_sent', v_reply.id is not null
  );
end;
$$;

-- -----------------------------------------------------------------------------
-- 4. Restore finalize access controls and always reset governed mutation flag
-- -----------------------------------------------------------------------------

create or replace function public.whatsapp_finalize_autonomous_so_promotion_v1(
  p_autonomy_decision_id uuid,
  p_draft_id uuid,
  p_promoted_order_id uuid,
  p_order_number text,
  p_idempotency_key text,
  p_governed_facts jsonb,
  p_readiness jsonb
)
returns void
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  v_projection public.whatsapp_order_autonomy_draft_executions%rowtype;
begin
  select * into v_projection
  from public.whatsapp_order_autonomy_draft_executions
  where autonomy_decision_id = p_autonomy_decision_id;

  if not found then
    raise exception 'CORE_C_DRAFT_EXECUTION_PROJECTION_REQUIRED' using errcode = 'P0001';
  end if;

  perform public.whatsapp_append_autonomy_draft_execution_event(
    p_autonomy_decision_id, 'PROMOTED',
    v_projection.potential_order_id, v_projection.case_id, v_projection.packet_id, v_projection.interpretation_id,
    p_draft_id, p_promoted_order_id, null,
    p_idempotency_key,
    p_governed_facts, p_readiness
  );

  if v_projection.case_id is not null then
    insert into public.whatsapp_case_events(case_id, event_type, actor_type, correlation_key, resulting_state, metadata)
    values (
      v_projection.case_id, 'AUTONOMOUS_SO_PROMOTED', 'SYSTEM',
      'core-b-promote:' || v_projection.interpretation_id::text,
      jsonb_build_object('sales_order_draft_id', p_draft_id, 'promoted_order_id', p_promoted_order_id),
      jsonb_build_object('order_number', p_order_number, 'autonomous', true)
    )
    on conflict (case_id, correlation_key) do nothing;

    update public.whatsapp_communication_cases
    set next_action = 'SO_CREATED_AWAITING_FULFILLMENT',
        updated_at = statement_timestamp()
    where id = v_projection.case_id;
  end if;

  begin
    perform set_config('app.wa1_governed_mutation', 'on', true);
    update public.whatsapp_potential_orders
    set state = 'CONVERTED',
        disposition = 'CONVERTED',
        sales_order_draft_id = p_draft_id,
        sales_order_id = p_promoted_order_id,
        next_action = 'ORDER_CREATED',
        updated_at = statement_timestamp()
    where id = v_projection.potential_order_id;
    perform set_config('app.wa1_governed_mutation', 'off', true);
  exception
    when others then
      perform set_config('app.wa1_governed_mutation', 'off', true);
      raise;
  end;

  perform public.whatsapp_enqueue_promoted_order_acknowledgement_v1(
    p_autonomy_decision_id, p_order_number
  );
end;
$$;

revoke all on function public.whatsapp_finalize_autonomous_so_promotion_v1(uuid, uuid, uuid, text, text, jsonb, jsonb)
  from public, anon, authenticated;
grant execute on function public.whatsapp_finalize_autonomous_so_promotion_v1(uuid, uuid, uuid, text, text, jsonb, jsonb)
  to service_role;

commit;

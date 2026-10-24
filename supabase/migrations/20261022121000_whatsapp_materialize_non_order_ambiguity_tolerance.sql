-- WA-RECOVERY-01: packet-AI case materialization must not fail on ambiguous potential orders
-- when no linked potential order has a sales order.
--
-- Root cause (production, four historical jobs looping since 2026-10-05): the inbound path records one
-- potential order per inbound message. A stitched packet of N messages therefore resolves to N potential
-- orders, and public.whatsapp_case_potential_order_id() raises "multiple potential orders are linked to
-- this communication case". whatsapp_materialize_packet_ai_case() called that strict resolver
-- unconditionally, even for greetings, catalogue requests and third-party auto-replies, solely to feed
-- whatsapp_core_c_guard_post_so_correction_v1(). That guard can only block when the resolved potential
-- order already has a sales order, so when no candidate has one the ambiguity cannot change its outcome.
--
-- Fix: a guard-specific resolver that keeps the strict behaviour (raise) when any candidate potential
-- order already has a sales order, and returns NULL (guard not blocked) otherwise. The strict resolver is
-- unchanged and remains the authority for clarification correlation and lineage. No potential order is
-- ever selected automatically, no data is modified, and no order or message is created.
--
-- The two function bodies below are production's current definitions (md5 of prosrc verified equal to the
-- replay of main for both) with exactly one call replaced in each. Existing ACLs are preserved by
-- CREATE OR REPLACE.

create or replace function public.whatsapp_case_potential_order_id_for_correction_guard_v1(p_case_id uuid)
returns uuid
language plpgsql
stable
security definer
set search_path = pg_catalog, public
as $fn$
begin
  begin
    return public.whatsapp_case_potential_order_id(p_case_id);
  exception when raise_exception then
    if sqlerrm is distinct from 'multiple potential orders are linked to this communication case' then
      raise;
    end if;
    if exists (
      select 1
      from public.whatsapp_communication_cases c
      join public.whatsapp_message_packets p on p.id = c.packet_id
      join public.whatsapp_contacts ct on ct.id = p.contact_id
      join public.whatsapp_commercial_evidence e
        on e.potential_order_id is not null
       and e.sender_key = lower(regexp_replace(ct.phone_number, '\D', '', 'g'))
       and (
         e.packet_id = c.packet_id
         or exists (
           select 1
           from public.whatsapp_messages m
           join public.whatsapp_contacts mc on mc.id = m.contact_id
           where m.packet_id = c.packet_id
             and m.direction = 'inbound'
             and m.provider_message_id is not null
             and btrim(m.provider_message_id) <> ''
             and btrim(m.provider_message_id) = btrim(e.provider_message_id)
             and lower(regexp_replace(mc.phone_number, '\D', '', 'g')) = lower(regexp_replace(ct.phone_number, '\D', '', 'g'))
         )
       )
      join public.whatsapp_potential_orders po on po.id = e.potential_order_id
      where c.id = p_case_id
        and po.sales_order_id is not null
    ) then
      raise;
    end if;
    return null;
  end;
end;
$fn$;

revoke all on function public.whatsapp_case_potential_order_id_for_correction_guard_v1(uuid) from public, anon, authenticated;
grant execute on function public.whatsapp_case_potential_order_id_for_correction_guard_v1(uuid) to service_role;

-- Second call site: whatsapp_evaluate_and_materialize_order_autonomy() also resolved the strict resolver
-- before it knew whether the message was an order. Tolerance here is limited to intents that never reach
-- capture_whatsapp_potential_order() (explicit non-order intents at confidence >= 0.50). ORDER, NEW_ORDER,
-- UNCLEAR, low-confidence and order-modification intents keep the strict behaviour, so an ambiguous
-- order-like message still fails into governed human review and no potential order is ever picked.
create or replace function public.whatsapp_case_potential_order_id_for_non_order_v1(
  p_case_id uuid, p_intent text, p_confidence numeric
)
returns uuid
language plpgsql
stable
security definer
set search_path = pg_catalog, public
as $fn$
begin
  if upper(coalesce(p_intent, '')) in (
       'ENQUIRY', 'SPECIFICATION_QUERY', 'SPECIFICATION', 'DELIVERY_QUERY', 'DISPATCH',
       'COMPLAINT', 'ACCOUNT_QUERY', 'FINANCE', 'PAYMENT_ADVICE', 'OTHER'
     )
     and coalesce(p_confidence, 0) >= 0.50 then
    return public.whatsapp_case_potential_order_id_for_correction_guard_v1(p_case_id);
  end if;
  return public.whatsapp_case_potential_order_id(p_case_id);
end;
$fn$;

revoke all on function public.whatsapp_case_potential_order_id_for_non_order_v1(uuid, text, numeric) from public, anon, authenticated;
grant execute on function public.whatsapp_case_potential_order_id_for_non_order_v1(uuid, text, numeric) to service_role;


CREATE OR REPLACE FUNCTION public.whatsapp_materialize_packet_ai_case(p_packet_id uuid, p_interpretation_id uuid, p_job_id uuid DEFAULT NULL::uuid, p_lease_token uuid DEFAULT NULL::uuid, p_packet_revision bigint DEFAULT NULL::bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'auth'
AS $function$
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
  v_correction_guard jsonb;
  v_has_corrections boolean := false;
  v_clarification jsonb;
  v_non_order jsonb;
  v_autonomy_outcome text := null;
  v_human_decision_required boolean := true;
  v_autonomy jsonb := '{}'::jsonb;
  v_draft_execution jsonb;
begin
  if v_role <> 'service_role' then
    raise exception 'trusted packet processor required' using errcode = '42501';
  end if;

  if p_job_id is not null then
    perform public.whatsapp_require_packet_ai_dispatch_lease(
      p_job_id, p_lease_token, p_packet_revision
    );
  end if;

  select * into v_packet from public.whatsapp_message_packets where id = p_packet_id;
  if not found then raise exception 'WhatsApp packet not found'; end if;

  select * into v_ai from public.whatsapp_packet_ai_interpretations
  where id = p_interpretation_id and packet_id = p_packet_id;
  if not found then raise exception 'packet AI interpretation not found for packet'; end if;

  select * into v_contact from public.whatsapp_contacts where id = v_packet.contact_id;
  if not found then raise exception 'WhatsApp packet contact not found'; end if;

  v_conclusion := case when jsonb_typeof(v_ai.interpretation -> 'conclusion') = 'object'
    then v_ai.interpretation -> 'conclusion' else '{}'::jsonb end;
  v_intent := upper(coalesce(nullif(btrim(v_conclusion ->> 'intent'), ''), 'UNCLEAR'));
  v_case_type := case v_intent
    when 'NEW_ORDER' then 'ORDER' when 'ORDER' then 'ORDER'
    when 'AMENDMENT' then 'ORDER_CHANGE' when 'ORDER_CHANGE' then 'ORDER_CHANGE'
    when 'CANCELLATION' then 'CANCELLATION' when 'ENQUIRY' then 'ENQUIRY'
    when 'COMPLAINT' then 'COMPLAINT' when 'PAYMENT_ADVICE' then 'PAYMENT_ADVICE'
    when 'ACCOUNT_QUERY' then 'ACCOUNT_QUERY' when 'FINANCE' then 'ACCOUNT_QUERY'
    when 'DELIVERY_QUERY' then 'DISPATCH' when 'DISPATCH' then 'DISPATCH'
    when 'SPECIFICATION_QUERY' then 'SPECIFICATION' when 'SPECIFICATION' then 'SPECIFICATION'
    else 'UNCLASSIFIED' end;
  v_recommended_action := nullif(btrim(coalesce(v_conclusion ->> 'recommended_action', '')), '');
  v_primary_department := nullif(upper(btrim(coalesce(v_conclusion ->> 'primary_department', ''))), '');
  v_contributors := case when jsonb_typeof(v_conclusion -> 'contributor_departments') = 'array'
    then v_conclusion -> 'contributor_departments' else '[]'::jsonb end;
  v_reply_clearance := nullif(upper(btrim(coalesce(v_conclusion ->> 'reply_clearance', ''))), '');
  v_draft_reply := nullif(btrim(coalesce(v_conclusion ->> 'draft_reply', '')), '');
  v_ambiguity_count := case when jsonb_typeof(v_conclusion -> 'ambiguities') = 'array'
    then jsonb_array_length(v_conclusion -> 'ambiguities') else 0 end;
  v_has_corrections := jsonb_typeof(v_conclusion -> 'corrections') = 'array'
    and jsonb_array_length(v_conclusion -> 'corrections') > 0;

  insert into public.whatsapp_communication_cases (
    packet_id, case_type, status, next_action, source_channel, rule_version
  ) values (
    p_packet_id, v_case_type, 'NEEDS_IDENTITY', v_recommended_action, 'WHATSAPP', 'packet-ai-b2b-v1'
  )
  on conflict (packet_id) do update
  set case_type = case when public.whatsapp_communication_cases.accountability_status = 'UNASSIGNED'
      and public.whatsapp_communication_cases.status in ('OPEN', 'NEEDS_IDENTITY', 'NEEDS_CLARIFICATION', 'READY_FOR_DRAFT')
      then excluded.case_type else public.whatsapp_communication_cases.case_type end,
      next_action = case when public.whatsapp_communication_cases.accountability_status = 'UNASSIGNED'
      and public.whatsapp_communication_cases.status in ('OPEN', 'NEEDS_IDENTITY', 'NEEDS_CLARIFICATION', 'READY_FOR_DRAFT')
      then excluded.next_action else public.whatsapp_communication_cases.next_action end,
      rule_version = case when public.whatsapp_communication_cases.accountability_status = 'UNASSIGNED'
      and public.whatsapp_communication_cases.status in ('OPEN', 'NEEDS_IDENTITY', 'NEEDS_CLARIFICATION', 'READY_FOR_DRAFT')
      then excluded.rule_version else public.whatsapp_communication_cases.rule_version end,
      updated_at = statement_timestamp()
  returning * into v_case;

  insert into public.whatsapp_case_identities (
    case_id, identity_role, party_type, party_id, display_label, phone_e164, resolution_status, confidence, evidence
  ) values (
    v_case.id, 'SUBMITTING_SENDER', 'CONTACT', v_contact.id,
    coalesce(nullif(v_contact.customer_name, ''), nullif(v_contact.company_name, ''), v_contact.phone_number),
    v_contact.phone_number, 'SUGGESTED', 1.0,
    jsonb_build_array(jsonb_build_object('source', 'WHATSAPP_PACKET', 'packet_id', p_packet_id, 'contact_id', v_contact.id))
  )
  on conflict (case_id, identity_role) do update
  set party_type = excluded.party_type, party_id = excluded.party_id, display_label = excluded.display_label,
      phone_e164 = excluded.phone_e164, confidence = excluded.confidence, evidence = excluded.evidence
  where public.whatsapp_case_identities.resolution_status <> 'CONFIRMED';

  v_event_key := 'packet-ai:' || p_interpretation_id::text;
  insert into public.whatsapp_case_events (case_id, event_type, actor_id, actor_type, correlation_key, resulting_state, metadata)
  values (
    v_case.id, 'AI_CONCLUSION_READY', null, 'SYSTEM', v_event_key,
    jsonb_build_object('case_type', v_case_type, 'case_status', v_case.status),
    jsonb_build_object(
      'packet_id', p_packet_id, 'packet_ai_interpretation_id', p_interpretation_id,
      'content_fingerprint', v_ai.content_fingerprint, 'model_version', v_ai.model_version,
      'intent', v_intent, 'summary', coalesce(v_conclusion ->> 'summary', ''),
      'confidence', v_ai.interpretation -> 'confidence', 'ambiguity_count', v_ambiguity_count,
      'recommended_action', v_recommended_action, 'primary_department', v_primary_department,
      'contributor_departments', v_contributors, 'reply_clearance', v_reply_clearance,
      'draft_reply', v_draft_reply, 'conclusion', v_conclusion
    )
  )
  on conflict (case_id, correlation_key) do nothing;

  v_correction_guard := public.whatsapp_core_c_guard_post_so_correction_v1(
    coalesce(
      public.whatsapp_case_potential_order_id_for_correction_guard_v1(v_case.id),
      (
        select d.potential_order_id
        from public.whatsapp_order_autonomy_decisions d
        where d.case_id = v_case.id
        order by d.evaluated_at desc
        limit 1
      )
    ),
    v_intent,
    v_has_corrections
  );
  if coalesce((v_correction_guard ->> 'blocked')::boolean, false) then
    insert into public.whatsapp_case_events(
      case_id, event_type, actor_type, correlation_key, metadata
    ) values (
      v_case.id, 'POST_SO_CORRECTION_ROUTED', 'SYSTEM',
      'core-c-post-so-correction:' || p_interpretation_id::text,
      v_correction_guard
    )
    on conflict (case_id, correlation_key) do nothing;
  else
    v_autonomy := public.whatsapp_evaluate_and_materialize_order_autonomy(
      p_packet_id, p_interpretation_id, p_job_id, p_lease_token, p_packet_revision
    );

    v_autonomy_outcome := v_autonomy->>'autonomy_outcome';
    v_human_decision_required := coalesce(
      (v_autonomy->>'human_decision_required')::boolean,
      (v_autonomy_outcome <> 'AUTO_ELIGIBLE')
    );

    v_draft_execution := null;
    if v_autonomy_outcome = 'AUTO_ELIGIBLE' and v_autonomy->>'decision_id' is not null then
      v_draft_execution := public.whatsapp_execute_autonomous_order_draft_v1(
        (v_autonomy->>'decision_id')::uuid,
        true
      );
    elsif v_autonomy_outcome = 'CLARIFICATION_REQUIRED' and v_autonomy->>'decision_id' is not null then
      v_clarification := public.whatsapp_enqueue_autonomy_clarification_v1(
        (v_autonomy->>'decision_id')::uuid,
        v_draft_reply
      );
    end if;
  end if;

  if v_intent not in ('ORDER', 'NEW_ORDER') or v_case.case_type <> 'ORDER' then
    v_non_order := public.whatsapp_apply_non_order_case_governance_v1(
      v_case.id, p_interpretation_id, v_intent, v_primary_department,
      v_reply_clearance, v_draft_reply
    );
  end if;

  select * into v_case from public.whatsapp_communication_cases where id = v_case.id;

  return jsonb_build_object(
    'case_id', v_case.id,
    'packet_id', p_packet_id,
    'interpretation_id', p_interpretation_id,
    'case_type', v_case.case_type,
    'status', v_case.status,
    'accountability_status', v_case.accountability_status,
    'autonomy_outcome', v_autonomy_outcome,
    'autonomy_decision_id', v_autonomy->>'decision_id',
    'governed_facts', v_autonomy->'governed_facts',
    'readiness', v_autonomy->'readiness',
    'draft_execution', v_draft_execution,
    'clarification', v_clarification,
    'non_order_governance', v_non_order,
    'post_so_correction_guard', v_correction_guard,
    'ai_event_correlation_key', v_event_key,
    'human_decision_required', v_human_decision_required,
    'idempotent_replay', coalesce((v_autonomy->>'idempotent_replay')::boolean, false)
  );
end;
$function$;

CREATE OR REPLACE FUNCTION public.whatsapp_evaluate_and_materialize_order_autonomy(p_packet_id uuid, p_interpretation_id uuid, p_job_id uuid DEFAULT NULL::uuid, p_lease_token uuid DEFAULT NULL::uuid, p_packet_revision bigint DEFAULT NULL::bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'auth'
AS $function$
declare
  v_packet public.whatsapp_message_packets%rowtype;
  v_contact public.whatsapp_contacts%rowtype;
  v_ai public.whatsapp_packet_ai_interpretations%rowtype;
  v_conclusion jsonb;
  v_intent text;
  v_case public.whatsapp_communication_cases%rowtype;
  v_existing_decision public.whatsapp_order_autonomy_decisions%rowtype;
  v_potential_order_id uuid;
  v_po public.whatsapp_potential_orders%rowtype;
  v_primary_msg_id uuid;
  v_customer_rec record;
  v_branch_rec record;
  v_branch_status text := 'UNRESOLVED';
  v_lines jsonb;
  v_line jsonb;
  v_line_idx integer;
  v_line_rec record;
  v_governed_lines jsonb := '[]'::jsonb;
  v_all_lines_resolved boolean := true;
  v_any_missing_qty boolean := false;
  v_any_ambiguous_sku boolean := false;
  v_any_ambiguous_uom boolean := false;
  v_any_below_moq boolean := false;
  v_is_moq_policy_only boolean;
  v_blocking_reasons text[] := '{}'::text[];
  v_decision_reasons text[] := '{}'::text[];
  v_governed_facts jsonb := '{}'::jsonb;
  v_readiness jsonb;
  v_is_ready boolean := false;
  v_outcome text;
  v_confidence numeric;
  v_decision public.whatsapp_order_autonomy_decisions%rowtype;
  v_event_key text;
  v_confirmed_customer_id uuid;
  v_customer_candidate jsonb;
begin
  if coalesce(auth.jwt()->>'role', '') <> 'service_role' then
    raise exception 'trusted packet processor required' using errcode = '42501';
  end if;

  if p_job_id is not null then
    perform public.whatsapp_require_packet_ai_dispatch_lease(
      p_job_id, p_lease_token, p_packet_revision
    );
  end if;

  -- Idempotency check: if decision already recorded for this exact interpretation, return it
  select * into v_existing_decision
  from public.whatsapp_order_autonomy_decisions
  where packet_id = p_packet_id and interpretation_id = p_interpretation_id;

  if found then
    return jsonb_build_object(
      'decision_id', v_existing_decision.id,
      'autonomy_outcome', v_existing_decision.autonomy_outcome,
      'case_id', v_existing_decision.case_id,
      'potential_order_id', v_existing_decision.potential_order_id,
      'packet_id', v_existing_decision.packet_id,
      'decision_reasons', to_jsonb(v_existing_decision.decision_reasons),
      'blocking_reasons', to_jsonb(v_existing_decision.blocking_reasons),
      'governed_facts', v_existing_decision.governed_facts,
      'readiness', v_existing_decision.readiness_snapshot,
      'human_decision_required', (v_existing_decision.autonomy_outcome not in ('AUTO_ELIGIBLE', 'CLARIFICATION_REQUIRED')),
      'idempotent_replay', true
    );
  end if;

  select * into v_packet from public.whatsapp_message_packets where id = p_packet_id;
  if not found then raise exception 'WhatsApp packet not found' using errcode = 'P0002'; end if;

  select * into v_ai from public.whatsapp_packet_ai_interpretations
  where id = p_interpretation_id and packet_id = p_packet_id;
  if not found then raise exception 'packet AI interpretation not found' using errcode = 'P0002'; end if;

  select * into v_contact from public.whatsapp_contacts where id = v_packet.contact_id;
  if not found then raise exception 'packet contact not found' using errcode = 'P0002'; end if;

  v_conclusion := case
    when jsonb_typeof(v_ai.interpretation->'conclusion') = 'object' then v_ai.interpretation->'conclusion'
    else '{}'::jsonb
  end;

  v_confidence := case
    when jsonb_typeof(v_ai.interpretation->'confidence') = 'number' then (v_ai.interpretation->>'confidence')::numeric
    else 0.0::numeric
  end;

  v_intent := upper(coalesce(nullif(btrim(v_conclusion->>'intent'), ''), 'UNCLEAR'));

  -- Locate or create communication case
  select * into v_case from public.whatsapp_communication_cases where packet_id = p_packet_id for update;

  -- Resolve or bridge potential order
  if v_case.id is not null then
    v_potential_order_id := public.whatsapp_case_potential_order_id_for_non_order_v1(v_case.id, v_intent, v_confidence);
  end if;

  if v_potential_order_id is null then
    -- Match by inbound messages on this packet deterministically
    select im.id into v_primary_msg_id
    from public.whatsapp_messages wm
    join public.whatsapp_inbound_messages im on im.provider_message_id = wm.provider_message_id
    where wm.packet_id = p_packet_id and lower(wm.direction) = 'inbound'
    order by wm.packet_sequence nulls last, coalesce(wm.message_timestamp, wm.created_at), wm.created_at, wm.id
    limit 1;

    if v_primary_msg_id is not null and (v_intent in ('ORDER', 'NEW_ORDER') or v_intent = 'UNCLEAR' or v_confidence < 0.50) then
      select * into v_po from public.capture_whatsapp_potential_order(
        v_primary_msg_id,
        (v_intent in ('ORDER', 'NEW_ORDER')),
        (v_intent = 'UNCLEAR' or v_confidence < 0.50),
        jsonb_build_object('packet_id', p_packet_id, 'interpretation_id', p_interpretation_id)
      );
      v_potential_order_id := v_po.id;
    end if;
  else
    select * into v_po from public.whatsapp_potential_orders where id = v_potential_order_id for update;
    if v_primary_msg_id is null then
      v_primary_msg_id := v_po.source_message_id;
    end if;
  end if;

  if v_primary_msg_id is null then
    select im.id into v_primary_msg_id
    from public.whatsapp_messages wm
    join public.whatsapp_inbound_messages im on im.provider_message_id = wm.provider_message_id
    where wm.packet_id = p_packet_id and lower(wm.direction) = 'inbound'
    order by wm.packet_sequence nulls last, coalesce(wm.message_timestamp, wm.created_at), wm.created_at, wm.id
    limit 1;
  end if;

  -- 1. Intent Validation
  if v_intent not in ('ORDER', 'NEW_ORDER') then
    if v_intent in ('ENQUIRY', 'SPECIFICATION_QUERY', 'SPECIFICATION', 'DELIVERY_QUERY', 'DISPATCH') then
      v_outcome := 'CLARIFICATION_REQUIRED';
      v_decision_reasons := array_append(v_decision_reasons, 'non_order_intent:' || v_intent);
      v_blocking_reasons := array_append(v_blocking_reasons, 'intent_is_not_commercial_order');
    elsif v_intent in ('COMPLAINT', 'ACCOUNT_QUERY', 'FINANCE', 'PAYMENT_ADVICE') then
      v_outcome := 'HUMAN_EXCEPTION_REQUIRED';
      v_decision_reasons := array_append(v_decision_reasons, 'support_intent:' || v_intent);
      v_blocking_reasons := array_append(v_blocking_reasons, 'intent_requires_human_support');
    elsif v_intent in ('CANCELLATION', 'ORDER_CHANGE', 'AMENDMENT') then
      v_outcome := 'HUMAN_EXCEPTION_REQUIRED';
      v_decision_reasons := array_append(v_decision_reasons, 'order_modification_intent:' || v_intent);
      v_blocking_reasons := array_append(v_blocking_reasons, 'order_change_requires_human_verification');
    else
      if v_intent = 'UNCLEAR'
         and v_confidence >= 0.50
         and (
           upper(coalesce(nullif(btrim(v_conclusion->>'reply_clearance'), ''), '')) = 'CLARIFICATION_REQUIRED'
           or (
             jsonb_typeof(v_conclusion->'explicit_facts') = 'array'
             and jsonb_array_length(v_conclusion->'explicit_facts') > 0
           )
         ) then
        v_outcome := 'CLARIFICATION_REQUIRED';
        v_decision_reasons := array_append(v_decision_reasons, 'unclear_intent_requires_clarification');
        v_blocking_reasons := array_append(v_blocking_reasons, 'unclear_intent');
      else
        v_outcome := 'FAILED_INTERPRETATION';
        v_decision_reasons := array_append(v_decision_reasons, 'unclear_or_unsupported_intent');
        v_blocking_reasons := array_append(v_blocking_reasons, 'unclear_intent');
      end if;
    end if;
  end if;

  -- 2. Customer Validation (Deterministic, fail-closed)
  --
  -- MC#629 activation repair: a CONFIRMED COMMERCIAL_CUSTOMER case identity
  -- (written only by the real, permission-gated whatsapp_confirm_case_identity
  -- RPC) is governed, human-verified evidence and takes priority over the
  -- AI's own extracted candidate. This is resolver Priority 0 (explicit
  -- company_id) exactly as whatsapp_resolve_governed_customer already
  -- defines it -- no resolver change. When no such identity exists, behavior
  -- is byte-for-byte identical to before this migration.
  select ci.party_id into v_confirmed_customer_id
  from public.whatsapp_case_identities ci
  where ci.case_id = v_case.id
    and ci.identity_role = 'COMMERCIAL_CUSTOMER'
    and ci.resolution_status = 'CONFIRMED'
  limit 1;

  v_customer_candidate := case
    when v_confirmed_customer_id is not null then jsonb_build_object('company_id', v_confirmed_customer_id)
    when jsonb_typeof(v_conclusion->'customer') = 'object' then v_conclusion->'customer'
    else '{}'::jsonb
  end;

  select * into v_customer_rec
  from public.whatsapp_resolve_governed_customer(
    v_packet.contact_id,
    v_customer_candidate
  );

  if v_customer_rec.resolution_status = 'RESOLVED' then
    v_governed_facts := v_governed_facts || jsonb_build_object(
      'customer', jsonb_build_object(
        'company_id', v_customer_rec.company_id,
        'business_name', v_customer_rec.business_name,
        'gst_number', v_customer_rec.gst_number,
        'payment_terms', v_customer_rec.payment_terms,
        'is_frozen', v_customer_rec.is_frozen,
        'match_method', v_customer_rec.match_method
      )
    );
    v_decision_reasons := array_append(v_decision_reasons, 'customer_resolved:' || v_customer_rec.match_method);

    if v_po.id is not null and v_primary_msg_id is not null then
      perform public.record_whatsapp_order_field_evidence(
        v_po.id, 'client_identity', v_primary_msg_id,
        'core-a:customer:' || p_interpretation_id::text,
        jsonb_build_object('company_id', v_customer_rec.company_id, 'business_name', v_customer_rec.business_name),
        'resolved', 1.0, v_customer_rec.business_name,
        jsonb_build_object('match_method', v_customer_rec.match_method, 'rule_version', 'core-a-autonomy/v1'),
        true
      );
    end if;

    if v_case.id is not null then
      update public.whatsapp_communication_cases
      set company_id = v_customer_rec.company_id, updated_at = statement_timestamp()
      where id = v_case.id;

      insert into public.whatsapp_case_identities(
        case_id, identity_role, party_type, party_id, display_label, phone_e164,
        resolution_status, confidence, resolved_by, resolved_at, evidence
      ) values (
        v_case.id, 'COMMERCIAL_CUSTOMER', 'COMPANY', v_customer_rec.company_id, v_customer_rec.business_name,
        v_contact.phone_number,
        case when auth.uid() is not null then 'CONFIRMED' else 'SUGGESTED' end,
        1.0,
        auth.uid(),
        case when auth.uid() is not null then statement_timestamp() end,
        jsonb_build_array(jsonb_build_object('source', 'CORE_A_DETERMINISTIC_RESOLVER', 'method', v_customer_rec.match_method))
      )
      on conflict (case_id, identity_role) do update set
        -- MC#629 fix: an operator's human CONFIRMED identity must survive a
        -- later service_role re-evaluation (e.g. the identity-confirmation
        -- continuation this migration adds). auth.uid() is null under
        -- service_role, so excluded.resolution_status/resolved_by/resolved_at
        -- would otherwise silently downgrade the confirmation that triggered
        -- the re-run back to SUGGESTED and erase the operator attribution.
        party_id = case when public.whatsapp_case_identities.resolution_status = 'CONFIRMED'
                        then public.whatsapp_case_identities.party_id else excluded.party_id end,
        display_label = case when public.whatsapp_case_identities.resolution_status = 'CONFIRMED'
                        then public.whatsapp_case_identities.display_label else excluded.display_label end,
        -- MC#629 fix (CodeRabbit follow-up): whatsapp_confirm_case_identity
        -- stores the confirmed company's own phone on this identity; this
        -- re-evaluation instead supplies the submitting sender's phone, so
        -- the same CONFIRMED guard applies here too -- otherwise the
        -- confirmed company phone would be silently replaced.
        phone_e164 = case when public.whatsapp_case_identities.resolution_status = 'CONFIRMED'
                        then public.whatsapp_case_identities.phone_e164 else excluded.phone_e164 end,
        resolution_status = case when public.whatsapp_case_identities.resolution_status = 'CONFIRMED'
                        then 'CONFIRMED' else excluded.resolution_status end,
        confidence = 1.0,
        resolved_by = coalesce(
          case when public.whatsapp_case_identities.resolution_status = 'CONFIRMED'
               then public.whatsapp_case_identities.resolved_by end,
          excluded.resolved_by
        ),
        resolved_at = coalesce(
          case when public.whatsapp_case_identities.resolution_status = 'CONFIRMED'
               then public.whatsapp_case_identities.resolved_at end,
          excluded.resolved_at
        ),
        evidence = public.whatsapp_case_identities.evidence || excluded.evidence;
    end if;

    -- Policy Check: Frozen company
    if v_customer_rec.is_frozen then
      v_blocking_reasons := array_append(v_blocking_reasons, 'customer_company_credit_frozen');
    end if;
  elsif v_customer_rec.resolution_status = 'AMBIGUOUS' then
    v_blocking_reasons := array_append(v_blocking_reasons, 'ambiguous_customer_match');
    if v_po.id is not null and v_primary_msg_id is not null then
      perform public.record_whatsapp_order_field_evidence(
        v_po.id, 'client_identity', v_primary_msg_id,
        'core-a:customer:' || p_interpretation_id::text,
        null, 'ambiguous', 0.5, null,
        jsonb_build_object('details', v_customer_rec.details), true
      );
    end if;
  else
    v_blocking_reasons := array_append(v_blocking_reasons, 'unresolved_customer');
    if v_po.id is not null and v_primary_msg_id is not null then
      perform public.record_whatsapp_order_field_evidence(
        v_po.id, 'client_identity', v_primary_msg_id,
        'core-a:customer:' || p_interpretation_id::text,
        null, 'unresolved', 0.0, null,
        jsonb_build_object('details', v_customer_rec.details), true
      );
    end if;
  end if;

  -- 3. Branch Validation (Deterministic)
  if v_customer_rec.company_id is not null then
    select * into v_branch_rec
    from public.whatsapp_resolve_governed_branch(
      v_customer_rec.company_id,
      case
        when jsonb_typeof(v_conclusion->'branch') = 'object' then v_conclusion->'branch'
        when jsonb_typeof(v_conclusion->'delivery_address') = 'object' then v_conclusion->'delivery_address'
        else '{}'::jsonb
      end
    );

    v_branch_status := coalesce(v_branch_rec.resolution_status, 'UNRESOLVED');

    if v_branch_rec.resolution_status = 'RESOLVED' then
      v_governed_facts := v_governed_facts || jsonb_build_object(
        'branch', jsonb_build_object(
          'delivery_address_id', v_branch_rec.delivery_address_id,
          'label', v_branch_rec.label,
          'street_address', v_branch_rec.street_address,
          'city', v_branch_rec.city,
          'pincode', v_branch_rec.pincode,
          'match_method', v_branch_rec.match_method
        )
      );
      v_decision_reasons := array_append(v_decision_reasons, 'branch_resolved:' || v_branch_rec.match_method);

      if v_po.id is not null and v_primary_msg_id is not null then
        perform public.record_whatsapp_order_field_evidence(
          v_po.id, 'delivery_address', v_primary_msg_id,
          'core-a:branch:' || p_interpretation_id::text,
          jsonb_build_object(
            'delivery_address_id', v_branch_rec.delivery_address_id,
            'label', v_branch_rec.label,
            'city', v_branch_rec.city,
            'pincode', v_branch_rec.pincode
          ),
          'resolved', 1.0, v_branch_rec.label,
          jsonb_build_object('match_method', v_branch_rec.match_method), true
        );
      end if;
    elsif v_branch_rec.resolution_status = 'AMBIGUOUS' then
      v_blocking_reasons := array_append(v_blocking_reasons, 'ambiguous_branch_match');
      if v_po.id is not null and v_primary_msg_id is not null then
        perform public.record_whatsapp_order_field_evidence(
          v_po.id, 'delivery_address', v_primary_msg_id,
          'core-a:branch:' || p_interpretation_id::text,
          null, 'ambiguous', 0.5, null,
          jsonb_build_object('details', v_branch_rec.details), true
        );
      end if;
    else
      -- MC#631: missing delivery branch blocks dispatch/billing gates, not SO capture.
      v_governed_facts := v_governed_facts || jsonb_build_object('pending_holds', coalesce(v_governed_facts->'pending_holds', '[]'::jsonb) || jsonb_build_array('DELIVERY_DETAILS_PENDING'));
      if v_po.id is not null and v_primary_msg_id is not null then
        perform public.record_whatsapp_order_field_evidence(
          v_po.id, 'delivery_address', v_primary_msg_id,
          'core-a:branch:' || p_interpretation_id::text,
          null, 'unresolved', 0.0, null,
          jsonb_build_object('details', v_branch_rec.details), true
        );
      end if;
    end if;
  else
    v_branch_status := 'UNRESOLVED';
    v_blocking_reasons := array_append(v_blocking_reasons, 'branch_requires_customer');
  end if;

  -- 4. Order Lines Validation (Exact SKU, explicit quantity, governed UOM/pack, MOQ)
  v_lines := case
    when jsonb_typeof(v_conclusion->'order_lines') = 'array' then v_conclusion->'order_lines'
    else '[]'::jsonb
  end;

  if jsonb_array_length(v_lines) = 0 and v_intent in ('ORDER', 'NEW_ORDER') then
    v_all_lines_resolved := false;
    v_blocking_reasons := array_append(v_blocking_reasons, 'no_order_lines_extracted');
  end if;

  for v_line, v_line_idx in
    select value, ordinality::integer from jsonb_array_elements(v_lines) with ordinality
  loop
    select * into v_line_rec
    from public.whatsapp_resolve_governed_product_line(
      v_line,
      v_ai.knowledge_snapshot_id,
      v_customer_rec.company_id,
      p_packet_id
    );

    if v_line_rec.resolution_status = 'RESOLVED' then
      v_governed_lines := v_governed_lines || jsonb_build_array(jsonb_build_object(
        'line_number', v_line_idx,
        'product_id', v_line_rec.product_id,
        'sku', v_line_rec.sku,
        'product_name', v_line_rec.product_name,
        'quantity', v_line_rec.quantity,
        'uom', v_line_rec.uom,
        'pack_size', v_line_rec.pack_size,
        'moq', v_line_rec.moq,
        'moq_satisfied', v_line_rec.moq_satisfied,
        'match_method', v_line_rec.match_method
      ));
    else
      -- Governed MOQ-only policy constraints keep commercial facts explicit while routing
      -- to POLICY_APPROVAL_REQUIRED. All other non-RESOLVED lines fail closed.
      v_is_moq_policy_only := (
        not coalesce(v_line_rec.moq_satisfied, true)
        and coalesce(cardinality(v_line_rec.unresolved_reasons), 0) > 0
        and not exists (
          select 1
            from unnest(v_line_rec.unresolved_reasons) r
           where r not in (
             'below_moq_carton_constraint',
             'violates_canonical_b2b_moq_or_increment_or_carton'
           )
        )
      );

      if not v_is_moq_policy_only then
        v_all_lines_resolved := false;
        v_blocking_reasons := array_append(v_blocking_reasons, 'unresolved_line_' || v_line_idx::text);
      end if;

      if not coalesce(v_line_rec.moq_satisfied, true)
         or 'below_moq_carton_constraint' = any(v_line_rec.unresolved_reasons)
         or 'violates_canonical_b2b_moq_or_increment_or_carton' = any(v_line_rec.unresolved_reasons) then
        v_any_below_moq := true;
        v_blocking_reasons := array_append(v_blocking_reasons, 'below_moq_line_' || v_line_idx::text);
      end if;

      if 'missing_quantity' = any(v_line_rec.unresolved_reasons)
         or 'quantity_not_evidence_proven' = any(v_line_rec.unresolved_reasons)
         or 'quantity_mismatch_with_evidence' = any(v_line_rec.unresolved_reasons) then
        v_any_missing_qty := true;
        v_blocking_reasons := array_append(v_blocking_reasons, 'missing_explicit_quantity_line_' || v_line_idx::text);
      end if;
      if exists (select 1 from unnest(v_line_rec.unresolved_reasons) r where r like '%ambiguous%') then
        v_any_ambiguous_sku := true;
        v_blocking_reasons := array_append(v_blocking_reasons, 'ambiguous_product_line_' || v_line_idx::text);
      end if;
      if 'unresolved_product' = any(v_line_rec.unresolved_reasons) then
        v_blocking_reasons := array_append(v_blocking_reasons, 'unresolved_product_line_' || v_line_idx::text);
      end if;
      if 'unresolved_unit' = any(v_line_rec.unresolved_reasons) or 'invalid_or_ambiguous_uom' = any(v_line_rec.unresolved_reasons) then
        v_any_ambiguous_uom := true;
        v_blocking_reasons := array_append(v_blocking_reasons, 'unresolved_unit_line_' || v_line_idx::text);
      end if;
      if 'missing_approved_b2b_product_authority' = any(v_line_rec.unresolved_reasons) or 'product_not_available_for_buyer' = any(v_line_rec.unresolved_reasons) then
        v_blocking_reasons := array_append(v_blocking_reasons, 'missing_b2b_product_authority_line_' || v_line_idx::text);
      end if;
    end if;
  end loop;

  v_governed_facts := v_governed_facts || jsonb_build_object('order_lines', v_governed_lines);

  -- Materialise field evidence to WA-3 for product, quantity, unit_packaging, moq_carton (ONLY FOR COMMERCIAL ORDERS)
  if v_intent in ('ORDER', 'NEW_ORDER') and v_po.id is not null and v_primary_msg_id is not null then
    -- Product dimension
    if v_all_lines_resolved and jsonb_array_length(v_governed_lines) > 0 then
      perform public.record_whatsapp_order_field_evidence(
        v_po.id, 'product', v_primary_msg_id,
        'core-a:product:' || p_interpretation_id::text,
        v_governed_lines, 'resolved', 1.0, null,
        jsonb_build_object('line_count', jsonb_array_length(v_governed_lines), 'governed_materialisation', 'true'), true
      );
    elsif v_any_ambiguous_sku then
      perform public.record_whatsapp_order_field_evidence(
        v_po.id, 'product', v_primary_msg_id,
        'core-a:product:' || p_interpretation_id::text,
        null, 'ambiguous', 0.5, null,
        jsonb_build_object('raw_lines', v_lines), true
      );
    else
      perform public.record_whatsapp_order_field_evidence(
        v_po.id, 'product', v_primary_msg_id,
        'core-a:product:' || p_interpretation_id::text,
        null, 'unresolved', 0.0, null,
        jsonb_build_object('raw_lines', v_lines), true
      );
    end if;

    -- Quantity dimension (Strict: NEVER default to 1)
    if not v_any_missing_qty and v_all_lines_resolved and jsonb_array_length(v_governed_lines) > 0 then
      perform public.record_whatsapp_order_field_evidence(
        v_po.id, 'quantity', v_primary_msg_id,
        'core-a:quantity:' || p_interpretation_id::text,
        (select jsonb_agg(l->'quantity') from jsonb_array_elements(v_governed_lines) l),
        'resolved', 1.0, null, jsonb_build_object('governed_materialisation', 'true'), true
      );
    else
      perform public.record_whatsapp_order_field_evidence(
        v_po.id, 'quantity', v_primary_msg_id,
        'core-a:quantity:' || p_interpretation_id::text,
        null, 'unresolved', 0.0, null, '{}'::jsonb, true
      );
    end if;

    -- Unit Packaging dimension
    if not v_any_ambiguous_uom and v_all_lines_resolved and jsonb_array_length(v_governed_lines) > 0 then
      perform public.record_whatsapp_order_field_evidence(
        v_po.id, 'unit_packaging', v_primary_msg_id,
        'core-a:unit:' || p_interpretation_id::text,
        (select jsonb_agg(l->'uom') from jsonb_array_elements(v_governed_lines) l),
        'resolved', 1.0, null, jsonb_build_object('governed_materialisation', 'true'), true
      );
    elsif v_any_ambiguous_uom then
      perform public.record_whatsapp_order_field_evidence(
        v_po.id, 'unit_packaging', v_primary_msg_id,
        'core-a:unit:' || p_interpretation_id::text,
        null, 'ambiguous', 0.5, null, '{}'::jsonb, true
      );
    else
      perform public.record_whatsapp_order_field_evidence(
        v_po.id, 'unit_packaging', v_primary_msg_id,
        'core-a:unit:' || p_interpretation_id::text,
        null, 'unresolved', 0.0, null, '{}'::jsonb, true
      );
    end if;

    -- MOQ / Carton dimension
    if not v_any_below_moq and v_all_lines_resolved and jsonb_array_length(v_governed_lines) > 0 then
      perform public.record_whatsapp_order_field_evidence(
        v_po.id, 'moq_carton', v_primary_msg_id,
        'core-a:moq:' || p_interpretation_id::text,
        jsonb_build_object('moq_satisfied', true),
        'resolved', 1.0, null, jsonb_build_object('governed_materialisation', 'true'), true
      );
    elsif v_any_below_moq and not v_any_missing_qty and not v_any_ambiguous_sku and not v_any_ambiguous_uom then
      -- Explicit quantity below MOQ is a clear policy constraint, resolved as below_moq for policy approval
      perform public.record_whatsapp_order_field_evidence(
        v_po.id, 'moq_carton', v_primary_msg_id,
        'core-a:moq:' || p_interpretation_id::text,
        jsonb_build_object('moq_satisfied', false, 'below_moq', true),
        'resolved', 1.0, null, jsonb_build_object('governed_materialisation', 'true'), true
      );
    else
      perform public.record_whatsapp_order_field_evidence(
        v_po.id, 'moq_carton', v_primary_msg_id,
        'core-a:moq:' || p_interpretation_id::text,
        null, case when v_any_below_moq then 'ambiguous' else 'unresolved' end,
        0.5, null, jsonb_build_object('below_moq', v_any_below_moq), true
      );
    end if;

    -- Payment terms dimension
    if v_customer_rec.company_id is not null and v_customer_rec.payment_terms is not null then
      perform public.record_whatsapp_order_field_evidence(
        v_po.id, 'payment_terms', v_primary_msg_id,
        'core-a:payment:' || p_interpretation_id::text,
        jsonb_build_object('payment_terms', v_customer_rec.payment_terms),
        'resolved', 1.0, v_customer_rec.payment_terms,
        jsonb_build_object('governed_materialisation', 'true'), true
      );
    else
      perform public.record_whatsapp_order_field_evidence(
        v_po.id, 'payment_terms', v_primary_msg_id,
        'core-a:payment:' || p_interpretation_id::text,
        null, 'unresolved', 0.0, null, '{}'::jsonb, true
      );
    end if;
  end if;

  -- 5. Evaluate WA-3 Readiness (ONLY FOR COMMERCIAL ORDERS)
  if v_intent in ('ORDER', 'NEW_ORDER') and v_po.id is not null then
    v_readiness := public.evaluate_whatsapp_order_so_recordable_readiness(v_po.id);
    v_is_ready := coalesce((v_readiness->>'ready')::boolean, false);
  else
    v_readiness := jsonb_build_object('ready', false, 'blocking_fields', to_jsonb(v_blocking_reasons));
    v_is_ready := false;
  end if;

  -- 6. Canonical Autonomy Outcome Derivation
  if v_outcome is null then
    if v_customer_rec.is_frozen or (v_any_below_moq and v_intent in ('ORDER', 'NEW_ORDER') and v_all_lines_resolved and not v_any_missing_qty and not v_any_ambiguous_sku and not v_any_ambiguous_uom) then
      v_outcome := 'POLICY_APPROVAL_REQUIRED';
      v_decision_reasons := array_append(v_decision_reasons, 'policy_constraint_violated');
    elsif v_is_ready
          and v_intent in ('ORDER', 'NEW_ORDER')
          and v_customer_rec.resolution_status = 'RESOLVED'
          and v_all_lines_resolved
          and not v_any_missing_qty
          and not v_any_ambiguous_sku
          and not v_any_ambiguous_uom
          and cardinality(v_blocking_reasons) = 0 then
      v_outcome := 'AUTO_ELIGIBLE';
      v_decision_reasons := array_append(v_decision_reasons, 'so_recordable_facts_deterministically_resolved');
    elsif v_customer_rec.resolution_status = 'AMBIGUOUS'
          or exists (select 1 from unnest(v_blocking_reasons) r where r like '%cross_customer%' or r like '%conflict%') then
      v_outcome := 'HUMAN_EXCEPTION_REQUIRED';
      v_decision_reasons := array_append(v_decision_reasons, 'commercial_ambiguity_fails_closed');
    elsif v_confidence < 0.50 then
      v_outcome := 'FAILED_INTERPRETATION';
      v_decision_reasons := array_append(v_decision_reasons, 'low_confidence_interpretation');
    else
      v_outcome := 'CLARIFICATION_REQUIRED';
      v_decision_reasons := array_append(v_decision_reasons, 'missing_or_unresolved_facts_require_clarification');
    end if;
  end if;

  -- 7. Persist Autonomy Decision in whatsapp_order_autonomy_decisions (IMMUTABLE PATTERN)
  insert into public.whatsapp_order_autonomy_decisions(
    potential_order_id, case_id, packet_id, interpretation_id,
    autonomy_outcome, decision_reasons, blocking_reasons,
    governed_facts, readiness_snapshot, knowledge_snapshot_id,
    knowledge_snapshot_schema_version, resolver_rule_version
  ) values (
    v_po.id, v_case.id, p_packet_id, p_interpretation_id,
    v_outcome, v_decision_reasons, v_blocking_reasons,
    v_governed_facts, v_readiness, v_ai.knowledge_snapshot_id,
    v_ai.knowledge_snapshot_schema_version, 'core-a-autonomy/v1'
  )
  on conflict (packet_id, interpretation_id) do nothing
  returning * into v_decision;

  if v_decision.id is null then
    select * into v_decision
    from public.whatsapp_order_autonomy_decisions
    where packet_id = p_packet_id and interpretation_id = p_interpretation_id;
  end if;

  -- 8. Apply state transitions to Case and Potential Order
  if v_case.id is not null then
    if v_outcome = 'AUTO_ELIGIBLE' then
      update public.whatsapp_communication_cases
      set status = 'READY_FOR_DRAFT',
          next_action = 'CREATE_SALES_ORDER_DRAFT',
          company_id = coalesce(v_customer_rec.company_id, company_id),
          updated_at = statement_timestamp()
      where id = v_case.id returning * into v_case;
    elsif v_outcome = 'CLARIFICATION_REQUIRED' then
      update public.whatsapp_communication_cases
      set status = 'AWAITING_CUSTOMER',
          next_action = 'AWAIT_CUSTOMER_CLARIFICATION',
          company_id = coalesce(v_customer_rec.company_id, company_id),
          updated_at = statement_timestamp()
      where id = v_case.id returning * into v_case;
    elsif v_outcome = 'POLICY_APPROVAL_REQUIRED' then
      update public.whatsapp_communication_cases
      set status = case when v_customer_rec.resolution_status = 'RESOLVED' and status = 'NEEDS_IDENTITY' then 'OPEN' else status end,
          next_action = 'POLICY_APPROVAL_REQUIRED',
          company_id = coalesce(v_customer_rec.company_id, company_id),
          updated_at = statement_timestamp()
      where id = v_case.id returning * into v_case;
    elsif v_outcome = 'HUMAN_EXCEPTION_REQUIRED' then
      update public.whatsapp_communication_cases
      set next_action = 'HUMAN_EXCEPTION_TRIAGE',
          updated_at = statement_timestamp()
      where id = v_case.id returning * into v_case;
    elsif v_outcome = 'FAILED_INTERPRETATION' then
      update public.whatsapp_communication_cases
      set next_action = 'HUMAN_INTERPRETATION',
          updated_at = statement_timestamp()
      where id = v_case.id returning * into v_case;
    end if;

    v_event_key := 'autonomy-decision:' || p_interpretation_id::text;
    insert into public.whatsapp_case_events(
      case_id, event_type, actor_id, actor_type, correlation_key,
      resulting_state, metadata
    ) values (
      v_case.id, 'AUTONOMY_EVALUATED', null, 'SYSTEM', v_event_key,
      jsonb_build_object(
        'autonomy_outcome', v_outcome,
        'case_status', v_case.status,
        'case_type', v_case.case_type,
        'human_decision_required', (v_outcome not in ('AUTO_ELIGIBLE', 'CLARIFICATION_REQUIRED'))
      ),
      jsonb_build_object(
        'decision_id', v_decision.id,
        'decision_reasons', to_jsonb(v_decision_reasons),
        'blocking_reasons', to_jsonb(v_blocking_reasons),
        'governed_facts', v_governed_facts,
        'readiness', v_readiness
      )
    )
    on conflict (case_id, correlation_key) do nothing;
  end if;

  if v_po.id is not null then
    perform set_config('app.wa1_governed_mutation', 'on', true);
    if v_outcome = 'AUTO_ELIGIBLE' then
      update public.whatsapp_potential_orders
      set next_action = 'AUTO_CONVERT_DRAFT',
          updated_at = statement_timestamp()
      where id = v_po.id;
    elsif v_outcome = 'CLARIFICATION_REQUIRED' then
      update public.whatsapp_potential_orders
      set state = 'AWAITING_CLARIFICATION',
          next_action = 'AWAIT_CUSTOMER_CLARIFICATION',
          updated_at = statement_timestamp()
      where id = v_po.id;
    elsif v_outcome = 'FAILED_INTERPRETATION' then
      update public.whatsapp_potential_orders
      set state = 'FAILED_INTERPRETATION',
          queue = 'WA_FAILED_INTERPRETATION',
          next_action = 'HUMAN_INTERPRETATION',
          updated_at = statement_timestamp()
      where id = v_po.id;
    end if;
    perform set_config('app.wa1_governed_mutation', 'off', true);
  end if;

  return jsonb_build_object(
    'decision_id', v_decision.id,
    'autonomy_outcome', v_outcome,
    'case_id', v_case.id,
    'potential_order_id', v_po.id,
    'packet_id', p_packet_id,
    'interpretation_id', p_interpretation_id,
    'decision_reasons', to_jsonb(v_decision_reasons),
    'blocking_reasons', to_jsonb(v_blocking_reasons),
    'governed_facts', v_governed_facts,
    'readiness', v_readiness,
    'human_decision_required', (v_outcome not in ('AUTO_ELIGIBLE', 'CLARIFICATION_REQUIRED')),
    'idempotent_replay', false
  );
exception when others then
  perform set_config('app.wa1_governed_mutation', 'off', true);
  perform set_config('app.wa3_governed_mutation', 'off', true);
  raise;
end;
$function$;

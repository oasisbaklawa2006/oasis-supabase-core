-- Stage-1B: map advisory UNCLEAR interpretations with clarification signals to CLARIFICATION_REQUIRED.

create or replace function public.whatsapp_evaluate_and_materialize_order_autonomy(
  p_packet_id uuid,
  p_interpretation_id uuid,
  p_job_id uuid default null,
  p_lease_token uuid default null,
  p_packet_revision bigint default null
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public, auth
as $$
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
    v_potential_order_id := public.whatsapp_case_potential_order_id(v_case.id);
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
  select * into v_customer_rec
  from public.whatsapp_resolve_governed_customer(
    v_packet.contact_id,
    case when jsonb_typeof(v_conclusion->'customer') = 'object' then v_conclusion->'customer' else '{}'::jsonb end
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
        party_id = excluded.party_id,
        display_label = excluded.display_label,
        phone_e164 = excluded.phone_e164,
        resolution_status = excluded.resolution_status,
        confidence = 1.0,
        resolved_by = excluded.resolved_by,
        resolved_at = excluded.resolved_at,
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
      v_blocking_reasons := array_append(v_blocking_reasons, 'unresolved_branch');
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
    v_readiness := public.evaluate_whatsapp_order_readiness(v_po.id);
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
          and v_branch_status = 'RESOLVED'
          and v_all_lines_resolved
          and not v_any_missing_qty
          and not v_any_ambiguous_sku
          and not v_any_ambiguous_uom
          and cardinality(v_blocking_reasons) = 0 then
      v_outcome := 'AUTO_ELIGIBLE';
      v_decision_reasons := array_append(v_decision_reasons, 'all_commercial_facts_deterministically_resolved');
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
$$;

revoke all on function public.whatsapp_evaluate_and_materialize_order_autonomy(uuid, uuid, uuid, uuid, bigint)
  from public, anon, authenticated;
grant execute on function public.whatsapp_evaluate_and_materialize_order_autonomy(uuid, uuid, uuid, uuid, bigint)
  to service_role;

comment on function public.whatsapp_evaluate_and_materialize_order_autonomy(uuid, uuid, uuid, uuid, bigint) is
  'CORE-A canonical autonomy evaluator and governed field materialiser. Validates customer, branch, products, explicit quantities, and UOM against master data, deriving one of the 5 canonical autonomy outcomes.';

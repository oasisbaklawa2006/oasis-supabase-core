-- WA450-D4: order interpretation safety (corrections, duplicates, ambiguous quantities).
--
-- Defect: whatsapp_resolve_governed_product_line proves an AI-extracted quantity only by
-- checking that the number occurs in a cited message. A negated or superseded number
-- ("10 mix nahi 12 mix" with the model returning 10), the same SKU listed twice, or a
-- correction the model did not record all still reached AUTO_ELIGIBLE and created a
-- draft. This migration adds a deterministic, fail-closed pre-check in front of the
-- autonomy evaluator. Anything it cannot reconcile is routed to a human with an
-- ORDER_CORRECTION_AMBIGUITY_ROUTED event instead of a commercial action. It never
-- changes a quantity itself and never replaces the evaluator: clear orders flow exactly
-- as before.

create or replace function public.whatsapp_d4_order_ambiguity_v1(
  p_packet_id uuid,
  p_conclusion jsonb
) returns jsonb
language plpgsql
stable
security definer
set search_path = pg_catalog, public
as $fn$
declare
  c_unit constant text := '(?:box(?:es)?|mix|kgs?|pcs?|pieces?|cartons?|trays?|packs?|packets?|dabba|dibba)';
  c_qty constant text := '(\d+(?:\.\d+)?)\s*' || c_unit || '\M';
  v_reasons text[] := '{}';
  v_lines jsonb;
  v_corrections jsonb;
  v_text text;
  v_line_count int;
  v_distinct_skus int;
  v_mentions numeric[];
  v_last numeric;
  v_line_qty numeric;
  v_repl numeric;
  v_sup numeric;
  v_correction jsonb;
  v_recorded_ok boolean := false;
  v_line jsonb;
  v_q numeric;
  v_sku text;
  v_distinct_qty int;
  v_fwd_all boolean;
  v_rev_all boolean;
begin
  v_lines := case when jsonb_typeof(p_conclusion -> 'order_lines') = 'array'
    then p_conclusion -> 'order_lines' else '[]'::jsonb end;
  v_corrections := case when jsonb_typeof(p_conclusion -> 'corrections') = 'array'
    then p_conclusion -> 'corrections' else '[]'::jsonb end;
  v_line_count := jsonb_array_length(v_lines);
  if v_line_count = 0 then
    return jsonb_build_object('ambiguous', false, 'reasons', '[]'::jsonb);
  end if;

  select count(distinct lower(coalesce(nullif(btrim(l ->> 'sku'), ''), btrim(l ->> 'product_name'), '')))
    into v_distinct_skus
  from jsonb_array_elements(v_lines) l;

  -- R1: the same product listed more than once is never merged or summed automatically.
  if v_distinct_skus < v_line_count then
    v_reasons := array_append(v_reasons, 'duplicate_product_lines'::text);
  end if;

  select string_agg(wm.content, E'\n' order by wm.packet_sequence nulls last,
                    coalesce(wm.message_timestamp, wm.created_at), wm.created_at, wm.id)
    into v_text
  from public.whatsapp_messages wm
  where wm.packet_id = p_packet_id and lower(wm.direction) = 'inbound';
  v_text := coalesce(v_text, '');

  select array_agg(m[1]::numeric order by o)
    into v_mentions
  from regexp_matches(v_text, c_qty, 'gi') with ordinality as t(m, o);
  v_mentions := coalesce(v_mentions, '{}');

  if v_line_count = 1 and v_distinct_skus = 1 then
    -- A present but non-numeric quantity is never cast (that would raise before routing);
    -- it is itself an unreconciled quantity and goes to a human.
    v_line_qty := case
      when coalesce(v_lines -> 0 ->> 'quantity', '') ~ '^\s*\d+(\.\d+)?\s*$'
        then (v_lines -> 0 ->> 'quantity')::numeric
      else null
    end;
    if nullif(btrim(v_lines -> 0 ->> 'quantity'), '') is not null and v_line_qty is null then
      v_reasons := array_append(v_reasons, 'unreconciled_quantity_mentions'::text);
    end if;

    -- R2: a recorded correction must agree with the quantity the model chose.
    if jsonb_array_length(v_corrections) > 0 and v_line_qty is not null then
      for v_correction in select * from jsonb_array_elements(v_corrections) loop
        v_repl := substring(coalesce(v_correction ->> 'replacement', '') from '(\d+(?:\.\d+)?)')::numeric;
        v_sup := substring(coalesce(v_correction ->> 'supersedes', '') from '(\d+(?:\.\d+)?)')::numeric;
        if v_repl is not null and v_repl <> v_line_qty then
          v_reasons := array_append(v_reasons, 'quantity_conflicts_with_recorded_correction'::text);
        elsif v_repl is not null and v_repl = v_line_qty and v_sup is distinct from v_line_qty then
          v_recorded_ok := true;
        end if;
      end loop;
    end if;

    -- R3: more quantity mentions than lines means the customer changed or repeated a
    -- number. It is only reconciled when the correction is recorded, or the text itself
    -- negates the earlier value and the chosen quantity is the last one stated.
    if coalesce(array_length(v_mentions, 1), 0) > 1
       and not 'quantity_conflicts_with_recorded_correction' = any (v_reasons) then
      v_last := v_mentions[array_length(v_mentions, 1)];
      if not v_recorded_ok then
        if v_line_qty is null or v_last is distinct from v_line_qty
           -- Only the Hinglish replacement markers count. English "no"/"not" negate the number
           -- that follows them ("send 10 box, not 12 box"), so they must never reconcile it.
           or v_text !~* ('\m(?:nahi|nahin)\M\W*' || regexp_replace(trim_scale(v_line_qty)::text, '\.', '\\.', 'g') || '\s*' || c_unit || '\M') then
          v_reasons := array_append(v_reasons, 'unreconciled_quantity_mentions'::text);
        end if;
      end if;
    end if;
  elsif coalesce(array_length(v_mentions, 1), 0) > v_line_count then
    -- R4: several lines with surplus quantity mentions cannot be attributed deterministically.
    v_reasons := array_append(v_reasons, 'unreconciled_quantity_mentions'::text);
  elsif v_line_count > 1 and v_distinct_skus = v_line_count then
    -- R5: when the lines carry different quantities, a swap between products must be
    -- impossible. Each line's quantity has to sit next to its own product code in the text;
    -- otherwise it cannot be attributed deterministically and a human decides. Lines that all
    -- carry the same quantity cannot be swapped and are not affected.
    select count(distinct case when (l ->> 'quantity') ~ '^\s*\d+(\.\d+)?\s*$'
                               then trim_scale((l ->> 'quantity')::numeric)::text
                               else 'invalid:' || coalesce(l ->> 'quantity', '') end)
      into v_distinct_qty
    from jsonb_array_elements(v_lines) l;
    if v_distinct_qty > 1 then
      -- Every line must be attributed in the SAME orientation ("CODE 10 box" for all, or
      -- "10 box CODE" for all). Mixing orientations lets one quantity mention be read as
      -- belonging to two products, so a mixed or partial match is routed to a human.
      v_fwd_all := true;
      v_rev_all := true;
      for v_line in select * from jsonb_array_elements(v_lines) loop
        v_sku := btrim(coalesce(v_line ->> 'sku', ''));
        v_q := case when (v_line ->> 'quantity') ~ '^\s*\d+(\.\d+)?\s*$'
                    then (v_line ->> 'quantity')::numeric end;
        if v_sku = '' or v_q is null then
          v_fwd_all := false;
          v_rev_all := false;
          exit;
        end if;
        v_fwd_all := v_fwd_all and v_text ~* ('\m' || regexp_replace(v_sku, '([.\\+*?\[\](){}|^$])', '\\\1', 'g')
                        || '\W{0,8}' || regexp_replace(trim_scale(v_q)::text, '\.', '\\.', 'g') || '\s*' || c_unit || '\M');
        v_rev_all := v_rev_all and v_text ~* ('\m' || regexp_replace(trim_scale(v_q)::text, '\.', '\\.', 'g') || '\s*' || c_unit
                        || '\W{0,8}' || regexp_replace(v_sku, '([.\\+*?\[\](){}|^$])', '\\\1', 'g') || '\M');
      end loop;
      if not (v_fwd_all or v_rev_all) then
        v_reasons := array_append(v_reasons, 'unattributed_multi_line_quantities'::text);
      end if;
    end if;
  end if;

  return jsonb_build_object(
    'ambiguous', coalesce(array_length(v_reasons, 1), 0) > 0,
    'reasons', to_jsonb(v_reasons),
    'quantity_mentions', to_jsonb(v_mentions)
  );
end;
$fn$;

revoke all on function public.whatsapp_d4_order_ambiguity_v1(uuid, jsonb) from public, anon, authenticated;
grant execute on function public.whatsapp_d4_order_ambiguity_v1(uuid, jsonb) to service_role;

-- Materializer: live definition plus the D4 guard immediately before the autonomy evaluator.
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
  v_d4 jsonb := '{"ambiguous": false}'::jsonb;
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
  if v_intent in ('ORDER', 'NEW_ORDER') then
    v_d4 := public.whatsapp_d4_order_ambiguity_v1(p_packet_id, v_conclusion);
  end if;

  if coalesce((v_d4 ->> 'ambiguous')::boolean, false)
     and not coalesce((v_correction_guard ->> 'blocked')::boolean, false) then
    -- WA450-D4: uncertain quantity/correction intent never reaches the autonomy pipeline.
    insert into public.whatsapp_case_events(
      case_id, event_type, actor_type, correlation_key, metadata
    ) values (
      v_case.id, 'ORDER_CORRECTION_AMBIGUITY_ROUTED', 'SYSTEM',
      'wa450-d4-order-ambiguity:' || p_interpretation_id::text,
      jsonb_build_object('packet_id', p_packet_id, 'interpretation_id', p_interpretation_id,
                         'ambiguity', v_d4)
    )
    on conflict (case_id, correlation_key) do nothing;
  elsif coalesce((v_correction_guard ->> 'blocked')::boolean, false) then
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
    'order_ambiguity_guard', case when coalesce((v_d4 ->> 'ambiguous')::boolean, false) then v_d4 else null end,
    'ai_event_correlation_key', v_event_key,
    'human_decision_required', v_human_decision_required,
    'idempotent_replay', coalesce((v_autonomy->>'idempotent_replay')::boolean, false)
  );
end;
$function$;

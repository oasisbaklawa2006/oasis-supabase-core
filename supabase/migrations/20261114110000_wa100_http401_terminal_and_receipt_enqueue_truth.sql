-- WA-100 / #532: outbound authentication rejection must fail closed, and
-- queue insertion must not masquerade as provider send/delivery evidence.
--
-- Forward-only function-body updates. Existing data and immutable audit events
-- are intentionally preserved. Historical AUTONOMOUS_NON_ORDER_RECEIPT_SENT
-- entries describe legacy enqueue operations, not proven delivery.
--
-- Source derived from the *latest* tracked definitions in:
--  20260919130000_whatsapp_operator_reply_quarantine_and_consumer_hardening
--  20261024130000_whatsapp_phase2_case_task_dedupe_and_follow_up_receipt
-- No production dispatch, retries, credentials or provider calls in this migration.

create or replace function public.fail_whatsapp_operator_reply(
  p_reply_id uuid,
  p_lease_token uuid,
  p_error_code text,
  p_error_detail text,
  p_acceptance_unknown boolean default false
)
returns public.whatsapp_operator_reply_outbox
language plpgsql
security definer
set search_path = pg_catalog, public, pg_temp
as $$
declare
  v_result public.whatsapp_operator_reply_outbox%rowtype;
begin
  if auth.uid() is not null then
    raise exception 'WA5_SERVICE_ROLE_REQUIRED';
  end if;
  update public.whatsapp_operator_reply_outbox
  set
    status = case
      when p_acceptance_unknown then 'ACCEPTANCE_UNKNOWN'
      when upper(btrim(coalesce(p_error_code, ''))) = 'HTTP_401' then 'FAILED_FINAL'
      when attempt_count < 5 then 'FAILED_RETRYABLE'
      else 'FAILED_FINAL'
    end,
    next_attempt_at = case
      when p_acceptance_unknown then 'infinity'::timestamptz
      when upper(btrim(coalesce(p_error_code, ''))) = 'HTTP_401' then 'infinity'::timestamptz
      when attempt_count >= 5 then 'infinity'::timestamptz
      else statement_timestamp()
        + make_interval(secs => least(3600, 30 * (2 ^ greatest(attempt_count - 1, 0))::integer))
    end,
    lease_token = null,
    lease_expires_at = null,
    last_error_code = btrim(p_error_code),
    last_error_detail = left(p_error_detail, 1000),
    updated_at = statement_timestamp()
  where id = p_reply_id
    and status = 'SENDING'
    and lease_token = p_lease_token
  returning * into v_result;
  if not found then
    raise exception 'WA5_STALE_OR_INVALID_LEASE';
  end if;
  insert into public.whatsapp_operator_reply_events(reply_id, event_type, evidence)
  values (
    v_result.id,
    case when p_acceptance_unknown then 'PROVIDER_ACCEPTANCE_UNKNOWN' else 'SEND_FAILED' end,
    jsonb_build_object(
      'error_code', p_error_code,
      'retryable', v_result.status = 'FAILED_RETRYABLE',
      'message_origin', v_result.message_origin
    )
  );
  return v_result;
end;
$$;

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
  v_receipt_enqueued boolean := false;
  v_receipt_suppressed boolean := false;
  v_inferred text[];
  v_policy text;
  v_follow_up boolean := false;
  v_quantity numeric;
  v_unit text;
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

  -- An owned case keeps its accountable team; only an UNASSIGNED case is (re)routed.
  v_team := case
    when v_case.accountability_status <> 'UNASSIGNED' and nullif(btrim(v_case.accountable_team), '') is not null
      then v_case.accountable_team
    else coalesce(
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
    )
  end;
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

  -- One open accountable-owner task per case and team. A later interpretation of the same case
  -- (a correction, a follow-up message) refreshes the case; it must not stack another identical
  -- task on the queue while one is still live (OPEN, IN_PROGRESS or BLOCKED).
  insert into public.whatsapp_case_department_tasks(
    case_id, department, task_type, instructions, status, due_at, correlation_key, created_by
  )
  select
    p_case_id, v_team, 'ACCOUNTABLE_RESPONSE_OWNER',
    'Governed non-order case requires accountable department action.',
    'OPEN', v_due, 'core-c-non-order:' || p_interpretation_id::text,
    v_principal
  where not exists (
    select 1 from public.whatsapp_case_department_tasks t
    where t.case_id = p_case_id
      and t.department = v_team
      and t.task_type = 'ACCOUNTABLE_RESPONSE_OWNER'
      and t.status in ('OPEN', 'IN_PROGRESS', 'BLOCKED')
  )
  on conflict (case_id, correlation_key) do nothing;

  v_allow_receipt := v_case.case_type in (
    'ENQUIRY', 'COMPLAINT', 'PAYMENT_ADVICE', 'ACCOUNT_QUERY',
    'DISPATCH', 'SPECIFICATION', 'UNCLASSIFIED'
  );

  if v_allow_receipt then
    v_key := 'core-c:non-order-receipt:' || p_interpretation_id::text;

    if exists (
      select 1 from public.whatsapp_case_events
      where case_id = p_case_id and correlation_key = 'core-c-receipt:' || v_key
    ) then
      v_receipt_enqueued := true;
      select * into v_reply
      from public.whatsapp_operator_reply_outbox
      where packet_id = v_case.packet_id and idempotency_key = v_key
      limit 1;
    elsif exists (
      select 1 from public.whatsapp_case_events
      where case_id = p_case_id and correlation_key = 'core-c-receipt-suppressed:' || v_key
    ) then
      v_receipt_suppressed := true;
    else
      v_policy := public.whatsapp_core_c_receipt_policy_v1(v_case.packet_id);

      if v_policy is not null then
        insert into public.whatsapp_case_events(
          case_id, event_type, actor_type, correlation_key, metadata
        ) values (
          p_case_id, 'AUTONOMOUS_NON_ORDER_RECEIPT_SUPPRESSED', 'SYSTEM',
          'core-c-receipt-suppressed:' || v_key,
          jsonb_build_object(
            'interpretation_id', p_interpretation_id,
            'case_type', v_case.case_type,
            'suppression_reason', v_policy
          )
        )
        on conflict (case_id, correlation_key) do nothing;
        v_receipt_suppressed := true;
      else
        select * into v_packet from public.whatsapp_message_packets where id = v_case.packet_id;
        select * into v_contact from public.whatsapp_contacts where id = v_packet.contact_id;
        -- A second acknowledgement on the same packet is a follow-up to a newer customer message:
        -- say that the update was noted (with the customer's corrected quantity when it is a plain
        -- quantity) instead of repeating the identical generic text.
        v_follow_up := public.whatsapp_core_c_has_prior_live_receipt_v1(v_case.packet_id);
        if v_follow_up then
          select (i.interpretation -> 'conclusion' -> 'order_lines' -> 0 ->> 'quantity')::numeric,
                 i.interpretation -> 'conclusion' -> 'order_lines' -> 0 ->> 'unit'
          into v_quantity, v_unit
          from public.whatsapp_packet_ai_interpretations i
          where i.id = p_interpretation_id
            and jsonb_typeof(i.interpretation -> 'conclusion' -> 'corrections') = 'array'
            and jsonb_array_length(i.interpretation -> 'conclusion' -> 'corrections') > 0
            and jsonb_typeof(i.interpretation -> 'conclusion' -> 'order_lines') = 'array'
            and jsonb_array_length(i.interpretation -> 'conclusion' -> 'order_lines') = 1
            and jsonb_typeof(i.interpretation -> 'conclusion' -> 'order_lines' -> 0 -> 'quantity') = 'number'
            -- only a line that is identified, evidenced and not "unclear", and that a correction in
            -- this interpretation cites as evidence, is restated to the customer
            and coalesce(i.interpretation -> 'conclusion' -> 'order_lines' -> 0 ->> 'status', '') in ('explicit', 'interpreted')
            and coalesce(nullif(btrim(i.interpretation -> 'conclusion' -> 'order_lines' -> 0 ->> 'product_name'), ''),
                         nullif(btrim(i.interpretation -> 'conclusion' -> 'order_lines' -> 0 ->> 'sku'), '')) is not null
            and exists (
              select 1
              from jsonb_array_elements(i.interpretation -> 'conclusion' -> 'corrections') as corr(value)
              where jsonb_typeof(i.interpretation -> 'conclusion' -> 'order_lines' -> 0 -> 'evidence_ids') = 'array'
                and jsonb_exists(
                  i.interpretation -> 'conclusion' -> 'order_lines' -> 0 -> 'evidence_ids',
                  corr.value ->> 'provider_message_id'
                )
            );
          v_body := public.whatsapp_core_c_safe_follow_up_receipt(v_team, v_case.id, v_quantity, v_unit);
        else
          v_body := public.whatsapp_core_c_safe_non_order_receipt(v_case.case_type, v_team, v_case.id);
        end if;
        v_inferred := coalesce(public.wa6_infer_commercial_disclosure(v_body), '{}'::text[]);

        if v_inferred = '{}'::text[] then
          v_reply := public.enqueue_governed_whatsapp_autonomous_reply(
            v_case.packet_id, v_contact.id,
            '+' || regexp_replace(v_contact.phone_number, '\D', '', 'g'),
            v_body, v_key, 'NON_ORDER_RECEIPT',
            null, v_case.id, null, '{}'::text[]
          );
          insert into public.whatsapp_case_events(
            case_id, event_type, actor_type, correlation_key, metadata
          ) values (
            p_case_id, 'AUTONOMOUS_NON_ORDER_RECEIPT_QUEUED', 'SYSTEM',
            'core-c-receipt:' || v_key,
            jsonb_build_object(
              'reply_id', v_reply.id,
              'case_type', v_case.case_type,
              'interpretation_id', p_interpretation_id
            )
          )
          on conflict (case_id, correlation_key) do nothing;
          v_receipt_enqueued := true;
        else
          insert into public.whatsapp_case_events(
            case_id, event_type, actor_type, correlation_key, metadata
          ) values (
            p_case_id, 'AUTONOMOUS_NON_ORDER_RECEIPT_SUPPRESSED', 'SYSTEM',
            'core-c-receipt-suppressed:' || v_key,
            jsonb_build_object(
              'interpretation_id', p_interpretation_id,
              'case_type', v_case.case_type,
              'suppression_reason', 'UNSAFE_COMMERCIAL_DISCLOSURE',
              'inferred_disclosure_scope', to_jsonb(v_inferred)
            )
          )
          on conflict (case_id, correlation_key) do nothing;
          v_receipt_suppressed := true;
        end if;
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
    'receipt_enqueued', v_receipt_enqueued,
    'receipt_sent', false,
    'receipt_suppressed', v_receipt_suppressed
  );
end;
$$;

-- Retain the existing privileged RPC boundaries; no browser authority granted.
revoke all on function public.fail_whatsapp_operator_reply(uuid, uuid, text, text, boolean)
  from public, anon, authenticated;
grant execute on function public.fail_whatsapp_operator_reply(uuid, uuid, text, text, boolean)
  to service_role;
revoke all on function public.whatsapp_apply_non_order_case_governance_v1(uuid, uuid, text, text, text, text)
  from public, anon, authenticated;
grant execute on function public.whatsapp_apply_non_order_case_governance_v1(uuid, uuid, text, text, text, text)
  to service_role;

comment on function public.fail_whatsapp_operator_reply(uuid, uuid, text, text, boolean) is
  'WA-100: provider HTTP_401 is terminal with no automatic retry; acceptance-unknown remains quarantined from replay.';
comment on function public.whatsapp_apply_non_order_case_governance_v1(uuid, uuid, text, text, text, text) is
  'WA-100: receipt_enqueued is queue truth; legacy receipt_sent key is always false until external provider evidence, and historical SENT audit events do not prove delivery.';

-- WA PHASE 2 (ASM-06 / Central #638), findings 5 and 6.
--
-- Production evidence (read-only, 2026-10-24, case bf241cb6 for the four-message packet 0455bfc1):
--   * Four interpretations of one case left FOUR identical OPEN ACCOUNTABLE_RESPONSE_OWNER tasks for SALES
--     (task correlation is per interpretation). Across production 133 department tasks exist, all OPEN.
--   * The customer received two identical generic receipts 40 minutes apart; the second followed the
--     message that raised the quantity from 50 to 75 boxes but did not mention the update.
--
-- Changes (function bodies only; signatures, grants and security posture unchanged):
--   1. whatsapp_apply_non_order_case_governance_v1: creates the accountable-owner task only when the case has
--      no live (OPEN, IN_PROGRESS or BLOCKED) task of the same type for the effective team. The existing per-interpretation correlation
--      key and the routing event are kept, so replays stay idempotent.
--   2. Receipt wording: when a live receipt already exists on the packet, the new acknowledgement is a
--      follow-up that says the update was noted. When the interpretation carries a correction and exactly
--      one structured order line, the line's numeric quantity and an allow-listed unit are stated
--      ("now 75 boxes"); free text from the model or the customer is never echoed. The first receipt keeps
--      the existing generic text. The send/suppress policy (6 h staleness, 30 min cooldown,
--      newer-message rule, unsafe-disclosure suppression) is unchanged.
--
-- Not changed: existing tasks, outbox rows, events or interpretations (no data is modified), commercial
-- order authority, staffing/assignment, any customer message already sent.

create or replace function public.whatsapp_core_c_has_prior_live_receipt_v1(p_packet_id uuid)
returns boolean
language sql
stable
set search_path = pg_catalog, public
as $$
  select exists (
    select 1
    from public.whatsapp_operator_reply_outbox o
    where o.packet_id = p_packet_id
      and o.idempotency_key like 'core-c:non-order-receipt:%'
      and o.status in (
        'QUEUED', 'SENDING', 'ACCEPTANCE_UNKNOWN', 'ACCEPTED', 'DELIVERED', 'READ', 'FAILED_RETRYABLE'
      )
  );
$$;

create or replace function public.whatsapp_core_c_safe_follow_up_receipt(
  p_primary_department text,
  p_case_id uuid,
  p_quantity numeric,
  p_unit text
)
returns text
language sql
immutable
set search_path = pg_catalog, public
as $$
  select format(
    'Thank you. We have noted your update%s and added it to case reference %s. Our %s team will review it and respond through this channel.',
    case
      when p_quantity is not null and p_quantity > 0 and p_quantity <= 999999
        and lower(btrim(coalesce(p_unit, ''))) in (
          'boxes', 'box', 'kgs', 'kg', 'cartons', 'carton', 'pieces', 'piece', 'pcs', 'pc', 'packs', 'pack'
        )
        then ' (now ' || trim_scale(p_quantity)::text || ' ' || lower(btrim(p_unit)) || ')'
      else ''
    end,
    left(p_case_id::text, 8),
    coalesce(nullif(upper(btrim(p_primary_department)), ''), 'CUSTOMER_SERVICE')
  );
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
  v_receipt_sent boolean := false;
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
      v_receipt_sent := true;
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
            p_case_id, 'AUTONOMOUS_NON_ORDER_RECEIPT_SENT', 'SYSTEM',
            'core-c-receipt:' || v_key,
            jsonb_build_object(
              'reply_id', v_reply.id,
              'case_type', v_case.case_type,
              'interpretation_id', p_interpretation_id
            )
          )
          on conflict (case_id, correlation_key) do nothing;
          v_receipt_sent := true;
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
    'receipt_sent', v_receipt_sent,
    'receipt_suppressed', v_receipt_suppressed
  );
end;
$$;

revoke all on function public.whatsapp_core_c_has_prior_live_receipt_v1(uuid) from public, anon, authenticated;
revoke all on function public.whatsapp_core_c_safe_follow_up_receipt(text, uuid, numeric, text) from public, anon, authenticated;
grant execute on function public.whatsapp_core_c_has_prior_live_receipt_v1(uuid) to service_role;
grant execute on function public.whatsapp_core_c_safe_follow_up_receipt(text, uuid, numeric, text) to service_role;

revoke all on function public.whatsapp_apply_non_order_case_governance_v1(
  uuid, uuid, text, text, text, text
) from public, anon, authenticated;
grant execute on function public.whatsapp_apply_non_order_case_governance_v1(
  uuid, uuid, text, text, text, text
) to service_role;

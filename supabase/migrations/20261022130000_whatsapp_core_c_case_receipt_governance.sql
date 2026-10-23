-- WA-RELEASE-04: case-level governance for autonomous non-order receipts.
--
-- Production evidence (read-only, 2026-10-22): the idempotency key
-- 'core-c:non-order-receipt:<interpretation_id>' is unique per interpretation, so every additional
-- interpretation of the same communication case may enqueue another autonomous acknowledgement. After the
-- WA-RECOVERY-01 replay, four stale receipts were accepted by the provider on 2026-10-22 for packets whose
-- last inbound message was 1-17 days old (three of them duplicates of an earlier acknowledgement on the
-- same case). Total non-order receipts: 127 (57 ACCEPTED, 70 QUARANTINED, none in flight).
--
-- Policy added to whatsapp_apply_non_order_case_governance_v1():
--   1. STALE_REPLAY: the packet's newest inbound message is older than 6 hours when governance runs, so an
--      acknowledgement would be a late replay, not a timely receipt. The case is still routed to its team.
--   2. CASE_RECEIPT_ALREADY_SENT: a live acknowledgement (not quarantined/cancelled/final-failed) already
--      exists for the case's packet and either it was created in the last 30 minutes or no newer inbound
--      message has arrived since it was created. A genuinely newer customer message outside the cooldown
--      still receives an acknowledgement.
-- A suppression is recorded as AUTONOMOUS_NON_ORDER_RECEIPT_SUPPRESSED with correlation
-- 'core-c-receipt-suppressed:<key>', so a retry or replay of the same interpretation is idempotent. The
-- decision runs while the case row is locked FOR UPDATE, so concurrent calls serialize.
--
-- Also fixed: the function overwrote whatsapp_communication_cases.accountable_team for cases that already
-- have an accountable owner. The team is now changed only while the case is UNASSIGNED; owner, assignment
-- and status are untouched. Department tasks and the routing event use the effective team.
--
-- Not changed: commercial order authority, existing outbox rows (provider ids, events and audit lineage are
-- preserved), the strict unsafe-disclosure suppression, grants. No data is modified by this migration.

create or replace function public.whatsapp_core_c_receipt_staleness_interval()
returns interval
language sql
immutable
set search_path = pg_catalog, public
as $$
  select interval '6 hours';
$$;

create or replace function public.whatsapp_core_c_receipt_cooldown_interval()
returns interval
language sql
immutable
set search_path = pg_catalog, public
as $$
  select interval '30 minutes';
$$;

create or replace function public.whatsapp_core_c_receipt_policy_v1(
  p_packet_id uuid,
  p_now timestamptz default statement_timestamp()
)
returns text
language plpgsql
stable
set search_path = pg_catalog, public
as $$
declare
  v_last_inbound timestamptz;  -- when the customer sent the newest message (provider time, arrival as fallback)
  v_last_arrival timestamptz;  -- when the newest message reached this system
  v_prior_created timestamptz;
begin
  -- The message and packet timestamps are timestamp WITHOUT time zone and are written in UTC; read them
  -- as UTC explicitly so the decision does not depend on the session TimeZone.
  select max(coalesce(m.message_timestamp, m.created_at)) at time zone 'UTC',
         max(m.created_at) at time zone 'UTC'
  into v_last_inbound, v_last_arrival
  from public.whatsapp_messages m
  where m.packet_id = p_packet_id and m.direction = 'inbound';

  if v_last_inbound is null then
    select coalesce(p.last_message_at, p.created_at) at time zone 'UTC' into v_last_inbound
    from public.whatsapp_message_packets p where p.id = p_packet_id;
  end if;

  -- Fail closed: without any arrival time the receipt cannot be shown to be timely.
  if v_last_inbound is null
     or p_now - v_last_inbound > public.whatsapp_core_c_receipt_staleness_interval() then
    return 'STALE_REPLAY';
  end if;

  select max(o.created_at) into v_prior_created
  from public.whatsapp_operator_reply_outbox o
  where o.packet_id = p_packet_id
    and o.idempotency_key like 'core-c:non-order-receipt:%'
    and o.status in (
      'QUEUED', 'SENDING', 'ACCEPTANCE_UNKNOWN', 'ACCEPTED', 'DELIVERED', 'READ', 'FAILED_RETRYABLE'
    );

  if v_prior_created is not null
     and (p_now - v_prior_created <= public.whatsapp_core_c_receipt_cooldown_interval()
          or coalesce(v_last_arrival, v_last_inbound) <= v_prior_created) then
    return 'CASE_RECEIPT_ALREADY_SENT';
  end if;

  return null;
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
  v_receipt_sent boolean := false;
  v_receipt_suppressed boolean := false;
  v_inferred text[];
  v_policy text;
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
        v_body := public.whatsapp_core_c_safe_non_order_receipt(v_case.case_type, v_team, v_case.id);
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

revoke all on function public.whatsapp_core_c_receipt_staleness_interval() from public, anon, authenticated;
revoke all on function public.whatsapp_core_c_receipt_cooldown_interval() from public, anon, authenticated;
revoke all on function public.whatsapp_core_c_receipt_policy_v1(uuid, timestamptz) from public, anon, authenticated;
grant execute on function public.whatsapp_core_c_receipt_staleness_interval() to service_role;
grant execute on function public.whatsapp_core_c_receipt_cooldown_interval() to service_role;
grant execute on function public.whatsapp_core_c_receipt_policy_v1(uuid, timestamptz) to service_role;

revoke all on function public.whatsapp_apply_non_order_case_governance_v1(
  uuid, uuid, text, text, text, text
) from public, anon, authenticated;
grant execute on function public.whatsapp_apply_non_order_case_governance_v1(
  uuid, uuid, text, text, text, text
) to service_role;

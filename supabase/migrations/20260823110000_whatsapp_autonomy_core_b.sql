-- CORE-B: WhatsApp Autonomous Sales Order Draft Creation and Governed SO Continuation.
-- Consumes CORE-A governed facts only. Service-role orchestration around canonical draft/SO authority.

begin;

-- 1. Immutable draft execution ledger (exactly-once linkage + provenance)
create table if not exists public.whatsapp_order_autonomy_draft_executions (
  id uuid primary key default gen_random_uuid(),
  autonomy_decision_id uuid not null
    references public.whatsapp_order_autonomy_decisions(id) on delete restrict,
  potential_order_id uuid references public.whatsapp_potential_orders(id) on delete restrict,
  case_id uuid references public.whatsapp_communication_cases(id) on delete restrict,
  packet_id uuid not null references public.whatsapp_message_packets(id) on delete restrict,
  interpretation_id uuid not null references public.whatsapp_packet_ai_interpretations(id) on delete restrict,
  sales_order_draft_id uuid references public.sales_order_drafts(id) on delete restrict,
  promoted_order_id uuid references public.orders(id) on delete restrict,
  execution_status text not null check (execution_status in (
    'DRAFT_CREATED',
    'PROMOTED',
    'PROMOTION_BLOCKED',
    'REJECTED_NOT_ELIGIBLE'
  )),
  blocking_reason text,
  idempotency_key text not null,
  governed_facts_snapshot jsonb not null default '{}'::jsonb,
  readiness_snapshot jsonb not null default '{}'::jsonb,
  resolver_rule_version text not null default 'core-b-draft/v1',
  executed_at timestamptz not null default statement_timestamp(),
  constraint whatsapp_order_autonomy_draft_executions_decision_unique unique (autonomy_decision_id),
  constraint whatsapp_order_autonomy_draft_executions_idempotency_unique unique (idempotency_key),
  constraint whatsapp_order_autonomy_draft_executions_packet_interp_unique unique (packet_id, interpretation_id)
);

create index if not exists whatsapp_order_autonomy_draft_executions_draft_idx
  on public.whatsapp_order_autonomy_draft_executions(sales_order_draft_id);

create index if not exists whatsapp_order_autonomy_draft_executions_status_idx
  on public.whatsapp_order_autonomy_draft_executions(execution_status, executed_at desc);

alter table public.whatsapp_order_autonomy_draft_executions enable row level security;
revoke all on table public.whatsapp_order_autonomy_draft_executions from public, anon, authenticated;
grant select, insert on table public.whatsapp_order_autonomy_draft_executions to service_role;
revoke update, delete on table public.whatsapp_order_autonomy_draft_executions from service_role;
grant select on table public.whatsapp_order_autonomy_draft_executions to authenticated;

create or replace function public.whatsapp_guard_autonomy_draft_execution_immutable()
returns trigger language plpgsql security definer set search_path = pg_catalog, public as $$
begin
  raise exception 'whatsapp_order_autonomy_draft_executions is append-only' using errcode = '55000';
end;
$$;

drop trigger if exists whatsapp_order_autonomy_draft_executions_immutable
  on public.whatsapp_order_autonomy_draft_executions;
create trigger whatsapp_order_autonomy_draft_executions_immutable
  before update or delete on public.whatsapp_order_autonomy_draft_executions
  for each row execute function public.whatsapp_guard_autonomy_draft_execution_immutable();

drop policy if exists whatsapp_order_autonomy_draft_executions_reader
  on public.whatsapp_order_autonomy_draft_executions;
create policy whatsapp_order_autonomy_draft_executions_reader
  on public.whatsapp_order_autonomy_draft_executions
  for select to authenticated
  using (public.has_whatsapp_permission('wa.intake.read'));

comment on table public.whatsapp_order_autonomy_draft_executions is
  'CORE-B immutable ledger linking AUTO_ELIGIBLE autonomy decisions to exactly one canonical sales order draft and optional SO promotion.';

-- 2. Staleness guard: decision must belong to the latest interpretation for its packet
create or replace function public.whatsapp_autonomy_decision_is_current(p_decision_id uuid)
returns boolean
language sql
stable
security definer
set search_path = pg_catalog, public
as $$
  select exists (
    select 1
    from public.whatsapp_order_autonomy_decisions d
    where d.id = p_decision_id
      and d.interpretation_id = (
        select ai.id
        from public.whatsapp_packet_ai_interpretations ai
        where ai.packet_id = d.packet_id
        order by ai.created_at desc, ai.id desc
        limit 1
      )
  );
$$;

revoke all on function public.whatsapp_autonomy_decision_is_current(uuid) from public, anon, authenticated;
grant execute on function public.whatsapp_autonomy_decision_is_current(uuid) to service_role;

-- 3. Build canonical draft readiness dimensions from governed CORE-A facts
create or replace function public.whatsapp_build_core_b_readiness_dimensions(p_governed_facts jsonb)
returns jsonb
language sql
immutable
set search_path = pg_catalog
as $$
  select jsonb_build_array(
    jsonb_build_object('dimension', 'client', 'status', 'ready', 'score', 100),
    jsonb_build_object('dimension', 'product', 'status', 'ready', 'score', 100),
    jsonb_build_object('dimension', 'quantity', 'status', 'ready', 'score', 100),
    jsonb_build_object('dimension', 'address', 'status', 'ready', 'score', 100),
    jsonb_build_object('dimension', 'payment_terms', 'status', 'ready', 'score', 100)
  )
  where coalesce(p_governed_facts->'customer'->>'company_id', '') <> ''
    and jsonb_typeof(p_governed_facts->'order_lines') = 'array'
    and jsonb_array_length(p_governed_facts->'order_lines') > 0
    and coalesce(p_governed_facts->'branch'->>'delivery_address_id', '') <> '';
$$;

revoke all on function public.whatsapp_build_core_b_readiness_dimensions(jsonb) from public, anon, authenticated;
grant execute on function public.whatsapp_build_core_b_readiness_dimensions(jsonb) to service_role;

-- 4. Service-only promotion for CORE-B governed drafts (mirrors approve_sales_order_draft_for_so_atomic)
create or replace function public.whatsapp_promote_autonomous_sales_order_draft_v1(
  p_draft_id uuid,
  p_expected_extraction_request_key text
)
returns table (
  draft_id uuid,
  promoted_order_id uuid,
  order_number text,
  already_promoted boolean,
  promotion_blocked boolean,
  blocking_reason text
)
language plpgsql
security definer
set search_path = pg_catalog, public, extensions
as $$
#variable_conflict use_column
declare
  v_draft public.sales_order_drafts%rowtype;
  v_order_id uuid;
  v_order_number text;
  v_line record;
  v_qty numeric;
  v_lines int := 0;
begin
  if coalesce(auth.jwt()->>'role', '') <> 'service_role' then
    raise exception 'trusted packet processor required' using errcode = '42501';
  end if;

  select * into v_draft from public.sales_order_drafts d where d.id = p_draft_id for update;
  if not found then
    return query select p_draft_id, null::uuid, null::text, false, true, 'draft_not_found';
    return;
  end if;

  if coalesce(v_draft.extraction_request_key, '') not like 'core-b:autonomy:%' then
    return query select p_draft_id, null::uuid, null::text, false, true, 'draft_not_core_b_governed';
    return;
  end if;

  if v_draft.extraction_request_key is distinct from btrim(p_expected_extraction_request_key) then
    return query select p_draft_id, null::uuid, null::text, false, true, 'idempotency_key_mismatch';
    return;
  end if;

  if v_draft.promoted_order_id is not null then
    select o.order_number into v_order_number from public.orders o where o.id = v_draft.promoted_order_id;
    return query select p_draft_id, v_draft.promoted_order_id, v_order_number, true, false, null::text;
    return;
  end if;

  if v_draft.status <> 'UNDER_REVIEW' or v_draft.company_id is null then
    return query select p_draft_id, null::uuid, null::text, false, true, 'draft_not_ready_for_promotion';
    return;
  end if;

  begin
    perform public.validate_sales_order_draft_readiness(v_draft.readiness_dimensions);
    perform 1 from public.sales_order_draft_lines l where l.draft_id = p_draft_id for update;
    select count(*) into v_lines
    from public.sales_order_draft_lines l
    where l.draft_id = p_draft_id
      and l.product_id is not null
      and coalesce(l.operator_quantity, l.normalized_quantity, l.raw_quantity, 0) > 0;

    if v_lines = 0 then
      return query select p_draft_id, null::uuid, null::text, false, true, 'draft_has_no_valid_lines';
      return;
    end if;

    insert into public.orders(company_id, status, order_origin, payment_status, tracking_token)
    values (v_draft.company_id, 'submitted', 'LEGACY_ERP', 'awaiting_receipt', encode(extensions.gen_random_bytes(16), 'hex'))
    returning id, public.orders.order_number into v_order_id, v_order_number;

    for v_line in
      select l.* from public.sales_order_draft_lines l
      where l.draft_id = p_draft_id
      order by l.line_index
    loop
      v_qty := coalesce(v_line.operator_quantity, v_line.normalized_quantity, v_line.raw_quantity, 0);
      if v_line.product_id is not null and v_qty > 0 then
        insert into public.order_items(order_id, product_id, quantity, pack_size, notes)
        values (
          v_order_id, v_line.product_id, v_qty,
          coalesce(v_line.normalized_unit, v_line.raw_unit),
          left(coalesce(v_line.product_name, ''), 500)
        );
      end if;
    end loop;

    perform public.restore_order_financials(v_order_id);

    update public.sales_order_drafts d
    set status = 'APPROVED_FOR_SO',
        promoted_order_id = v_order_id,
        approver_name = 'CORE-B_AUTONOMY',
        review_notes = 'Autonomous promotion from CORE-B governed draft',
        updated_at = statement_timestamp()
    where d.id = p_draft_id;

    insert into public.sales_order_draft_audit_log(
      draft_id, action, from_status, to_status, actor_name, metadata
    ) values (
      p_draft_id, 'APPROVE', 'UNDER_REVIEW', 'APPROVED_FOR_SO', 'CORE-B_AUTONOMY',
      jsonb_build_object('promoted_order_id', v_order_id, 'autonomous', true)
    );

    insert into public.audit_logs(
      action_type, module_name, entity_name, entity_id, risk_level, new_value
    ) values (
      'WA_DRAFT_PROMOTED_TO_SO', 'WhatsApp', 'orders', v_order_id::text, 'high',
      jsonb_build_object('draft_id', p_draft_id, 'autonomous', true)
    );

    return query select p_draft_id, v_order_id, v_order_number, false, false, null::text;
  exception when others then
    return query select p_draft_id, null::uuid, null::text, false, true, sqlerrm;
  end;
end;
$$;

revoke all on function public.whatsapp_promote_autonomous_sales_order_draft_v1(uuid, text)
  from public, anon, authenticated;
grant execute on function public.whatsapp_promote_autonomous_sales_order_draft_v1(uuid, text)
  to service_role;

-- 5. CORE-B main orchestrator: governed draft creation + optional SO promotion
create or replace function public.whatsapp_execute_autonomous_order_draft_v1(
  p_autonomy_decision_id uuid,
  p_attempt_promotion boolean default true
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public, auth, extensions
as $$
declare
  v_decision public.whatsapp_order_autonomy_decisions%rowtype;
  v_existing public.whatsapp_order_autonomy_draft_executions%rowtype;
  v_case public.whatsapp_communication_cases%rowtype;
  v_po public.whatsapp_potential_orders%rowtype;
  v_company public.companies%rowtype;
  v_packet_text text := '';
  v_governed_facts jsonb;
  v_readiness jsonb;
  v_idempotency_key text;
  v_extraction_key text;
  v_draft_id uuid;
  v_line jsonb;
  v_line_idx integer;
  v_b2b record;
  v_execution public.whatsapp_order_autonomy_draft_executions%rowtype;
  v_promo record;
  v_exec_status text;
  v_blocking text;
  v_promoted_order_id uuid;
  v_promoted_order_number text;
begin
  if coalesce(auth.jwt()->>'role', '') <> 'service_role' then
    raise exception 'trusted packet processor required' using errcode = '42501';
  end if;

  -- Idempotency: return prior execution if recorded
  select * into v_existing
  from public.whatsapp_order_autonomy_draft_executions
  where autonomy_decision_id = p_autonomy_decision_id;

  if found then
    if p_attempt_promotion
       and v_existing.sales_order_draft_id is not null
       and v_existing.promoted_order_id is null
       and v_existing.execution_status = 'DRAFT_CREATED' then
      select * into v_promo
      from public.whatsapp_promote_autonomous_sales_order_draft_v1(
        v_existing.sales_order_draft_id,
        v_existing.idempotency_key
      );

      if coalesce(v_promo.promotion_blocked, false) then
        return jsonb_build_object(
          'execution_id', v_existing.id,
          'autonomy_decision_id', v_existing.autonomy_decision_id,
          'sales_order_draft_id', v_existing.sales_order_draft_id,
          'promoted_order_id', null,
          'execution_status', 'PROMOTION_BLOCKED',
          'blocking_reason', v_promo.blocking_reason,
          'idempotent_replay', true
        );
      end if;

      if v_promo.promoted_order_id is not null then
        if v_existing.potential_order_id is not null then
          perform set_config('app.wa1_governed_mutation', 'on', true);
          update public.whatsapp_potential_orders
          set state = 'CONVERTED',
              disposition = 'CONVERTED',
              sales_order_draft_id = v_existing.sales_order_draft_id,
              sales_order_id = v_promo.promoted_order_id,
              next_action = 'ORDER_CREATED',
              updated_at = statement_timestamp()
          where id = v_existing.potential_order_id;
          perform set_config('app.wa1_governed_mutation', 'off', true);
        end if;

        return jsonb_build_object(
          'execution_id', v_existing.id,
          'autonomy_decision_id', v_existing.autonomy_decision_id,
          'sales_order_draft_id', v_existing.sales_order_draft_id,
          'promoted_order_id', v_promo.promoted_order_id,
          'execution_status', 'PROMOTED',
          'blocking_reason', null,
          'order_number', v_promo.order_number,
          'idempotent_replay', true
        );
      end if;
    end if;

    return jsonb_build_object(
      'execution_id', v_existing.id,
      'autonomy_decision_id', v_existing.autonomy_decision_id,
      'sales_order_draft_id', v_existing.sales_order_draft_id,
      'promoted_order_id', v_existing.promoted_order_id,
      'execution_status', v_existing.execution_status,
      'blocking_reason', v_existing.blocking_reason,
      'idempotent_replay', true
    );
  end if;

  select * into v_decision
  from public.whatsapp_order_autonomy_decisions
  where id = p_autonomy_decision_id
  for update;

  if not found then
    raise exception 'autonomy decision not found' using errcode = 'P0002';
  end if;

  v_idempotency_key := 'core-b:autonomy:' || p_autonomy_decision_id::text;
  v_extraction_key := v_idempotency_key;
  v_governed_facts := v_decision.governed_facts;

  -- Fail closed unless every CORE-B eligibility gate still holds
  if v_decision.autonomy_outcome <> 'AUTO_ELIGIBLE' then
    insert into public.whatsapp_order_autonomy_draft_executions(
      autonomy_decision_id, potential_order_id, case_id, packet_id, interpretation_id,
      execution_status, blocking_reason, idempotency_key,
      governed_facts_snapshot, readiness_snapshot
    ) values (
      v_decision.id, v_decision.potential_order_id, v_decision.case_id,
      v_decision.packet_id, v_decision.interpretation_id,
      'REJECTED_NOT_ELIGIBLE', 'autonomy_outcome_not_auto_eligible:' || v_decision.autonomy_outcome,
      v_idempotency_key, v_governed_facts, v_decision.readiness_snapshot
    )
    on conflict (autonomy_decision_id) do nothing
    returning * into v_execution;

    if v_execution.id is null then
      select * into v_execution
      from public.whatsapp_order_autonomy_draft_executions
      where autonomy_decision_id = p_autonomy_decision_id;
    end if;

    return jsonb_build_object(
      'execution_id', v_execution.id,
      'autonomy_decision_id', v_decision.id,
      'execution_status', v_execution.execution_status,
      'blocking_reason', v_execution.blocking_reason,
      'idempotent_replay', false
    );
  end if;

  if not public.whatsapp_autonomy_decision_is_current(p_autonomy_decision_id) then
    insert into public.whatsapp_order_autonomy_draft_executions(
      autonomy_decision_id, potential_order_id, case_id, packet_id, interpretation_id,
      execution_status, blocking_reason, idempotency_key,
      governed_facts_snapshot, readiness_snapshot
    ) values (
      v_decision.id, v_decision.potential_order_id, v_decision.case_id,
      v_decision.packet_id, v_decision.interpretation_id,
      'REJECTED_NOT_ELIGIBLE', 'stale_autonomy_decision_superseded',
      v_idempotency_key, v_governed_facts, v_decision.readiness_snapshot
    )
    on conflict (autonomy_decision_id) do nothing
    returning * into v_execution;

    if v_execution.id is null then
      select * into v_execution
      from public.whatsapp_order_autonomy_draft_executions
      where autonomy_decision_id = p_autonomy_decision_id;
    end if;

    return jsonb_build_object(
      'execution_id', v_execution.id,
      'autonomy_decision_id', v_decision.id,
      'execution_status', v_execution.execution_status,
      'blocking_reason', v_execution.blocking_reason,
      'idempotent_replay', false
    );
  end if;

  if v_decision.potential_order_id is null then
    raise exception 'autonomy decision missing potential order' using errcode = 'P0001';
  end if;

  -- Serialize concurrent draft attempts for this packet
  perform pg_advisory_xact_lock(hashtextextended('core-b-draft:' || v_decision.packet_id::text, 0));

  -- Re-check idempotency after acquiring lock
  select * into v_existing
  from public.whatsapp_order_autonomy_draft_executions
  where autonomy_decision_id = p_autonomy_decision_id;

  if found then
    return jsonb_build_object(
      'execution_id', v_existing.id,
      'autonomy_decision_id', v_existing.autonomy_decision_id,
      'sales_order_draft_id', v_existing.sales_order_draft_id,
      'promoted_order_id', v_existing.promoted_order_id,
      'execution_status', v_existing.execution_status,
      'blocking_reason', v_existing.blocking_reason,
      'idempotent_replay', true
    );
  end if;

  select * into v_po
  from public.whatsapp_potential_orders
  where id = v_decision.potential_order_id
  for update;

  v_readiness := public.evaluate_whatsapp_order_readiness(v_decision.potential_order_id);
  if not coalesce((v_readiness->>'ready')::boolean, false) then
    insert into public.whatsapp_order_autonomy_draft_executions(
      autonomy_decision_id, potential_order_id, case_id, packet_id, interpretation_id,
      execution_status, blocking_reason, idempotency_key,
      governed_facts_snapshot, readiness_snapshot
    ) values (
      v_decision.id, v_decision.potential_order_id, v_decision.case_id,
      v_decision.packet_id, v_decision.interpretation_id,
      'REJECTED_NOT_ELIGIBLE', 'readiness_no_longer_true',
      v_idempotency_key, v_governed_facts, v_readiness
    )
    on conflict (autonomy_decision_id) do nothing
    returning * into v_execution;

    if v_execution.id is null then
      select * into v_execution
      from public.whatsapp_order_autonomy_draft_executions
      where autonomy_decision_id = p_autonomy_decision_id;
    end if;

    return jsonb_build_object(
      'execution_id', v_execution.id,
      'autonomy_decision_id', v_decision.id,
      'execution_status', v_execution.execution_status,
      'blocking_reason', v_execution.blocking_reason,
      'readiness', v_readiness,
      'idempotent_replay', false
    );
  end if;

  -- Reuse existing active draft for packet if already linked to this decision lineage
  select d.id into v_draft_id
  from public.sales_order_drafts d
  where d.packet_id = v_decision.packet_id
    and d.status <> 'REJECTED'
  limit 1;

  if v_draft_id is not null and not exists (
    select 1 from public.whatsapp_order_autonomy_draft_executions e
    where e.sales_order_draft_id = v_draft_id
      and e.autonomy_decision_id = p_autonomy_decision_id
  ) then
    insert into public.whatsapp_order_autonomy_draft_executions(
      autonomy_decision_id, potential_order_id, case_id, packet_id, interpretation_id,
      execution_status, blocking_reason, idempotency_key,
      governed_facts_snapshot, readiness_snapshot
    ) values (
      v_decision.id, v_decision.potential_order_id, v_decision.case_id,
      v_decision.packet_id, v_decision.interpretation_id,
      'REJECTED_NOT_ELIGIBLE', 'conflicting_active_draft_for_packet',
      v_idempotency_key, v_governed_facts, v_readiness
    )
    on conflict (autonomy_decision_id) do nothing
    returning * into v_execution;

    if v_execution.id is null then
      select * into v_execution
      from public.whatsapp_order_autonomy_draft_executions
      where autonomy_decision_id = p_autonomy_decision_id;
    end if;

    return jsonb_build_object(
      'execution_id', v_execution.id,
      'autonomy_decision_id', v_decision.id,
      'execution_status', v_execution.execution_status,
      'blocking_reason', v_execution.blocking_reason,
      'idempotent_replay', false
    );
  end if;

  if v_draft_id is null then
    select * into v_company
    from public.companies
    where id = (v_governed_facts->'customer'->>'company_id')::uuid;

    if not found then
      raise exception 'governed customer company not found' using errcode = 'P0001';
    end if;

    select coalesce(string_agg(wm.content, E'\n' order by wm.packet_sequence nulls last, wm.created_at), '')
    into v_packet_text
    from public.whatsapp_messages wm
    where wm.packet_id = v_decision.packet_id
      and lower(wm.direction) = 'inbound';

    insert into public.sales_order_drafts (
      packet_id,
      extraction_request_key,
      status,
      company_id,
      company_name,
      readiness_overall_score,
      readiness_dimensions,
      original_whatsapp_text,
      ai_draft_snapshot,
      potential_order_id,
      created_by,
      updated_by
    ) values (
      v_decision.packet_id,
      v_extraction_key,
      'UNDER_REVIEW',
      v_company.id,
      v_company.business_name,
      100,
      public.whatsapp_build_core_b_readiness_dimensions(v_governed_facts),
      left(coalesce(v_packet_text, ''), 10000),
      jsonb_build_object(
        'source', 'CORE_B_AUTONOMY',
        'autonomy_decision_id', v_decision.id,
        'governed_facts', v_governed_facts,
        'branch', v_governed_facts->'branch',
        'payment_terms', v_governed_facts->'customer'->>'payment_terms'
      ),
      v_decision.potential_order_id,
      null,
      null
    )
    returning id into v_draft_id;

    for v_line, v_line_idx in
      select value, ordinality::integer
      from jsonb_array_elements(v_governed_facts->'order_lines') with ordinality
    loop
      select * into v_b2b
      from public.customer_resolve_buyer_product_authority_v1(
        v_company.id,
        (v_line->>'product_id')::uuid
      );

      if not coalesce(v_b2b.is_available, false) then
        raise exception 'missing_b2b_product_authority_for_line_%', v_line_idx using errcode = 'P0001';
      end if;

      insert into public.sales_order_draft_lines (
        draft_id,
        line_index,
        product_id,
        product_name,
        sku,
        raw_quantity,
        raw_unit,
        normalized_quantity,
        normalized_unit,
        operator_quantity,
        product_confidence,
        quantity_confidence,
        ai_line_snapshot
      ) values (
        v_draft_id,
        coalesce((v_line->>'line_number')::integer, v_line_idx) - 1,
        (v_line->>'product_id')::uuid,
        coalesce(v_line->>'product_name', v_b2b.product_name),
        coalesce(v_line->>'sku', v_b2b.sku),
        (v_line->>'quantity')::numeric,
        v_line->>'uom',
        (v_line->>'quantity')::numeric,
        v_line->>'uom',
        (v_line->>'quantity')::numeric,
        1.0,
        1.0,
        jsonb_build_object(
          'source', 'CORE_B_GOVERNED',
          'selling_price', v_b2b.selling_price,
          'currency', v_b2b.currency,
          'gst_rate', v_b2b.gst_rate,
          'pack_size', v_line->>'pack_size',
          'moq', v_line->>'moq'
        )
      );
    end loop;

    insert into public.sales_order_draft_audit_log (
      draft_id, action, from_status, to_status, actor_name, metadata
    ) values (
      v_draft_id, 'CREATE', null, 'UNDER_REVIEW', 'CORE-B_AUTONOMY',
      jsonb_build_object(
        'autonomy_decision_id', v_decision.id,
        'autonomous', true,
        'governed_facts', v_governed_facts
      )
    );
  end if;

  v_exec_status := 'DRAFT_CREATED';
  v_blocking := null;
  v_promoted_order_id := null;

  -- Link case and potential order state transitions
  if v_decision.case_id is not null then
    select * into v_case
    from public.whatsapp_communication_cases
    where id = v_decision.case_id
    for update;

    update public.whatsapp_communication_cases
    set sales_order_draft_id = v_draft_id,
        status = 'DRAFTED',
        next_action = case
          when p_attempt_promotion then 'AUTONOMOUS_SO_PROMOTION_PENDING'
          else 'Review governed Sales Order Draft'
        end,
        updated_at = statement_timestamp()
    where id = v_decision.case_id;

    insert into public.whatsapp_case_events(
      case_id, event_type, actor_type, correlation_key, resulting_state, metadata
    ) values (
      v_decision.case_id, 'AUTONOMOUS_DRAFT_CREATED', 'SYSTEM',
      'core-b-draft:' || v_decision.interpretation_id::text,
      jsonb_build_object('sales_order_draft_id', v_draft_id, 'status', 'DRAFTED'),
      jsonb_build_object('autonomy_decision_id', v_decision.id, 'autonomous', true)
    )
    on conflict (case_id, correlation_key) do nothing;
  end if;

  perform set_config('app.wa1_governed_mutation', 'on', true);
  update public.whatsapp_potential_orders
  set sales_order_draft_id = v_draft_id,
      next_action = case when p_attempt_promotion then 'AUTONOMOUS_SO_PROMOTION' else 'DRAFT_LINKED' end,
      updated_at = statement_timestamp()
  where id = v_decision.potential_order_id;
  perform set_config('app.wa1_governed_mutation', 'off', true);

  -- Attempt canonical SO promotion when permitted
  if p_attempt_promotion then
    select * into v_promo
    from public.whatsapp_promote_autonomous_sales_order_draft_v1(v_draft_id, v_extraction_key);

    if coalesce(v_promo.promotion_blocked, false) then
      v_exec_status := 'PROMOTION_BLOCKED';
      v_blocking := v_promo.blocking_reason;
    elsif v_promo.promoted_order_id is not null then
      v_exec_status := 'PROMOTED';
      v_promoted_order_id := v_promo.promoted_order_id;
      v_promoted_order_number := v_promo.order_number;

      if v_decision.case_id is not null then
        insert into public.whatsapp_case_events(
          case_id, event_type, actor_type, correlation_key, resulting_state, metadata
        ) values (
          v_decision.case_id, 'AUTONOMOUS_SO_PROMOTED', 'SYSTEM',
          'core-b-promote:' || v_decision.interpretation_id::text,
          jsonb_build_object('sales_order_draft_id', v_draft_id, 'promoted_order_id', v_promoted_order_id),
          jsonb_build_object('order_number', v_promoted_order_number, 'autonomous', true)
        )
        on conflict (case_id, correlation_key) do nothing;

        update public.whatsapp_communication_cases
        set next_action = 'SO_CREATED_AWAITING_FULFILLMENT',
            updated_at = statement_timestamp()
        where id = v_decision.case_id;
      end if;

      perform set_config('app.wa1_governed_mutation', 'on', true);
      update public.whatsapp_potential_orders
      set state = 'CONVERTED',
          disposition = 'CONVERTED',
          sales_order_draft_id = v_draft_id,
          sales_order_id = v_promoted_order_id,
          next_action = 'ORDER_CREATED',
          updated_at = statement_timestamp()
      where id = v_decision.potential_order_id;
      perform set_config('app.wa1_governed_mutation', 'off', true);
    end if;
  end if;

  insert into public.whatsapp_order_autonomy_draft_executions(
    autonomy_decision_id, potential_order_id, case_id, packet_id, interpretation_id,
    sales_order_draft_id, promoted_order_id, execution_status, blocking_reason,
    idempotency_key, governed_facts_snapshot, readiness_snapshot
  ) values (
    v_decision.id, v_decision.potential_order_id, v_decision.case_id,
    v_decision.packet_id, v_decision.interpretation_id,
    v_draft_id, v_promoted_order_id, v_exec_status, v_blocking,
    v_idempotency_key, v_governed_facts, v_readiness
  )
  on conflict (autonomy_decision_id) do nothing
  returning * into v_execution;

  if v_execution.id is null then
    select * into v_execution
    from public.whatsapp_order_autonomy_draft_executions
    where autonomy_decision_id = p_autonomy_decision_id;
  end if;

  return jsonb_build_object(
    'execution_id', v_execution.id,
    'autonomy_decision_id', v_decision.id,
    'sales_order_draft_id', v_draft_id,
    'promoted_order_id', v_promoted_order_id,
    'execution_status', v_execution.execution_status,
    'blocking_reason', v_execution.blocking_reason,
    'order_number', v_promoted_order_number,
    'idempotent_replay', false
  );
exception when others then
  perform set_config('app.wa1_governed_mutation', 'off', true);
  raise;
end;
$$;

revoke all on function public.whatsapp_execute_autonomous_order_draft_v1(uuid, boolean)
  from public, anon, authenticated;
grant execute on function public.whatsapp_execute_autonomous_order_draft_v1(uuid, boolean)
  to service_role;

comment on function public.whatsapp_execute_autonomous_order_draft_v1(uuid, boolean) is
  'CORE-B service-only orchestrator. Creates exactly one canonical sales order draft from an AUTO_ELIGIBLE autonomy decision and optionally promotes to Sales Order.';

-- 6. Integrate CORE-B into packet materialisation path (AUTO_ELIGIBLE only)
create or replace function public.whatsapp_materialize_packet_ai_case(
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
  v_autonomy jsonb;
  v_autonomy_outcome text;
  v_human_decision_required boolean;
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
          and public.whatsapp_communication_cases.status in ('OPEN', 'NEEDS_IDENTITY', 'NEEDS_CLARIFICATION', 'READY_FOR_DRAFT')
          then excluded.case_type
        else public.whatsapp_communication_cases.case_type
      end,
      next_action = case
        when public.whatsapp_communication_cases.accountability_status = 'UNASSIGNED'
          and public.whatsapp_communication_cases.status in ('OPEN', 'NEEDS_IDENTITY', 'NEEDS_CLARIFICATION', 'READY_FOR_DRAFT')
          then excluded.next_action
        else public.whatsapp_communication_cases.next_action
      end,
      rule_version = case
        when public.whatsapp_communication_cases.accountability_status = 'UNASSIGNED'
          and public.whatsapp_communication_cases.status in ('OPEN', 'NEEDS_IDENTITY', 'NEEDS_CLARIFICATION', 'READY_FOR_DRAFT')
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
      'case_status', v_case.status
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
      'conclusion', v_conclusion
    )
  )
  on conflict (case_id, correlation_key) do nothing;

  v_autonomy := public.whatsapp_evaluate_and_materialize_order_autonomy(
    p_packet_id,
    p_interpretation_id,
    p_job_id,
    p_lease_token,
    p_packet_revision
  );

  v_autonomy_outcome := v_autonomy->>'autonomy_outcome';
  v_human_decision_required := coalesce((v_autonomy->>'human_decision_required')::boolean, (v_autonomy_outcome <> 'AUTO_ELIGIBLE'));

  -- CORE-B: autonomous draft creation and governed SO continuation for AUTO_ELIGIBLE only
  v_draft_execution := null;
  if v_autonomy_outcome = 'AUTO_ELIGIBLE' and v_autonomy->>'decision_id' is not null then
    v_draft_execution := public.whatsapp_execute_autonomous_order_draft_v1(
      (v_autonomy->>'decision_id')::uuid,
      false
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
    'ai_event_correlation_key', v_event_key,
    'human_decision_required', v_human_decision_required,
    'idempotent_replay', coalesce((v_autonomy->>'idempotent_replay')::boolean, false)
  );
end;
$$;

comment on function public.whatsapp_materialize_packet_ai_case(uuid, uuid, uuid, uuid, bigint) is
  'Service-role-only bridge from append-only packet AI interpretation to governed commercial autonomy, autonomous draft creation (CORE-B), and communication case lifecycle.';

revoke all on function public.whatsapp_materialize_packet_ai_case(uuid, uuid, uuid, uuid, bigint)
  from public, anon, authenticated;
grant execute on function public.whatsapp_materialize_packet_ai_case(uuid, uuid, uuid, uuid, bigint)
  to service_role;

commit;

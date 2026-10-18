-- MC#631 — durable pending billing/dispatch tasks after SO_RECORDABLE promotion.
begin;

create table if not exists public.sales_order_governance_pending_tasks (
  id uuid primary key default gen_random_uuid(),
  order_id uuid not null references public.orders(id) on delete restrict,
  sales_order_draft_id uuid references public.sales_order_drafts(id) on delete set null,
  readiness_gate text not null check (readiness_gate in ('BILLING_READY', 'DISPATCH_READY', 'TRANSPORT_READY')),
  hold_code text not null,
  status text not null default 'OPEN' check (status in ('OPEN', 'RESOLVED', 'CANCELLED')),
  original_instructions text not null default '',
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default statement_timestamp(),
  resolved_at timestamptz,
  resolved_by uuid,
  resolution_evidence text,
  owner_role text not null default 'sales_operations',
  due_at timestamptz not null default (statement_timestamp() + interval '24 hours'),
  unique (order_id, readiness_gate, hold_code)
);

alter table public.sales_order_governance_pending_tasks enable row level security;
revoke all on public.sales_order_governance_pending_tasks from public, anon;
grant select on public.sales_order_governance_pending_tasks to authenticated;
grant all on public.sales_order_governance_pending_tasks to service_role;

create policy sales_order_governance_pending_tasks_read on public.sales_order_governance_pending_tasks
  for select to authenticated
  using (public.has_whatsapp_permission('wa.intake.read') or public.has_whatsapp_permission('wa.draft.manage'));

comment on table public.sales_order_governance_pending_tasks is
  'MC#631: visible downstream work after early SO capture — billing/dispatch/transport gaps must not hide the order.';

create or replace function public.sync_sales_order_governance_pending_tasks_from_draft(
  p_order_id uuid,
  p_draft_id uuid
)
returns void
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  v_draft public.sales_order_drafts%rowtype;
  v_dim jsonb;
  v_gate text;
  v_hold text;
begin
  select * into v_draft from public.sales_order_drafts where id = p_draft_id;
  if not found then
    return;
  end if;

  for v_dim in
    select elem
    from jsonb_array_elements(coalesce(v_draft.readiness_dimensions, '[]'::jsonb)) as elem
  loop
    if coalesce(v_dim->>'status', '') <> 'pending' then
      continue;
    end if;
    -- Human-extracted drafts carry no gate/hold_code: derive them from the
    -- dimension so a pending address or payment term is never silently dropped.
    v_gate := upper(coalesce(
      nullif(v_dim->>'gate', ''),
      case v_dim->>'dimension'
        when 'address' then 'DISPATCH_READY'
        when 'payment_terms' then 'BILLING_READY'
        else ''
      end
    ));
    v_hold := coalesce(
      nullif(v_dim->>'hold_code', ''),
      case v_dim->>'dimension'
        when 'address' then 'DELIVERY_DETAILS_PENDING'
        when 'payment_terms' then 'BILLING_DETAILS_PENDING'
        else null
      end,
      v_dim->>'dimension',
      'PENDING_DETAIL'
    );
    if v_gate not in ('BILLING_READY', 'DISPATCH_READY', 'TRANSPORT_READY') then
      continue;
    end if;
    insert into public.sales_order_governance_pending_tasks (
      order_id, sales_order_draft_id, readiness_gate, hold_code, original_instructions, metadata, owner_role
    ) values (
      p_order_id,
      p_draft_id,
      v_gate,
      v_hold,
      left(coalesce(v_draft.original_whatsapp_text, ''), 10000),
      jsonb_build_object(
        'readiness_dimension', v_dim,
        'promoted_at', statement_timestamp(),
        'source', 'SO_RECORDABLE'
      ),
      case v_gate when 'BILLING_READY' then 'finance' else 'dispatch' end
    )
    on conflict (order_id, readiness_gate, hold_code) do update
      set status = case
            when public.sales_order_governance_pending_tasks.status = 'RESOLVED'
              then public.sales_order_governance_pending_tasks.status
            else 'OPEN'
          end,
          original_instructions = excluded.original_instructions,
          metadata = public.sales_order_governance_pending_tasks.metadata || excluded.metadata;
  end loop;

  insert into public.audit_logs(
    action_type, module_name, entity_name, entity_id, risk_level, new_value
  ) values (
    'SO_PENDING_GOVERNANCE_TASKS_MATERIALIZED',
    'WhatsApp',
    'orders',
    p_order_id::text,
    'medium',
    jsonb_build_object(
      'draft_id', p_draft_id,
      'pending_task_count', (
        select count(*) from public.sales_order_governance_pending_tasks t
        where t.order_id = p_order_id and t.status = 'OPEN'
      )
    )
  );
end;
$$;

revoke all on function public.sync_sales_order_governance_pending_tasks_from_draft(uuid, uuid)
  from public, anon, authenticated;
grant execute on function public.sync_sales_order_governance_pending_tasks_from_draft(uuid, uuid)
  to service_role;

-- Extend governed promotion to materialize pending tasks (SO_RECORDABLE path).
create or replace function public.promote_sales_order_draft_to_order_governed_v1(
  p_draft_id uuid, p_expected_extraction_request_key text, p_actor_id uuid,
  p_actor_name text, p_review_notes text DEFAULT NULL, p_metadata jsonb DEFAULT '{}'::jsonb
) RETURNS TABLE (draft_id uuid, promoted_order_id uuid, order_number text, already_promoted boolean)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public, extensions AS $$
#variable_conflict use_column
DECLARE v_draft public.sales_order_drafts%rowtype; v_order_id uuid; v_order_number text;
  v_line record; v_qty numeric; v_lines int := 0; v_gate text := 'FULL';
BEGIN
  SELECT * INTO v_draft FROM public.sales_order_drafts d WHERE d.id = p_draft_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'DRAFT_NOT_FOUND' USING ERRCODE = 'P0001'; END IF;
  IF v_draft.extraction_request_key IS DISTINCT FROM btrim(p_expected_extraction_request_key) THEN
    RAISE EXCEPTION 'IDEMPOTENCY_KEY_MISMATCH' USING ERRCODE = 'P0001';
  END IF;
  IF v_draft.promoted_order_id IS NOT NULL THEN
    SELECT o.order_number INTO v_order_number FROM public.orders o WHERE o.id = v_draft.promoted_order_id;
    RETURN QUERY SELECT p_draft_id, v_draft.promoted_order_id, v_order_number, true; RETURN;
  END IF;
  IF v_draft.status <> 'UNDER_REVIEW' OR v_draft.company_id IS NULL THEN RAISE EXCEPTION 'DRAFT_NOT_READY' USING ERRCODE = 'P0001'; END IF;
  -- The weaker SO_RECORDABLE gate is never selected by caller-supplied
  -- metadata alone: it requires a service_role JWT (the autonomous path) AND a
  -- Core-B autonomy draft. Human wrappers always get the FULL gate.
  if upper(coalesce(p_metadata->>'readiness_gate', 'FULL')) = 'SO_RECORDABLE' then
    if coalesce(auth.jwt()->>'role', '') = 'service_role'
       and coalesce(p_metadata->>'autonomous', '') = 'true'
       and coalesce(v_draft.extraction_request_key, '') like 'core-b:autonomy:%' then
      v_gate := 'SO_RECORDABLE';
    elsif coalesce(p_metadata->>'human_early_so', '') = 'true'
       and auth.uid() is not null
       and auth.uid() is not distinct from p_actor_id
       and public.has_whatsapp_permission('wa.draft.promote') then
      -- Human early-SO: only an operator who holds wa.draft.promote (high-risk,
      -- step-up aware) at call time. Billing, finance, production and dispatch
      -- gates are untouched; open pending-detail tasks record what is missing.
      v_gate := 'SO_RECORDABLE';
      PERFORM set_config('app.wa3_promotion_gate_authority', 'HUMAN_PROMOTE', true);
    end if;
  end if;
  if v_gate = 'SO_RECORDABLE' then
    perform public.validate_sales_order_so_recordable_readiness(v_draft.readiness_dimensions);
  else
    perform public.validate_sales_order_draft_readiness(v_draft.readiness_dimensions);
  end if;
  PERFORM 1 FROM public.sales_order_draft_lines l WHERE l.draft_id = p_draft_id FOR UPDATE;
  SELECT count(*) INTO v_lines FROM public.sales_order_draft_lines l WHERE l.draft_id = p_draft_id
    AND l.product_id IS NOT NULL AND coalesce(l.operator_quantity, l.normalized_quantity, l.raw_quantity, 0) > 0;
  IF v_lines = 0 THEN RAISE EXCEPTION 'DRAFT_HAS_NO_VALID_LINES' USING ERRCODE = 'P0001'; END IF;

  INSERT INTO public.sales_order_creation_scopes(backend_pid, transaction_id, authority)
  VALUES (pg_backend_pid(), txid_current(), 'WHATSAPP_DRAFT_PROMOTION')
  ON CONFLICT (backend_pid, transaction_id) DO UPDATE
    SET authority = EXCLUDED.authority, created_at = statement_timestamp();

  INSERT INTO public.orders(company_id, status, order_origin, payment_status, tracking_token)
  VALUES (v_draft.company_id, 'submitted', 'WHATSAPP', 'awaiting_receipt', encode(extensions.gen_random_bytes(16), 'hex'))
  RETURNING id, public.orders.order_number INTO v_order_id, v_order_number;

  DELETE FROM public.sales_order_creation_scopes
  WHERE backend_pid = pg_backend_pid() AND transaction_id = txid_current();
  FOR v_line IN SELECT l.* FROM public.sales_order_draft_lines l WHERE l.draft_id = p_draft_id ORDER BY l.line_index LOOP
    v_qty := coalesce(v_line.operator_quantity, v_line.normalized_quantity, v_line.raw_quantity, 0);
    IF v_line.product_id IS NOT NULL AND v_qty > 0 THEN
      INSERT INTO public.order_items(order_id, product_id, quantity, pack_size, notes)
      VALUES (v_order_id, v_line.product_id, v_qty, coalesce(v_line.normalized_unit, v_line.raw_unit), left(coalesce(v_line.product_name, ''), 500));
    END IF;
  END LOOP;
  PERFORM public.restore_order_financials(v_order_id);
  UPDATE public.sales_order_drafts d
     SET promoted_order_id = v_order_id, updated_by = p_actor_id, updated_at = statement_timestamp()
   WHERE d.id = p_draft_id;
  PERFORM public.create_sales_order_commercial_version_v1(
    v_order_id, 'WHATSAPP_DRAFT_PROMOTION', 'wa-draft:' || p_draft_id::text,
    'wa-so-version:' || p_draft_id::text, p_actor_id
  );
  PERFORM set_config('app.wa3_promotion_readiness_gate', v_gate, true);
  UPDATE public.sales_order_drafts d SET status = 'APPROVED_FOR_SO',
    approver_id = p_actor_id, approver_name = p_actor_name, review_notes = p_review_notes,
    updated_by = p_actor_id, updated_at = statement_timestamp() WHERE d.id = p_draft_id;
  PERFORM public.sync_sales_order_governance_pending_tasks_from_draft(v_order_id, p_draft_id);
  INSERT INTO public.sales_order_draft_audit_log(draft_id, action, from_status, to_status, actor_id, actor_name, metadata)
  VALUES (p_draft_id, 'APPROVE', 'UNDER_REVIEW', 'APPROVED_FOR_SO', p_actor_id, p_actor_name,
    coalesce(p_metadata, '{}'::jsonb) || jsonb_build_object('promoted_order_id', v_order_id, 'readiness_gate', v_gate));
  INSERT INTO public.audit_logs(action_type, module_name, entity_name, entity_id, actor_id, risk_level, new_value)
  VALUES ('WA_DRAFT_PROMOTED_TO_SO', 'WhatsApp', 'orders', v_order_id::text, p_actor_id, 'high', jsonb_build_object('draft_id', p_draft_id));
  PERFORM set_config('app.wa3_promotion_readiness_gate', 'FULL', true);
  PERFORM set_config('app.wa3_promotion_gate_authority', '', true);
  RETURN QUERY SELECT p_draft_id, v_order_id, v_order_number, false;
END;
$$;

-- Human wrapper: caller metadata can never select the weaker gate by itself. The
-- wrapper strips any caller-supplied gate/authority keys and only forwards a
-- human early-SO request; promote_sales_order_draft_to_order_governed_v1 then
-- re-verifies wa.draft.promote for the same authenticated actor.
create or replace function public.approve_sales_order_draft_for_so_atomic(
  p_draft_id uuid,
  p_expected_extraction_request_key text,
  p_actor_id uuid,
  p_actor_name text,
  p_review_notes text default null,
  p_metadata jsonb default '{}'::jsonb
)
returns table(draft_id uuid, promoted_order_id uuid, order_number text, already_promoted boolean)
language plpgsql
security definer
set search_path = pg_catalog, public, extensions
as $$
#variable_conflict use_column
declare
  v_actor_name text;
  v_meta jsonb := coalesce(p_metadata, '{}'::jsonb);
  v_early boolean;
begin
  if auth.uid() is null
     or not public.is_whatsapp_inbox_reader(auth.uid())
     or p_actor_id is distinct from auth.uid() then
    raise exception 'NOT_AUTHORIZED' using errcode = 'P0001';
  end if;

  v_early := upper(coalesce(v_meta->>'readiness_gate', '')) = 'SO_RECORDABLE';
  v_meta := v_meta - 'readiness_gate' - 'autonomous' - 'human_early_so';
  if v_early then
    v_meta := v_meta || jsonb_build_object('readiness_gate', 'SO_RECORDABLE', 'human_early_so', true);
  end if;

  select coalesce(nullif(btrim(u.full_name), ''), nullif(btrim(u.name), ''), nullif(btrim(u.email), ''), p_actor_id::text)
    into v_actor_name
  from public.users u
  where u.id = p_actor_id;
  v_actor_name := coalesce(v_actor_name, p_actor_id::text);

  return query
  select *
  from public.promote_sales_order_draft_to_order_governed_v1(
    p_draft_id, p_expected_extraction_request_key, p_actor_id, v_actor_name, p_review_notes, v_meta
  );
end;
$$;

revoke all on function public.approve_sales_order_draft_for_so_atomic(uuid, text, uuid, text, text, jsonb)
  from public, anon;
grant execute on function public.approve_sales_order_draft_for_so_atomic(uuid, text, uuid, text, text, jsonb)
  to authenticated, service_role;

-- Later verified details release exactly one pending hold. This never changes
-- order status, payment, finance verification or dispatch state: the
-- downstream gates (finance release, packing, dispatch) still enforce
-- themselves.
create or replace function public.resolve_sales_order_governance_pending_task_v1(
  p_order_id uuid,
  p_readiness_gate text,
  p_hold_code text,
  p_evidence text
)
returns table(task_id uuid, status text, already_resolved boolean)
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  v_task public.sales_order_governance_pending_tasks%rowtype;
begin
  if coalesce(auth.jwt()->>'role', '') <> 'service_role'
     and (auth.uid() is null or not public.has_whatsapp_permission('wa.draft.manage')) then
    raise exception 'NOT_AUTHORIZED' using errcode = 'P0001';
  end if;
  if nullif(btrim(coalesce(p_evidence, '')), '') is null then
    raise exception 'RESOLUTION_EVIDENCE_REQUIRED' using errcode = 'P0001';
  end if;

  select * into v_task
  from public.sales_order_governance_pending_tasks t
  where t.order_id = p_order_id
    and t.readiness_gate = upper(p_readiness_gate)
    and t.hold_code = p_hold_code
  for update;
  if not found then
    raise exception 'PENDING_TASK_NOT_FOUND' using errcode = 'P0001';
  end if;
  if v_task.status = 'RESOLVED' then
    return query select v_task.id, v_task.status, true;
    return;
  end if;

  update public.sales_order_governance_pending_tasks t
     set status = 'RESOLVED', resolved_at = statement_timestamp(),
         resolved_by = auth.uid(), resolution_evidence = btrim(p_evidence)
   where t.id = v_task.id;

  insert into public.audit_logs(action_type, module_name, entity_name, entity_id, actor_id, risk_level, new_value)
  values ('SO_PENDING_GOVERNANCE_TASK_RESOLVED', 'WhatsApp', 'orders', p_order_id::text, auth.uid(), 'medium',
          jsonb_build_object('readiness_gate', v_task.readiness_gate, 'hold_code', v_task.hold_code));

  return query select v_task.id, 'RESOLVED'::text, false;
end;
$$;

revoke all on function public.resolve_sales_order_governance_pending_task_v1(uuid, text, text, text) from public, anon;
grant execute on function public.resolve_sales_order_governance_pending_task_v1(uuid, text, text, text) to authenticated, service_role;

commit;

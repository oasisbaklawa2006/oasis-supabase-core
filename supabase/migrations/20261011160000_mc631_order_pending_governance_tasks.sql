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
    v_gate := upper(coalesce(v_dim->>'gate', ''));
    v_hold := coalesce(v_dim->>'hold_code', v_dim->>'dimension', 'PENDING_DETAIL');
    if v_gate not in ('BILLING_READY', 'DISPATCH_READY', 'TRANSPORT_READY') then
      continue;
    end if;
    insert into public.sales_order_governance_pending_tasks (
      order_id, sales_order_draft_id, readiness_gate, hold_code, original_instructions, metadata
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
      )
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
  v_line record; v_qty numeric; v_lines int := 0;
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
    if upper(coalesce(p_metadata->>'readiness_gate', 'FULL')) = 'SO_RECORDABLE' then
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
  PERFORM set_config(
    'app.wa3_promotion_readiness_gate',
    upper(coalesce(p_metadata->>'readiness_gate', 'FULL')),
    true
  );
  UPDATE public.sales_order_drafts d SET status = 'APPROVED_FOR_SO',
    approver_id = p_actor_id, approver_name = p_actor_name, review_notes = p_review_notes,
    updated_by = p_actor_id, updated_at = statement_timestamp() WHERE d.id = p_draft_id;
  PERFORM public.sync_sales_order_governance_pending_tasks_from_draft(v_order_id, p_draft_id);
  INSERT INTO public.sales_order_draft_audit_log(draft_id, action, from_status, to_status, actor_id, actor_name, metadata)
  VALUES (p_draft_id, 'APPROVE', 'UNDER_REVIEW', 'APPROVED_FOR_SO', p_actor_id, p_actor_name,
    coalesce(p_metadata, '{}'::jsonb) || jsonb_build_object('promoted_order_id', v_order_id));
  INSERT INTO public.audit_logs(action_type, module_name, entity_name, entity_id, actor_id, risk_level, new_value)
  VALUES ('WA_DRAFT_PROMOTED_TO_SO', 'WhatsApp', 'orders', v_order_id::text, p_actor_id, 'high', jsonb_build_object('draft_id', p_draft_id));
  PERFORM set_config('app.wa3_promotion_readiness_gate', 'FULL', true);
  RETURN QUERY SELECT p_draft_id, v_order_id, v_order_number, false;
END;
$$;

commit;

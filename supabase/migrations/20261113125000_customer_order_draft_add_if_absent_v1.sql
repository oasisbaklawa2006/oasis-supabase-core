-- Buyer cart: atomic insert-if-absent (additive, no change to existing RPCs).
--
-- Problem: add_customer_order_draft_line_v1 is an UPSERT (ON CONFLICT DO UPDATE SET quantity = excluded.quantity).
-- Buyer "Quick order" and "Reorder" first READ the cart, decide a product is absent, then call the upsert. If another
-- session of the same company adds that product in between, the upsert silently REPLACES the newer quantity with the
-- bulk-add quantity (a stale-read overwrite). The check and the write must be one atomic step in Core.
--
-- This function applies exactly the same authority checks as add_customer_order_draft_line_v1 (auth, approved buyer
-- company, server-resolved price/MOQ/increment/carton rules, per-company advisory lock) but never updates an existing
-- line: when the product is already in the active draft it returns inserted=false and the existing quantity, so the
-- Buyer can tell the customer instead of overwriting.
--
-- Additive: new function only. No table, constraint, grant or existing function is altered.

create or replace function public.add_customer_order_draft_line_if_absent_v1(
  p_product_id uuid,
  p_quantity numeric
)
returns table (
  draft_id uuid,
  line_id uuid,
  inserted boolean,
  existing_quantity numeric,
  readiness_status text,
  readiness_issues jsonb
)
language plpgsql
security definer
set search_path to pg_catalog, public, auth
as $$
declare
  v_uid uuid := auth.uid();
  v_company_id uuid;
  v_draft_id uuid;
  v_auth record;
  v_line_id uuid;
  v_existing_qty numeric;
begin
  if v_uid is null then
    raise exception 'AUTH_REQUIRED: authentication is required' using errcode = '28000';
  end if;

  v_company_id := public.customer_buyer_eligible_company_id();
  if v_company_id is null then
    raise exception 'BUYER_NOT_ELIGIBLE: approved buyer company context is required' using errcode = '42501';
  end if;

  if p_product_id is null or p_quantity is null or p_quantity <= 0 then
    raise exception 'VALIDATION_FAILED: product_id and positive quantity are required';
  end if;

  select * into v_auth from public.customer_resolve_buyer_product_authority_v1(v_company_id, p_product_id);
  if not coalesce(v_auth.is_available, false) then
    raise exception 'PRODUCT_UNAVAILABLE: product % is not available for this buyer', p_product_id;
  end if;

  if not public.customer_validate_order_quantity_v1(
    p_quantity, v_auth.minimum_order_quantity, v_auth.order_increment, v_auth.min_carton_qty
  ) then
    raise exception 'QUANTITY_RULE_VIOLATION: quantity does not satisfy MOQ/increment/carton rules for product %', p_product_id;
  end if;

  -- Same per-company lock as add/update/remove/clear: serialises every cart mutation of one company.
  perform pg_advisory_xact_lock(
    hashtextextended('customer_draft:' || v_company_id::text, 0)
  );

  select d.id into v_draft_id
  from public.customer_order_drafts d
  where d.company_id = v_company_id and d.status = 'active'
  for update;

  if v_draft_id is null then
    insert into public.customer_order_drafts (company_id, created_by, status)
    values (v_company_id, v_uid, 'active')
    returning id into v_draft_id;
    perform public.customer_order_draft_audit_v1(v_draft_id, v_company_id, v_uid, 'CREATE', '{}'::jsonb);
  end if;

  insert into public.customer_order_draft_lines (
    draft_id, product_id, quantity,
    unit_price_snapshot, currency_snapshot, uom_snapshot,
    gst_rate_snapshot, tax_inclusive_snapshot,
    minimum_order_quantity_snapshot, minimum_order_uom_snapshot,
    order_increment_snapshot, order_increment_uom_snapshot,
    min_carton_qty_snapshot, sku_snapshot, product_name_snapshot
  ) values (
    v_draft_id, p_product_id, p_quantity,
    v_auth.selling_price, v_auth.currency, v_auth.uom,
    v_auth.gst_rate, v_auth.tax_inclusive,
    v_auth.minimum_order_quantity, v_auth.minimum_order_uom,
    v_auth.order_increment, v_auth.order_increment_uom,
    v_auth.min_carton_qty, v_auth.sku, v_auth.product_name
  )
  on conflict on constraint uq_customer_order_draft_lines_one_product_per_draft
  do nothing
  returning id into v_line_id;

  if v_line_id is not null then
    perform public.customer_order_draft_audit_v1(
      v_draft_id, v_company_id, v_uid, 'ADD_LINE',
      jsonb_build_object('line_id', v_line_id, 'product_id', p_product_id, 'quantity', p_quantity, 'mode', 'if_absent'));
    perform public.customer_recompute_draft_readiness_v1(v_draft_id);
    return query
    select d.id, v_line_id, true, p_quantity, d.readiness_status, d.readiness_issues
    from public.customer_order_drafts d where d.id = v_draft_id;
    return;
  end if;

  -- Already present: report it, change nothing.
  select l.id, l.quantity into v_line_id, v_existing_qty
  from public.customer_order_draft_lines l
  where l.draft_id = v_draft_id and l.product_id = p_product_id;

  return query
  select d.id, v_line_id, false, v_existing_qty, d.readiness_status, d.readiness_issues
  from public.customer_order_drafts d where d.id = v_draft_id;
end;
$$;

comment on function public.add_customer_order_draft_line_if_absent_v1(uuid, numeric) is
  'Atomic insert-if-absent for a buyer draft line. Never overwrites an existing line; returns inserted=false with the existing quantity. Same authority checks and lock as add_customer_order_draft_line_v1.';

revoke all on function public.add_customer_order_draft_line_if_absent_v1(uuid, numeric) from public, anon;
grant execute on function public.add_customer_order_draft_line_if_absent_v1(uuid, numeric) to authenticated, service_role;

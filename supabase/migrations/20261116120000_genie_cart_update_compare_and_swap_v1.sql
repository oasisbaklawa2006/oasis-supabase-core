-- Additive Genie compare-and-swap quantity update: Core #536 / Buyer #81.
-- Preserve update_customer_order_draft_line_v1 unchanged for existing consumers.
-- This function takes the SAME per-company advisory lock as all Cart writers
-- BEFORE row lock and compares the current product/quantity atomically.
create function public.update_customer_order_draft_line_genie_if_quantity_v1(
  p_line_id uuid,
  p_product_id uuid,
  p_expected_quantity numeric,
  p_quantity numeric
)
returns table (
  draft_id uuid,
  line_id uuid,
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
  v_line public.customer_order_draft_lines%rowtype;
begin
  if v_uid is null then
    raise exception 'AUTH_REQUIRED: authentication is required' using errcode = '28000';
  end if;
  v_company_id := public.customer_buyer_eligible_company_id();
  if v_company_id is null then
    raise exception 'BUYER_NOT_ELIGIBLE: approved buyer company context is required' using errcode = '42501';
  end if;
  if p_line_id is null or p_product_id is null or
     p_expected_quantity is null or p_quantity is null or
     p_expected_quantity <= 0 or p_quantity <= 0 or
     p_expected_quantity = 'NaN'::numeric or p_quantity = 'NaN'::numeric then
    raise exception 'VALIDATION_FAILED: line, product and positive quantities are required';
  end if;

  -- Atomicity with the other Cart mutations: under this transaction's company
  -- advisory lock, no v1 update/remove/clear/upsert or Genie insert can modify
  -- the shared Cart. Use the same lock order as the v1 implementation.
  perform pg_advisory_xact_lock(hashtextextended('customer_draft:' || v_company_id::text, 0));

  select l.* into v_line
  from public.customer_order_draft_lines l
  join public.customer_order_drafts d on d.id = l.draft_id
  where l.id = p_line_id
    and d.company_id = v_company_id
    and d.status = 'active'
  for update of l;
  if not found then
    raise exception 'LINE_NOT_FOUND: Cart line not mutable for this buyer' using errcode = 'P0002';
  end if;
  if v_line.product_id is distinct from p_product_id or
     v_line.quantity is distinct from p_expected_quantity then
    raise exception 'GENIE_CART_STALE: product or quantity changed; reconcile in Cart'
      using errcode = '40001';
  end if;

  -- Delegate all price, MOQ, increment, stock/availability, audit and readiness
  -- rules to the already reviewed v1 function while the locks remain held.
  return query
  select v.draft_id, v.line_id, v.readiness_status, v.readiness_issues
  from public.update_customer_order_draft_line_v1(p_line_id, p_quantity) v;
end;
$$;

comment on function public.update_customer_order_draft_line_genie_if_quantity_v1(uuid,uuid,numeric,numeric) is
  'Genie protected atomic compare-and-swap: reject concurrent Cart changes before existing v1 update rules; never overwrite without expected quantity.';
revoke all on function public.update_customer_order_draft_line_genie_if_quantity_v1(uuid,uuid,numeric,numeric)
  from public, anon;
grant execute on function public.update_customer_order_draft_line_genie_if_quantity_v1(uuid,uuid,numeric,numeric)
  to authenticated, service_role;

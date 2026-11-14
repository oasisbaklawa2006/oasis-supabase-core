-- Buyer cart: deterministic lock order for line mutations (companion to 20261113125000_customer_order_draft_add_if_absent_v1).
--
-- Problem (reproduced on the Supabase Postgres 17 image, see docs/cart-insert-if-absent/README.md): the cart RPCs take locks in two
-- different orders.
--   add_customer_order_draft_line_v1, add_customer_order_draft_line_if_absent_v1, clear_customer_order_draft_v1 :
--       shared customer_draft:<company> advisory lock  ->  draft row (FOR UPDATE)  ->  line rows
--   submit_customer_order_v1 instead uses a separate customer_checkout:<company>:<idempotency_key> advisory lock;
--   get_customer_order_draft_v1 does not FOR UPDATE-lock the draft row and is not part of this mutation-lock guarantee.
--   remove_customer_order_draft_line_v1 and update_customer_order_draft_line_v1 :
--       line row (FOR UPDATE)  ->  draft row  (audit FK key-share, then readiness recompute FOR UPDATE)   -- no advisory lock
-- Two concurrent calls of the two families on the same company therefore wait on each other's tuple locks and PostgreSQL aborts one
-- with SQLSTATE 40P01. This already exists between the RELEASED add/clear and remove/update RPCs (it is not introduced by the
-- insert-if-absent function); a 24-client mixed workload on one company produced ~7% deadlock failures with released functions only.
--
-- Fix (smallest change): remove_ and update_customer_order_draft_line_v1 take the SAME per-company advisory lock, with the same key,
-- before they lock any line or draft row. Every cart mutation then serialises per company on one lock first, so no lock cycle
-- between line and draft rows can form. Nothing else changes: bodies are otherwise byte-identical to the released definitions
-- (production hashes verified 2026-11-02), signatures, SECURITY DEFINER, search_path, owner and grants are unchanged.
--
-- Reversible: the rollback file restores the released definitions verbatim.
-- Cost: line mutations for ONE company now queue behind each other (they already did for add/clear/submit); other companies are unaffected.

CREATE OR REPLACE FUNCTION public.remove_customer_order_draft_line_v1(p_line_id uuid)
 RETURNS TABLE(draft_id uuid, readiness_status text, readiness_issues jsonb)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'auth'
AS $function$
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

  -- Deterministic lock order (Core #477): the per-company cart lock is taken BEFORE any line or draft-row lock, as in add/clear.
  perform pg_advisory_xact_lock(hashtextextended('customer_draft:' || v_company_id::text, 0));

  select l.* into v_line
  from public.customer_order_draft_lines l
  join public.customer_order_drafts d on d.id = l.draft_id
  where l.id = p_line_id
    and d.company_id = v_company_id
    and d.status = 'active'
  for update of l;

  if not found then
    raise exception 'LINE_NOT_FOUND: draft line % is not mutable for this buyer', p_line_id using errcode = 'P0002';
  end if;

  delete from public.customer_order_draft_lines where id = p_line_id;

  perform public.customer_order_draft_audit_v1(
    v_line.draft_id, v_company_id, v_uid, 'REMOVE_LINE',
    jsonb_build_object('line_id', p_line_id, 'product_id', v_line.product_id));
  perform public.customer_recompute_draft_readiness_v1(v_line.draft_id);

  return query
  select d.id, d.readiness_status, d.readiness_issues
  from public.customer_order_drafts d where d.id = v_line.draft_id;
end;
$function$
;;

CREATE OR REPLACE FUNCTION public.update_customer_order_draft_line_v1(p_line_id uuid, p_quantity numeric)
 RETURNS TABLE(draft_id uuid, line_id uuid, readiness_status text, readiness_issues jsonb)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'auth'
AS $function$
declare
  v_uid uuid := auth.uid();
  v_company_id uuid;
  v_line public.customer_order_draft_lines%rowtype;
  v_auth record;
begin
  if v_uid is null then
    raise exception 'AUTH_REQUIRED: authentication is required' using errcode = '28000';
  end if;

  v_company_id := public.customer_buyer_eligible_company_id();
  if v_company_id is null then
    raise exception 'BUYER_NOT_ELIGIBLE: approved buyer company context is required' using errcode = '42501';
  end if;

  if p_line_id is null or p_quantity is null or p_quantity <= 0 then
    raise exception 'VALIDATION_FAILED: line_id and positive quantity are required';
  end if;

  -- Deterministic lock order (Core #477): the per-company cart lock is taken BEFORE any line or draft-row lock, as in add/clear.
  perform pg_advisory_xact_lock(hashtextextended('customer_draft:' || v_company_id::text, 0));

  select l.* into v_line
  from public.customer_order_draft_lines l
  join public.customer_order_drafts d on d.id = l.draft_id
  where l.id = p_line_id
    and d.company_id = v_company_id
    and d.status = 'active'
  for update of l;

  if not found then
    raise exception 'LINE_NOT_FOUND: draft line % is not mutable for this buyer', p_line_id using errcode = 'P0002';
  end if;

  select * into v_auth from public.customer_resolve_buyer_product_authority_v1(v_company_id, v_line.product_id);
  if not coalesce(v_auth.is_available, false) then
    raise exception 'PRODUCT_UNAVAILABLE: product % is not available for this buyer', v_line.product_id;
  end if;

  if not public.customer_validate_order_quantity_v1(
    p_quantity, v_auth.minimum_order_quantity, v_auth.order_increment, v_auth.min_carton_qty
  ) then
    raise exception 'QUANTITY_RULE_VIOLATION: quantity does not satisfy MOQ/increment/carton rules';
  end if;

  update public.customer_order_draft_lines
  set quantity = p_quantity,
      unit_price_snapshot = v_auth.selling_price,
      currency_snapshot = v_auth.currency,
      uom_snapshot = v_auth.uom,
      gst_rate_snapshot = v_auth.gst_rate,
      tax_inclusive_snapshot = v_auth.tax_inclusive,
      minimum_order_quantity_snapshot = v_auth.minimum_order_quantity,
      minimum_order_uom_snapshot = v_auth.minimum_order_uom,
      order_increment_snapshot = v_auth.order_increment,
      order_increment_uom_snapshot = v_auth.order_increment_uom,
      min_carton_qty_snapshot = v_auth.min_carton_qty,
      sku_snapshot = v_auth.sku,
      product_name_snapshot = v_auth.product_name,
      updated_at = now()
  where id = p_line_id;

  perform public.customer_order_draft_audit_v1(
    v_line.draft_id, v_company_id, v_uid, 'UPDATE_LINE',
    jsonb_build_object('line_id', p_line_id, 'quantity', p_quantity));
  perform public.customer_recompute_draft_readiness_v1(v_line.draft_id);

  return query
  select d.id, p_line_id, d.readiness_status, d.readiness_issues
  from public.customer_order_drafts d where d.id = v_line.draft_id;
end;
$function$
;;

revoke all on function public.remove_customer_order_draft_line_v1(uuid) from public, anon;
grant execute on function public.remove_customer_order_draft_line_v1(uuid) to authenticated, service_role;
revoke all on function public.update_customer_order_draft_line_v1(uuid, numeric) from public, anon;
grant execute on function public.update_customer_order_draft_line_v1(uuid, numeric) to authenticated, service_role;

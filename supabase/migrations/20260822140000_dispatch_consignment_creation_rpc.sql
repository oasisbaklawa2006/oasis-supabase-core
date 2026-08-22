-- Owner directive (Dispatch migration approach): treat the existing legacy
-- Dispatch UI (dispatches/dispatch_cartons, still fully live in Central) as
-- the migration SOURCE, not something to rewrite wholesale. The mandated
-- process is: map every legacy Dispatch action to the existing b2b_dispatch_*
-- state machine, add a governed RPC only where a real command is genuinely
-- missing, migrate one operation at a time with regression tests proving
-- parity, and never delete a legacy path until its replacement is proven
-- reachable and complete. No shared schema reinterpretation, no new role
-- proliferation, no production mutation.
--
-- Inventory finding that drives this migration: the entire b2b_dispatch_*
-- schema (added 20260804103000) has zero RPCs and zero client callers. Every
-- table downstream of b2b_dispatch_consignments (shipments, cartons, handoffs,
-- releases, exceptions...) is unreachable because nothing can create the
-- consignment row those tables hang off of -- there is no "start a dispatch
-- for this order" command at all. That is the first, most fundamental
-- missing command, and every other Dispatch action-migration in this
-- programme is blocked until it exists. This migration adds exactly that one
-- command and nothing else -- no client wiring, no legacy table touched, no
-- legacy path disabled. main stays fully coherent: this is pure additive
-- capability that nothing currently depends on.
--
-- Domain-model check performed before writing this (per the standing
-- directive to STOP and establish the correct model before any schema
-- work): b2b_dispatch_* is scoped to orders with a company (companies-linked,
-- i.e. this business's wholesale/B2B order model). orders.company_id is
-- nullable at the column level, but the existing RLS policy "Buyers insert
-- own orders" already requires company_id IS NOT NULL for buyer-created
-- orders, and every legacy Dispatch admin screen joins orders to companies
-- as a matter of course. There is no evidence of a distinct "retail, no
-- company" order class flowing through Dispatch today. This RPC still
-- guards explicitly: an order with a NULL company_id is rejected with a
-- clear error rather than silently mis-modelled, so any edge case is
-- surfaced, not swallowed.
--
-- Quantity-oversubscription guard: because the legacy flow allows partial
-- dispatch legs (one dispatch-leg record per partial shipment, potentially
-- several per order), this RPC preserves that exact capability -- callers
-- pass an explicit per-line selected_qty (mirroring what an operator picks
-- in the legacy UI today) -- and it fail-closes if the sum of all
-- non-cancelled consignments' selected_qty for an order_item would exceed
-- the item's ordered quantity, preventing double-booking the same units
-- across two dispatch legs/consignments.

CREATE OR REPLACE FUNCTION public.create_b2b_dispatch_consignment(
  p_order_id uuid,
  p_dispatch_mode text,
  p_lines jsonb,
  p_correlation_id text
)
RETURNS public.b2b_dispatch_consignments
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_actor_id uuid := auth.uid();
  v_order public.orders%ROWTYPE;
  v_existing public.b2b_dispatch_consignments%ROWTYPE;
  v_consignment public.b2b_dispatch_consignments%ROWTYPE;
  v_next_sequence integer;
  v_consignment_number text;
  v_line jsonb;
  v_order_item public.order_items%ROWTYPE;
  v_selected_qty numeric;
  v_already_selected numeric;
  v_uom text;
  v_product_code text;
BEGIN
  IF v_actor_id IS NULL OR NOT public.can_manage_b2b_dispatch(v_actor_id) THEN
    RAISE EXCEPTION 'Not authorised to create a dispatch consignment' USING ERRCODE = '42501';
  END IF;
  IF nullif(btrim(p_correlation_id), '') IS NULL THEN
    RAISE EXCEPTION 'A correlation id is required';
  END IF;
  IF nullif(btrim(p_dispatch_mode), '') IS NULL THEN
    RAISE EXCEPTION 'A dispatch mode is required';
  END IF;
  IF p_lines IS NULL OR jsonb_typeof(p_lines) <> 'array' OR jsonb_array_length(p_lines) = 0 THEN
    RAISE EXCEPTION 'At least one dispatch line is required';
  END IF;

  -- Idempotent by correlation_id: a retried/duplicated call returns the same
  -- consignment rather than creating a second one or erroring.
  SELECT * INTO v_existing FROM public.b2b_dispatch_consignments WHERE correlation_id = p_correlation_id;
  IF FOUND THEN
    RETURN v_existing;
  END IF;

  SELECT * INTO v_order FROM public.orders WHERE id = p_order_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Order not found';
  END IF;
  IF v_order.company_id IS NULL THEN
    RAISE EXCEPTION 'Order % has no company_id and is not eligible for the governed B2B dispatch flow', p_order_id USING ERRCODE = '42501';
  END IF;

  SELECT coalesce(max(sequence_number), 0) + 1 INTO v_next_sequence
  FROM public.b2b_dispatch_consignments
  WHERE order_id = p_order_id;

  v_consignment_number := v_order.order_number || '-DC-' || lpad(v_next_sequence::text, 2, '0');

  INSERT INTO public.b2b_dispatch_consignments (
    consignment_number, order_id, sequence_number, dispatch_mode, created_by, correlation_id
  ) VALUES (
    v_consignment_number, p_order_id, v_next_sequence, p_dispatch_mode, v_actor_id, p_correlation_id
  )
  RETURNING * INTO v_consignment;

  FOR v_line IN SELECT * FROM jsonb_array_elements(p_lines)
  LOOP
    IF nullif(v_line ->> 'order_item_id', '') IS NULL THEN
      RAISE EXCEPTION 'order_item_id is required for every dispatch line';
    END IF;

    SELECT * INTO v_order_item
    FROM public.order_items
    WHERE id = (v_line ->> 'order_item_id')::uuid AND order_id = p_order_id
    FOR UPDATE;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'order_item % does not belong to order %', v_line ->> 'order_item_id', p_order_id;
    END IF;

    v_selected_qty := nullif(v_line ->> 'selected_qty', '')::numeric;
    IF v_selected_qty IS NULL OR v_selected_qty <= 0 THEN
      RAISE EXCEPTION 'selected_qty must be a positive number for order_item %', v_order_item.id;
    END IF;

    SELECT coalesce(sum(cl.selected_qty), 0) INTO v_already_selected
    FROM public.b2b_dispatch_consignment_lines cl
    JOIN public.b2b_dispatch_consignments c2 ON c2.id = cl.consignment_id
    WHERE cl.order_item_id = v_order_item.id AND c2.status <> 'cancelled';

    IF v_already_selected + v_selected_qty > v_order_item.quantity + 0.0001 THEN
      RAISE EXCEPTION 'selected_qty % for order_item % would exceed the remaining undispatched quantity (% of % already committed to other dispatch legs)',
        v_selected_qty, v_order_item.id, v_already_selected, v_order_item.quantity;
    END IF;

    v_uom := coalesce(nullif(btrim(v_line ->> 'uom'), ''), nullif(btrim(v_order_item.carton_type), ''), 'unit');

    SELECT sku INTO v_product_code FROM public.products WHERE id = v_order_item.product_id;
    IF v_product_code IS NULL THEN
      RAISE EXCEPTION 'Product % referenced by order_item % was not found', v_order_item.product_id, v_order_item.id;
    END IF;

    INSERT INTO public.b2b_dispatch_consignment_lines (
      consignment_id, order_item_id, product_id, product_code, uom, original_order_qty, selected_qty
    ) VALUES (
      v_consignment.id, v_order_item.id, v_order_item.product_id, v_product_code, v_uom, v_order_item.quantity, v_selected_qty
    );
  END LOOP;

  RETURN v_consignment;
END;
$$;

COMMENT ON FUNCTION public.create_b2b_dispatch_consignment(uuid, text, jsonb, text) IS
  'Foundational governed command that starts a b2b_dispatch_* consignment for an order -- the missing entry point every downstream b2b_dispatch_* table (shipments, cartons, releases...) depends on. p_lines is a jsonb array of {order_item_id, selected_qty, uom?}, mirroring the per-leg line selection the legacy Dispatch UI already lets an operator make. Fail-closes on: unauthorised caller, an order with no company_id, an order_item not belonging to the order, a non-positive selected_qty, or a selected_qty that would oversubscribe the order_item across consignments. Idempotent by correlation_id.';

REVOKE ALL ON FUNCTION public.create_b2b_dispatch_consignment(uuid, text, jsonb, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.create_b2b_dispatch_consignment(uuid, text, jsonb, text) TO authenticated;

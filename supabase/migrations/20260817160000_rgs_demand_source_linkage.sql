-- =================================================================================
-- RGS demand-source linkage: P&A / outlet / internal demand into
-- reserve_rgs_stock. Prior to this migration `reserve_rgs_stock` only
-- accepted a customer sales order as its demand source (order_id NOT NULL);
-- the reconciliation matrix flagged this as a real gap (section H-K) --
-- `issue_rgs_stock` already accepted pna/outlet/internal as issue
-- *destinations*, but nothing could *reserve* stock against those channels
-- as a demand source in the first place.
--
-- This is additive and backward compatible: existing B2B/order_items
-- reservations are unaffected (demand_source_type defaults to 'b2b', and
-- order_id stays required for that source type via a CHECK constraint).
-- =================================================================================

ALTER TABLE public.inventory_reservations
  ADD COLUMN IF NOT EXISTS demand_source_type text NOT NULL DEFAULT 'b2b',
  ADD COLUMN IF NOT EXISTS demand_reference text;

ALTER TABLE public.inventory_reservations
  ALTER COLUMN order_id DROP NOT NULL;

ALTER TABLE public.inventory_reservations
  DROP CONSTRAINT IF EXISTS inventory_reservations_demand_source_type_check;
ALTER TABLE public.inventory_reservations
  ADD CONSTRAINT inventory_reservations_demand_source_type_check
  CHECK (demand_source_type IN ('b2b', 'pna', 'outlet', 'internal'));

ALTER TABLE public.inventory_reservations
  DROP CONSTRAINT IF EXISTS inventory_reservations_order_id_required_for_b2b;
ALTER TABLE public.inventory_reservations
  ADD CONSTRAINT inventory_reservations_order_id_required_for_b2b
  CHECK (demand_source_type <> 'b2b' OR order_id IS NOT NULL);

COMMENT ON COLUMN public.inventory_reservations.demand_source_type IS
  'Demand channel this reservation was raised for: b2b (sales order, order_id required), pna, outlet, internal.';
COMMENT ON COLUMN public.inventory_reservations.demand_reference IS
  'Free-text/opaque reference into the demand_source_type channel (e.g. a P&A plan id, outlet code, internal requisition number) when there is no order_id to anchor to.';

-- ---------------------------------------------------------------------------------
-- reserve_rgs_stock must be dropped and recreated (not CREATE OR REPLACE) --
-- appending new parameters to an existing function creates an ambiguous
-- overload rather than replacing it, per the lesson from
-- 20260817140000_rgs_department_execution_metadata.sql.
-- ---------------------------------------------------------------------------------
DROP FUNCTION IF EXISTS public.reserve_rgs_stock(text, uuid, uuid, text, numeric, text, text, text, text, uuid, uuid);

CREATE FUNCTION public.reserve_rgs_stock(
  p_reservation_number text,
  p_order_id uuid,
  p_product_id uuid,
  p_sku text,
  p_requested_qty numeric,
  p_source_department text,
  p_correlation_id text,
  p_priority text DEFAULT 'normal',
  p_location_code text DEFAULT 'FINISHED_GOODS',
  p_queue_item_id uuid DEFAULT NULL,
  p_customer_id uuid DEFAULT NULL,
  p_demand_source_type text DEFAULT 'b2b',
  p_demand_reference text DEFAULT NULL
)
RETURNS public.inventory_reservations
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_actor_id uuid := auth.uid();
  v_existing public.inventory_reservations%ROWTYPE;
  v_balance record;
  v_reserve_qty numeric;
  v_status text;
BEGIN
  IF v_actor_id IS NULL OR NOT public.is_inventory_manage_role((SELECT role FROM public.users WHERE id = v_actor_id))
     AND NOT public.is_inventory_receive_role((SELECT role FROM public.users WHERE id = v_actor_id)) THEN
    RAISE EXCEPTION 'Not authorised to reserve RGS stock' USING ERRCODE = '42501';
  END IF;
  IF p_requested_qty IS NULL OR p_requested_qty <= 0 THEN
    RAISE EXCEPTION 'Requested quantity must be positive';
  END IF;
  IF nullif(btrim(p_correlation_id), '') IS NULL THEN
    RAISE EXCEPTION 'A correlation id is required';
  END IF;
  IF p_demand_source_type NOT IN ('b2b', 'pna', 'outlet', 'internal') THEN
    RAISE EXCEPTION 'Unknown demand source type %', p_demand_source_type;
  END IF;
  IF p_demand_source_type = 'b2b' AND p_order_id IS NULL THEN
    RAISE EXCEPTION 'order_id is required for a b2b demand source';
  END IF;
  IF p_demand_source_type <> 'b2b' AND p_order_id IS NOT NULL THEN
    RAISE EXCEPTION 'order_id must be null for a non-b2b demand source; use p_demand_reference instead';
  END IF;

  -- Idempotent replay: a retried reservation request with the same
  -- correlation id returns the reservation already created by it.
  SELECT * INTO v_existing FROM public.inventory_reservations WHERE correlation_id = p_correlation_id;
  IF FOUND THEN
    RETURN v_existing;
  END IF;

  PERFORM pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(p_product_id::text || ':' || p_sku || ':' || p_location_code, 0)
  );

  SELECT * INTO v_balance
  FROM public.inventory_stock_balances
  WHERE product_id = p_product_id AND sku = p_sku AND location_code = p_location_code
  FOR UPDATE;

  v_reserve_qty := least(p_requested_qty, coalesce(v_balance.available_qty, 0));

  IF v_reserve_qty > 0 THEN
    IF FOUND THEN
      UPDATE public.inventory_stock_balances
      SET available_qty = available_qty - v_reserve_qty,
          reserved_qty = reserved_qty + v_reserve_qty,
          version = version + 1,
          updated_at = now()
      WHERE product_id = p_product_id AND sku = p_sku AND location_code = p_location_code;
    ELSE
      RAISE EXCEPTION 'Stock balance disappeared during reservation for % / %', p_product_id, p_sku USING ERRCODE = '40001';
    END IF;
  END IF;

  v_status := CASE
    WHEN v_reserve_qty >= p_requested_qty THEN 'reserved'
    WHEN v_reserve_qty > 0 THEN 'partially_reserved'
    ELSE 'pending'
  END;

  INSERT INTO public.inventory_reservations (
    reservation_number, order_id, queue_item_id, customer_id, product_id, sku,
    requested_qty, reserved_qty, reservation_status, reservation_priority,
    source_department, location_code, reserved_by, correlation_id,
    demand_source_type, demand_reference
  ) VALUES (
    p_reservation_number, p_order_id, p_queue_item_id, p_customer_id, p_product_id, p_sku,
    p_requested_qty, v_reserve_qty, v_status, coalesce(p_priority, 'normal'),
    p_source_department, p_location_code, v_actor_id, p_correlation_id,
    p_demand_source_type, p_demand_reference
  )
  RETURNING * INTO v_existing;

  IF v_reserve_qty > 0 THEN
    INSERT INTO public.inventory_movements (
      movement_type, reservation_id, product_id, sku, quantity, source_location,
      actor_id, correlation_id, metadata
    ) VALUES (
      'reservation_created', v_existing.id, p_product_id, p_sku, v_reserve_qty, p_location_code,
      v_actor_id, p_correlation_id, jsonb_build_object('requested_qty', p_requested_qty, 'demand_source_type', p_demand_source_type)
    );
  END IF;

  RETURN v_existing;
END;
$$;

COMMENT ON FUNCTION public.reserve_rgs_stock IS
  'Governed RGS demand intake. Accepts b2b (order_id required), pna, outlet, or internal (order_id must be null, use p_demand_reference) as the demand source. Idempotent by correlation_id.';

REVOKE ALL ON FUNCTION public.reserve_rgs_stock(text, uuid, uuid, text, numeric, text, text, text, text, uuid, uuid, text, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.reserve_rgs_stock(text, uuid, uuid, text, numeric, text, text, text, text, uuid, uuid, text, text) TO authenticated;

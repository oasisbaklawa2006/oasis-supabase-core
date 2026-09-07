-- MACRO INVENTORY + FACTORY RUNTIME completion: lot lifecycle closure, store
-- isolation, lineage, quality-hold wiring, command-facts surfacing.
-- Extends 20260907143000 without a parallel stock ledger.

SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '120s';

-- =================================================================================
-- 1. Schema: receipt lineage + allocation entity constraint
-- =================================================================================

ALTER TABLE public.b2b_inventory_receipt_lines
  ADD COLUMN IF NOT EXISTS manufactured_date date NULL,
  ADD COLUMN IF NOT EXISTS best_before_date date NULL;

ALTER TABLE public.inventory_reservation_allocations
  DROP CONSTRAINT IF EXISTS inventory_reservation_allocations_entity_type_check;
ALTER TABLE public.inventory_reservation_allocations
  ADD CONSTRAINT inventory_reservation_allocations_entity_type_check
  CHECK (inventory_entity_type = 'lot_position');

ALTER TABLE public.inventory_movements DROP CONSTRAINT IF EXISTS inventory_movements_type_check;
ALTER TABLE public.inventory_movements ADD CONSTRAINT inventory_movements_type_check
  CHECK (movement_type = ANY (ARRAY[
    'reservation_created', 'reservation_adjusted', 'reservation_released', 'reservation_expired',
    'reservation_fulfilled', 'inventory_hold', 'inventory_unhold',
    'dispatch_consumption_confirmed', 'dispatch_consumption_reversed',
    'stock_variance_recorded', 'stock_quarantined', 'stock_quarantine_released',
    'supplier_receipt_accepted', 'production_receipt_accepted', 'opening_balance_accepted',
    'issued_to_production', 'issued_to_assembly', 'returned_from_assembly',
    'assembly_output_accepted', 'dispatch_issue_confirmed', 'correction_in', 'correction_out',
    'stock_picked', 'stock_unpicked', 'stock_issued', 'assembly_handover_acknowledged',
    'assembly_consumption_recorded', 'assembly_3pgs_requirement_fulfilled',
    'lot_position_posted', 'lot_allocated', 'lot_allocation_released', 'lot_picked',
    'lot_position_reversed', 'lot_consumed'
  ]));

CREATE TABLE IF NOT EXISTS public.inventory_lot_exception_events (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  lot_position_id uuid NOT NULL REFERENCES public.inventory_lot_positions(id) ON DELETE RESTRICT,
  location_code text NOT NULL,
  product_id uuid NOT NULL REFERENCES public.products(id) ON DELETE RESTRICT,
  sku text NOT NULL,
  action text NOT NULL CHECK (action IN ('quarantine','release_quarantine','damage_writeoff','expire_writeoff')),
  quantity numeric NOT NULL CHECK (quantity > 0),
  reason text NOT NULL CHECK (nullif(btrim(reason), '') IS NOT NULL),
  actor_id uuid NOT NULL REFERENCES public.users(id) ON DELETE RESTRICT,
  correlation_id text NOT NULL UNIQUE,
  created_at timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE public.inventory_lot_exception_events ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Staff read lot exception events" ON public.inventory_lot_exception_events
  FOR SELECT TO authenticated USING (public.is_internal_staff((SELECT auth.uid())));
REVOKE ALL ON public.inventory_lot_exception_events FROM anon;
REVOKE INSERT, UPDATE, DELETE ON public.inventory_lot_exception_events FROM authenticated;
GRANT SELECT ON public.inventory_lot_exception_events TO authenticated;

-- Store-scoped lot position reads.
DROP POLICY IF EXISTS "Staff read lot positions" ON public.inventory_lot_positions;
CREATE POLICY "Staff read lot positions" ON public.inventory_lot_positions
  FOR SELECT TO authenticated
  USING (
    public.is_internal_staff((SELECT auth.uid()))
    AND public.can_access_b2b_inventory_store((SELECT auth.uid()), location_code, 'receive')
  );

-- =================================================================================
-- 2. Helpers: store access + lot-tracked SKU detection
-- =================================================================================

CREATE OR REPLACE FUNCTION public.assert_inventory_store_mutation_access(
  p_actor uuid,
  p_store_code text
)
RETURNS void
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_role text;
BEGIN
  IF p_actor IS NULL THEN
    RAISE EXCEPTION 'Not authorised' USING ERRCODE = '42501';
  END IF;

  IF public.can_access_b2b_inventory_store(p_actor, p_store_code, 'manage')
     OR public.can_access_b2b_inventory_store(p_actor, p_store_code, 'receive') THEN
    RETURN;
  END IF;

  SELECT role INTO v_role FROM public.users WHERE id = p_actor;

  -- Inventory/RGS roles without explicit store assignments retain global authority.
  IF (public.is_inventory_manage_role(v_role) OR public.is_inventory_receive_role(v_role))
     AND NOT EXISTS (
       SELECT 1 FROM public.b2b_inventory_store_assignments a WHERE a.user_id = p_actor
     ) THEN
    RETURN;
  END IF;

  RAISE EXCEPTION 'Not authorised for store %', p_store_code USING ERRCODE = '42501';
END;
$$;

CREATE OR REPLACE FUNCTION public.inventory_lot_positions_exist(
  p_product_id uuid,
  p_sku text,
  p_location_code text
)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.inventory_lot_positions lp
    WHERE lp.product_id = p_product_id
      AND lp.sku = p_sku
      AND lp.location_code = p_location_code
      AND lp.position_status <> 'depleted'
      AND (lp.available_qty + lp.reserved_qty + lp.picked_qty) > 0
  );
$$;

CREATE OR REPLACE FUNCTION public.assert_lot_allocation_covers_qty(
  p_reservation_id uuid,
  p_required_qty numeric,
  p_mode text
)
RETURNS void
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_reservation public.inventory_reservations%ROWTYPE;
  v_active numeric;
  v_fulfilled numeric;
BEGIN
  SELECT * INTO v_reservation FROM public.inventory_reservations WHERE id = p_reservation_id;
  IF NOT FOUND THEN RETURN; END IF;

  IF NOT public.inventory_lot_positions_exist(
    v_reservation.product_id, v_reservation.sku, v_reservation.location_code
  ) THEN
    RETURN;
  END IF;

  SELECT coalesce(sum(allocated_qty), 0) INTO v_active
  FROM public.inventory_reservation_allocations
  WHERE reservation_id = p_reservation_id
    AND inventory_entity_type = 'lot_position'
    AND allocation_status = 'active';

  SELECT coalesce(sum(allocated_qty), 0) INTO v_fulfilled
  FROM public.inventory_reservation_allocations
  WHERE reservation_id = p_reservation_id
    AND inventory_entity_type = 'lot_position'
    AND allocation_status = 'fulfilled';

  IF p_mode = 'pick' AND v_active < p_required_qty THEN
    RAISE EXCEPTION 'Lot-tracked stock requires active lot allocations covering pick quantity';
  END IF;
  IF p_mode = 'issue' AND (v_active + v_fulfilled) < p_required_qty THEN
    RAISE EXCEPTION 'Lot-tracked stock requires lot allocations covering issue quantity';
  END IF;
END;
$$;

-- =================================================================================
-- 3. Lot lifecycle: release, reverse, consume, exception
-- =================================================================================

CREATE OR REPLACE FUNCTION public.release_lot_allocations_from_reservation(
  p_reservation_id uuid,
  p_release_qty numeric,
  p_correlation_id text
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_alloc record;
  v_remaining numeric := p_release_qty;
  v_take numeric;
BEGIN
  IF EXISTS (
    SELECT 1 FROM public.inventory_movements
    WHERE correlation_id = p_correlation_id AND movement_type = 'lot_allocation_released'
  ) THEN
    RETURN;
  END IF;

  FOR v_alloc IN
    SELECT a.*, lp.batch_lot, lp.expiry_date, lp.product_id, lp.sku, lp.location_code
    FROM public.inventory_reservation_allocations a
    JOIN public.inventory_lot_positions lp ON lp.id = a.inventory_entity_id
    WHERE a.reservation_id = p_reservation_id
      AND a.inventory_entity_type = 'lot_position'
      AND a.allocation_status = 'active'
    ORDER BY a.allocated_at DESC
  LOOP
    EXIT WHEN v_remaining <= 0;
    v_take := least(v_remaining, v_alloc.allocated_qty);

    UPDATE public.inventory_lot_positions
    SET reserved_qty = reserved_qty - v_take,
        available_qty = available_qty + v_take,
        version = version + 1,
        updated_at = now()
    WHERE id = v_alloc.inventory_entity_id;

    IF v_take >= v_alloc.allocated_qty THEN
      UPDATE public.inventory_reservation_allocations
      SET allocation_status = 'released'
      WHERE id = v_alloc.id;
    ELSE
      UPDATE public.inventory_reservation_allocations
      SET allocated_qty = allocated_qty - v_take
      WHERE id = v_alloc.id;
    END IF;

    INSERT INTO public.inventory_movements (
      movement_type, reservation_id, product_id, sku, quantity,
      destination_location, correlation_id, batch_lot, expiry_date, metadata
    ) VALUES (
      'lot_allocation_released', p_reservation_id, v_alloc.product_id, v_alloc.sku, v_take,
      v_alloc.location_code, p_correlation_id || ':release:' || v_alloc.id,
      v_alloc.batch_lot, v_alloc.expiry_date,
      jsonb_build_object('lot_position_id', v_alloc.inventory_entity_id)
    );

    v_remaining := v_remaining - v_take;
  END LOOP;
END;
$$;

CREATE OR REPLACE FUNCTION public.reverse_grn_inventory_lot_positions(
  p_grn_id uuid,
  p_correlation_id text
)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_lot record;
  v_count integer := 0;
BEGIN
  IF EXISTS (
    SELECT 1 FROM public.inventory_lot_positions
    WHERE grn_id = p_grn_id
      AND (reserved_qty > 0 OR picked_qty > 0)
  ) THEN
    RAISE EXCEPTION 'Cannot reverse GRN while lot positions have reserved or picked quantity';
  END IF;

  FOR v_lot IN
    SELECT * FROM public.inventory_lot_positions
    WHERE grn_id = p_grn_id
      AND position_status <> 'depleted'
    FOR UPDATE
  LOOP
    IF v_lot.available_qty > 0 THEN
      INSERT INTO public.inventory_movements (
        movement_type, product_id, sku, quantity, source_location,
        correlation_id, batch_lot, expiry_date, metadata
      ) VALUES (
        'lot_position_reversed', v_lot.product_id, v_lot.sku, v_lot.available_qty,
        v_lot.location_code, p_correlation_id || ':reverse:' || v_lot.id,
        v_lot.batch_lot, v_lot.expiry_date,
        jsonb_build_object('grn_id', p_grn_id, 'lot_position_id', v_lot.id)
      );
    END IF;

    UPDATE public.inventory_lot_positions
    SET available_qty = 0,
        position_status = 'depleted',
        version = version + 1,
        updated_at = now()
    WHERE id = v_lot.id;

    v_count := v_count + 1;
  END LOOP;

  RETURN v_count;
END;
$$;

CREATE OR REPLACE FUNCTION public.consume_lot_allocations_on_issue(
  p_reservation_id uuid,
  p_issue_qty numeric,
  p_correlation_id text
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_alloc record;
  v_remaining numeric := p_issue_qty;
  v_take numeric;
BEGIN
  IF EXISTS (
    SELECT 1 FROM public.inventory_movements
    WHERE correlation_id = p_correlation_id AND movement_type = 'lot_consumed'
  ) THEN
    RETURN;
  END IF;

  FOR v_alloc IN
    SELECT a.*, lp.batch_lot, lp.expiry_date, lp.product_id, lp.sku, lp.location_code, lp.picked_qty
    FROM public.inventory_reservation_allocations a
    JOIN public.inventory_lot_positions lp ON lp.id = a.inventory_entity_id
    WHERE a.reservation_id = p_reservation_id
      AND a.inventory_entity_type = 'lot_position'
      AND a.allocation_status = 'fulfilled'
      AND lp.picked_qty > 0
    ORDER BY a.allocated_at
  LOOP
    EXIT WHEN v_remaining <= 0;
    v_take := least(v_remaining, v_alloc.picked_qty);

    UPDATE public.inventory_lot_positions
    SET picked_qty = picked_qty - v_take,
        position_status = CASE
          WHEN available_qty = 0 AND reserved_qty = 0 AND picked_qty - v_take <= 0 THEN 'depleted'
          ELSE position_status
        END,
        version = version + 1,
        updated_at = now()
    WHERE id = v_alloc.inventory_entity_id;

    INSERT INTO public.inventory_movements (
      movement_type, reservation_id, product_id, sku, quantity,
      source_location, correlation_id, batch_lot, expiry_date, metadata
    ) VALUES (
      'lot_consumed', p_reservation_id, v_alloc.product_id, v_alloc.sku, v_take,
      v_alloc.location_code, p_correlation_id || ':consume:' || v_alloc.id,
      v_alloc.batch_lot, v_alloc.expiry_date,
      jsonb_build_object('lot_position_id', v_alloc.inventory_entity_id)
    );

    v_remaining := v_remaining - v_take;
  END LOOP;
END;
$$;

CREATE OR REPLACE FUNCTION public.record_inventory_lot_exception(
  p_lot_position_id uuid,
  p_action text,
  p_quantity numeric,
  p_reason text,
  p_correlation_id text
)
RETURNS public.inventory_lot_exception_events
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_actor uuid := auth.uid();
  v_lot public.inventory_lot_positions%ROWTYPE;
  v_event public.inventory_lot_exception_events%ROWTYPE;
BEGIN
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'Not authorised' USING ERRCODE = '42501';
  END IF;
  IF p_action NOT IN ('quarantine','release_quarantine','damage_writeoff','expire_writeoff') THEN
    RAISE EXCEPTION 'Unsupported lot exception action';
  END IF;
  IF p_quantity IS NULL OR p_quantity <= 0 OR nullif(btrim(p_reason), '') IS NULL
     OR nullif(btrim(p_correlation_id), '') IS NULL THEN
    RAISE EXCEPTION 'Quantity, reason and correlation id are required';
  END IF;

  SELECT * INTO v_event FROM public.inventory_lot_exception_events WHERE correlation_id = p_correlation_id;
  IF FOUND THEN RETURN v_event; END IF;

  SELECT * INTO v_lot FROM public.inventory_lot_positions WHERE id = p_lot_position_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Lot position not found'; END IF;

  PERFORM public.assert_inventory_store_mutation_access(v_actor, v_lot.location_code);

  IF p_action = 'quarantine' THEN
    IF v_lot.available_qty < p_quantity THEN RAISE EXCEPTION 'Insufficient available lot quantity'; END IF;
    UPDATE public.inventory_lot_positions
    SET available_qty = available_qty - p_quantity,
        position_status = 'quarantine',
        version = version + 1,
        updated_at = now()
    WHERE id = p_lot_position_id;
    UPDATE public.inventory_stock_balances
    SET available_qty = available_qty - p_quantity,
        quarantine_qty = quarantine_qty + p_quantity,
        version = version + 1,
        updated_at = now()
    WHERE product_id = v_lot.product_id AND sku = v_lot.sku AND location_code = v_lot.location_code;
    INSERT INTO public.inventory_movements (
      movement_type, product_id, sku, quantity, source_location, actor_id, correlation_id, metadata
    ) VALUES (
      'stock_quarantined', v_lot.product_id, v_lot.sku, p_quantity, v_lot.location_code,
      v_actor, p_correlation_id, jsonb_build_object('lot_position_id', p_lot_position_id)
    );
  ELSIF p_action = 'release_quarantine' THEN
    IF v_lot.position_status <> 'quarantine' THEN RAISE EXCEPTION 'Lot is not in quarantine'; END IF;
    UPDATE public.inventory_lot_positions
    SET available_qty = available_qty + p_quantity,
        position_status = 'available',
        version = version + 1,
        updated_at = now()
    WHERE id = p_lot_position_id;
    UPDATE public.inventory_stock_balances
    SET available_qty = available_qty + p_quantity,
        quarantine_qty = greatest(quarantine_qty - p_quantity, 0),
        version = version + 1,
        updated_at = now()
    WHERE product_id = v_lot.product_id AND sku = v_lot.sku AND location_code = v_lot.location_code;
    INSERT INTO public.inventory_movements (
      movement_type, product_id, sku, quantity, destination_location, actor_id, correlation_id, metadata
    ) VALUES (
      'stock_quarantine_released', v_lot.product_id, v_lot.sku, p_quantity, v_lot.location_code,
      v_actor, p_correlation_id, jsonb_build_object('lot_position_id', p_lot_position_id)
    );
  ELSIF p_action IN ('damage_writeoff', 'expire_writeoff') THEN
    IF v_lot.available_qty < p_quantity THEN RAISE EXCEPTION 'Insufficient available lot quantity'; END IF;
    UPDATE public.inventory_lot_positions
    SET available_qty = available_qty - p_quantity,
        position_status = CASE p_action WHEN 'damage_writeoff' THEN 'damaged' ELSE 'expired' END,
        version = version + 1,
        updated_at = now()
    WHERE id = p_lot_position_id;
    UPDATE public.inventory_stock_balances
    SET available_qty = available_qty - p_quantity,
        damaged_qty = damaged_qty + CASE WHEN p_action = 'damage_writeoff' THEN p_quantity ELSE 0 END,
        expired_qty = expired_qty + CASE WHEN p_action = 'expire_writeoff' THEN p_quantity ELSE 0 END,
        version = version + 1,
        updated_at = now()
    WHERE product_id = v_lot.product_id AND sku = v_lot.sku AND location_code = v_lot.location_code;
    INSERT INTO public.inventory_movements (
      movement_type, product_id, sku, quantity, source_location, actor_id, correlation_id, metadata
    ) VALUES (
      'stock_variance_recorded', v_lot.product_id, v_lot.sku, p_quantity, v_lot.location_code,
      v_actor, p_correlation_id,
      jsonb_build_object('lot_position_id', p_lot_position_id, 'action', p_action)
    );
  END IF;

  INSERT INTO public.inventory_lot_exception_events (
    lot_position_id, location_code, product_id, sku, action, quantity, reason, actor_id, correlation_id
  ) VALUES (
    p_lot_position_id, v_lot.location_code, v_lot.product_id, v_lot.sku,
    p_action, p_quantity, btrim(p_reason), v_actor, p_correlation_id
  )
  RETURNING * INTO v_event;

  RETURN v_event;
END;
$$;

-- =================================================================================
-- 4. Patch post_grn_inventory_lot_positions: lineage + qc_hold + bin/store guard
-- =================================================================================

CREATE OR REPLACE FUNCTION public.post_grn_inventory_lot_positions(
  p_grn_id uuid,
  p_correlation_id text
)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_task record;
  v_line public.b2b_inventory_receipt_lines%ROWTYPE;
  v_bin public.b2b_inventory_bins%ROWTYPE;
  v_receipt public.b2b_inventory_receipts%ROWTYPE;
  v_count integer := 0;
  v_batch text;
  v_status text;
BEGIN
  SELECT r.* INTO v_receipt
  FROM public.b2b_inventory_grns g
  JOIN public.b2b_inventory_receipts r ON r.id = g.receipt_id
  WHERE g.id = p_grn_id;

  FOR v_task IN
    SELECT t.*
    FROM public.b2b_inventory_putaway_tasks t
    JOIN public.b2b_inventory_receipt_lines l ON l.id = t.receipt_line_id
    WHERE l.receipt_id = v_receipt.id
      AND t.disposition IN ('accepted', 'qc_hold')
      AND t.status = 'completed'
      AND t.placed_qty > 0
  LOOP
    SELECT * INTO v_line FROM public.b2b_inventory_receipt_lines WHERE id = v_task.receipt_line_id;
    SELECT * INTO v_bin FROM public.b2b_inventory_bins WHERE id = v_task.bin_id;

    IF v_bin.store_code <> v_receipt.destination_store_code THEN
      RAISE EXCEPTION 'Put-away bin store does not match receipt destination store';
    END IF;

    v_batch := coalesce(v_line.oasis_batch_lot, v_line.supplier_batch_lot, 'UNKNOWN');
    v_status := CASE
      WHEN v_task.disposition = 'qc_hold' THEN 'quarantine'
      WHEN v_bin.storage_class IN ('quarantine', 'damaged', 'rejected', 'return_to_vendor') THEN v_bin.storage_class
      WHEN v_line.expiry_date IS NOT NULL AND v_line.expiry_date < current_date THEN 'expired'
      ELSE 'available'
    END;

    INSERT INTO public.inventory_lot_positions (
      product_id, sku, location_code, bin_id, batch_lot,
      expiry_date, manufactured_date, best_before_date,
      receipt_line_id, putaway_task_id, grn_id,
      available_qty, storage_class, position_status
    ) VALUES (
      v_line.product_id, v_line.sku, v_receipt.destination_store_code, v_task.bin_id,
      v_batch, v_line.expiry_date, v_line.manufactured_date, v_line.best_before_date,
      v_line.id, v_task.id, p_grn_id,
      CASE WHEN v_status = 'available' THEN v_task.placed_qty ELSE 0 END,
      v_bin.storage_class, v_status
    )
    ON CONFLICT (putaway_task_id) DO NOTHING;

    IF NOT EXISTS (
      SELECT 1 FROM public.inventory_movements
      WHERE correlation_id = p_correlation_id || ':lot:' || v_task.id
        AND movement_type = 'lot_position_posted'
    ) THEN
      v_count := v_count + 1;
      INSERT INTO public.inventory_movements (
        movement_type, product_id, sku, quantity, destination_location,
        correlation_id, batch_lot, expiry_date, metadata
      ) VALUES (
        'lot_position_posted', v_line.product_id, v_line.sku, v_task.placed_qty,
        v_receipt.destination_store_code, p_correlation_id || ':lot:' || v_task.id,
        v_batch, v_line.expiry_date,
        jsonb_build_object(
          'grn_id', p_grn_id, 'putaway_task_id', v_task.id,
          'bin_id', v_task.bin_id, 'position_status', v_status,
          'manufactured_date', v_line.manufactured_date,
          'best_before_date', v_line.best_before_date
        )
      );
    END IF;
  END LOOP;

  RETURN v_count;
END;
$$;

-- =================================================================================
-- 5. Patch put-away allocation: bin must belong to receipt store
-- =================================================================================

CREATE OR REPLACE FUNCTION public.allocate_b2b_inventory_putaway(
  p_receipt_id uuid, p_allocations jsonb, p_correlation_id text
)
RETURNS SETOF public.b2b_inventory_putaway_tasks
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_actor uuid := auth.uid();
  v_receipt public.b2b_inventory_receipts%ROWTYPE;
  v_item jsonb;
  v_line public.b2b_inventory_receipt_lines%ROWTYPE;
  v_bin public.b2b_inventory_bins%ROWTYPE;
  v_qty numeric;
  v_disposition text;
BEGIN
  IF v_actor IS NULL OR NOT public.can_manage_b2b_inventory(v_actor) THEN
    RAISE EXCEPTION 'Not authorised' USING ERRCODE='42501';
  END IF;
  SELECT * INTO v_receipt FROM public.b2b_inventory_receipts WHERE id = p_receipt_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Receipt not found'; END IF;
  PERFORM public.assert_inventory_store_mutation_access(v_actor, v_receipt.destination_store_code);

  IF jsonb_typeof(p_allocations) <> 'array' OR jsonb_array_length(p_allocations)=0
     OR nullif(btrim(p_correlation_id),'') IS NULL THEN
    RAISE EXCEPTION 'Allocations and correlation id are required';
  END IF;

  FOR v_item IN SELECT value FROM jsonb_array_elements(p_allocations) LOOP
    SELECT * INTO STRICT v_line FROM public.b2b_inventory_receipt_lines
      WHERE id=(v_item->>'line_id')::uuid AND receipt_id=p_receipt_id FOR UPDATE;
    SELECT * INTO STRICT v_bin FROM public.b2b_inventory_bins
      WHERE id=(v_item->>'bin_id')::uuid AND active FOR UPDATE;

    IF v_bin.store_code <> v_receipt.destination_store_code THEN
      RAISE EXCEPTION 'Put-away bin must belong to receipt destination store';
    END IF;

    v_qty := (v_item->>'quantity')::numeric;
    v_disposition := v_item->>'disposition';
    IF v_qty IS NULL OR v_qty <= 0 THEN RAISE EXCEPTION 'Allocation quantity must be positive'; END IF;
    IF (v_disposition='accepted' AND v_bin.storage_class IN ('quarantine','damaged','rejected','return_to_vendor'))
       OR (v_disposition='qc_hold' AND v_bin.storage_class NOT IN ('quarantine'))
       OR (v_disposition NOT IN ('accepted','qc_hold') AND v_bin.storage_class='ambient') THEN
      RAISE EXCEPTION 'Disposition and bin storage class mismatch';
    END IF;

    INSERT INTO public.b2b_inventory_putaway_tasks(receipt_line_id,bin_id,disposition,allocated_qty,assigned_to)
    VALUES(v_line.id,v_bin.id,v_disposition,v_qty,(v_item->>'assigned_to')::uuid)
    ON CONFLICT (receipt_line_id,bin_id,disposition) DO UPDATE
      SET allocated_qty=EXCLUDED.allocated_qty, assigned_to=EXCLUDED.assigned_to, updated_at=now();
  END LOOP;

  IF EXISTS (
    SELECT 1 FROM public.b2b_inventory_receipt_lines l
    WHERE l.receipt_id=p_receipt_id AND (
      coalesce((SELECT sum(t.allocated_qty) FROM public.b2b_inventory_putaway_tasks t WHERE t.receipt_line_id=l.id AND t.disposition='accepted'),0) <> l.accepted_qty
      OR coalesce((SELECT sum(t.allocated_qty) FROM public.b2b_inventory_putaway_tasks t WHERE t.receipt_line_id=l.id AND t.disposition='damaged'),0) <> l.damaged_qty
      OR coalesce((SELECT sum(t.allocated_qty) FROM public.b2b_inventory_putaway_tasks t WHERE t.receipt_line_id=l.id AND t.disposition='rejected'),0) <> l.rejected_qty
    )
  ) THEN RAISE EXCEPTION 'Put-away allocations must reconcile with every receipt disposition'; END IF;

  RETURN QUERY SELECT t.* FROM public.b2b_inventory_putaway_tasks t
    JOIN public.b2b_inventory_receipt_lines l ON l.id=t.receipt_line_id
    WHERE l.receipt_id=p_receipt_id ORDER BY t.created_at;
END $$;

-- Sections 6-10: GRN reversal wire, RPC patches, production hold_qty, command facts, grants.

REVOKE ALL ON FUNCTION public.assert_inventory_store_mutation_access(uuid, text),
  public.inventory_lot_positions_exist(uuid, text, text),
  public.assert_lot_allocation_covers_qty(uuid, numeric, text),
  public.release_lot_allocations_from_reservation(uuid, numeric, text),
  public.reverse_grn_inventory_lot_positions(uuid, text),
  public.consume_lot_allocations_on_issue(uuid, numeric, text),
  public.record_inventory_lot_exception(uuid, text, numeric, text, text)
FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.record_inventory_lot_exception(uuid, text, numeric, text, text) TO authenticated;

CREATE OR REPLACE FUNCTION public.reverse_b2b_inventory_grn(
  p_grn_id uuid, p_reversal_number text, p_reason text, p_correlation_id text
) RETURNS public.b2b_inventory_grns
LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE v_actor uuid:=auth.uid(); v_original public.b2b_inventory_grns%ROWTYPE;
 v_reversal public.b2b_inventory_grns%ROWTYPE; v_receipt public.b2b_inventory_receipts%ROWTYPE;
 v_group record; v_line public.b2b_inventory_receipt_lines%ROWTYPE;
BEGIN
  IF v_actor IS NULL OR NOT public.can_manage_b2b_inventory(v_actor) THEN RAISE EXCEPTION 'Not authorised' USING ERRCODE='42501'; END IF;
  IF nullif(btrim(p_reversal_number),'') IS NULL OR nullif(btrim(p_reason),'') IS NULL OR nullif(btrim(p_correlation_id),'') IS NULL THEN RAISE EXCEPTION 'Reversal number, reason and correlation id are required'; END IF;
  SELECT * INTO v_original FROM public.b2b_inventory_grns WHERE id=p_grn_id FOR UPDATE;
  IF NOT FOUND OR v_original.status<>'finalised' THEN RAISE EXCEPTION 'Finalised GRN not found'; END IF;
  SELECT * INTO v_receipt FROM public.b2b_inventory_receipts WHERE id=v_original.receipt_id;
  IF NOT public.can_access_b2b_inventory_store(v_actor,v_receipt.destination_store_code,'manage') THEN RAISE EXCEPTION 'Not authorised' USING ERRCODE='42501'; END IF;
  PERFORM public.reverse_grn_inventory_lot_positions(p_grn_id, p_correlation_id);
  FOR v_group IN SELECT product_id,sku,sum(accepted_qty) qty FROM public.b2b_inventory_receipt_lines WHERE receipt_id=v_receipt.id AND accepted_qty>0 GROUP BY product_id,sku LOOP
    UPDATE public.inventory_stock_balances SET available_qty=available_qty-v_group.qty,version=version+1,updated_at=now()
    WHERE product_id=v_group.product_id AND sku=v_group.sku AND location_code=v_receipt.destination_store_code AND available_qty>=v_group.qty;
    IF NOT FOUND THEN RAISE EXCEPTION 'Insufficient available stock for GRN reversal'; END IF;
  END LOOP;
  UPDATE public.b2b_inventory_grns SET status='reversed',reversal_reason=btrim(p_reason) WHERE id=v_original.id;
  INSERT INTO public.b2b_inventory_grns(grn_number,receipt_id,status,finalised_by,finalised_at,reversal_grn_id,reversal_reason,correlation_id,stock_posted_at,stock_posted_by)
  VALUES(btrim(p_reversal_number),v_receipt.id,'reversed',v_actor,now(),v_original.id,btrim(p_reason),p_correlation_id,now(),v_actor) RETURNING * INTO v_reversal;
  FOR v_line IN SELECT * FROM public.b2b_inventory_receipt_lines WHERE receipt_id=v_receipt.id AND accepted_qty>0 ORDER BY id LOOP
    INSERT INTO public.inventory_movements(movement_type,product_id,sku,quantity,source_location,actor_id,reason_code,correlation_id,source_document_type,source_document_reference,batch_lot,expiry_date,metadata)
    VALUES('correction_out',v_line.product_id,v_line.sku,v_line.accepted_qty,v_receipt.destination_store_code,v_actor,'grn_reversal',p_correlation_id||':'||v_line.id,v_receipt.source_document_type,v_receipt.source_document_reference,coalesce(v_line.oasis_batch_lot,v_line.supplier_batch_lot),v_line.expiry_date,jsonb_build_object('original_grn_id',v_original.id,'reversal_grn_id',v_reversal.id,'reason',p_reason));
  END LOOP;
  RETURN v_reversal;
END $$;


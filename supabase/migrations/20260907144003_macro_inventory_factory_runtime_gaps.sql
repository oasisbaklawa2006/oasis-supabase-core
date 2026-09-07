-- MACRO INVENTORY: substantive runtime gap closure (Points82–90 tranche)
-- 1. qc_hold GRN lot posting syncs aggregate quarantine_qty
-- 2. GRN reversal reverses lot quarantine_qty on aggregate ledger
-- 3. P&A reserve/issue keeps lot positions coherent with aggregate balances

SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '120s';

-- =================================================================================
-- 1. Internal: FIFO lot reserve/issue sync for assembly component paths
-- =================================================================================

CREATE OR REPLACE FUNCTION public.sync_lot_reserve_fifo(
  p_product_id uuid,
  p_sku text,
  p_location_code text,
  p_qty numeric,
  p_correlation_id text
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_lot record;
  v_remaining numeric := p_qty;
  v_take numeric;
BEGIN
  IF p_qty IS NULL OR p_qty <= 0 THEN
    RETURN;
  END IF;

  IF NOT public.inventory_lot_positions_exist(p_product_id, p_sku, p_location_code) THEN
    RETURN;
  END IF;

  FOR v_lot IN
    SELECT lp.*
    FROM public.inventory_lot_positions lp
    JOIN public.b2b_inventory_bins b ON b.id = lp.bin_id
    WHERE lp.product_id = p_product_id
      AND lp.sku = p_sku
      AND lp.location_code = p_location_code
      AND lp.position_status = 'available'
      AND lp.available_qty > 0
      AND b.storage_class NOT IN ('quarantine', 'damaged', 'rejected', 'return_to_vendor')
      AND (lp.expiry_date IS NULL OR lp.expiry_date >= current_date)
    ORDER BY lp.created_at ASC
    FOR UPDATE OF lp
  LOOP
    EXIT WHEN v_remaining <= 0;
    v_take := least(v_remaining, v_lot.available_qty);
    IF v_take <= 0 THEN
      CONTINUE;
    END IF;

    UPDATE public.inventory_lot_positions
    SET available_qty = available_qty - v_take,
        reserved_qty = reserved_qty + v_take,
        version = version + 1,
        updated_at = now()
    WHERE id = v_lot.id;

    INSERT INTO public.inventory_movements (
      movement_type, product_id, sku, quantity, source_location, correlation_id, metadata
    ) VALUES (
      'lot_reserved', p_product_id, p_sku, v_take, p_location_code,
      p_correlation_id || ':lot:' || v_lot.id,
      jsonb_build_object('lot_position_id', v_lot.id, 'context', 'assembly_reserve')
    );

    v_remaining := v_remaining - v_take;
  END LOOP;

  IF v_remaining > 0 THEN
    RAISE EXCEPTION 'Lot layer cannot cover reserve quantity for % / % at %', p_product_id, p_sku, p_location_code;
  END IF;
END;
$$;

CREATE OR REPLACE FUNCTION public.sync_lot_issue_reserved(
  p_product_id uuid,
  p_sku text,
  p_location_code text,
  p_qty numeric,
  p_correlation_id text
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_lot record;
  v_remaining numeric := p_qty;
  v_take numeric;
BEGIN
  IF p_qty IS NULL OR p_qty <= 0 THEN
    RETURN;
  END IF;

  IF NOT public.inventory_lot_positions_exist(p_product_id, p_sku, p_location_code) THEN
    RETURN;
  END IF;

  FOR v_lot IN
    SELECT *
    FROM public.inventory_lot_positions
    WHERE product_id = p_product_id
      AND sku = p_sku
      AND location_code = p_location_code
      AND reserved_qty > 0
    ORDER BY created_at ASC
    FOR UPDATE
  LOOP
    EXIT WHEN v_remaining <= 0;
    v_take := least(v_remaining, v_lot.reserved_qty);
    IF v_take <= 0 THEN
      CONTINUE;
    END IF;

    UPDATE public.inventory_lot_positions
    SET reserved_qty = reserved_qty - v_take,
        position_status = CASE
          WHEN available_qty = 0 AND reserved_qty - v_take <= 0 AND picked_qty <= 0 THEN 'depleted'
          ELSE position_status
        END,
        version = version + 1,
        updated_at = now()
    WHERE id = v_lot.id;

    INSERT INTO public.inventory_movements (
      movement_type, product_id, sku, quantity, source_location, correlation_id, metadata
    ) VALUES (
      'lot_issued', p_product_id, p_sku, v_take, p_location_code,
      p_correlation_id || ':lot:' || v_lot.id,
      jsonb_build_object('lot_position_id', v_lot.id, 'context', 'assembly_issue')
    );

    v_remaining := v_remaining - v_take;
  END LOOP;

  IF v_remaining > 0 THEN
    RAISE EXCEPTION 'Lot layer cannot cover issue quantity for % / % at %', p_product_id, p_sku, p_location_code;
  END IF;
END;
$$;

REVOKE ALL ON FUNCTION public.sync_lot_reserve_fifo(uuid, text, text, numeric, text),
  public.sync_lot_issue_reserved(uuid, text, text, numeric, text)
FROM PUBLIC, anon, authenticated;

-- =================================================================================
-- 2. Patch post_grn_inventory_lot_positions: sync aggregate quarantine on qc_hold
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
      WHEN v_bin.storage_class IN ('rejected', 'return_to_vendor') THEN 'quarantine'
      WHEN v_bin.storage_class IN ('quarantine', 'damaged') THEN v_bin.storage_class
      WHEN v_line.expiry_date IS NOT NULL AND v_line.expiry_date < current_date THEN 'expired'
      ELSE 'available'
    END;

    INSERT INTO public.inventory_lot_positions (
      product_id, sku, location_code, bin_id, batch_lot,
      expiry_date, manufactured_date, best_before_date,
      receipt_line_id, putaway_task_id, grn_id,
      available_qty, quarantine_qty, storage_class, position_status
    ) VALUES (
      v_line.product_id, v_line.sku, v_receipt.destination_store_code, v_task.bin_id,
      v_batch, v_line.expiry_date, v_line.manufactured_date, v_line.best_before_date,
      v_line.id, v_task.id, p_grn_id,
      CASE WHEN v_status = 'available' THEN v_task.placed_qty ELSE 0 END,
      CASE WHEN v_status = 'quarantine' THEN v_task.placed_qty ELSE 0 END,
      v_bin.storage_class, v_status
    )
    ON CONFLICT (putaway_task_id) DO NOTHING;

    IF v_task.disposition = 'qc_hold' AND v_status = 'quarantine' THEN
      UPDATE public.inventory_stock_balances
      SET quarantine_qty = quarantine_qty + v_task.placed_qty,
          version = version + 1,
          updated_at = now()
      WHERE product_id = v_line.product_id
        AND sku = v_line.sku
        AND location_code = v_receipt.destination_store_code;
      IF NOT FOUND THEN
        INSERT INTO public.inventory_stock_balances (
          product_id, sku, location_code, quarantine_qty
        ) VALUES (
          v_line.product_id, v_line.sku, v_receipt.destination_store_code, v_task.placed_qty
        );
      END IF;
    END IF;

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
          'disposition', v_task.disposition,
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
-- 3. Patch reverse_grn_inventory_lot_positions: reverse quarantine aggregate qty
-- =================================================================================

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
        jsonb_build_object('grn_id', p_grn_id, 'lot_position_id', v_lot.id, 'bucket', 'available')
      );
    END IF;

    IF v_lot.quarantine_qty > 0 THEN
      INSERT INTO public.inventory_movements (
        movement_type, product_id, sku, quantity, source_location,
        correlation_id, batch_lot, expiry_date, metadata
      ) VALUES (
        'lot_position_reversed', v_lot.product_id, v_lot.sku, v_lot.quarantine_qty,
        v_lot.location_code, p_correlation_id || ':reverse-qh:' || v_lot.id,
        v_lot.batch_lot, v_lot.expiry_date,
        jsonb_build_object('grn_id', p_grn_id, 'lot_position_id', v_lot.id, 'bucket', 'quarantine')
      );

      UPDATE public.inventory_stock_balances
      SET quarantine_qty = greatest(quarantine_qty - v_lot.quarantine_qty, 0),
          version = version + 1,
          updated_at = now()
      WHERE product_id = v_lot.product_id
        AND sku = v_lot.sku
        AND location_code = v_lot.location_code;
      IF NOT FOUND THEN
        RAISE EXCEPTION 'Aggregate stock balance not found for quarantine GRN reversal';
      END IF;
    END IF;

    UPDATE public.inventory_lot_positions
    SET available_qty = 0,
        quarantine_qty = 0,
        position_status = 'depleted',
        version = version + 1,
        updated_at = now()
    WHERE id = v_lot.id;

    v_count := v_count + 1;
  END LOOP;

  RETURN v_count;
END;
$$;

-- =================================================================================
-- 4. Patch P&A reserve/issue to keep lot layer coherent
-- =================================================================================

CREATE OR REPLACE FUNCTION public.reserve_assembly_components(
  p_assembly_job_id uuid,
  p_priority text,
  p_correlation_id text
)
RETURNS public.b2b_assembly_jobs
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_actor_id uuid := auth.uid();
  v_job public.b2b_assembly_jobs%ROWTYPE;
  v_component record;
  v_balance record;
  v_reserve_qty numeric;
  v_shortfall numeric;
  v_department text;
  v_rgs_reservation public.inventory_reservations%ROWTYPE;
  v_all_reserved boolean := true;
  v_requirement_number text;
BEGIN
  IF v_actor_id IS NULL OR NOT public.can_manage_b2b_inventory(v_actor_id) THEN
    RAISE EXCEPTION 'Not authorised to reserve assembly components' USING ERRCODE = '42501';
  END IF;
  IF nullif(btrim(p_correlation_id), '') IS NULL THEN
    RAISE EXCEPTION 'A correlation id is required';
  END IF;

  SELECT * INTO v_job FROM public.b2b_assembly_jobs WHERE id = p_assembly_job_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Assembly job not found'; END IF;

  IF v_job.status NOT IN ('planned', 'partially_reserved') THEN
    RETURN v_job;
  END IF;

  FOR v_component IN
    SELECT * FROM public.b2b_assembly_components WHERE assembly_job_id = p_assembly_job_id ORDER BY id FOR UPDATE
  LOOP
    IF v_component.reserved_qty < v_component.required_qty THEN
      PERFORM pg_catalog.pg_advisory_xact_lock(
        pg_catalog.hashtextextended(v_component.product_id::text || ':' || v_component.sku || ':' || v_component.source_store_code, 0)
      );

      SELECT * INTO v_balance
      FROM public.inventory_stock_balances
      WHERE product_id = v_component.product_id AND sku = v_component.sku AND location_code = v_component.source_store_code
      FOR UPDATE;
      IF NOT FOUND THEN
        RAISE EXCEPTION 'Stock balance not found for % / % at %', v_component.product_id, v_component.sku, v_component.source_store_code;
      END IF;

      v_reserve_qty := least(v_component.required_qty - v_component.reserved_qty, coalesce(v_balance.available_qty, 0));

      IF v_reserve_qty > 0 THEN
        UPDATE public.inventory_stock_balances
        SET available_qty = available_qty - v_reserve_qty,
            reserved_qty = reserved_qty + v_reserve_qty,
            version = version + 1,
            updated_at = now()
        WHERE product_id = v_component.product_id AND sku = v_component.sku AND location_code = v_component.source_store_code;

        PERFORM public.sync_lot_reserve_fifo(
          v_component.product_id, v_component.sku, v_component.source_store_code,
          v_reserve_qty, p_correlation_id || ':asm:' || v_component.id::text
        );

        UPDATE public.b2b_assembly_components
        SET reserved_qty = reserved_qty + v_reserve_qty
        WHERE id = v_component.id;
      END IF;

      v_shortfall := v_component.required_qty - (v_component.reserved_qty + v_reserve_qty);
      IF v_shortfall > 0 THEN
        v_all_reserved := false;

        IF v_component.source_store_code = 'FINISHED_GOODS' THEN
          SELECT public.canonical_production_department(p.production_department) INTO v_department
          FROM public.products p WHERE p.id = v_component.product_id;
          IF v_department IS NULL THEN
            RAISE EXCEPTION 'Component % / % has no canonical production department to route its shortfall to', v_component.product_id, v_component.sku;
          END IF;

          SELECT * INTO v_rgs_reservation
          FROM public.inventory_reservations
          WHERE demand_source_type = 'pna' AND demand_reference = v_job.assembly_job_number
            AND product_id = v_component.product_id AND sku = v_component.sku;
          IF NOT FOUND THEN
            v_rgs_reservation := public.reserve_rgs_stock(
              p_reservation_number := v_job.assembly_job_number || ':' || v_component.id::text,
              p_order_id := NULL,
              p_product_id := v_component.product_id,
              p_sku := v_component.sku,
              p_requested_qty := v_shortfall,
              p_source_department := v_department,
              p_correlation_id := p_correlation_id || ':' || v_component.id::text,
              p_priority := coalesce(p_priority, 'normal'),
              p_location_code := 'FINISHED_GOODS',
              p_demand_source_type := 'pna',
              p_demand_reference := v_job.assembly_job_number
            );
          END IF;
          IF v_rgs_reservation.requested_qty > v_rgs_reservation.reserved_qty + v_rgs_reservation.fulfilled_qty + v_rgs_reservation.released_qty THEN
            PERFORM public.create_production_shortage_demand(
              v_rgs_reservation.id, v_department, coalesce(p_priority, 'normal'),
              p_correlation_id || ':shortage:' || v_component.id::text
            );
          END IF;
        ELSE
          IF NOT EXISTS (
            SELECT 1 FROM public.b2b_assembly_3pgs_requirements
            WHERE assembly_component_id = v_component.id AND status IN ('open', 'partially_fulfilled')
          ) THEN
            v_requirement_number := v_job.assembly_job_number || ':3PGS:' || v_component.id::text;
            INSERT INTO public.b2b_assembly_3pgs_requirements (
              requirement_number, assembly_job_id, assembly_component_id, product_id, sku,
              source_store_code, requested_qty, priority, raised_by, correlation_id
            ) VALUES (
              v_requirement_number, v_job.id, v_component.id, v_component.product_id, v_component.sku,
              v_component.source_store_code, v_shortfall, coalesce(p_priority, 'normal'), v_actor_id,
              p_correlation_id || ':3pgs:' || v_component.id::text
            )
            ON CONFLICT (correlation_id) DO NOTHING;
          END IF;
        END IF;
      END IF;
    END IF;
  END LOOP;

  UPDATE public.b2b_assembly_jobs
  SET status = CASE WHEN v_all_reserved THEN 'materials_reserved' ELSE 'partially_reserved' END,
      reserved_at = now(), updated_at = now()
  WHERE id = p_assembly_job_id
  RETURNING * INTO v_job;

  RETURN v_job;
END;
$$;

CREATE OR REPLACE FUNCTION public.issue_assembly_components(
  p_assembly_job_id uuid,
  p_correlation_id text
)
RETURNS public.b2b_assembly_jobs
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_actor_id uuid := auth.uid();
  v_job public.b2b_assembly_jobs%ROWTYPE;
  v_component record;
  v_issue_qty numeric;
BEGIN
  IF v_actor_id IS NULL OR NOT public.can_manage_b2b_inventory(v_actor_id) THEN
    RAISE EXCEPTION 'Not authorised to issue assembly components' USING ERRCODE = '42501';
  END IF;
  IF nullif(btrim(p_correlation_id), '') IS NULL THEN
    RAISE EXCEPTION 'A correlation id is required';
  END IF;

  SELECT * INTO v_job FROM public.b2b_assembly_jobs WHERE id = p_assembly_job_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Assembly job not found'; END IF;
  IF v_job.status IN ('issued', 'in_progress', 'qc_pending', 'accepted', 'partially_accepted', 'rejected',
                       'reconciliation_pending', 'job_completed', 'job_closed') THEN
    RETURN v_job;
  END IF;
  IF v_job.status = 'planned' THEN
    RAISE EXCEPTION 'Assembly job has not been reserved yet' USING ERRCODE = '42501';
  END IF;
  IF v_job.status = 'partially_reserved' AND NOT v_job.partial_issue_authorized THEN
    RAISE EXCEPTION 'Assembly job reservation is incomplete; issue refused without an authorized partial-issue plan (call authorize_partial_assembly_issue)' USING ERRCODE = '42501';
  END IF;
  IF v_job.status NOT IN ('materials_reserved', 'partially_reserved') THEN
    RAISE EXCEPTION 'Assembly job is not in an issuable state';
  END IF;

  FOR v_component IN
    SELECT * FROM public.b2b_assembly_components WHERE assembly_job_id = p_assembly_job_id AND reserved_qty > issued_qty ORDER BY id FOR UPDATE
  LOOP
    v_issue_qty := v_component.reserved_qty - v_component.issued_qty;
    IF v_issue_qty <= 0 THEN
      CONTINUE;
    END IF;

    PERFORM pg_catalog.pg_advisory_xact_lock(
      pg_catalog.hashtextextended(v_component.product_id::text || ':' || v_component.sku || ':' || v_component.source_store_code, 0)
    );

    UPDATE public.inventory_stock_balances
    SET reserved_qty = reserved_qty - v_issue_qty,
        version = version + 1,
        updated_at = now()
    WHERE product_id = v_component.product_id AND sku = v_component.sku AND location_code = v_component.source_store_code;

    PERFORM public.sync_lot_issue_reserved(
      v_component.product_id, v_component.sku, v_component.source_store_code,
      v_issue_qty, p_correlation_id || ':asm:' || v_component.id::text
    );

    INSERT INTO public.inventory_movements (
      movement_type, product_id, sku, quantity, source_location, actor_id, correlation_id,
      source_document_type, source_document_reference, metadata
    ) VALUES (
      'issued_to_assembly', v_component.product_id, v_component.sku, v_issue_qty,
      v_component.source_store_code, v_actor_id, p_correlation_id || ':' || v_component.id::text,
      'b2b_assembly_job', v_job.assembly_job_number,
      jsonb_build_object('assembly_job_id', v_job.id, 'component_id', v_component.id)
    );

    UPDATE public.b2b_assembly_components SET issued_qty = reserved_qty WHERE id = v_component.id;
  END LOOP;

  UPDATE public.b2b_assembly_jobs
  SET status = 'issued', issued_at = now(), updated_at = now()
  WHERE id = p_assembly_job_id
  RETURNING * INTO v_job;

  RETURN v_job;
END;
$$;

-- =================================================================================
-- 5. Extend movement vocabulary for assembly lot sync
-- =================================================================================

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
    'lot_position_reversed', 'lot_consumed', 'lot_reserved', 'lot_issued'
  ])) NOT VALID;

ALTER TABLE public.inventory_movements
  VALIDATE CONSTRAINT inventory_movements_type_check;

-- =================================================================================
-- 5. Extend movement vocabulary for assembly lot sync
-- =================================================================================

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
    'lot_position_reversed', 'lot_consumed', 'lot_reserved', 'lot_issued'
  ])) NOT VALID;

ALTER TABLE public.inventory_movements
  VALIDATE CONSTRAINT inventory_movements_type_check;

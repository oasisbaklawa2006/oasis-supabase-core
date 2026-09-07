-- MACRO INVENTORY: production-origin lot posting, assembly return lot sync,
-- and lineage anchors for RGS production receipt acceptance (Points82–90 D7/D9/D10).

SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '120s';

-- =================================================================================
-- 1. Schema: production transfer lineage + dual-origin lot positions
-- =================================================================================

ALTER TABLE public.production_rgs_transfers
  ADD COLUMN IF NOT EXISTS destination_bin_id uuid NULL
    REFERENCES public.b2b_inventory_bins(id) ON DELETE RESTRICT,
  ADD COLUMN IF NOT EXISTS expiry_date date NULL,
  ADD COLUMN IF NOT EXISTS manufactured_date date NULL,
  ADD COLUMN IF NOT EXISTS best_before_date date NULL;

-- destructive-change-approved: nullable GRN FKs allow production-origin lot rows
-- rollback-plan: backfill receipt_line_id/putaway_task_id before re-adding NOT NULL
ALTER TABLE public.inventory_lot_positions
  ALTER COLUMN receipt_line_id DROP NOT NULL,
  ALTER COLUMN putaway_task_id DROP NOT NULL;

ALTER TABLE public.inventory_lot_positions
  ADD COLUMN IF NOT EXISTS production_rgs_transfer_id uuid NULL
    REFERENCES public.production_rgs_transfers(id) ON DELETE RESTRICT;

CREATE UNIQUE INDEX IF NOT EXISTS uq_inventory_lot_positions_production_transfer
  ON public.inventory_lot_positions (production_rgs_transfer_id)
  WHERE production_rgs_transfer_id IS NOT NULL;

ALTER TABLE public.inventory_lot_positions
  DROP CONSTRAINT IF EXISTS inventory_lot_positions_origin_check;
ALTER TABLE public.inventory_lot_positions
  ADD CONSTRAINT inventory_lot_positions_origin_check
  CHECK (
    (receipt_line_id IS NOT NULL AND putaway_task_id IS NOT NULL AND production_rgs_transfer_id IS NULL)
    OR (production_rgs_transfer_id IS NOT NULL AND receipt_line_id IS NULL AND putaway_task_id IS NULL)
  ) NOT VALID;

-- =================================================================================
-- 2. Internal: restore returned assembly quantity to depleted lot positions
-- =================================================================================

CREATE OR REPLACE FUNCTION public.sync_lot_return_available(
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
    ORDER BY
      CASE WHEN position_status = 'depleted' THEN 0 ELSE 1 END,
      updated_at DESC,
      created_at DESC
    FOR UPDATE
  LOOP
    EXIT WHEN v_remaining <= 0;
    v_take := v_remaining;
    IF v_take <= 0 THEN
      CONTINUE;
    END IF;

    UPDATE public.inventory_lot_positions
    SET available_qty = available_qty + v_take,
        position_status = CASE
          WHEN position_status = 'depleted' THEN 'available'
          ELSE position_status
        END,
        version = version + 1,
        updated_at = now()
    WHERE id = v_lot.id;

    INSERT INTO public.inventory_movements (
      movement_type, product_id, sku, quantity, destination_location, correlation_id, metadata
    ) VALUES (
      'lot_returned', p_product_id, p_sku, v_take, p_location_code,
      p_correlation_id || ':lot:' || v_lot.id,
      jsonb_build_object('lot_position_id', v_lot.id, 'context', 'assembly_return')
    );

    v_remaining := v_remaining - v_take;
  END LOOP;

  IF v_remaining > 0 THEN
    RAISE EXCEPTION 'Lot layer cannot absorb returned quantity for % / % at %', p_product_id, p_sku, p_location_code;
  END IF;
END;
$$;

-- =================================================================================
-- 3. Production receipt lot posting (idempotent, bin-bound)
-- =================================================================================

CREATE OR REPLACE FUNCTION public.post_production_receipt_lot_positions(
  p_transfer_id uuid,
  p_accepted_qty numeric,
  p_hold_qty numeric,
  p_correlation_id text
)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_transfer public.production_rgs_transfers%ROWTYPE;
  v_bin public.b2b_inventory_bins%ROWTYPE;
  v_inserted boolean;
  v_status text;
  v_count integer := 0;
BEGIN
  IF nullif(btrim(p_correlation_id), '') IS NULL THEN
    RAISE EXCEPTION 'A correlation id is required';
  END IF;

  SELECT * INTO v_transfer FROM public.production_rgs_transfers WHERE id = p_transfer_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Transfer not found';
  END IF;

  IF coalesce(p_accepted_qty, 0) = 0 AND coalesce(p_hold_qty, 0) = 0 THEN
    RETURN 0;
  END IF;

  IF v_transfer.destination_bin_id IS NULL THEN
    RETURN 0;
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.inventory_movements
    WHERE correlation_id = p_correlation_id || ':production-lot'
      AND movement_type = 'lot_position_posted'
  ) THEN
    RETURN 0;
  END IF;

  SELECT * INTO v_bin FROM public.b2b_inventory_bins WHERE id = v_transfer.destination_bin_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Destination bin not found';
  END IF;
  IF v_bin.store_code <> v_transfer.destination_store_code THEN
    RAISE EXCEPTION 'Destination bin store does not match transfer destination store';
  END IF;

  v_status := CASE
    WHEN coalesce(p_hold_qty, 0) > 0 AND coalesce(p_accepted_qty, 0) = 0 THEN 'quarantine'
    WHEN v_bin.storage_class IN ('quarantine', 'damaged') THEN v_bin.storage_class
    WHEN v_transfer.expiry_date IS NOT NULL AND v_transfer.expiry_date < current_date THEN 'expired'
    ELSE 'available'
  END;

  v_inserted := false;
  INSERT INTO public.inventory_lot_positions (
    product_id, sku, location_code, bin_id, batch_lot,
    expiry_date, manufactured_date, best_before_date,
    production_rgs_transfer_id,
    available_qty, quarantine_qty, storage_class, position_status
  ) VALUES (
    v_transfer.product_id, v_transfer.sku, v_transfer.destination_store_code, v_transfer.destination_bin_id,
    coalesce(v_transfer.batch_number, 'UNKNOWN'),
    v_transfer.expiry_date, v_transfer.manufactured_date, v_transfer.best_before_date,
    p_transfer_id,
    CASE WHEN v_status = 'available' THEN coalesce(p_accepted_qty, 0) ELSE 0 END,
    coalesce(p_hold_qty, 0),
    v_bin.storage_class, v_status
  )
  ON CONFLICT (production_rgs_transfer_id) DO NOTHING
  RETURNING true INTO v_inserted;

  v_inserted := coalesce(v_inserted, false);

  IF v_inserted THEN
    v_count := 1;
    INSERT INTO public.inventory_movements (
      movement_type, product_id, sku, quantity, destination_location,
      correlation_id, batch_lot, expiry_date, metadata
    ) VALUES (
      'lot_position_posted', v_transfer.product_id, v_transfer.sku,
      coalesce(p_accepted_qty, 0) + coalesce(p_hold_qty, 0),
      v_transfer.destination_store_code, p_correlation_id || ':production-lot',
      coalesce(v_transfer.batch_number, 'UNKNOWN'), v_transfer.expiry_date,
      jsonb_build_object(
        'production_rgs_transfer_id', p_transfer_id,
        'bin_id', v_transfer.destination_bin_id,
        'position_status', v_status,
        'accepted_qty', p_accepted_qty,
        'hold_qty', p_hold_qty,
        'manufactured_date', v_transfer.manufactured_date,
        'best_before_date', v_transfer.best_before_date,
        'origin', 'production'
      )
    );
  END IF;

  RETURN v_count;
END;
$$;

-- =================================================================================
-- 4. Patch accept_rgs_production_receipt: post lot positions after aggregate
-- =================================================================================

CREATE OR REPLACE FUNCTION public.accept_rgs_production_receipt(
  p_transfer_id uuid, p_accepted_qty numeric, p_rejected_qty numeric, p_hold_qty numeric,
  p_expected_balance_version integer, p_correlation_id text
)
RETURNS public.production_rgs_transfers LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_actor_id uuid := auth.uid(); v_transfer public.production_rgs_transfers%ROWTYPE; v_current_version integer; v_factory_inventory_id uuid;
BEGIN
  IF v_actor_id IS NULL OR NOT public.is_inventory_receive_role((SELECT role FROM public.users WHERE id = v_actor_id)) THEN RAISE EXCEPTION 'Not authorised' USING ERRCODE = '42501'; END IF;
  IF nullif(btrim(p_correlation_id), '') IS NULL THEN RAISE EXCEPTION 'A correlation id is required'; END IF;
  SELECT * INTO v_transfer FROM public.production_rgs_transfers WHERE id = p_transfer_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Transfer not found'; END IF;
  IF v_transfer.accepted_qty IS NOT NULL THEN RETURN v_transfer; END IF;
  IF v_transfer.status <> 'received' THEN RAISE EXCEPTION 'Transfer is not awaiting acceptance'; END IF;
  IF least(coalesce(p_accepted_qty,-1), coalesce(p_rejected_qty,-1), coalesce(p_hold_qty,-1)) < 0
     OR coalesce(p_accepted_qty,0) + coalesce(p_rejected_qty,0) + coalesce(p_hold_qty,0) <> v_transfer.received_qty THEN
    RAISE EXCEPTION 'Accepted + rejected + hold must equal the received quantity exactly';
  END IF;
  IF p_accepted_qty > 0 AND p_expected_balance_version IS NULL THEN RAISE EXCEPTION 'An expected balance version is required when accepting stock'; END IF;
  PERFORM public.assert_inventory_store_mutation_access(v_actor_id, v_transfer.destination_store_code);
  IF p_accepted_qty > 0 OR p_hold_qty > 0 THEN
    PERFORM pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(v_transfer.product_id::text || ':' || v_transfer.sku || ':' || v_transfer.destination_store_code, 0));
    SELECT version INTO v_current_version FROM public.inventory_stock_balances
      WHERE product_id = v_transfer.product_id AND sku = v_transfer.sku AND location_code = v_transfer.destination_store_code FOR UPDATE;
    IF p_accepted_qty > 0 THEN
      IF FOUND THEN
        IF v_current_version <> p_expected_balance_version THEN RAISE EXCEPTION 'Stale stock balance version' USING ERRCODE = '40001'; END IF;
        UPDATE public.inventory_stock_balances SET available_qty = available_qty + p_accepted_qty, version = version + 1, updated_at = now()
          WHERE product_id = v_transfer.product_id AND sku = v_transfer.sku AND location_code = v_transfer.destination_store_code AND version = p_expected_balance_version;
        IF NOT FOUND THEN RAISE EXCEPTION 'Stock balance update did not apply' USING ERRCODE = '40001'; END IF;
      ELSE
        IF p_expected_balance_version <> 0 THEN RAISE EXCEPTION 'Stock balance does not exist at expected version' USING ERRCODE = '40001'; END IF;
        INSERT INTO public.inventory_stock_balances (product_id, sku, location_code, available_qty) VALUES (v_transfer.product_id, v_transfer.sku, v_transfer.destination_store_code, p_accepted_qty);
      END IF;
      INSERT INTO public.inventory_movements (movement_type, product_id, sku, quantity, destination_location, actor_id, reason_code, correlation_id, source_document_type, source_document_reference, batch_lot, metadata)
        VALUES ('production_receipt_accepted', v_transfer.product_id, v_transfer.sku, p_accepted_qty, v_transfer.destination_store_code, v_actor_id, 'rgs_production_acceptance', p_correlation_id, 'production_rgs_transfer', v_transfer.id::text, v_transfer.batch_number, jsonb_build_object('transfer_id', v_transfer.id, 'accepted_qty', p_accepted_qty));
      IF v_transfer.product_id IS NOT NULL THEN
        SELECT id INTO v_factory_inventory_id FROM public.factory_inventory WHERE product_id = v_transfer.product_id LIMIT 1;
        IF v_factory_inventory_id IS NOT NULL THEN UPDATE public.factory_inventory SET quantity = coalesce(quantity, 0) + p_accepted_qty, last_updated = now() WHERE id = v_factory_inventory_id;
        ELSE INSERT INTO public.factory_inventory (product_id, quantity) VALUES (v_transfer.product_id, p_accepted_qty); END IF;
      END IF;
    END IF;
    IF p_hold_qty > 0 THEN
      UPDATE public.inventory_stock_balances
      SET quarantine_qty = quarantine_qty + p_hold_qty, version = version + 1, updated_at = now()
      WHERE product_id = v_transfer.product_id AND sku = v_transfer.sku AND location_code = v_transfer.destination_store_code;
      IF NOT FOUND THEN
        INSERT INTO public.inventory_stock_balances (product_id, sku, location_code, quarantine_qty)
          VALUES (v_transfer.product_id, v_transfer.sku, v_transfer.destination_store_code, p_hold_qty);
      END IF;
      INSERT INTO public.inventory_movements (movement_type, product_id, sku, quantity, destination_location, actor_id, reason_code, correlation_id, metadata)
        VALUES ('stock_quarantined', v_transfer.product_id, v_transfer.sku, p_hold_qty, v_transfer.destination_store_code, v_actor_id, 'production_qc_hold', p_correlation_id || ':hold', jsonb_build_object('transfer_id', v_transfer.id, 'hold_qty', p_hold_qty));
    END IF;
  END IF;
  PERFORM public.post_production_receipt_lot_positions(
    p_transfer_id, p_accepted_qty, p_hold_qty, p_correlation_id
  );
  UPDATE public.production_rgs_transfers SET accepted_qty = p_accepted_qty, rejected_qty = p_rejected_qty, hold_qty = p_hold_qty,
    status = CASE WHEN p_accepted_qty = 0 THEN 'rejected' WHEN p_accepted_qty < v_transfer.received_qty THEN 'partially_accepted' ELSE 'accepted' END,
    accepted_by = v_actor_id, accepted_at = now(), rgs_notified = true WHERE id = p_transfer_id RETURNING * INTO v_transfer;
  RETURN v_transfer;
END;
$$;

-- =================================================================================
-- 5. Patch record_assembly_consumption: sync returned qty to lot layer
-- =================================================================================

CREATE OR REPLACE FUNCTION public.record_assembly_consumption(
  p_component_id uuid,
  p_consumed_qty numeric,
  p_wasted_qty numeric,
  p_returned_qty numeric,
  p_correlation_id text
)
RETURNS public.b2b_assembly_components
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_actor_id uuid := auth.uid();
  v_component public.b2b_assembly_components%ROWTYPE;
  v_job public.b2b_assembly_jobs%ROWTYPE;
BEGIN
  IF v_actor_id IS NULL OR NOT public.can_manage_b2b_inventory(v_actor_id) THEN
    RAISE EXCEPTION 'Not authorised to record assembly consumption' USING ERRCODE = '42501';
  END IF;
  IF nullif(btrim(p_correlation_id), '') IS NULL THEN
    RAISE EXCEPTION 'A correlation id is required';
  END IF;
  IF coalesce(p_consumed_qty, 0) < 0 OR coalesce(p_wasted_qty, 0) < 0 OR coalesce(p_returned_qty, 0) < 0 THEN
    RAISE EXCEPTION 'Consumption quantities must not be negative';
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.inventory_movements
    WHERE correlation_id = p_correlation_id AND movement_type = 'assembly_consumption_recorded'
  ) THEN
    SELECT * INTO v_component FROM public.b2b_assembly_components WHERE id = p_component_id;
    RETURN v_component;
  END IF;

  SELECT * INTO v_component FROM public.b2b_assembly_components WHERE id = p_component_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Assembly component not found'; END IF;

  SELECT * INTO v_job FROM public.b2b_assembly_jobs WHERE id = v_component.assembly_job_id FOR UPDATE;
  IF v_job.status NOT IN ('issued', 'in_progress') THEN
    RAISE EXCEPTION 'Assembly job is not in a consumable state';
  END IF;

  IF v_component.consumed_qty + v_component.wasted_qty + v_component.returned_qty
     + coalesce(p_consumed_qty, 0) + coalesce(p_wasted_qty, 0) + coalesce(p_returned_qty, 0) > v_component.issued_qty THEN
    RAISE EXCEPTION 'Consumed + wasted + returned cannot exceed issued quantity';
  END IF;

  UPDATE public.b2b_assembly_components
  SET consumed_qty = consumed_qty + coalesce(p_consumed_qty, 0),
      wasted_qty = wasted_qty + coalesce(p_wasted_qty, 0),
      returned_qty = returned_qty + coalesce(p_returned_qty, 0)
  WHERE id = p_component_id
  RETURNING * INTO v_component;

  IF coalesce(p_returned_qty, 0) > 0 THEN
    PERFORM pg_catalog.pg_advisory_xact_lock(
      pg_catalog.hashtextextended(v_component.product_id::text || ':' || v_component.sku || ':' || v_component.source_store_code, 0)
    );
    UPDATE public.inventory_stock_balances
    SET available_qty = available_qty + p_returned_qty,
        version = version + 1,
        updated_at = now()
    WHERE product_id = v_component.product_id AND sku = v_component.sku AND location_code = v_component.source_store_code;

    PERFORM public.sync_lot_return_available(
      v_component.product_id, v_component.sku, v_component.source_store_code,
      p_returned_qty, p_correlation_id || ':returned-lot'
    );

    INSERT INTO public.inventory_movements (
      movement_type, product_id, sku, quantity, destination_location, actor_id, correlation_id,
      source_document_type, source_document_reference, metadata
    ) VALUES (
      'returned_from_assembly', v_component.product_id, v_component.sku, p_returned_qty,
      v_component.source_store_code, v_actor_id, p_correlation_id || ':returned',
      'b2b_assembly_job', v_job.assembly_job_number,
      jsonb_build_object('assembly_job_id', v_job.id, 'component_id', v_component.id)
    );
  END IF;

  INSERT INTO public.inventory_movements (
    movement_type, product_id, sku, quantity, actor_id, correlation_id,
    source_document_type, source_document_reference, metadata
  ) VALUES (
    'assembly_consumption_recorded', v_component.product_id, v_component.sku,
    coalesce(p_consumed_qty, 0) + coalesce(p_wasted_qty, 0) + coalesce(p_returned_qty, 0),
    v_actor_id, p_correlation_id, 'b2b_assembly_job', v_job.assembly_job_number,
    jsonb_build_object('assembly_job_id', v_job.id, 'component_id', v_component.id,
      'consumed_qty', p_consumed_qty, 'wasted_qty', p_wasted_qty, 'returned_qty', p_returned_qty)
  );

  IF v_job.status = 'issued' THEN
    UPDATE public.b2b_assembly_jobs SET status = 'in_progress', updated_at = now() WHERE id = v_job.id;
  END IF;

  RETURN v_component;
END;
$$;

-- =================================================================================
-- 6. Movement vocabulary: lot_returned
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
    'lot_position_reversed', 'lot_consumed', 'lot_reserved', 'lot_issued', 'lot_returned'
  ])) NOT VALID;

REVOKE ALL ON FUNCTION public.sync_lot_return_available(uuid, text, text, numeric, text),
  public.post_production_receipt_lot_positions(uuid, numeric, numeric, text)
  FROM PUBLIC, anon, authenticated;

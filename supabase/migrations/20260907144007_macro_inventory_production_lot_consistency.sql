-- MACRO INVENTORY: final production/assembly lot consistency closure.
-- Repairs component-to-lot issue/return lineage and keeps lot buckets aligned
-- with the canonical inventory_stock_balances buckets.

SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '120s';

-- =================================================================================
-- 1. Complete the lot bucket model and persist assembly component -> lot lineage.
-- =================================================================================

ALTER TABLE public.inventory_lot_positions
  ADD COLUMN IF NOT EXISTS damaged_qty numeric NOT NULL DEFAULT 0 CHECK (damaged_qty >= 0),
  ADD COLUMN IF NOT EXISTS expired_qty numeric NOT NULL DEFAULT 0 CHECK (expired_qty >= 0);

COMMENT ON COLUMN public.inventory_lot_positions.damaged_qty IS
  'Quantity held in the damaged bucket for this exact lot position.';
COMMENT ON COLUMN public.inventory_lot_positions.expired_qty IS
  'Quantity held in the expired bucket for this exact lot position.';

CREATE TABLE IF NOT EXISTS public.b2b_assembly_component_lot_issues (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  assembly_component_id uuid NOT NULL
    REFERENCES public.b2b_assembly_components(id) ON DELETE RESTRICT,
  lot_position_id uuid NOT NULL
    REFERENCES public.inventory_lot_positions(id) ON DELETE RESTRICT,
  issued_qty numeric NOT NULL CHECK (issued_qty > 0),
  returned_qty numeric NOT NULL DEFAULT 0
    CHECK (returned_qty >= 0 AND returned_qty <= issued_qty),
  issue_correlation_id text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT b2b_assembly_component_lot_issues_unique
    UNIQUE (assembly_component_id, lot_position_id, issue_correlation_id)
);

CREATE INDEX IF NOT EXISTS idx_b2b_assembly_component_lot_issues_component
  ON public.b2b_assembly_component_lot_issues
  (assembly_component_id, created_at, id);

ALTER TABLE public.b2b_assembly_component_lot_issues ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "Inventory staff read assembly lot issues"
  ON public.b2b_assembly_component_lot_issues;
CREATE POLICY "Inventory staff read assembly lot issues"
  ON public.b2b_assembly_component_lot_issues
  FOR SELECT TO authenticated
  USING (
    public.can_manage_b2b_inventory((SELECT auth.uid()))
    OR public.can_receive_b2b_inventory((SELECT auth.uid()))
  );

REVOKE ALL ON public.b2b_assembly_component_lot_issues FROM PUBLIC, anon;
REVOKE INSERT, UPDATE, DELETE ON public.b2b_assembly_component_lot_issues FROM authenticated;
GRANT SELECT ON public.b2b_assembly_component_lot_issues TO authenticated;

CREATE OR REPLACE FUNCTION public.classify_production_receipt_lot_status(
  p_storage_class text,
  p_expiry_date date,
  p_accepted_qty numeric,
  p_hold_qty numeric
)
RETURNS text
LANGUAGE sql
STABLE
SET search_path = ''
AS $$
  SELECT CASE
    WHEN coalesce(p_accepted_qty, 0) = 0 AND coalesce(p_hold_qty, 0) > 0 THEN 'quarantine'
    WHEN p_storage_class IN ('rejected', 'return_to_vendor', 'quarantine') THEN 'quarantine'
    WHEN p_storage_class = 'damaged' THEN 'damaged'
    WHEN p_expiry_date IS NOT NULL AND p_expiry_date < current_date THEN 'expired'
    ELSE 'available'
  END;
$$;

REVOKE ALL ON FUNCTION public.classify_production_receipt_lot_status(text, date, numeric, numeric)
  FROM PUBLIC, anon, authenticated;

-- =================================================================================
-- 2. Assembly issue now records exactly which lots supplied each component.
-- =================================================================================

CREATE OR REPLACE FUNCTION public.sync_lot_issue_reserved(
  p_component_id uuid,
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

  IF NOT EXISTS (
    SELECT 1
    FROM public.b2b_assembly_components c
    WHERE c.id = p_component_id
      AND c.product_id = p_product_id
      AND c.sku = p_sku
      AND c.source_store_code = p_location_code
  ) THEN
    RAISE EXCEPTION 'Assembly component does not match requested lot issue identity';
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
      AND lp.position_status IN ('available', 'depleted')
      AND lp.reserved_qty > 0
      AND b.storage_class NOT IN ('quarantine', 'damaged', 'rejected', 'return_to_vendor')
      AND (lp.expiry_date IS NULL OR lp.expiry_date >= current_date)
    ORDER BY lp.created_at ASC, lp.id ASC
    FOR UPDATE OF lp
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

    INSERT INTO public.b2b_assembly_component_lot_issues (
      assembly_component_id, lot_position_id, issued_qty, issue_correlation_id
    ) VALUES (
      p_component_id, v_lot.id, v_take, p_correlation_id
    );

    INSERT INTO public.inventory_movements (
      movement_type, product_id, sku, quantity, source_location, correlation_id, metadata
    ) VALUES (
      'lot_issued', p_product_id, p_sku, v_take, p_location_code,
      p_correlation_id || ':lot:' || v_lot.id,
      jsonb_build_object(
        'lot_position_id', v_lot.id,
        'assembly_component_id', p_component_id,
        'context', 'assembly_issue'
      )
    );

    v_remaining := v_remaining - v_take;
  END LOOP;

  IF v_remaining > 0 THEN
    RAISE EXCEPTION 'Lot layer cannot cover assembly issue quantity for component %: short by %',
      p_component_id, v_remaining;
  END IF;
END;
$$;

REVOKE ALL ON FUNCTION public.sync_lot_issue_reserved(uuid, uuid, text, text, numeric, text)
  FROM PUBLIC, anon, authenticated;

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

  SELECT * INTO v_job
  FROM public.b2b_assembly_jobs
  WHERE id = p_assembly_job_id
  FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Assembly job not found'; END IF;

  IF v_job.status IN (
    'issued', 'in_progress', 'qc_pending', 'accepted', 'partially_accepted', 'rejected',
    'reconciliation_pending', 'job_completed', 'job_closed'
  ) THEN
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
    SELECT *
    FROM public.b2b_assembly_components
    WHERE assembly_job_id = p_assembly_job_id
      AND reserved_qty > issued_qty
    ORDER BY id
    FOR UPDATE
  LOOP
    v_issue_qty := v_component.reserved_qty - v_component.issued_qty;
    IF v_issue_qty <= 0 THEN CONTINUE; END IF;

    PERFORM pg_catalog.pg_advisory_xact_lock(
      pg_catalog.hashtextextended(
        v_component.product_id::text || ':' || v_component.sku || ':' || v_component.source_store_code,
        0
      )
    );

    UPDATE public.inventory_stock_balances
    SET reserved_qty = reserved_qty - v_issue_qty,
        version = version + 1,
        updated_at = now()
    WHERE product_id = v_component.product_id
      AND sku = v_component.sku
      AND location_code = v_component.source_store_code
      AND reserved_qty >= v_issue_qty;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'Aggregate reserved stock is missing or insufficient for assembly component %', v_component.id;
    END IF;

    PERFORM public.sync_lot_issue_reserved(
      v_component.id,
      v_component.product_id,
      v_component.sku,
      v_component.source_store_code,
      v_issue_qty,
      p_correlation_id || ':asm:' || v_component.id::text
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

    UPDATE public.b2b_assembly_components
    SET issued_qty = reserved_qty
    WHERE id = v_component.id;
  END LOOP;

  UPDATE public.b2b_assembly_jobs
  SET status = 'issued', issued_at = now(), updated_at = now()
  WHERE id = p_assembly_job_id
  RETURNING * INTO v_job;

  RETURN v_job;
END;
$$;

-- =================================================================================
-- 3. Returns are restored only to the exact eligible lots previously issued.
-- =================================================================================

CREATE OR REPLACE FUNCTION public.sync_assembly_lot_return_available(
  p_component_id uuid,
  p_qty numeric,
  p_correlation_id text
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_component public.b2b_assembly_components%ROWTYPE;
  v_issue record;
  v_remaining numeric := p_qty;
  v_take numeric;
BEGIN
  IF p_qty IS NULL OR p_qty <= 0 THEN RETURN; END IF;

  SELECT * INTO v_component
  FROM public.b2b_assembly_components
  WHERE id = p_component_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Assembly component not found'; END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.b2b_assembly_component_lot_issues
    WHERE assembly_component_id = p_component_id
  ) THEN
    IF public.inventory_lot_positions_exist(
      v_component.product_id, v_component.sku, v_component.source_store_code
    ) THEN
      RAISE EXCEPTION 'Lot-tracked assembly component % has no durable lot issue lineage', p_component_id;
    END IF;
    RETURN;
  END IF;

  FOR v_issue IN
    SELECT
      i.id AS issue_id,
      i.lot_position_id,
      i.issued_qty,
      i.returned_qty,
      lp.batch_lot,
      lp.expiry_date
    FROM public.b2b_assembly_component_lot_issues i
    JOIN public.inventory_lot_positions lp ON lp.id = i.lot_position_id
    JOIN public.b2b_inventory_bins b ON b.id = lp.bin_id
    WHERE i.assembly_component_id = p_component_id
      AND i.returned_qty < i.issued_qty
      AND lp.position_status IN ('available', 'depleted')
      AND b.storage_class NOT IN ('quarantine', 'damaged', 'rejected', 'return_to_vendor')
      AND (lp.expiry_date IS NULL OR lp.expiry_date >= current_date)
    ORDER BY i.created_at ASC, i.id ASC
    FOR UPDATE OF i, lp
  LOOP
    EXIT WHEN v_remaining <= 0;
    v_take := least(v_remaining, v_issue.issued_qty - v_issue.returned_qty);
    IF v_take <= 0 THEN CONTINUE; END IF;

    UPDATE public.inventory_lot_positions
    SET available_qty = available_qty + v_take,
        position_status = CASE WHEN position_status = 'depleted' THEN 'available' ELSE position_status END,
        version = version + 1,
        updated_at = now()
    WHERE id = v_issue.lot_position_id;

    UPDATE public.b2b_assembly_component_lot_issues
    SET returned_qty = returned_qty + v_take,
        updated_at = now()
    WHERE id = v_issue.issue_id;

    INSERT INTO public.inventory_movements (
      movement_type, product_id, sku, quantity, destination_location,
      correlation_id, batch_lot, expiry_date, metadata
    ) VALUES (
      'lot_returned', v_component.product_id, v_component.sku, v_take,
      v_component.source_store_code,
      p_correlation_id || ':lot:' || v_issue.issue_id,
      v_issue.batch_lot, v_issue.expiry_date,
      jsonb_build_object(
        'lot_position_id', v_issue.lot_position_id,
        'assembly_component_id', p_component_id,
        'assembly_component_lot_issue_id', v_issue.issue_id,
        'context', 'assembly_return'
      )
    );

    v_remaining := v_remaining - v_take;
  END LOOP;

  IF v_remaining > 0 THEN
    RAISE EXCEPTION 'Eligible issued lots cannot absorb assembly return for component %: short by %',
      p_component_id, v_remaining;
  END IF;
END;
$$;

REVOKE ALL ON FUNCTION public.sync_assembly_lot_return_available(uuid, numeric, text)
  FROM PUBLIC, anon, authenticated;

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
    WHERE correlation_id = p_correlation_id
      AND movement_type = 'assembly_consumption_recorded'
  ) THEN
    SELECT * INTO v_component
    FROM public.b2b_assembly_components
    WHERE id = p_component_id;
    RETURN v_component;
  END IF;

  SELECT * INTO v_component
  FROM public.b2b_assembly_components
  WHERE id = p_component_id
  FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Assembly component not found'; END IF;

  SELECT * INTO v_job
  FROM public.b2b_assembly_jobs
  WHERE id = v_component.assembly_job_id
  FOR UPDATE;
  IF v_job.status NOT IN ('issued', 'in_progress') THEN
    RAISE EXCEPTION 'Assembly job is not in a consumable state';
  END IF;

  IF v_component.consumed_qty + v_component.wasted_qty + v_component.returned_qty
     + coalesce(p_consumed_qty, 0) + coalesce(p_wasted_qty, 0) + coalesce(p_returned_qty, 0)
     > v_component.issued_qty THEN
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
      pg_catalog.hashtextextended(
        v_component.product_id::text || ':' || v_component.sku || ':' || v_component.source_store_code,
        0
      )
    );

    UPDATE public.inventory_stock_balances
    SET available_qty = available_qty + p_returned_qty,
        version = version + 1,
        updated_at = now()
    WHERE product_id = v_component.product_id
      AND sku = v_component.sku
      AND location_code = v_component.source_store_code;
    IF NOT FOUND THEN
      INSERT INTO public.inventory_stock_balances (
        product_id, sku, location_code, available_qty, version, updated_at
      ) VALUES (
        v_component.product_id, v_component.sku, v_component.source_store_code,
        p_returned_qty, 1, now()
      );
    END IF;

    PERFORM public.sync_assembly_lot_return_available(
      v_component.id,
      p_returned_qty,
      p_correlation_id || ':returned-lot'
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
    jsonb_build_object(
      'assembly_job_id', v_job.id,
      'component_id', v_component.id,
      'consumed_qty', p_consumed_qty,
      'wasted_qty', p_wasted_qty,
      'returned_qty', p_returned_qty
    )
  );

  IF v_job.status = 'issued' THEN
    UPDATE public.b2b_assembly_jobs
    SET status = 'in_progress', updated_at = now()
    WHERE id = v_job.id;
  END IF;

  RETURN v_component;
END;
$$;

-- =================================================================================
-- 4. Production receipts classify stock identically in lot and aggregate layers.
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

  SELECT * INTO v_transfer
  FROM public.production_rgs_transfers
  WHERE id = p_transfer_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Transfer not found'; END IF;

  IF coalesce(p_accepted_qty, 0) = 0 AND coalesce(p_hold_qty, 0) = 0 THEN
    RETURN 0;
  END IF;
  IF v_transfer.destination_bin_id IS NULL THEN RETURN 0; END IF;

  IF EXISTS (
    SELECT 1 FROM public.inventory_movements
    WHERE correlation_id = p_correlation_id || ':production-lot'
      AND movement_type = 'lot_position_posted'
  ) THEN
    RETURN 0;
  END IF;

  SELECT * INTO v_bin
  FROM public.b2b_inventory_bins
  WHERE id = v_transfer.destination_bin_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Destination bin not found'; END IF;
  IF v_bin.store_code <> v_transfer.destination_store_code THEN
    RAISE EXCEPTION 'Destination bin store does not match transfer destination store';
  END IF;

  v_status := public.classify_production_receipt_lot_status(
    v_bin.storage_class, v_transfer.expiry_date, p_accepted_qty, p_hold_qty
  );

  v_inserted := false;
  INSERT INTO public.inventory_lot_positions (
    product_id, sku, location_code, bin_id, batch_lot,
    expiry_date, manufactured_date, best_before_date,
    production_rgs_transfer_id,
    available_qty, quarantine_qty, damaged_qty, expired_qty,
    storage_class, position_status
  ) VALUES (
    v_transfer.product_id, v_transfer.sku, v_transfer.destination_store_code,
    v_transfer.destination_bin_id, coalesce(v_transfer.batch_number, 'UNKNOWN'),
    v_transfer.expiry_date, v_transfer.manufactured_date, v_transfer.best_before_date,
    p_transfer_id,
    CASE WHEN v_status = 'available' THEN coalesce(p_accepted_qty, 0) ELSE 0 END,
    coalesce(p_hold_qty, 0)
      + CASE WHEN v_status = 'quarantine' THEN coalesce(p_accepted_qty, 0) ELSE 0 END,
    CASE WHEN v_status = 'damaged' THEN coalesce(p_accepted_qty, 0) ELSE 0 END,
    CASE WHEN v_status = 'expired' THEN coalesce(p_accepted_qty, 0) ELSE 0 END,
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
      v_transfer.destination_store_code,
      p_correlation_id || ':production-lot',
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

CREATE OR REPLACE FUNCTION public.accept_rgs_production_receipt(
  p_transfer_id uuid,
  p_accepted_qty numeric,
  p_rejected_qty numeric,
  p_hold_qty numeric,
  p_expected_balance_version integer,
  p_correlation_id text
)
RETURNS public.production_rgs_transfers
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_actor_id uuid := auth.uid();
  v_transfer public.production_rgs_transfers%ROWTYPE;
  v_bin public.b2b_inventory_bins%ROWTYPE;
  v_status text;
  v_current_version integer;
  v_factory_inventory_id uuid;
BEGIN
  IF v_actor_id IS NULL
     OR NOT public.is_inventory_receive_role((SELECT role FROM public.users WHERE id = v_actor_id)) THEN
    RAISE EXCEPTION 'Not authorised' USING ERRCODE = '42501';
  END IF;
  IF nullif(btrim(p_correlation_id), '') IS NULL THEN
    RAISE EXCEPTION 'A correlation id is required';
  END IF;

  SELECT * INTO v_transfer
  FROM public.production_rgs_transfers
  WHERE id = p_transfer_id
  FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Transfer not found'; END IF;
  IF v_transfer.accepted_qty IS NOT NULL THEN RETURN v_transfer; END IF;
  IF v_transfer.status <> 'received' THEN RAISE EXCEPTION 'Transfer is not awaiting acceptance'; END IF;

  IF least(coalesce(p_accepted_qty, -1), coalesce(p_rejected_qty, -1), coalesce(p_hold_qty, -1)) < 0
     OR coalesce(p_accepted_qty, 0) + coalesce(p_rejected_qty, 0) + coalesce(p_hold_qty, 0)
        <> v_transfer.received_qty THEN
    RAISE EXCEPTION 'Accepted + rejected + hold must equal the received quantity exactly';
  END IF;
  IF p_accepted_qty > 0 AND p_expected_balance_version IS NULL THEN
    RAISE EXCEPTION 'An expected balance version is required when accepting stock';
  END IF;

  PERFORM public.assert_inventory_store_mutation_access(v_actor_id, v_transfer.destination_store_code);

  IF v_transfer.destination_bin_id IS NOT NULL THEN
    SELECT * INTO v_bin
    FROM public.b2b_inventory_bins
    WHERE id = v_transfer.destination_bin_id;
    IF NOT FOUND THEN RAISE EXCEPTION 'Destination bin not found'; END IF;
    IF v_bin.store_code <> v_transfer.destination_store_code THEN
      RAISE EXCEPTION 'Destination bin store does not match transfer destination store';
    END IF;
    v_status := public.classify_production_receipt_lot_status(
      v_bin.storage_class, v_transfer.expiry_date, p_accepted_qty, p_hold_qty
    );
  ELSE
    v_status := CASE
      WHEN coalesce(p_accepted_qty, 0) = 0 AND coalesce(p_hold_qty, 0) > 0 THEN 'quarantine'
      ELSE 'available'
    END;
  END IF;

  IF p_accepted_qty > 0 OR p_hold_qty > 0 THEN
    PERFORM pg_catalog.pg_advisory_xact_lock(
      pg_catalog.hashtextextended(
        v_transfer.product_id::text || ':' || v_transfer.sku || ':' || v_transfer.destination_store_code,
        0
      )
    );

    SELECT version INTO v_current_version
    FROM public.inventory_stock_balances
    WHERE product_id = v_transfer.product_id
      AND sku = v_transfer.sku
      AND location_code = v_transfer.destination_store_code
    FOR UPDATE;

    IF p_accepted_qty > 0 THEN
      IF FOUND THEN
        IF v_current_version <> p_expected_balance_version THEN
          RAISE EXCEPTION 'Stale stock balance version' USING ERRCODE = '40001';
        END IF;
        UPDATE public.inventory_stock_balances
        SET available_qty = available_qty
              + CASE WHEN v_status = 'available' THEN p_accepted_qty ELSE 0 END,
            quarantine_qty = quarantine_qty
              + CASE WHEN v_status = 'quarantine' THEN p_accepted_qty ELSE 0 END,
            damaged_qty = damaged_qty
              + CASE WHEN v_status = 'damaged' THEN p_accepted_qty ELSE 0 END,
            expired_qty = expired_qty
              + CASE WHEN v_status = 'expired' THEN p_accepted_qty ELSE 0 END,
            version = version + 1,
            updated_at = now()
        WHERE product_id = v_transfer.product_id
          AND sku = v_transfer.sku
          AND location_code = v_transfer.destination_store_code
          AND version = p_expected_balance_version;
        IF NOT FOUND THEN
          RAISE EXCEPTION 'Stock balance update did not apply' USING ERRCODE = '40001';
        END IF;
      ELSE
        IF p_expected_balance_version <> 0 THEN
          RAISE EXCEPTION 'Stock balance does not exist at expected version' USING ERRCODE = '40001';
        END IF;
        INSERT INTO public.inventory_stock_balances (
          product_id, sku, location_code,
          available_qty, quarantine_qty, damaged_qty, expired_qty
        ) VALUES (
          v_transfer.product_id, v_transfer.sku, v_transfer.destination_store_code,
          CASE WHEN v_status = 'available' THEN p_accepted_qty ELSE 0 END,
          CASE WHEN v_status = 'quarantine' THEN p_accepted_qty ELSE 0 END,
          CASE WHEN v_status = 'damaged' THEN p_accepted_qty ELSE 0 END,
          CASE WHEN v_status = 'expired' THEN p_accepted_qty ELSE 0 END
        );
      END IF;

      INSERT INTO public.inventory_movements (
        movement_type, product_id, sku, quantity, destination_location, actor_id,
        reason_code, correlation_id, source_document_type, source_document_reference,
        batch_lot, metadata
      ) VALUES (
        'production_receipt_accepted', v_transfer.product_id, v_transfer.sku,
        p_accepted_qty, v_transfer.destination_store_code, v_actor_id,
        'rgs_production_acceptance', p_correlation_id,
        'production_rgs_transfer', v_transfer.id::text, v_transfer.batch_number,
        jsonb_build_object(
          'transfer_id', v_transfer.id,
          'accepted_qty', p_accepted_qty,
          'inventory_bucket', v_status
        )
      );

      IF v_status = 'available' AND v_transfer.product_id IS NOT NULL THEN
        SELECT id INTO v_factory_inventory_id
        FROM public.factory_inventory
        WHERE product_id = v_transfer.product_id
        LIMIT 1;
        IF v_factory_inventory_id IS NOT NULL THEN
          UPDATE public.factory_inventory
          SET quantity = coalesce(quantity, 0) + p_accepted_qty,
              last_updated = now()
          WHERE id = v_factory_inventory_id;
        ELSE
          INSERT INTO public.factory_inventory (product_id, quantity)
          VALUES (v_transfer.product_id, p_accepted_qty);
        END IF;
      END IF;
    END IF;

    IF p_hold_qty > 0 THEN
      UPDATE public.inventory_stock_balances
      SET quarantine_qty = quarantine_qty + p_hold_qty,
          version = version + 1,
          updated_at = now()
      WHERE product_id = v_transfer.product_id
        AND sku = v_transfer.sku
        AND location_code = v_transfer.destination_store_code;
      IF NOT FOUND THEN
        INSERT INTO public.inventory_stock_balances (
          product_id, sku, location_code, quarantine_qty
        ) VALUES (
          v_transfer.product_id, v_transfer.sku, v_transfer.destination_store_code,
          p_hold_qty
        );
      END IF;

      INSERT INTO public.inventory_movements (
        movement_type, product_id, sku, quantity, destination_location,
        actor_id, reason_code, correlation_id, metadata
      ) VALUES (
        'stock_quarantined', v_transfer.product_id, v_transfer.sku, p_hold_qty,
        v_transfer.destination_store_code, v_actor_id, 'production_qc_hold',
        p_correlation_id || ':hold',
        jsonb_build_object('transfer_id', v_transfer.id, 'hold_qty', p_hold_qty)
      );
    END IF;
  END IF;

  PERFORM public.post_production_receipt_lot_positions(
    p_transfer_id, p_accepted_qty, p_hold_qty, p_correlation_id
  );

  UPDATE public.production_rgs_transfers
  SET accepted_qty = p_accepted_qty,
      rejected_qty = p_rejected_qty,
      hold_qty = p_hold_qty,
      status = CASE
        WHEN p_accepted_qty = 0 THEN 'rejected'
        WHEN p_accepted_qty < v_transfer.received_qty THEN 'partially_accepted'
        ELSE 'accepted'
      END,
      accepted_by = v_actor_id,
      accepted_at = now(),
      rgs_notified = true
  WHERE id = p_transfer_id
  RETURNING * INTO v_transfer;

  RETURN v_transfer;
END;
$$;

-- =================================================================================
-- 5. Reconciliation now compares all lot buckets represented by the canonical balance.
--    Existing view columns remain in their original order; new bucket details append.
-- =================================================================================

CREATE OR REPLACE VIEW public.inventory_lot_aggregate_reconciliation
WITH (security_invoker=true) AS
WITH lot_agg AS (
  SELECT
    location_code,
    product_id,
    sku,
    sum(available_qty) FILTER (WHERE position_status = 'available') AS lot_available_qty,
    sum(reserved_qty) AS lot_reserved_qty,
    sum(picked_qty) AS lot_picked_qty,
    sum(quarantine_qty) AS lot_quarantine_qty,
    sum(damaged_qty) AS lot_damaged_qty,
    sum(expired_qty) AS lot_expired_qty,
    sum(
      CASE WHEN position_status = 'available' THEN available_qty ELSE 0 END
      + reserved_qty + picked_qty + quarantine_qty + damaged_qty + expired_qty
    ) AS lot_total_qty
  FROM public.inventory_lot_positions
  GROUP BY location_code, product_id, sku
)
SELECT
  coalesce(l.location_code, b.location_code) AS location_code,
  coalesce(l.product_id, b.product_id) AS product_id,
  coalesce(l.sku, b.sku) AS sku,
  coalesce(l.lot_available_qty, 0) AS lot_available_qty,
  coalesce(l.lot_reserved_qty, 0) AS lot_reserved_qty,
  coalesce(l.lot_picked_qty, 0) AS lot_picked_qty,
  coalesce(l.lot_total_qty, 0) AS lot_total_qty,
  b.available_qty AS balance_available_qty,
  b.reserved_qty AS balance_reserved_qty,
  b.picked_qty AS balance_picked_qty,
  (b.available_qty + b.reserved_qty + b.picked_qty
    + b.quarantine_qty + b.damaged_qty + b.expired_qty) AS balance_total_qty,
  CASE
    WHEN b.product_id IS NULL THEN 'balance_missing'
    WHEN coalesce(l.lot_total_qty, 0) = 0 THEN 'no_lot_positions'
    WHEN coalesce(l.lot_available_qty, 0) > b.available_qty + 0.0001
      OR coalesce(l.lot_reserved_qty, 0) > b.reserved_qty + 0.0001
      OR coalesce(l.lot_picked_qty, 0) > b.picked_qty + 0.0001
      OR coalesce(l.lot_quarantine_qty, 0) > b.quarantine_qty + 0.0001
      OR coalesce(l.lot_damaged_qty, 0) > b.damaged_qty + 0.0001
      OR coalesce(l.lot_expired_qty, 0) > b.expired_qty + 0.0001
    THEN 'lot_exceeds_balance'
    ELSE 'reconciled'
  END AS reconciliation_status,
  coalesce(l.lot_quarantine_qty, 0) AS lot_quarantine_qty,
  coalesce(l.lot_damaged_qty, 0) AS lot_damaged_qty,
  coalesce(l.lot_expired_qty, 0) AS lot_expired_qty,
  b.quarantine_qty AS balance_quarantine_qty,
  b.damaged_qty AS balance_damaged_qty,
  b.expired_qty AS balance_expired_qty
FROM public.inventory_stock_balances b
FULL OUTER JOIN lot_agg l
  ON l.product_id = b.product_id
 AND l.sku = b.sku
 AND l.location_code = b.location_code;

COMMENT ON VIEW public.inventory_lot_aggregate_reconciliation IS
  'Lot-position aggregate vs canonical inventory_stock_balances reconciliation across available, reserved, picked, quarantine, damaged, and expired buckets.';

REVOKE ALL ON public.inventory_lot_aggregate_reconciliation FROM PUBLIC, anon;
GRANT SELECT ON public.inventory_lot_aggregate_reconciliation TO authenticated;

-- Legacy private helpers remain revoked; final assembly paths above no longer call them.
REVOKE ALL ON FUNCTION public.sync_lot_issue_reserved(uuid, text, text, numeric, text),
  public.sync_lot_return_available(uuid, text, text, numeric, text)
  FROM PUBLIC, anon, authenticated;

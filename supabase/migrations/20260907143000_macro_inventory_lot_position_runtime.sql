-- MACRO INVENTORY + FACTORY RUNTIME: canonical lot positions, FEFO/FIFO selection,
-- atomic lot allocation to reservations, and GRN put-away reconciliation.
-- Extends the single inventory_stock_balances ledger — no parallel stock truth.

SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '120s';

-- =================================================================================
-- 1. Schema: authoritative lot/bin positions with expiry lineage
-- =================================================================================

CREATE TABLE public.inventory_lot_positions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  product_id uuid NOT NULL REFERENCES public.products(id) ON DELETE RESTRICT,
  sku text NOT NULL,
  location_code text NOT NULL,
  bin_id uuid NOT NULL REFERENCES public.b2b_inventory_bins(id) ON DELETE RESTRICT,
  batch_lot text NOT NULL,
  expiry_date date NULL,
  manufactured_date date NULL,
  best_before_date date NULL,
  receipt_line_id uuid NOT NULL REFERENCES public.b2b_inventory_receipt_lines(id) ON DELETE RESTRICT,
  putaway_task_id uuid NOT NULL UNIQUE REFERENCES public.b2b_inventory_putaway_tasks(id) ON DELETE RESTRICT,
  grn_id uuid NULL REFERENCES public.b2b_inventory_grns(id) ON DELETE RESTRICT,
  available_qty numeric NOT NULL DEFAULT 0 CHECK (available_qty >= 0),
  reserved_qty numeric NOT NULL DEFAULT 0 CHECK (reserved_qty >= 0),
  picked_qty numeric NOT NULL DEFAULT 0 CHECK (picked_qty >= 0),
  storage_class text NOT NULL DEFAULT 'ambient',
  position_status text NOT NULL DEFAULT 'available'
    CHECK (position_status IN ('available', 'quarantine', 'damaged', 'expired', 'depleted')),
  version integer NOT NULL DEFAULT 1,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT inventory_lot_positions_qty_coherent CHECK (
    available_qty + reserved_qty + picked_qty >= 0
  )
);

CREATE INDEX idx_inventory_lot_positions_selection
  ON public.inventory_lot_positions (product_id, sku, location_code, position_status)
  WHERE position_status = 'available' AND available_qty > 0;

CREATE INDEX idx_inventory_lot_positions_grn ON public.inventory_lot_positions (grn_id);

COMMENT ON TABLE public.inventory_lot_positions IS
  'Canonical lot/batch stock positions bound to bin/rack/shelf. Aggregate inventory_stock_balances remain the store-level truth; lot positions provide bin-level lineage and FEFO/FIFO allocation authority.';

ALTER TABLE public.inventory_lot_positions ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Staff read lot positions" ON public.inventory_lot_positions
  FOR SELECT TO authenticated USING (public.is_internal_staff((SELECT auth.uid())));
REVOKE ALL ON public.inventory_lot_positions FROM anon;
REVOKE INSERT, UPDATE, DELETE ON public.inventory_lot_positions FROM authenticated;
GRANT SELECT ON public.inventory_lot_positions TO authenticated;

-- Extend movement vocabulary for lot posting/allocation lifecycle.
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
    'lot_position_posted', 'lot_allocated', 'lot_allocation_released', 'lot_picked'
  ])) NOT VALID;

ALTER TABLE public.inventory_movements
  VALIDATE CONSTRAINT inventory_movements_type_check;

-- Restrict reservation allocation writes to governed RPCs.
DROP POLICY IF EXISTS "Staff insert reservation allocations" ON public.inventory_reservation_allocations;
DROP POLICY IF EXISTS "Staff update reservation allocations" ON public.inventory_reservation_allocations;
REVOKE INSERT, UPDATE, DELETE ON public.inventory_reservation_allocations FROM authenticated, anon;

COMMENT ON TABLE public.inventory_reservation_allocations IS
  'Atomic lot-level allocations to reservations. Writes via allocate_lots_to_reservation / fulfill_lot_allocations_on_pick only.';

-- =================================================================================
-- 2. Internal: post lot positions from completed GRN put-away
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
      AND t.disposition = 'accepted'
      AND t.status = 'completed'
      AND t.placed_qty > 0
  LOOP
    SELECT * INTO v_line FROM public.b2b_inventory_receipt_lines WHERE id = v_task.receipt_line_id;
    SELECT * INTO v_bin FROM public.b2b_inventory_bins WHERE id = v_task.bin_id;
    v_batch := coalesce(v_line.oasis_batch_lot, v_line.supplier_batch_lot, 'UNKNOWN');
    v_status := CASE
      WHEN v_bin.storage_class IN ('rejected', 'return_to_vendor') THEN 'quarantine'
      WHEN v_bin.storage_class IN ('quarantine', 'damaged') THEN v_bin.storage_class
      WHEN v_line.expiry_date IS NOT NULL AND v_line.expiry_date < current_date THEN 'expired'
      ELSE 'available'
    END;

    INSERT INTO public.inventory_lot_positions (
      product_id, sku, location_code, bin_id, batch_lot, expiry_date,
      receipt_line_id, putaway_task_id, grn_id,
      available_qty, storage_class, position_status
    ) VALUES (
      v_line.product_id, v_line.sku, v_receipt.destination_store_code, v_task.bin_id,
      v_batch, v_line.expiry_date, v_line.id, v_task.id, p_grn_id,
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
          'bin_id', v_task.bin_id, 'position_status', v_status
        )
      );
    END IF;
  END LOOP;

  RETURN v_count;
END;
$$;

-- =================================================================================
-- 3. FEFO/FIFO candidate selection (fail-closed exclusion)
-- =================================================================================

CREATE OR REPLACE FUNCTION public.select_inventory_lot_candidates(
  p_product_id uuid,
  p_sku text,
  p_location_code text,
  p_selection_mode text DEFAULT 'fefo',
  p_limit integer DEFAULT NULL
)
RETURNS SETOF public.inventory_lot_positions
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  IF p_selection_mode NOT IN ('fefo', 'fifo') THEN
    RAISE EXCEPTION 'Selection mode must be fefo or fifo';
  END IF;

  RETURN QUERY
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
  ORDER BY
    CASE WHEN p_selection_mode = 'fifo' THEN lp.created_at END ASC,
    CASE WHEN p_selection_mode = 'fefo' THEN lp.expiry_date END ASC NULLS LAST,
    lp.created_at ASC
  LIMIT p_limit;
END;
$$;

-- =================================================================================
-- 4. Atomic lot allocation to reservations
-- =================================================================================

CREATE OR REPLACE FUNCTION public.allocate_lots_to_reservation(
  p_reservation_id uuid,
  p_allocate_qty numeric,
  p_selection_mode text,
  p_correlation_id text
)
RETURNS SETOF public.inventory_reservation_allocations
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_actor uuid := auth.uid();
  v_reservation public.inventory_reservations%ROWTYPE;
  v_candidate public.inventory_lot_positions%ROWTYPE;
  v_remaining numeric;
  v_take numeric;
  v_already_allocated numeric;
  v_alloc public.inventory_reservation_allocations%ROWTYPE;
BEGIN
  IF v_actor IS NULL OR NOT (
    public.is_inventory_manage_role((SELECT role FROM public.users WHERE id = v_actor))
    OR public.is_inventory_receive_role((SELECT role FROM public.users WHERE id = v_actor))
  ) THEN
    RAISE EXCEPTION 'Not authorised to allocate lots' USING ERRCODE = '42501';
  END IF;
  IF p_allocate_qty IS NULL OR p_allocate_qty <= 0 THEN
    RAISE EXCEPTION 'Allocate quantity must be positive';
  END IF;
  IF p_selection_mode NOT IN ('fefo', 'fifo') THEN
    RAISE EXCEPTION 'Selection mode must be fefo or fifo';
  END IF;
  IF nullif(btrim(p_correlation_id), '') IS NULL THEN
    RAISE EXCEPTION 'A correlation id is required';
  END IF;

  -- Idempotent replay.
  IF EXISTS (
    SELECT 1 FROM public.inventory_movements
    WHERE correlation_id LIKE p_correlation_id || '%' AND movement_type = 'lot_allocated'
  ) THEN
    RETURN QUERY
    SELECT a.* FROM public.inventory_reservation_allocations a
    WHERE a.reservation_id = p_reservation_id
      AND a.inventory_entity_type = 'lot_position'
      AND a.allocation_status = 'active';
    RETURN;
  END IF;

  SELECT * INTO v_reservation FROM public.inventory_reservations WHERE id = p_reservation_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Reservation not found'; END IF;
  IF v_reservation.reservation_status NOT IN ('reserved', 'partially_reserved') THEN
    RAISE EXCEPTION 'Reservation is not in an allocatable state';
  END IF;

  SELECT coalesce(sum(allocated_qty), 0) INTO v_already_allocated
  FROM public.inventory_reservation_allocations
  WHERE reservation_id = p_reservation_id AND allocation_status = 'active';

  IF p_allocate_qty > v_reservation.reserved_qty - v_already_allocated THEN
    RAISE EXCEPTION 'Allocate quantity exceeds unallocated reserved quantity';
  END IF;

  PERFORM pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(
      v_reservation.product_id::text || ':' || v_reservation.sku || ':' || v_reservation.location_code, 0
    )
  );

  v_remaining := p_allocate_qty;

  FOR v_candidate IN
    SELECT * FROM public.select_inventory_lot_candidates(
      v_reservation.product_id, v_reservation.sku, v_reservation.location_code,
      p_selection_mode, NULL
    )
  LOOP
    EXIT WHEN v_remaining <= 0;

    SELECT * INTO v_candidate FROM public.inventory_lot_positions WHERE id = v_candidate.id FOR UPDATE;
    IF v_candidate.available_qty <= 0 THEN CONTINUE; END IF;

    v_take := least(v_remaining, v_candidate.available_qty);

    UPDATE public.inventory_lot_positions
    SET available_qty = available_qty - v_take,
        reserved_qty = reserved_qty + v_take,
        version = version + 1,
        updated_at = now()
    WHERE id = v_candidate.id;

    INSERT INTO public.inventory_reservation_allocations (
      reservation_id, inventory_entity_type, inventory_entity_id, allocated_qty
    ) VALUES (
      p_reservation_id, 'lot_position', v_candidate.id, v_take
    )
    RETURNING * INTO v_alloc;

    INSERT INTO public.inventory_movements (
      movement_type, reservation_id, product_id, sku, quantity,
      source_location, actor_id, correlation_id, batch_lot, expiry_date, metadata
    ) VALUES (
      'lot_allocated', p_reservation_id, v_reservation.product_id, v_reservation.sku, v_take,
      v_reservation.location_code, v_actor, p_correlation_id || ':lot:' || v_candidate.id,
      v_candidate.batch_lot, v_candidate.expiry_date,
      jsonb_build_object('lot_position_id', v_candidate.id, 'selection_mode', p_selection_mode)
    );

    v_remaining := v_remaining - v_take;
    RETURN NEXT v_alloc;
  END LOOP;

  IF v_remaining > 0 THEN
    RAISE EXCEPTION 'Insufficient eligible lot stock: short by %', v_remaining;
  END IF;

  RETURN;
END;
$$;

-- =================================================================================
-- 5. Fulfill lot allocations when picking (integrates with pick_rgs_reservation)
-- =================================================================================

CREATE OR REPLACE FUNCTION public.fulfill_lot_allocations_on_pick(
  p_reservation_id uuid,
  p_pick_qty numeric,
  p_correlation_id text
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_alloc record;
  v_remaining numeric := p_pick_qty;
  v_take numeric;
BEGIN
  FOR v_alloc IN
    SELECT a.*, lp.batch_lot, lp.expiry_date, lp.product_id, lp.sku, lp.location_code
    FROM public.inventory_reservation_allocations a
    JOIN public.inventory_lot_positions lp ON lp.id = a.inventory_entity_id
    WHERE a.reservation_id = p_reservation_id
      AND a.inventory_entity_type = 'lot_position'
      AND a.allocation_status = 'active'
    ORDER BY a.allocated_at
  LOOP
    EXIT WHEN v_remaining <= 0;
    v_take := least(v_remaining, v_alloc.allocated_qty);

    UPDATE public.inventory_lot_positions
    SET reserved_qty = reserved_qty - v_take,
        picked_qty = picked_qty + v_take,
        position_status = CASE
          WHEN available_qty = 0 AND reserved_qty - v_take <= 0 THEN 'depleted'
          ELSE position_status
        END,
        version = version + 1,
        updated_at = now()
    WHERE id = v_alloc.inventory_entity_id;

    IF v_take >= v_alloc.allocated_qty THEN
      UPDATE public.inventory_reservation_allocations
      SET allocation_status = 'fulfilled'
      WHERE id = v_alloc.id;
    ELSE
      UPDATE public.inventory_reservation_allocations
      SET allocated_qty = allocated_qty - v_take
      WHERE id = v_alloc.id;
    END IF;

    INSERT INTO public.inventory_movements (
      movement_type, reservation_id, product_id, sku, quantity,
      source_location, correlation_id, batch_lot, expiry_date, metadata
    ) VALUES (
      'lot_picked', p_reservation_id, v_alloc.product_id, v_alloc.sku, v_take,
      v_alloc.location_code, p_correlation_id || ':fulfill:' || v_alloc.id,
      v_alloc.batch_lot, v_alloc.expiry_date,
      jsonb_build_object('lot_position_id', v_alloc.inventory_entity_id)
    );

    v_remaining := v_remaining - v_take;
  END LOOP;

  IF v_remaining > 0 AND EXISTS (
    SELECT 1 FROM public.inventory_reservation_allocations
    WHERE reservation_id = p_reservation_id AND inventory_entity_type = 'lot_position' AND allocation_status = 'active'
  ) THEN
    RAISE EXCEPTION 'Pick quantity exceeds active lot allocation total';
  END IF;
END;
$$;

-- =================================================================================
-- 6. Extend finalise_b2b_inventory_grn to post lot positions
-- =================================================================================

CREATE OR REPLACE FUNCTION public.finalise_b2b_inventory_grn(
  p_receipt_id uuid, p_grn_number text, p_correlation_id text
) RETURNS public.b2b_inventory_grns
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_actor uuid:=auth.uid();
  v_receipt public.b2b_inventory_receipts%ROWTYPE;
  v_grn public.b2b_inventory_grns%ROWTYPE;
  v_group record;
  v_line public.b2b_inventory_receipt_lines%ROWTYPE;
BEGIN
  IF v_actor IS NULL OR NOT public.can_manage_b2b_inventory(v_actor) THEN
    RAISE EXCEPTION 'Not authorised' USING ERRCODE='42501';
  END IF;
  IF nullif(btrim(p_grn_number),'') IS NULL OR nullif(btrim(p_correlation_id),'') IS NULL THEN
    RAISE EXCEPTION 'GRN number and correlation id are required';
  END IF;
  SELECT * INTO v_receipt FROM public.b2b_inventory_receipts
    WHERE id=p_receipt_id FOR UPDATE;
  IF NOT FOUND OR v_receipt.status NOT IN ('accepted','partially_accepted','rejected') THEN
    RAISE EXCEPTION 'Receipt is not ready for GRN';
  END IF;
  IF NOT public.can_access_b2b_inventory_store(v_actor,v_receipt.destination_store_code,'manage') THEN
    RAISE EXCEPTION 'Not authorised' USING ERRCODE='42501';
  END IF;
  IF EXISTS (SELECT 1 FROM public.b2b_inventory_putaway_tasks t
    JOIN public.b2b_inventory_receipt_lines l ON l.id=t.receipt_line_id
    WHERE l.receipt_id=p_receipt_id AND t.status<>'completed') THEN
    RAISE EXCEPTION 'Every put-away task must be completed';
  END IF;
  IF EXISTS (SELECT 1 FROM public.b2b_inventory_receipt_lines l
    WHERE l.receipt_id=p_receipt_id AND l.accepted_qty>0 AND NOT EXISTS (
      SELECT 1 FROM public.b2b_inventory_putaway_tasks t
      WHERE t.receipt_line_id=l.id AND t.disposition='accepted' AND t.status='completed')) THEN
    RAISE EXCEPTION 'Every accepted quantity requires completed put-away';
  END IF;
  IF EXISTS (SELECT 1 FROM public.b2b_inventory_receipt_lines l
    WHERE l.receipt_id=p_receipt_id AND
      coalesce((SELECT sum(t.allocated_qty) FROM public.b2b_inventory_putaway_tasks t
        WHERE t.receipt_line_id=l.id AND t.disposition='accepted'),0)<>l.accepted_qty) THEN
    RAISE EXCEPTION 'Put-away does not reconcile with accepted quantity';
  END IF;
  IF EXISTS (SELECT 1 FROM public.b2b_inventory_grns
    WHERE receipt_id=p_receipt_id AND status IN ('draft','finalised')) THEN
    RAISE EXCEPTION 'Receipt already has an open GRN';
  END IF;
  IF EXISTS (SELECT 1 FROM public.b2b_inventory_grns
    WHERE receipt_id=p_receipt_id AND stock_posted_at IS NOT NULL) THEN
    RAISE EXCEPTION 'Receipt stock has already been posted';
  END IF;

  INSERT INTO public.b2b_inventory_grns(
    grn_number,receipt_id,status,finalised_by,finalised_at,correlation_id,
    stock_posted_at,stock_posted_by
  ) VALUES (btrim(p_grn_number),p_receipt_id,'finalised',v_actor,now(),p_correlation_id,now(),v_actor)
  RETURNING * INTO v_grn;

  FOR v_group IN
    SELECT product_id, sku, sum(accepted_qty) AS qty
    FROM public.b2b_inventory_receipt_lines
    WHERE receipt_id=p_receipt_id AND accepted_qty>0
    GROUP BY product_id,sku
  LOOP
    UPDATE public.inventory_stock_balances
    SET available_qty=available_qty+v_group.qty, version=version+1, updated_at=now()
    WHERE product_id=v_group.product_id AND sku=v_group.sku
      AND location_code=v_receipt.destination_store_code;
    IF NOT FOUND THEN RAISE EXCEPTION 'Held stock balance missing at GRN finalisation'; END IF;
  END LOOP;

  FOR v_line IN SELECT * FROM public.b2b_inventory_receipt_lines
    WHERE receipt_id=p_receipt_id AND accepted_qty>0 ORDER BY id
  LOOP
    INSERT INTO public.inventory_movements(
      movement_type,product_id,sku,quantity,destination_location,actor_id,
      reason_code,correlation_id,source_document_type,source_document_reference,
      batch_lot,expiry_date,metadata
    ) VALUES (
      'inventory_unhold',v_line.product_id,v_line.sku,v_line.accepted_qty,
      v_receipt.destination_store_code,v_actor,'grn_finalised',
      p_correlation_id || ':stock-post:' || v_line.id,
      v_receipt.source_document_type,v_receipt.source_document_reference,
      coalesce(v_line.oasis_batch_lot,v_line.supplier_batch_lot),v_line.expiry_date,
      jsonb_build_object('grn_id',v_grn.id,'grn_number',v_grn.grn_number,
        'receipt_id',p_receipt_id,'receipt_line_id',v_line.id)
    );
  END LOOP;

  PERFORM public.post_grn_inventory_lot_positions(v_grn.id, p_correlation_id);

  RETURN v_grn;
END $$;

-- =================================================================================
-- 7. Extend pick_rgs_reservation to fulfill lot allocations when present
-- =================================================================================

CREATE OR REPLACE FUNCTION public.pick_rgs_reservation(
  p_reservation_id uuid,
  p_pick_qty numeric,
  p_correlation_id text
)
RETURNS public.inventory_reservations
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_actor_id uuid := auth.uid();
  v_reservation public.inventory_reservations%ROWTYPE;
BEGIN
  IF v_actor_id IS NULL OR NOT public.is_internal_staff(v_actor_id) THEN
    RAISE EXCEPTION 'Not authorised' USING ERRCODE = '42501';
  END IF;
  IF nullif(btrim(p_correlation_id), '') IS NULL THEN
    RAISE EXCEPTION 'A correlation id is required';
  END IF;
  IF EXISTS (
    SELECT 1 FROM public.inventory_movements
    WHERE correlation_id = p_correlation_id AND movement_type = 'stock_picked'
  ) THEN
    SELECT * INTO v_reservation FROM public.inventory_reservations WHERE id = p_reservation_id;
    RETURN v_reservation;
  END IF;

  SELECT * INTO v_reservation FROM public.inventory_reservations WHERE id = p_reservation_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Reservation not found'; END IF;
  IF p_pick_qty IS NULL OR p_pick_qty <= 0 OR p_pick_qty > v_reservation.reserved_qty THEN
    RAISE EXCEPTION 'Pick quantity must be positive and cannot exceed reserved quantity';
  END IF;

  PERFORM pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(v_reservation.product_id::text || ':' || v_reservation.sku || ':' || v_reservation.location_code, 0)
  );

  -- Fulfill lot allocations when they exist for this reservation.
  IF EXISTS (
    SELECT 1 FROM public.inventory_reservation_allocations
    WHERE reservation_id = p_reservation_id
      AND inventory_entity_type = 'lot_position'
      AND allocation_status = 'active'
  ) THEN
    PERFORM public.fulfill_lot_allocations_on_pick(p_reservation_id, p_pick_qty, p_correlation_id);
  END IF;

  UPDATE public.inventory_stock_balances
  SET reserved_qty = reserved_qty - p_pick_qty, picked_qty = picked_qty + p_pick_qty, version = version + 1, updated_at = now()
  WHERE product_id = v_reservation.product_id AND sku = v_reservation.sku AND location_code = v_reservation.location_code;
  IF NOT FOUND THEN RAISE EXCEPTION 'Stock balance not found'; END IF;

  INSERT INTO public.inventory_movements (
    movement_type, reservation_id, product_id, sku, quantity, source_location, actor_id, correlation_id
  ) VALUES (
    'stock_picked', p_reservation_id, v_reservation.product_id, v_reservation.sku, p_pick_qty,
    v_reservation.location_code, v_actor_id, p_correlation_id
  );

  RETURN v_reservation;
END;
$$;

-- =================================================================================
-- 8. Aggregate reconciliation view: lot positions vs store balances
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
    sum(
      CASE WHEN position_status = 'available' THEN available_qty ELSE 0 END
      + reserved_qty + picked_qty
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
  (b.available_qty + b.reserved_qty + b.picked_qty) AS balance_total_qty,
  CASE
    WHEN b.product_id IS NULL THEN 'balance_missing'
    WHEN coalesce(l.lot_total_qty, 0) = 0 THEN 'no_lot_positions'
    WHEN coalesce(l.lot_available_qty, 0) > b.available_qty + 0.0001 THEN 'lot_exceeds_balance'
    ELSE 'reconciled'
  END AS reconciliation_status
FROM public.inventory_stock_balances b
FULL OUTER JOIN lot_agg l
  ON l.product_id = b.product_id AND l.sku = b.sku AND l.location_code = b.location_code;

COMMENT ON VIEW public.inventory_lot_aggregate_reconciliation IS
  'Lot-position aggregate vs store-level inventory_stock_balances reconciliation. Lot totals must not exceed balance buckets.';

-- =================================================================================
-- Grants
-- =================================================================================

REVOKE ALL ON FUNCTION public.post_grn_inventory_lot_positions(uuid, text) FROM PUBLIC, anon, authenticated;

REVOKE ALL ON FUNCTION public.select_inventory_lot_candidates(uuid, text, text, text, integer) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.select_inventory_lot_candidates(uuid, text, text, text, integer) TO authenticated;

REVOKE ALL ON FUNCTION public.allocate_lots_to_reservation(uuid, numeric, text, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.allocate_lots_to_reservation(uuid, numeric, text, text) TO authenticated;

REVOKE ALL ON FUNCTION public.fulfill_lot_allocations_on_pick(uuid, numeric, text) FROM PUBLIC, anon, authenticated;

REVOKE ALL ON FUNCTION public.finalise_b2b_inventory_grn(uuid, text, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.finalise_b2b_inventory_grn(uuid, text, text) TO authenticated;

REVOKE ALL ON FUNCTION public.pick_rgs_reservation(uuid, numeric, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.pick_rgs_reservation(uuid, numeric, text) TO authenticated;

REVOKE ALL ON public.inventory_lot_aggregate_reconciliation FROM PUBLIC, anon;
GRANT SELECT ON public.inventory_lot_aggregate_reconciliation TO authenticated;

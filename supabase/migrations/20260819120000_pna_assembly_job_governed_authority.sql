-- Lane 2 (P&A) PR B: governed assembly job lifecycle RPCs.
--
-- b2b_assembly_jobs / b2b_assembly_components (20260803194132) shipped a
-- correct, versioned, forward-only-state-machine schema for P&A's component-
-- level BOM custody, but zero RPCs and zero client callers -- every write
-- path allowed by its RLS ("Assembly operators maintain B2B assembly jobs" /
-- "...components", FOR ALL TO authenticated) was a raw, ungoverned table
-- write. This migration adds the governed RPC layer, modeled directly on the
-- proven RGS pattern already live in reserve_rgs_stock / issue_rgs_stock /
-- create_production_shortage_demand (SECURITY DEFINER, correlation-id
-- idempotency, per-resource advisory lock, optimistic-version CAS on
-- inventory_stock_balances, append-only ledger insert, forward-only status
-- transitions), then revokes the direct table grants so RPC-only writes are
-- the sole path, matching every other governed surface in this schema.
--
-- Authoritative boundaries enforced by this migration (do not weaken):
--   * Food demand shortfalls (source_store_code = FINISHED_GOODS) route
--     P&A -> RGS -> Production via the EXISTING create_production_shortage_demand
--     RPC. This migration never inserts into production_jobs directly.
--   * Packaging/outsourced/giftware shortfalls (3PGS / PACKING_ASSEMBLY /
--     B2B_RAW) are never routed to Production. They are left as an
--     under-reserved component for 3PGS's own (out-of-scope-here) workflows
--     to action; no new 3PGS RPC is introduced by this migration.
--   * accept_assembly_output finalises P&A's OWN QC decision on its own
--     temporary WIP/output custody. It never writes to inventory_stock_balances
--     or any RGS/3PGS-owned table -- RGS/3PGS stock only increases through
--     their own existing acceptance RPCs (e.g. accept_rgs_production_receipt).
--     "Ready" (QC-accepted P&A output) is therefore never conflated with an
--     RGS/3PGS stock increase.
--   * Ready (qc accepted/partially_accepted), Handed Over, Job Completed and
--     Job Closed are kept as four distinct, separately-timestamped states.
--     handed_over_at / job_completed_at / closed_at are additive columns;
--     the existing status CHECK/transition trigger is untouched.

SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '60s';

-- =================================================================================
-- 1. Additive schema: idempotency + the Handed Over / Job Closed states the
--    existing status machine (planned..accepted/partially_accepted/rejected/
--    cancelled) does not yet distinguish from QC acceptance.
-- =================================================================================

ALTER TABLE public.b2b_assembly_jobs
  ADD COLUMN IF NOT EXISTS reserved_at timestamptz NULL,
  ADD COLUMN IF NOT EXISTS issued_at timestamptz NULL,
  ADD COLUMN IF NOT EXISTS handed_over_at timestamptz NULL,
  ADD COLUMN IF NOT EXISTS handed_over_by uuid NULL REFERENCES public.users (id) ON DELETE RESTRICT,
  ADD COLUMN IF NOT EXISTS job_closed_at timestamptz NULL,
  ADD COLUMN IF NOT EXISTS job_closed_by uuid NULL REFERENCES public.users (id) ON DELETE RESTRICT;

COMMENT ON COLUMN public.b2b_assembly_jobs.handed_over_at IS
  'Physical/custody handover of accepted output to RGS or 3PGS. Distinct from QC acceptance (status) and from job_closed_at.';
COMMENT ON COLUMN public.b2b_assembly_jobs.job_closed_at IS
  'Administrative closure after handover is confirmed. Distinct from QC acceptance and from handed_over_at.';

-- =================================================================================
-- 2. create_assembly_job: opens a job and snapshots its component requirements.
-- =================================================================================
CREATE OR REPLACE FUNCTION public.create_assembly_job(
  p_assembly_job_number text,
  p_order_id uuid,
  p_output_product_id uuid,
  p_output_sku text,
  p_planned_qty numeric,
  p_components jsonb,
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
  v_component jsonb;
BEGIN
  IF v_actor_id IS NULL OR NOT public.can_manage_b2b_inventory(v_actor_id) THEN
    RAISE EXCEPTION 'Not authorised to create an assembly job' USING ERRCODE = '42501';
  END IF;
  IF nullif(btrim(p_correlation_id), '') IS NULL THEN
    RAISE EXCEPTION 'A correlation id is required';
  END IF;
  IF p_planned_qty IS NULL OR p_planned_qty <= 0 THEN
    RAISE EXCEPTION 'Planned quantity must be positive';
  END IF;
  IF p_components IS NULL OR jsonb_typeof(p_components) <> 'array' OR jsonb_array_length(p_components) = 0 THEN
    RAISE EXCEPTION 'At least one component is required';
  END IF;

  SELECT * INTO v_job FROM public.b2b_assembly_jobs WHERE correlation_id = p_correlation_id;
  IF FOUND THEN
    RETURN v_job;
  END IF;

  INSERT INTO public.b2b_assembly_jobs (
    assembly_job_number, order_id, output_product_id, output_sku, planned_qty,
    status, correlation_id
  ) VALUES (
    p_assembly_job_number, p_order_id, p_output_product_id, p_output_sku, p_planned_qty,
    'planned', p_correlation_id
  )
  RETURNING * INTO v_job;

  FOR v_component IN SELECT * FROM jsonb_array_elements(p_components)
  LOOP
    IF NOT (v_component ? 'product_id' AND v_component ? 'sku' AND v_component ? 'source_store_code' AND v_component ? 'required_qty') THEN
      RAISE EXCEPTION 'Each component requires product_id, sku, source_store_code and required_qty';
    END IF;
    INSERT INTO public.b2b_assembly_components (
      assembly_job_id, product_id, sku, source_store_code, required_qty
    ) VALUES (
      v_job.id,
      (v_component->>'product_id')::uuid,
      v_component->>'sku',
      v_component->>'source_store_code',
      (v_component->>'required_qty')::numeric
    );
  END LOOP;

  RETURN v_job;
END;
$$;

COMMENT ON FUNCTION public.create_assembly_job(text, uuid, uuid, text, numeric, jsonb, text) IS
  'Opens a P&A assembly job and snapshots its BOM component requirements. Idempotent by correlation_id. Level 0 output only; P&A demand decomposition to Level 0 happens client-side before calling this.';

REVOKE ALL ON FUNCTION public.create_assembly_job(text, uuid, uuid, text, numeric, jsonb, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.create_assembly_job(text, uuid, uuid, text, numeric, jsonb, text) TO authenticated;

-- =================================================================================
-- 3. reserve_assembly_components: reserves each component from its
--    source_store_code. Food (FINISHED_GOODS) shortfalls route to RGS/Production
--    via the existing governed RGS RPCs. Packaging/outsourced/giftware
--    shortfalls (3PGS / PACKING_ASSEMBLY / B2B_RAW) never route to Production.
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
BEGIN
  IF v_actor_id IS NULL OR NOT public.can_manage_b2b_inventory(v_actor_id) THEN
    RAISE EXCEPTION 'Not authorised to reserve assembly components' USING ERRCODE = '42501';
  END IF;
  IF nullif(btrim(p_correlation_id), '') IS NULL THEN
    RAISE EXCEPTION 'A correlation id is required';
  END IF;

  SELECT * INTO v_job FROM public.b2b_assembly_jobs WHERE id = p_assembly_job_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Assembly job not found'; END IF;

  IF v_job.status <> 'planned' THEN
    -- Idempotent replay: already reserved (or past it).
    RETURN v_job;
  END IF;

  FOR v_component IN
    SELECT * FROM public.b2b_assembly_components WHERE assembly_job_id = p_assembly_job_id FOR UPDATE
  LOOP
    PERFORM pg_catalog.pg_advisory_xact_lock(
      pg_catalog.hashtextextended(v_component.product_id::text || ':' || v_component.sku || ':' || v_component.source_store_code, 0)
    );

    SELECT * INTO v_balance
    FROM public.inventory_stock_balances
    WHERE product_id = v_component.product_id AND sku = v_component.sku AND location_code = v_component.source_store_code
    FOR UPDATE;

    v_reserve_qty := least(v_component.required_qty - v_component.reserved_qty, coalesce(v_balance.available_qty, 0));

    IF v_reserve_qty > 0 THEN
      IF NOT FOUND THEN
        RAISE EXCEPTION 'Stock balance not found for % / % at %', v_component.product_id, v_component.sku, v_component.source_store_code;
      END IF;
      UPDATE public.inventory_stock_balances
      SET available_qty = available_qty - v_reserve_qty,
          reserved_qty = reserved_qty + v_reserve_qty,
          version = version + 1,
          updated_at = now()
      WHERE product_id = v_component.product_id AND sku = v_component.sku AND location_code = v_component.source_store_code;

      UPDATE public.b2b_assembly_components
      SET reserved_qty = reserved_qty + v_reserve_qty
      WHERE id = v_component.id;
    END IF;

    v_shortfall := v_component.required_qty - (v_component.reserved_qty + v_reserve_qty);
    IF v_shortfall > 0 AND v_component.source_store_code = 'FINISHED_GOODS' THEN
      -- Food demand: P&A -> RGS -> Production. Never P&A -> Production directly.
      -- The department is the SHORTED COMPONENT's own canonical production
      -- department (not a single job-level department) so a job spanning
      -- multiple food departments routes each shortfall correctly.
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
    END IF;
    -- Packaging/outsourced/giftware shortfalls (3PGS / PACKING_ASSEMBLY /
    -- B2B_RAW) are deliberately left under-reserved here: they are 3PGS's own
    -- procurement/handover concern, not Production's, and are not auto-routed.
  END LOOP;

  UPDATE public.b2b_assembly_jobs
  SET status = 'materials_reserved', reserved_at = now(), updated_at = now()
  WHERE id = p_assembly_job_id
  RETURNING * INTO v_job;

  RETURN v_job;
END;
$$;

COMMENT ON FUNCTION public.reserve_assembly_components(uuid, text, text) IS
  'Reserves every component of an assembly job from its source_store_code. FINISHED_GOODS shortfalls route through the existing reserve_rgs_stock/create_production_shortage_demand RPCs (P&A -> RGS -> Production). 3PGS/PACKING_ASSEMBLY/B2B_RAW shortfalls are never routed to Production.';

REVOKE ALL ON FUNCTION public.reserve_assembly_components(uuid, text, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.reserve_assembly_components(uuid, text, text) TO authenticated;

-- =================================================================================
-- 4. issue_assembly_components: moves reserved -> issued custody (P&A takes
--    temporary physical custody of the reserved components).
-- =================================================================================
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
BEGIN
  IF v_actor_id IS NULL OR NOT public.can_manage_b2b_inventory(v_actor_id) THEN
    RAISE EXCEPTION 'Not authorised to issue assembly components' USING ERRCODE = '42501';
  END IF;
  IF nullif(btrim(p_correlation_id), '') IS NULL THEN
    RAISE EXCEPTION 'A correlation id is required';
  END IF;

  SELECT * INTO v_job FROM public.b2b_assembly_jobs WHERE id = p_assembly_job_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Assembly job not found'; END IF;
  IF v_job.status <> 'materials_reserved' THEN
    RETURN v_job; -- idempotent replay
  END IF;

  FOR v_component IN
    SELECT * FROM public.b2b_assembly_components WHERE assembly_job_id = p_assembly_job_id AND reserved_qty > issued_qty FOR UPDATE
  LOOP
    UPDATE public.inventory_stock_balances
    SET reserved_qty = reserved_qty - (v_component.reserved_qty - v_component.issued_qty),
        version = version + 1,
        updated_at = now()
    WHERE product_id = v_component.product_id AND sku = v_component.sku AND location_code = v_component.source_store_code;

    INSERT INTO public.inventory_movements (
      movement_type, product_id, sku, quantity, source_location, actor_id, correlation_id,
      source_document_type, source_document_reference, metadata
    ) VALUES (
      'issued_to_assembly', v_component.product_id, v_component.sku, v_component.reserved_qty - v_component.issued_qty,
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

REVOKE ALL ON FUNCTION public.issue_assembly_components(uuid, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.issue_assembly_components(uuid, text) TO authenticated;

-- =================================================================================
-- 5. record_assembly_consumption: consumed/wasted/returned buckets against an
--    issued component. Returned quantity is ledgered back to its store.
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
    UPDATE public.inventory_stock_balances
    SET available_qty = available_qty + p_returned_qty,
        version = version + 1,
        updated_at = now()
    WHERE product_id = v_component.product_id AND sku = v_component.sku AND location_code = v_component.source_store_code;

    INSERT INTO public.inventory_movements (
      movement_type, product_id, sku, quantity, destination_location, actor_id, correlation_id,
      source_document_type, source_document_reference, metadata
    ) VALUES (
      'returned_from_assembly', v_component.product_id, v_component.sku, p_returned_qty,
      v_component.source_store_code, v_actor_id, p_correlation_id,
      'b2b_assembly_job', v_job.assembly_job_number,
      jsonb_build_object('assembly_job_id', v_job.id, 'component_id', v_component.id)
    );
  END IF;

  IF v_job.status = 'issued' THEN
    UPDATE public.b2b_assembly_jobs SET status = 'in_progress', updated_at = now() WHERE id = v_job.id;
  END IF;

  RETURN v_component;
END;
$$;

REVOKE ALL ON FUNCTION public.record_assembly_consumption(uuid, numeric, numeric, numeric, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.record_assembly_consumption(uuid, numeric, numeric, numeric, text) TO authenticated;

-- =================================================================================
-- 6. complete_assembly_job: production-side completion (in_progress -> qc_pending).
-- =================================================================================
CREATE OR REPLACE FUNCTION public.complete_assembly_job(
  p_assembly_job_id uuid,
  p_completed_qty numeric,
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
BEGIN
  IF v_actor_id IS NULL OR NOT public.can_manage_b2b_inventory(v_actor_id) THEN
    RAISE EXCEPTION 'Not authorised to complete an assembly job' USING ERRCODE = '42501';
  END IF;
  IF nullif(btrim(p_correlation_id), '') IS NULL THEN
    RAISE EXCEPTION 'A correlation id is required';
  END IF;
  IF p_completed_qty IS NULL OR p_completed_qty < 0 THEN
    RAISE EXCEPTION 'Completed quantity must not be negative';
  END IF;

  SELECT * INTO v_job FROM public.b2b_assembly_jobs WHERE id = p_assembly_job_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Assembly job not found'; END IF;
  IF v_job.status = 'qc_pending' THEN
    RETURN v_job; -- idempotent replay
  END IF;
  IF v_job.status <> 'in_progress' THEN
    RAISE EXCEPTION 'Assembly job is not in progress';
  END IF;

  UPDATE public.b2b_assembly_jobs
  SET completed_qty = p_completed_qty, completed_by = v_actor_id, completed_at = now(),
      status = 'qc_pending', updated_at = now()
  WHERE id = p_assembly_job_id
  RETURNING * INTO v_job;

  RETURN v_job;
END;
$$;

REVOKE ALL ON FUNCTION public.complete_assembly_job(uuid, numeric, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.complete_assembly_job(uuid, numeric, text) TO authenticated;

-- =================================================================================
-- 7. accept_assembly_output: P&A's own QC decision on its own temporary
--    output custody ("Ready"). Never writes RGS/3PGS stock balances.
-- =================================================================================
CREATE OR REPLACE FUNCTION public.accept_assembly_output(
  p_assembly_job_id uuid,
  p_accepted_qty numeric,
  p_rejected_qty numeric,
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
  v_status text;
BEGIN
  IF v_actor_id IS NULL OR NOT public.can_manage_b2b_inventory(v_actor_id) THEN
    RAISE EXCEPTION 'Not authorised to accept assembly output' USING ERRCODE = '42501';
  END IF;
  IF nullif(btrim(p_correlation_id), '') IS NULL THEN
    RAISE EXCEPTION 'A correlation id is required';
  END IF;
  IF coalesce(p_accepted_qty, 0) < 0 OR coalesce(p_rejected_qty, 0) < 0 THEN
    RAISE EXCEPTION 'Accepted/rejected quantities must not be negative';
  END IF;

  SELECT * INTO v_job FROM public.b2b_assembly_jobs WHERE id = p_assembly_job_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Assembly job not found'; END IF;
  IF v_job.status IN ('accepted', 'partially_accepted', 'rejected') THEN
    RETURN v_job; -- idempotent replay
  END IF;
  IF v_job.status <> 'qc_pending' THEN
    RAISE EXCEPTION 'Assembly job is not pending QC';
  END IF;
  IF coalesce(p_accepted_qty, 0) + coalesce(p_rejected_qty, 0) > v_job.completed_qty THEN
    RAISE EXCEPTION 'Accepted + rejected cannot exceed completed quantity';
  END IF;

  v_status := CASE
    WHEN p_rejected_qty > 0 AND p_accepted_qty = 0 THEN 'rejected'
    WHEN p_accepted_qty < v_job.completed_qty THEN 'partially_accepted'
    ELSE 'accepted'
  END;

  UPDATE public.b2b_assembly_jobs
  SET accepted_qty = coalesce(p_accepted_qty, 0), rejected_qty = coalesce(p_rejected_qty, 0),
      qc_accepted_by = v_actor_id, status = v_status, updated_at = now()
  WHERE id = p_assembly_job_id
  RETURNING * INTO v_job;

  IF coalesce(p_accepted_qty, 0) > 0 THEN
    INSERT INTO public.inventory_movements (
      movement_type, product_id, sku, quantity, actor_id, correlation_id,
      source_document_type, source_document_reference, metadata
    ) VALUES (
      'assembly_output_accepted', v_job.output_product_id, v_job.output_sku, p_accepted_qty,
      v_actor_id, p_correlation_id, 'b2b_assembly_job', v_job.assembly_job_number,
      jsonb_build_object('assembly_job_id', v_job.id, 'note', 'P&A WIP/output custody only; RGS/3PGS stock is credited by their own governed receipt RPCs on physical handover')
    );
  END IF;

  RETURN v_job;
END;
$$;

COMMENT ON FUNCTION public.accept_assembly_output(uuid, numeric, numeric, text) IS
  'QC decision on P&A''s own output custody ("Ready"). Deliberately does not touch inventory_stock_balances for any RGS/3PGS store -- physical handover and the resulting stock increase is a separate, later step through RGS/3PGS''s own governed receipt RPCs, keeping RGS/3PGS as the sole inventory custodians.';

REVOKE ALL ON FUNCTION public.accept_assembly_output(uuid, numeric, numeric, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.accept_assembly_output(uuid, numeric, numeric, text) TO authenticated;

-- =================================================================================
-- 8. mark_assembly_handed_over / close_assembly_job: Handed Over and Job
--    Closed as their own distinct, separately-timestamped states, per the
--    explicit requirement that Ready / Handed Over / Job Completed / Job
--    Closed never collapse into one status.
-- =================================================================================
CREATE OR REPLACE FUNCTION public.mark_assembly_handed_over(
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
BEGIN
  IF v_actor_id IS NULL OR NOT public.can_manage_b2b_inventory(v_actor_id) THEN
    RAISE EXCEPTION 'Not authorised to mark an assembly job handed over' USING ERRCODE = '42501';
  END IF;
  IF nullif(btrim(p_correlation_id), '') IS NULL THEN
    RAISE EXCEPTION 'A correlation id is required';
  END IF;

  SELECT * INTO v_job FROM public.b2b_assembly_jobs WHERE id = p_assembly_job_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Assembly job not found'; END IF;
  IF v_job.status NOT IN ('accepted', 'partially_accepted') THEN
    RAISE EXCEPTION 'Assembly job output has not been QC-accepted yet';
  END IF;
  IF v_job.handed_over_at IS NOT NULL THEN
    RETURN v_job; -- idempotent replay
  END IF;

  UPDATE public.b2b_assembly_jobs
  SET handed_over_at = now(), handed_over_by = v_actor_id, updated_at = now()
  WHERE id = p_assembly_job_id
  RETURNING * INTO v_job;

  RETURN v_job;
END;
$$;

REVOKE ALL ON FUNCTION public.mark_assembly_handed_over(uuid, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.mark_assembly_handed_over(uuid, text) TO authenticated;

CREATE OR REPLACE FUNCTION public.close_assembly_job(
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
BEGIN
  IF v_actor_id IS NULL OR NOT public.can_manage_b2b_inventory(v_actor_id) THEN
    RAISE EXCEPTION 'Not authorised to close an assembly job' USING ERRCODE = '42501';
  END IF;
  IF nullif(btrim(p_correlation_id), '') IS NULL THEN
    RAISE EXCEPTION 'A correlation id is required';
  END IF;

  SELECT * INTO v_job FROM public.b2b_assembly_jobs WHERE id = p_assembly_job_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Assembly job not found'; END IF;
  IF v_job.status = 'rejected' AND v_job.handed_over_at IS NULL THEN
    -- Fully rejected output can be closed without a handover.
    NULL;
  ELSIF v_job.handed_over_at IS NULL THEN
    RAISE EXCEPTION 'Assembly job cannot be closed before handover is confirmed';
  END IF;
  IF v_job.job_closed_at IS NOT NULL THEN
    RETURN v_job; -- idempotent replay
  END IF;

  UPDATE public.b2b_assembly_jobs
  SET job_closed_at = now(), job_closed_by = v_actor_id, updated_at = now()
  WHERE id = p_assembly_job_id
  RETURNING * INTO v_job;

  RETURN v_job;
END;
$$;

REVOKE ALL ON FUNCTION public.close_assembly_job(uuid, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.close_assembly_job(uuid, text) TO authenticated;

-- =================================================================================
-- 9. Lock down direct table writes now that the governed RPC layer exists,
--    matching every other governed surface in this schema (RGS, B2B receipts).
-- =================================================================================
DROP POLICY IF EXISTS "Assembly operators maintain B2B assembly jobs" ON public.b2b_assembly_jobs;
DROP POLICY IF EXISTS "Assembly operators maintain B2B assembly components" ON public.b2b_assembly_components;

REVOKE INSERT, UPDATE, DELETE ON public.b2b_assembly_jobs FROM authenticated;
REVOKE INSERT, UPDATE, DELETE ON public.b2b_assembly_components FROM authenticated;

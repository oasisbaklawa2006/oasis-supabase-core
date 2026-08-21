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
-- Amended after semantic review against the P&A specification (same PR,
-- pre-merge -- corrected in place in this file rather than layered as a
-- second migration, since nothing here has shipped to production yet):
--   1. A job may no longer reach materials_reserved while any component is
--      short. It reaches partially_reserved instead, and issue is refused
--      unless everything is fully reserved OR an explicit, reasoned,
--      authorised-partial-plan record exists (authorize_partial_assembly_issue).
--   2. Packaging/outsourced/giftware shortfalls create a governed
--      b2b_assembly_3pgs_requirements row (create_assembly_3pgs_requirement)
--      instead of merely sitting under-reserved for somebody to notice.
--   3. complete_assembly_job is execution/packing completion leading to QC
--      only. Authoritative "Job Completed" now requires a governed
--      reconciliation step (reconcile_assembly_job) after handover:
--      accepted/partially_accepted -> reconciliation_pending -> job_completed
--      -> job_closed.
--   4. mark_assembly_handed_over (unilateral) is replaced by a two-actor,
--      receiver-acknowledged custody transfer: initiate_assembly_handover
--      (dispatch) + acknowledge_assembly_handover (a DIFFERENT actor
--      confirms destination, quantity/cartons, time, evidence). Destination
--      is a configured value, never hard-coded to RGS/3PGS.
--   6. Level semantics corrected: Level 0 is P&A's component INPUTS (already
--      the b2b_assembly_components rows); a job's OUTPUT is Level 1A/1B/2
--      (output_level), carries its approved BOM/master-data version
--      (bom_version/master_data_version) and a job_purpose, and Level 1B is
--      hamper-only (enforced by CHECK).
--   8. 3PGS DEPENDENCY BOUNDARY (found in a further review, same PR,
--      pre-merge): 3PGS is an existing, partially implemented inventory/
--      store authority in Central -- the canonical 3PGS B2B inventory
--      store, packaging_material/sourced_ready_product classifications,
--      inventory balances/receipts foundation, ThirdPartyStore,
--      ThirdPartyExecutionBoard, third-party queue/feed infrastructure,
--      and departmental 3PCS routing all already exist. What this
--      migration adds is a NEW governed requirement type on top of that
--      existing authority (b2b_assembly_3pgs_requirements): no vendor
--      order, picking, collection or stock-crediting workflow is wired to
--      fulfil_assembly_3pgs_requirement yet. P&A may not bypass an
--      unresolved mandatory 3PGS requirement because of that gap.
--      authorize_partial_assembly_issue previously let a manager bypass
--      ANY shortfall uniformly, including a 3PGS/PACKING_ASSEMBLY/B2B_RAW
--      one -- which could not actually be resolved by anything downstream
--      of this new contract yet, letting a job silently reach Job
--      Completed while a required component was simply written off. It
--      now refuses, unconditionally, to authorise around an unresolved
--      3PGS/packaging shortfall. The remaining end-to-end 3PGS
--      procurement/picking/collection/fulfilment workflows are outside
--      this Lane-2 PR and will be completed in the dedicated 3PGS
--      completion lane. FINISHED_GOODS shortfalls remain authorisable,
--      since RGS/Production is a real, implemented lane a manager may
--      legitimately choose to proceed ahead of.
--
-- Authoritative boundaries enforced by this migration (do not weaken):
--   * Food demand shortfalls (source_store_code = FINISHED_GOODS) route
--     P&A -> RGS -> Production via the EXISTING create_production_shortage_demand
--     RPC. This migration never inserts into production_jobs directly.
--   * Packaging/outsourced/giftware shortfalls (3PGS / PACKING_ASSEMBLY /
--     B2B_RAW) are never routed to Production. They raise a governed 3PGS
--     requirement instead (see fix 2 above), and CANNOT be bypassed by
--     partial-issue authorization (see fix 8 above) until the existing
--     3PGS module (inward, stock, booking/reservation, shortage/vendor
--     order, picking, collection/handover) is extended to consume this
--     specific governed requirement type -- pending completion work in the
--     dedicated 3PGS completion lane, explicitly out of scope for this migration.
--     P&A may only create and expose the governed requirement; it may
--     never self-fulfil it (fulfil_assembly_3pgs_requirement requires
--     can_receive_b2b_inventory, a different authority than P&A's manage
--     role).
--   * accept_assembly_output finalises P&A's OWN QC decision on its own
--     temporary WIP/output custody. It never writes to inventory_stock_balances
--     or any RGS/3PGS-owned table -- RGS/3PGS stock only increases through
--     their own existing acceptance RPCs (e.g. accept_rgs_production_receipt).
--     "Ready" (QC-accepted P&A output) is therefore never conflated with an
--     RGS/3PGS stock increase, nor with Handed Over/Job Completed/Job Closed.
--   * Ready (qc accepted/partially_accepted), Handed Over (receiver-
--     acknowledged), Job Completed (post-reconciliation) and Job Closed are
--     four distinct, separately-timestamped states.

SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '60s';

-- =================================================================================
-- 0. inventory_movements.movement_type is a whitelisted CHECK constraint
--    (most recently extended by 20260817215000). acknowledge_assembly_handover
--    below logs its own append-only ledger entry per receiver confirmation
--    (used as its idempotency record, since a handover row only tracks the
--    current cumulative total, not each individual acknowledgement call) --
--    add the missing movement type, preserving every existing value.
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
    'assembly_consumption_recorded', 'assembly_3pgs_requirement_fulfilled'
  ]));

-- =================================================================================
-- 1. Additive schema: idempotency, the fuller status machine, Level semantics,
--    and partial-issue-authorisation/reconciliation fields.
-- =================================================================================

ALTER TABLE public.b2b_assembly_jobs
  ADD COLUMN IF NOT EXISTS reserved_at timestamptz NULL,
  ADD COLUMN IF NOT EXISTS issued_at timestamptz NULL,
  ADD COLUMN IF NOT EXISTS partial_issue_authorized boolean NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS partial_issue_authorized_by uuid NULL REFERENCES public.users (id) ON DELETE RESTRICT,
  ADD COLUMN IF NOT EXISTS partial_issue_authorized_at timestamptz NULL,
  ADD COLUMN IF NOT EXISTS partial_issue_reason text NULL,
  ADD COLUMN IF NOT EXISTS handed_over_at timestamptz NULL,
  ADD COLUMN IF NOT EXISTS handed_over_by uuid NULL REFERENCES public.users (id) ON DELETE RESTRICT,
  ADD COLUMN IF NOT EXISTS reconciliation_pending_at timestamptz NULL,
  ADD COLUMN IF NOT EXISTS reconciliation_notes text NULL,
  ADD COLUMN IF NOT EXISTS reconciliation_variance_qty numeric NULL,
  ADD COLUMN IF NOT EXISTS job_completed_at timestamptz NULL,
  ADD COLUMN IF NOT EXISTS job_completed_by uuid NULL REFERENCES public.users (id) ON DELETE RESTRICT,
  ADD COLUMN IF NOT EXISTS job_closed_at timestamptz NULL,
  ADD COLUMN IF NOT EXISTS job_closed_by uuid NULL REFERENCES public.users (id) ON DELETE RESTRICT,
  ADD COLUMN IF NOT EXISTS output_level text NOT NULL DEFAULT '2',
  ADD COLUMN IF NOT EXISTS job_purpose text NULL,
  ADD COLUMN IF NOT EXISTS bom_version text NULL,
  ADD COLUMN IF NOT EXISTS master_data_version text NULL;

COMMENT ON COLUMN public.b2b_assembly_jobs.handed_over_at IS
  'Receiver-acknowledged physical/custody handover of accepted output to its configured destination. Set only by acknowledge_assembly_handover, never unilaterally. Distinct from QC acceptance (status) and from job_closed_at.';
COMMENT ON COLUMN public.b2b_assembly_jobs.job_completed_at IS
  'Set only after post-handover reconciliation (reconcile_assembly_job). Distinct from QC acceptance, from handed_over_at, and from job_closed_at.';
COMMENT ON COLUMN public.b2b_assembly_jobs.job_closed_at IS
  'Administrative closure after Job Completed (or after a fully-rejected job with no handover). Distinct from every earlier state.';
COMMENT ON COLUMN public.b2b_assembly_jobs.output_level IS
  'P&A OUTPUT decomposition level: 1A, 1B (hamper-only, see CHECK) or 2. Level 0 is P&A''s component INPUTS (b2b_assembly_components), never the job''s own output.';
COMMENT ON COLUMN public.b2b_assembly_jobs.bom_version IS
  'Approved BOM version (AI Studio) this job''s component snapshot was taken from.';
COMMENT ON COLUMN public.b2b_assembly_jobs.master_data_version IS
  'Approved product/photo/master-data version (AI Studio) this job''s output is produced against.';

ALTER TABLE public.b2b_assembly_jobs
  DROP CONSTRAINT IF EXISTS b2b_assembly_jobs_output_level_check;
ALTER TABLE public.b2b_assembly_jobs
  ADD CONSTRAINT b2b_assembly_jobs_output_level_check CHECK (output_level IN ('1A', '1B', '2'));

ALTER TABLE public.b2b_assembly_jobs
  DROP CONSTRAINT IF EXISTS b2b_assembly_jobs_1b_hamper_only_check;
ALTER TABLE public.b2b_assembly_jobs
  ADD CONSTRAINT b2b_assembly_jobs_1b_hamper_only_check CHECK (output_level <> '1B' OR job_purpose = 'hamper');

ALTER TABLE public.b2b_assembly_jobs
  DROP CONSTRAINT IF EXISTS b2b_assembly_jobs_status_check;
ALTER TABLE public.b2b_assembly_jobs
  ADD CONSTRAINT b2b_assembly_jobs_status_check CHECK (
    status IN (
      'planned', 'partially_reserved', 'materials_reserved', 'issued', 'in_progress', 'qc_pending',
      'accepted', 'partially_accepted', 'rejected',
      'reconciliation_pending', 'job_completed', 'job_closed', 'cancelled'
    )
  );

CREATE OR REPLACE FUNCTION public.validate_b2b_assembly_transition()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = ''
AS $$
BEGIN
  IF NEW.status IS NOT DISTINCT FROM OLD.status THEN
    RETURN NEW;
  END IF;
  IF NOT (
    (OLD.status = 'planned' AND NEW.status IN ('partially_reserved', 'materials_reserved', 'cancelled'))
    OR (OLD.status = 'partially_reserved' AND NEW.status IN ('materials_reserved', 'issued', 'cancelled'))
    OR (OLD.status = 'materials_reserved' AND NEW.status IN ('issued', 'cancelled'))
    OR (OLD.status = 'issued' AND NEW.status IN ('in_progress', 'cancelled'))
    OR (OLD.status = 'in_progress' AND NEW.status = 'qc_pending')
    OR (OLD.status = 'qc_pending' AND NEW.status IN ('accepted', 'partially_accepted', 'rejected'))
    OR (OLD.status = 'partially_accepted' AND NEW.status IN ('accepted', 'rejected', 'reconciliation_pending'))
    OR (OLD.status = 'accepted' AND NEW.status = 'reconciliation_pending')
    OR (OLD.status = 'reconciliation_pending' AND NEW.status = 'job_completed')
    OR (OLD.status = 'job_completed' AND NEW.status = 'job_closed')
    OR (OLD.status = 'rejected' AND NEW.status = 'job_closed')
  ) THEN
    RAISE EXCEPTION 'Invalid B2B assembly transition: % -> %', OLD.status, NEW.status;
  END IF;
  RETURN NEW;
END;
$$;
-- Trigger already attached to this function by the original migration; the
-- CREATE OR REPLACE above extends its transition matrix in place.

-- =================================================================================
-- 1b. Governed 3PGS requirement (fix 2): packaging/outsourced/giftware
--     shortfalls must create/link a governed requirement, not merely sit
--     under-reserved.
-- =================================================================================

CREATE TABLE IF NOT EXISTS public.b2b_assembly_3pgs_requirements (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  requirement_number text NOT NULL UNIQUE,
  assembly_job_id uuid NOT NULL REFERENCES public.b2b_assembly_jobs (id) ON DELETE RESTRICT,
  assembly_component_id uuid NOT NULL REFERENCES public.b2b_assembly_components (id) ON DELETE RESTRICT,
  product_id uuid NOT NULL REFERENCES public.products (id) ON DELETE RESTRICT,
  sku text NOT NULL,
  source_store_code text NOT NULL,
  requested_qty numeric NOT NULL CHECK (requested_qty > 0),
  fulfilled_qty numeric NOT NULL DEFAULT 0 CHECK (fulfilled_qty >= 0),
  status text NOT NULL DEFAULT 'open',
  priority text NOT NULL DEFAULT 'normal',
  raised_by uuid NULL REFERENCES public.users (id) ON DELETE RESTRICT,
  correlation_id text NOT NULL UNIQUE,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT b2b_assembly_3pgs_requirements_store_check CHECK (
    source_store_code IN ('3PGS', 'PACKING_ASSEMBLY', 'B2B_RAW')
  ),
  CONSTRAINT b2b_assembly_3pgs_requirements_status_check CHECK (
    status IN ('open', 'partially_fulfilled', 'fulfilled', 'cancelled')
  ),
  CONSTRAINT b2b_assembly_3pgs_requirements_fulfil_check CHECK (fulfilled_qty <= requested_qty)
);

COMMENT ON TABLE public.b2b_assembly_3pgs_requirements IS
  'Governed record of a packaging/outsourced/giftware shortfall raised by P&A against 3PGS. Never routed to Production. 3PGS''s own internal procurement/fulfilment workflow against this requirement is out of scope here; fulfil_assembly_3pgs_requirement only records that 3PGS has fulfilled it.';

CREATE INDEX IF NOT EXISTS idx_b2b_assembly_3pgs_requirements_job
  ON public.b2b_assembly_3pgs_requirements (assembly_job_id, status);

ALTER TABLE public.b2b_assembly_3pgs_requirements ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "B2B assembly 3PGS requirements are readable by inventory staff" ON public.b2b_assembly_3pgs_requirements;
CREATE POLICY "B2B assembly 3PGS requirements are readable by inventory staff"
  ON public.b2b_assembly_3pgs_requirements FOR SELECT TO authenticated
  USING (public.can_manage_b2b_inventory(auth.uid()) OR public.can_receive_b2b_inventory(auth.uid()));

-- =================================================================================
-- 1c. Receiver-acknowledged custody handover (fix 4): replaces the unilateral
--     mark_assembly_handed_over with a two-actor transfer record.
-- =================================================================================

CREATE TABLE IF NOT EXISTS public.b2b_assembly_handovers (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  assembly_job_id uuid NOT NULL REFERENCES public.b2b_assembly_jobs (id) ON DELETE RESTRICT,
  destination_type text NOT NULL,
  destination_reference text NOT NULL,
  dispatched_qty numeric NOT NULL CHECK (dispatched_qty > 0),
  carton_count integer NULL CHECK (carton_count IS NULL OR carton_count > 0),
  dispatched_by uuid NOT NULL REFERENCES public.users (id) ON DELETE RESTRICT,
  dispatched_at timestamptz NOT NULL DEFAULT now(),
  dispatch_evidence_reference text NULL,
  receiver_id uuid NULL REFERENCES public.users (id) ON DELETE RESTRICT,
  received_qty numeric NULL CHECK (received_qty IS NULL OR received_qty >= 0),
  acknowledged_at timestamptz NULL,
  receipt_evidence_reference text NULL,
  status text NOT NULL DEFAULT 'pending_acknowledgement',
  correlation_id text NOT NULL UNIQUE,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT b2b_assembly_handovers_destination_check CHECK (
    destination_type IN ('RGS', '3PGS', 'OUTLET', 'INTERNAL', 'CUSTOMER_DIRECT')
  ),
  CONSTRAINT b2b_assembly_handovers_status_check CHECK (
    status IN ('pending_acknowledgement', 'partially_acknowledged', 'acknowledged', 'disputed', 'cancelled')
  ),
  CONSTRAINT b2b_assembly_handovers_ack_check CHECK (
    status <> 'acknowledged'
    OR (receiver_id IS NOT NULL AND acknowledged_at IS NOT NULL AND received_qty IS NOT NULL)
  ),
  CONSTRAINT b2b_assembly_handovers_distinct_actor_check CHECK (
    receiver_id IS NULL OR receiver_id <> dispatched_by
  )
);

COMMENT ON TABLE public.b2b_assembly_handovers IS
  'Receiver-acknowledged custody transfer of accepted P&A output to a configured destination (never hard-coded to RGS/3PGS). Handed Over is set on the job only once a DIFFERENT actor than the dispatcher acknowledges receipt.';

CREATE INDEX IF NOT EXISTS idx_b2b_assembly_handovers_job
  ON public.b2b_assembly_handovers (assembly_job_id, status);

ALTER TABLE public.b2b_assembly_handovers ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "B2B assembly handovers are readable by inventory staff" ON public.b2b_assembly_handovers;
CREATE POLICY "B2B assembly handovers are readable by inventory staff"
  ON public.b2b_assembly_handovers FOR SELECT TO authenticated
  USING (public.can_manage_b2b_inventory(auth.uid()) OR public.can_receive_b2b_inventory(auth.uid()));

-- =================================================================================
-- 2. create_assembly_job: opens a job and snapshots its component (Level 0
--    input) requirements, plus the job's own output Level/purpose/approved
--    BOM+master-data version (fix 6).
-- =================================================================================
CREATE OR REPLACE FUNCTION public.create_assembly_job(
  p_assembly_job_number text,
  p_order_id uuid,
  p_output_product_id uuid,
  p_output_sku text,
  p_planned_qty numeric,
  p_components jsonb,
  p_correlation_id text,
  p_output_level text DEFAULT '2',
  p_job_purpose text DEFAULT NULL,
  p_bom_version text DEFAULT NULL,
  p_master_data_version text DEFAULT NULL
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
  IF coalesce(p_output_level, '2') = '1B' AND coalesce(p_job_purpose, '') <> 'hamper' THEN
    RAISE EXCEPTION 'Level 1B output is hamper-only; job_purpose must be hamper' USING ERRCODE = '23514';
  END IF;

  SELECT * INTO v_job FROM public.b2b_assembly_jobs WHERE correlation_id = p_correlation_id;
  IF FOUND THEN
    RETURN v_job;
  END IF;

  INSERT INTO public.b2b_assembly_jobs (
    assembly_job_number, order_id, output_product_id, output_sku, planned_qty,
    status, correlation_id, output_level, job_purpose, bom_version, master_data_version
  ) VALUES (
    p_assembly_job_number, p_order_id, p_output_product_id, p_output_sku, p_planned_qty,
    'planned', p_correlation_id, coalesce(p_output_level, '2'), p_job_purpose, p_bom_version, p_master_data_version
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

COMMENT ON FUNCTION public.create_assembly_job(text, uuid, uuid, text, numeric, jsonb, text, text, text, text, text) IS
  'Opens a P&A assembly job. p_components snapshots the Level 0 INPUT requirements. p_output_level/p_job_purpose/p_bom_version/p_master_data_version record the job''s OWN Level 1A/1B/2 output, its purpose, and the approved AI-Studio BOM/master-data version it was produced against. Idempotent by correlation_id.';

REVOKE ALL ON FUNCTION public.create_assembly_job(text, uuid, uuid, text, numeric, jsonb, text, text, text, text, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.create_assembly_job(text, uuid, uuid, text, numeric, jsonb, text, text, text, text, text) TO authenticated;

-- =================================================================================
-- 3. reserve_assembly_components: reserves each component from its
--    source_store_code. Food (FINISHED_GOODS) shortfalls route to RGS/Production
--    via the existing governed RGS RPCs. Packaging/outsourced/giftware
--    shortfalls (3PGS / PACKING_ASSEMBLY / B2B_RAW) raise a governed 3PGS
--    requirement (fix 2) and never route to Production. A job only reaches
--    materials_reserved when EVERY component is fully reserved; otherwise it
--    is partially_reserved (fix 1).
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
    -- Idempotent replay: already fully reserved (or past it).
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

        UPDATE public.b2b_assembly_components
        SET reserved_qty = reserved_qty + v_reserve_qty
        WHERE id = v_component.id;
      END IF;

      v_shortfall := v_component.required_qty - (v_component.reserved_qty + v_reserve_qty);
      IF v_shortfall > 0 THEN
        v_all_reserved := false;

        IF v_component.source_store_code = 'FINISHED_GOODS' THEN
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
        ELSE
          -- Packaging/outsourced/giftware shortfall: raise a governed 3PGS
          -- requirement (fix 2). Never routed to Production.
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

COMMENT ON FUNCTION public.reserve_assembly_components(uuid, text, text) IS
  'Reserves every component of an assembly job from its source_store_code. FINISHED_GOODS shortfalls route through the existing reserve_rgs_stock/create_production_shortage_demand RPCs (P&A -> RGS -> Production). 3PGS/PACKING_ASSEMBLY/B2B_RAW shortfalls raise a governed b2b_assembly_3pgs_requirements row and are never routed to Production. The job reaches materials_reserved only when every component is fully reserved; otherwise it is partially_reserved.';

REVOKE ALL ON FUNCTION public.reserve_assembly_components(uuid, text, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.reserve_assembly_components(uuid, text, text) TO authenticated;

-- =================================================================================
-- 3b. create_assembly_3pgs_requirement: standalone entry point to (re-)raise
--     a governed 3PGS requirement outside the reservation pass (e.g. a
--     manually identified shortfall), and fulfil_assembly_3pgs_requirement to
--     record that 3PGS has actioned it (fix 2).
-- =================================================================================
CREATE OR REPLACE FUNCTION public.create_assembly_3pgs_requirement(
  p_assembly_component_id uuid,
  p_requested_qty numeric,
  p_priority text,
  p_correlation_id text
)
RETURNS public.b2b_assembly_3pgs_requirements
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_actor_id uuid := auth.uid();
  v_component public.b2b_assembly_components%ROWTYPE;
  v_job public.b2b_assembly_jobs%ROWTYPE;
  v_requirement public.b2b_assembly_3pgs_requirements%ROWTYPE;
BEGIN
  IF v_actor_id IS NULL OR NOT public.can_manage_b2b_inventory(v_actor_id) THEN
    RAISE EXCEPTION 'Not authorised to raise a 3PGS requirement' USING ERRCODE = '42501';
  END IF;
  IF nullif(btrim(p_correlation_id), '') IS NULL THEN
    RAISE EXCEPTION 'A correlation id is required';
  END IF;
  IF p_requested_qty IS NULL OR p_requested_qty <= 0 THEN
    RAISE EXCEPTION 'Requested quantity must be positive';
  END IF;

  SELECT * INTO v_requirement FROM public.b2b_assembly_3pgs_requirements WHERE correlation_id = p_correlation_id;
  IF FOUND THEN
    RETURN v_requirement;
  END IF;

  SELECT * INTO v_component FROM public.b2b_assembly_components WHERE id = p_assembly_component_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Assembly component not found'; END IF;
  IF v_component.source_store_code NOT IN ('3PGS', 'PACKING_ASSEMBLY', 'B2B_RAW') THEN
    RAISE EXCEPTION 'Component % is not a 3PGS/packaging/outsourced source', v_component.source_store_code;
  END IF;

  SELECT * INTO v_job FROM public.b2b_assembly_jobs WHERE id = v_component.assembly_job_id;

  INSERT INTO public.b2b_assembly_3pgs_requirements (
    requirement_number, assembly_job_id, assembly_component_id, product_id, sku,
    source_store_code, requested_qty, priority, raised_by, correlation_id
  ) VALUES (
    v_job.assembly_job_number || ':3PGS:' || v_component.id::text || ':' || p_correlation_id,
    v_job.id, v_component.id, v_component.product_id, v_component.sku,
    v_component.source_store_code, p_requested_qty, coalesce(p_priority, 'normal'), v_actor_id, p_correlation_id
  )
  RETURNING * INTO v_requirement;

  RETURN v_requirement;
END;
$$;

REVOKE ALL ON FUNCTION public.create_assembly_3pgs_requirement(uuid, numeric, text, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.create_assembly_3pgs_requirement(uuid, numeric, text, text) TO authenticated;

CREATE OR REPLACE FUNCTION public.fulfil_assembly_3pgs_requirement(
  p_requirement_id uuid,
  p_fulfilled_qty numeric,
  p_correlation_id text
)
RETURNS public.b2b_assembly_3pgs_requirements
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_actor_id uuid := auth.uid();
  v_requirement public.b2b_assembly_3pgs_requirements%ROWTYPE;
BEGIN
  IF v_actor_id IS NULL OR NOT public.can_receive_b2b_inventory(v_actor_id) THEN
    RAISE EXCEPTION 'Not authorised to fulfil a 3PGS requirement' USING ERRCODE = '42501';
  END IF;
  IF nullif(btrim(p_correlation_id), '') IS NULL THEN
    RAISE EXCEPTION 'A correlation id is required';
  END IF;
  IF p_fulfilled_qty IS NULL OR p_fulfilled_qty <= 0 THEN
    RAISE EXCEPTION 'Fulfilled quantity must be positive';
  END IF;

  -- Idempotent replay by correlation_id, not merely by terminal status: a
  -- retried PARTIAL fulfilment call (status stays 'partially_fulfilled', not
  -- 'fulfilled') would otherwise double-count on every retry.
  IF EXISTS (
    SELECT 1 FROM public.inventory_movements
    WHERE correlation_id = p_correlation_id AND movement_type = 'assembly_3pgs_requirement_fulfilled'
  ) THEN
    SELECT * INTO v_requirement FROM public.b2b_assembly_3pgs_requirements WHERE id = p_requirement_id;
    RETURN v_requirement;
  END IF;

  SELECT * INTO v_requirement FROM public.b2b_assembly_3pgs_requirements WHERE id = p_requirement_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION '3PGS requirement not found'; END IF;
  IF v_requirement.status IN ('fulfilled', 'cancelled') THEN
    RETURN v_requirement; -- idempotent replay (fully fulfilled/cancelled before this call was ever made)
  END IF;
  IF v_requirement.fulfilled_qty + p_fulfilled_qty > v_requirement.requested_qty THEN
    RAISE EXCEPTION 'Fulfilled quantity would exceed requested quantity';
  END IF;

  UPDATE public.b2b_assembly_3pgs_requirements
  SET fulfilled_qty = fulfilled_qty + p_fulfilled_qty,
      status = CASE WHEN fulfilled_qty + p_fulfilled_qty >= requested_qty THEN 'fulfilled' ELSE 'partially_fulfilled' END,
      updated_at = now()
  WHERE id = p_requirement_id
  RETURNING * INTO v_requirement;

  INSERT INTO public.inventory_movements (
    movement_type, product_id, sku, quantity, actor_id, correlation_id,
    source_document_type, source_document_reference, metadata
  ) VALUES (
    'assembly_3pgs_requirement_fulfilled', v_requirement.product_id, v_requirement.sku, p_fulfilled_qty,
    v_actor_id, p_correlation_id, 'b2b_assembly_3pgs_requirement', v_requirement.requirement_number,
    jsonb_build_object('requirement_id', v_requirement.id)
  );

  RETURN v_requirement;
END;
$$;

REVOKE ALL ON FUNCTION public.fulfil_assembly_3pgs_requirement(uuid, numeric, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.fulfil_assembly_3pgs_requirement(uuid, numeric, text) TO authenticated;

-- =================================================================================
-- 3c. authorize_partial_assembly_issue: the ONLY way to issue a job whose
--     reservation is incomplete (fix 1). Fails closed otherwise.
--
--     3PGS DEPENDENCY BOUNDARY: 3PGS (the 3rd Party/Contract Store) is an
--     existing, partially-built operational module in Central -- it is not
--     unbuilt. No existing 3PGS surface consumes THIS specific governed
--     requirement type yet: there is no vendor order, picking, or
--     collection workflow wired to fulfil_assembly_3pgs_requirement today,
--     so an outstanding 3PGS/PACKING_ASSEMBLY/B2B_RAW shortfall cannot yet
--     be resolved through it. That wiring is 3PGS COMPLETION WORK PENDING
--     in the dedicated 3PGS completion lane. Authorising a partial issue must
--     NEVER be usable to bypass one in the meantime -- doing so would let
--     P&A silently declare a job complete while a component that was never
--     supplied by anyone is simply written off. FINISHED_GOODS shortfalls
--     remain authorisable here: RGS/Production is a real, implemented lane
--     that a manager may legitimately choose to proceed ahead of.
-- =================================================================================
CREATE OR REPLACE FUNCTION public.authorize_partial_assembly_issue(
  p_assembly_job_id uuid,
  p_reason text,
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
  v_unresolved_3pgs_component text;
BEGIN
  IF v_actor_id IS NULL OR NOT public.can_manage_b2b_inventory(v_actor_id) THEN
    RAISE EXCEPTION 'Not authorised to authorise a partial assembly issue' USING ERRCODE = '42501';
  END IF;
  IF nullif(btrim(p_reason), '') IS NULL THEN
    RAISE EXCEPTION 'A reason is required to authorise a partial issue';
  END IF;
  IF nullif(btrim(p_correlation_id), '') IS NULL THEN
    RAISE EXCEPTION 'A correlation id is required';
  END IF;

  SELECT * INTO v_job FROM public.b2b_assembly_jobs WHERE id = p_assembly_job_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Assembly job not found'; END IF;
  IF v_job.status <> 'partially_reserved' THEN
    IF v_job.partial_issue_authorized THEN
      RETURN v_job; -- idempotent replay
    END IF;
    RAISE EXCEPTION 'Only a partially_reserved job can have a partial issue authorised';
  END IF;

  SELECT sku INTO v_unresolved_3pgs_component
  FROM public.b2b_assembly_components
  WHERE assembly_job_id = p_assembly_job_id
    AND source_store_code IN ('3PGS', 'PACKING_ASSEMBLY', 'B2B_RAW')
    AND reserved_qty < required_qty
  LIMIT 1;
  IF v_unresolved_3pgs_component IS NOT NULL THEN
    RAISE EXCEPTION 'Component % has an unresolved 3PGS/packaging shortfall; the existing 3PGS module does not yet action this governed requirement type (3PGS completion work pending), so it cannot be bypassed by partial-issue authorization. Resolve the governed 3PGS requirement (fulfil_assembly_3pgs_requirement) once that wiring lands, then re-run reserve_assembly_components', v_unresolved_3pgs_component USING ERRCODE = '42501';
  END IF;

  UPDATE public.b2b_assembly_jobs
  SET partial_issue_authorized = true,
      partial_issue_authorized_by = v_actor_id,
      partial_issue_authorized_at = now(),
      partial_issue_reason = p_reason,
      updated_at = now()
  WHERE id = p_assembly_job_id
  RETURNING * INTO v_job;

  RETURN v_job;
END;
$$;

COMMENT ON FUNCTION public.authorize_partial_assembly_issue(uuid, text, text) IS
  'Explicit, reasoned authority record allowing issue_assembly_components to proceed on a job with an incomplete reservation. Without this, issue fails closed. Refuses to authorise around any unresolved 3PGS/PACKING_ASSEMBLY/B2B_RAW shortfall -- the existing 3PGS module does not yet action this governed requirement type (3PGS completion work pending in the dedicated 3PGS completion lane), so it cannot yet be satisfied downstream. Only FINISHED_GOODS (RGS/Production, a real implemented lane) shortfalls are authorisable.';

REVOKE ALL ON FUNCTION public.authorize_partial_assembly_issue(uuid, text, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.authorize_partial_assembly_issue(uuid, text, text) TO authenticated;

-- =================================================================================
-- 4. issue_assembly_components: moves reserved -> issued custody (P&A takes
--    temporary physical custody of the reserved components). Fails closed
--    (fix 1) unless reservation is complete or an explicit partial-issue
--    authorisation record exists.
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
  IF v_job.status IN ('issued', 'in_progress', 'qc_pending', 'accepted', 'partially_accepted', 'rejected',
                       'reconciliation_pending', 'job_completed', 'job_closed') THEN
    RETURN v_job; -- idempotent replay
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
    PERFORM pg_catalog.pg_advisory_xact_lock(
      pg_catalog.hashtextextended(v_component.product_id::text || ':' || v_component.sku || ':' || v_component.source_store_code, 0)
    );

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

COMMENT ON FUNCTION public.issue_assembly_components(uuid, text) IS
  'Issues reserved components to P&A custody. Fails closed on an incomplete (partially_reserved) job unless authorize_partial_assembly_issue has already recorded an explicit authorisation.';

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

  -- Idempotent replay: logged unconditionally below (even a zero-return call)
  -- so a retried call is detected regardless of what it recorded.
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

  -- The idempotency record for THIS call, logged regardless of whether
  -- anything was returned -- a consumed/wasted-only call must also be
  -- replay-safe.
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

REVOKE ALL ON FUNCTION public.record_assembly_consumption(uuid, numeric, numeric, numeric, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.record_assembly_consumption(uuid, numeric, numeric, numeric, text) TO authenticated;

-- =================================================================================
-- 6. complete_assembly_job: execution/packing completion leading to QC ONLY
--    (fix 3). NOT the authoritative Job Completed -- that requires
--    reconcile_assembly_job after a receiver-acknowledged handover.
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

COMMENT ON FUNCTION public.complete_assembly_job(uuid, numeric, text) IS
  'Packing/execution completion leading to QC ONLY (in_progress -> qc_pending). This is NOT the authoritative "Job Completed" state -- see reconcile_assembly_job.';

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
  v_accepted_qty numeric;
  v_rejected_qty numeric;
BEGIN
  IF v_actor_id IS NULL OR NOT public.can_manage_b2b_inventory(v_actor_id) THEN
    RAISE EXCEPTION 'Not authorised to accept assembly output' USING ERRCODE = '42501';
  END IF;
  IF nullif(btrim(p_correlation_id), '') IS NULL THEN
    RAISE EXCEPTION 'A correlation id is required';
  END IF;
  v_accepted_qty := coalesce(p_accepted_qty, 0);
  v_rejected_qty := coalesce(p_rejected_qty, 0);
  IF v_accepted_qty < 0 OR v_rejected_qty < 0 THEN
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
  IF v_accepted_qty + v_rejected_qty > v_job.completed_qty THEN
    RAISE EXCEPTION 'Accepted + rejected cannot exceed completed quantity';
  END IF;

  v_status := CASE
    WHEN v_accepted_qty = 0 THEN 'rejected'
    WHEN v_accepted_qty < v_job.completed_qty THEN 'partially_accepted'
    ELSE 'accepted'
  END;

  UPDATE public.b2b_assembly_jobs
  SET accepted_qty = v_accepted_qty, rejected_qty = v_rejected_qty,
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
-- 8. initiate_assembly_handover / acknowledge_assembly_handover (fix 4):
--    receiver-acknowledged custody transfer to a configured destination.
--    Replaces the unilateral mark_assembly_handed_over.
-- =================================================================================
CREATE OR REPLACE FUNCTION public.initiate_assembly_handover(
  p_assembly_job_id uuid,
  p_destination_type text,
  p_destination_reference text,
  p_dispatched_qty numeric,
  p_carton_count integer,
  p_evidence_reference text,
  p_correlation_id text
)
RETURNS public.b2b_assembly_handovers
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_actor_id uuid := auth.uid();
  v_job public.b2b_assembly_jobs%ROWTYPE;
  v_handover public.b2b_assembly_handovers%ROWTYPE;
  v_already_dispatched numeric;
  v_available numeric;
BEGIN
  IF v_actor_id IS NULL OR NOT public.can_manage_b2b_inventory(v_actor_id) THEN
    RAISE EXCEPTION 'Not authorised to initiate an assembly handover' USING ERRCODE = '42501';
  END IF;
  IF nullif(btrim(p_correlation_id), '') IS NULL THEN
    RAISE EXCEPTION 'A correlation id is required';
  END IF;
  IF nullif(btrim(p_destination_reference), '') IS NULL THEN
    RAISE EXCEPTION 'A destination reference is required';
  END IF;
  IF p_dispatched_qty IS NULL OR p_dispatched_qty <= 0 THEN
    RAISE EXCEPTION 'Dispatched quantity must be positive';
  END IF;

  SELECT * INTO v_handover FROM public.b2b_assembly_handovers WHERE correlation_id = p_correlation_id;
  IF FOUND THEN
    RETURN v_handover;
  END IF;

  SELECT * INTO v_job FROM public.b2b_assembly_jobs WHERE id = p_assembly_job_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Assembly job not found'; END IF;
  IF v_job.status NOT IN ('accepted', 'partially_accepted') THEN
    RAISE EXCEPTION 'Assembly job output has not been QC-accepted yet';
  END IF;

  SELECT coalesce(sum(dispatched_qty), 0) INTO v_already_dispatched
  FROM public.b2b_assembly_handovers
  WHERE assembly_job_id = p_assembly_job_id AND status <> 'cancelled';

  v_available := v_job.accepted_qty - v_already_dispatched;
  IF p_dispatched_qty > v_available THEN
    RAISE EXCEPTION 'Dispatched quantity % exceeds remaining accepted quantity %', p_dispatched_qty, v_available;
  END IF;

  INSERT INTO public.b2b_assembly_handovers (
    assembly_job_id, destination_type, destination_reference, dispatched_qty, carton_count,
    dispatched_by, dispatch_evidence_reference, correlation_id
  ) VALUES (
    p_assembly_job_id, p_destination_type, p_destination_reference, p_dispatched_qty, p_carton_count,
    v_actor_id, p_evidence_reference, p_correlation_id
  )
  RETURNING * INTO v_handover;

  RETURN v_handover;
END;
$$;

COMMENT ON FUNCTION public.initiate_assembly_handover(uuid, text, text, numeric, integer, text, text) IS
  'Dispatch side of a custody transfer. destination_type/destination_reference are caller-supplied (RGS, 3PGS, OUTLET, INTERNAL, CUSTOMER_DIRECT) -- never hard-coded. Does not set the job as Handed Over; that requires acknowledge_assembly_handover by a different actor.';

REVOKE ALL ON FUNCTION public.initiate_assembly_handover(uuid, text, text, numeric, integer, text, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.initiate_assembly_handover(uuid, text, text, numeric, integer, text, text) TO authenticated;

CREATE OR REPLACE FUNCTION public.acknowledge_assembly_handover(
  p_handover_id uuid,
  p_received_qty numeric,
  p_evidence_reference text,
  p_correlation_id text
)
RETURNS public.b2b_assembly_handovers
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_actor_id uuid := auth.uid();
  v_handover public.b2b_assembly_handovers%ROWTYPE;
  v_job public.b2b_assembly_jobs%ROWTYPE;
  v_new_received_qty numeric;
  v_new_status text;
  v_total_acknowledged numeric;
BEGIN
  IF v_actor_id IS NULL OR NOT public.can_receive_b2b_inventory(v_actor_id) THEN
    RAISE EXCEPTION 'Not authorised to acknowledge an assembly handover' USING ERRCODE = '42501';
  END IF;
  IF nullif(btrim(p_correlation_id), '') IS NULL THEN
    RAISE EXCEPTION 'A correlation id is required';
  END IF;
  IF p_received_qty IS NULL OR p_received_qty < 0 THEN
    RAISE EXCEPTION 'Received quantity must not be negative';
  END IF;

  -- Idempotent replay: each acknowledgement call (there may be more than one
  -- per handover -- see below) is logged to inventory_movements by its own
  -- correlation_id, since the handover row itself only tracks the current
  -- cumulative total, not each individual call.
  IF EXISTS (
    SELECT 1 FROM public.inventory_movements
    WHERE correlation_id = p_correlation_id AND movement_type = 'assembly_handover_acknowledged'
  ) THEN
    SELECT * INTO v_handover FROM public.b2b_assembly_handovers WHERE id = p_handover_id;
    RETURN v_handover;
  END IF;

  SELECT * INTO v_handover FROM public.b2b_assembly_handovers WHERE id = p_handover_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Assembly handover not found'; END IF;
  IF v_handover.status = 'acknowledged' THEN
    RETURN v_handover; -- already fully receiver-acknowledged
  END IF;
  IF v_handover.status NOT IN ('pending_acknowledgement', 'partially_acknowledged') THEN
    RAISE EXCEPTION 'Assembly handover is not pending acknowledgement';
  END IF;
  IF v_actor_id = v_handover.dispatched_by THEN
    RAISE EXCEPTION 'Handover receiver must be a different actor than the dispatcher' USING ERRCODE = '42501';
  END IF;

  -- Receiver-acknowledged quantity accumulates across possibly-multiple
  -- custody-evidence confirmations (e.g. a short receipt followed later by
  -- the remainder). A single call, or a zero-quantity call, can never by
  -- itself take the handover past what has actually been confirmed received.
  v_new_received_qty := coalesce(v_handover.received_qty, 0) + p_received_qty;
  IF v_new_received_qty > v_handover.dispatched_qty THEN
    RAISE EXCEPTION 'Acknowledged quantity % would exceed dispatched quantity %', v_new_received_qty, v_handover.dispatched_qty;
  END IF;
  v_new_status := CASE WHEN v_new_received_qty >= v_handover.dispatched_qty THEN 'acknowledged' ELSE 'partially_acknowledged' END;

  UPDATE public.b2b_assembly_handovers
  SET receiver_id = v_actor_id,
      received_qty = v_new_received_qty,
      acknowledged_at = CASE WHEN v_new_status = 'acknowledged' THEN now() ELSE acknowledged_at END,
      receipt_evidence_reference = coalesce(p_evidence_reference, receipt_evidence_reference),
      status = v_new_status,
      updated_at = now()
  WHERE id = p_handover_id
  RETURNING * INTO v_handover;

  INSERT INTO public.inventory_movements (
    movement_type, product_id, sku, quantity, actor_id, correlation_id,
    source_document_type, source_document_reference, metadata
  )
  SELECT
    'assembly_handover_acknowledged', j.output_product_id, j.output_sku, p_received_qty,
    v_actor_id, p_correlation_id, 'b2b_assembly_handover', v_handover.id::text,
    jsonb_build_object('assembly_job_id', j.id, 'handover_id', v_handover.id, 'cumulative_received_qty', v_new_received_qty)
  FROM public.b2b_assembly_jobs j WHERE j.id = v_handover.assembly_job_id;

  SELECT * INTO v_job FROM public.b2b_assembly_jobs WHERE id = v_handover.assembly_job_id FOR UPDATE;

  -- Fix: the Handed Over gate is authoritative receiver-acknowledged
  -- quantity (received_qty on FULLY acknowledged handovers), never
  -- dispatched/declared quantity. A short receipt must never satisfy it.
  SELECT coalesce(sum(received_qty), 0) INTO v_total_acknowledged
  FROM public.b2b_assembly_handovers
  WHERE assembly_job_id = v_job.id AND status = 'acknowledged';

  IF v_total_acknowledged >= v_job.accepted_qty AND v_job.handed_over_at IS NULL THEN
    UPDATE public.b2b_assembly_jobs
    SET handed_over_at = now(), handed_over_by = v_actor_id,
        status = 'reconciliation_pending', reconciliation_pending_at = now(), updated_at = now()
    WHERE id = v_job.id;
  END IF;

  RETURN v_handover;
END;
$$;

COMMENT ON FUNCTION public.acknowledge_assembly_handover(uuid, numeric, text, text) IS
  'Receiver side of a custody transfer. Must be invoked by a DIFFERENT actor than initiate_assembly_handover. received_qty accumulates across possibly-multiple confirmations per handover (e.g. a short receipt followed by the remainder); a handover only reaches "acknowledged" once its cumulative received_qty meets its dispatched_qty. The job only moves to Handed Over (reconciliation_pending) once the SUM OF RECEIVED_QTY across fully-acknowledged handovers meets accepted_qty -- dispatched/declared quantity never satisfies this gate.';

REVOKE ALL ON FUNCTION public.acknowledge_assembly_handover(uuid, numeric, text, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.acknowledge_assembly_handover(uuid, numeric, text, text) TO authenticated;

-- =================================================================================
-- 9. reconcile_assembly_job / close_assembly_job (fix 3): post-handover
--    reconciliation gates Job Completed; Job Closed requires Job Completed
--    (or a fully-rejected job that never had a handover).
-- =================================================================================
-- compute_assembly_job_variance: the single authoritative derivation of
-- reconciliation variance from recorded data. STABLE/read-only so the client
-- can call it to display the true variance BEFORE reconciling; reconcile_
-- assembly_job below calls this SAME function internally rather than
-- trusting any caller-supplied number, so the two can never disagree.
--
-- Two independent sources of unaccounted-for quantity are summed:
--   1. Component residue: for every component, issued material that was
--      never dispositioned as consumed, wasted or returned.
--   2. Output-transfer shortfall: accepted (QC-passed) output minus the
--      SUM OF RECEIVER-ACKNOWLEDGED quantity across fully-acknowledged
--      handovers. This is structurally 0 at the moment the job first
--      reaches reconciliation_pending (the handover gate requires full
--      acknowledgement), but is recomputed live here rather than assumed,
--      so a handover disputed/cancelled after that point is still caught.
CREATE OR REPLACE FUNCTION public.compute_assembly_job_variance(
  p_assembly_job_id uuid
)
RETURNS numeric
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_actor_id uuid := auth.uid();
  v_job public.b2b_assembly_jobs%ROWTYPE;
  v_component_residue numeric;
  v_transfer_shortfall numeric;
BEGIN
  IF v_actor_id IS NULL OR NOT (public.can_manage_b2b_inventory(v_actor_id) OR public.can_receive_b2b_inventory(v_actor_id)) THEN
    RAISE EXCEPTION 'Not authorised to compute assembly job variance' USING ERRCODE = '42501';
  END IF;

  SELECT * INTO v_job FROM public.b2b_assembly_jobs WHERE id = p_assembly_job_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Assembly job not found'; END IF;

  SELECT coalesce(sum(issued_qty - consumed_qty - wasted_qty - returned_qty), 0) INTO v_component_residue
  FROM public.b2b_assembly_components
  WHERE assembly_job_id = p_assembly_job_id;

  SELECT v_job.accepted_qty - coalesce(sum(received_qty), 0) INTO v_transfer_shortfall
  FROM public.b2b_assembly_handovers
  WHERE assembly_job_id = p_assembly_job_id AND status = 'acknowledged';

  RETURN v_component_residue + v_transfer_shortfall;
END;
$$;

COMMENT ON FUNCTION public.compute_assembly_job_variance(uuid) IS
  'Authoritative, server-derived reconciliation variance: unaccounted-for component residue (issued minus consumed/wasted/returned) plus accepted output minus receiver-acknowledged output. reconcile_assembly_job calls this itself; it is exposed to clients only so the UI can DISPLAY the true variance before reconciling, never to let a caller declare one.';

REVOKE ALL ON FUNCTION public.compute_assembly_job_variance(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.compute_assembly_job_variance(uuid) TO authenticated;

CREATE OR REPLACE FUNCTION public.reconcile_assembly_job(
  p_assembly_job_id uuid,
  p_notes text,
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
  v_computed_variance numeric;
BEGIN
  IF v_actor_id IS NULL OR NOT public.can_manage_b2b_inventory(v_actor_id) THEN
    RAISE EXCEPTION 'Not authorised to reconcile an assembly job' USING ERRCODE = '42501';
  END IF;
  IF nullif(btrim(p_correlation_id), '') IS NULL THEN
    RAISE EXCEPTION 'A correlation id is required';
  END IF;

  SELECT * INTO v_job FROM public.b2b_assembly_jobs WHERE id = p_assembly_job_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Assembly job not found'; END IF;
  IF v_job.status = 'job_completed' THEN
    RETURN v_job; -- idempotent replay
  END IF;
  IF v_job.status <> 'reconciliation_pending' THEN
    RAISE EXCEPTION 'Assembly job is not pending reconciliation';
  END IF;

  -- Variance is NEVER taken from caller input. A caller supplying explanatory
  -- notes has no way to suppress or overwrite an actual discrepancy: the
  -- variance persisted below is always this server-side computation.
  v_computed_variance := public.compute_assembly_job_variance(p_assembly_job_id);

  -- Fail-closed variance/return/waste/rework/transfer gate: any non-zero
  -- COMPUTED variance must be explained, never silently closed.
  IF v_computed_variance <> 0 AND nullif(btrim(p_notes), '') IS NULL THEN
    RAISE EXCEPTION 'A non-zero reconciliation variance (%) requires explanatory notes', v_computed_variance USING ERRCODE = '42501';
  END IF;

  UPDATE public.b2b_assembly_jobs
  SET reconciliation_variance_qty = v_computed_variance,
      reconciliation_notes = p_notes,
      status = 'job_completed', job_completed_at = now(), job_completed_by = v_actor_id, updated_at = now()
  WHERE id = p_assembly_job_id
  RETURNING * INTO v_job;

  RETURN v_job;
END;
$$;

COMMENT ON FUNCTION public.reconcile_assembly_job(uuid, text, text) IS
  'Post-handover reconciliation. Variance is always SERVER-DERIVED via compute_assembly_job_variance -- callers supply only explanatory notes, never a variance figure, so a real discrepancy cannot be suppressed by declaring zero. Any non-zero computed variance (return/waste/rework/transfer) must be explained via p_notes -- fails closed otherwise. Sets the authoritative Job Completed state; Job Closed is a separate, later administrative step.';

REVOKE ALL ON FUNCTION public.reconcile_assembly_job(uuid, text, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.reconcile_assembly_job(uuid, text, text) TO authenticated;

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
  IF v_job.job_closed_at IS NOT NULL THEN
    RETURN v_job; -- idempotent replay
  END IF;
  IF v_job.status = 'rejected' THEN
    -- Fully rejected output can be closed without handover/reconciliation.
    NULL;
  ELSIF v_job.status <> 'job_completed' THEN
    RAISE EXCEPTION 'Assembly job cannot be closed before it is Job Completed (or fully rejected)';
  END IF;

  UPDATE public.b2b_assembly_jobs
  SET status = 'job_closed',
      job_closed_at = now(), job_closed_by = v_actor_id, updated_at = now()
  WHERE id = p_assembly_job_id
  RETURNING * INTO v_job;

  RETURN v_job;
END;
$$;

REVOKE ALL ON FUNCTION public.close_assembly_job(uuid, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.close_assembly_job(uuid, text) TO authenticated;

-- =================================================================================
-- 10. Lock down direct table writes now that the governed RPC layer exists,
--     matching every other governed surface in this schema (RGS, B2B receipts).
-- =================================================================================
DROP POLICY IF EXISTS "Assembly operators maintain B2B assembly jobs" ON public.b2b_assembly_jobs;
DROP POLICY IF EXISTS "Assembly operators maintain B2B assembly components" ON public.b2b_assembly_components;

REVOKE INSERT, UPDATE, DELETE ON public.b2b_assembly_jobs FROM authenticated;
REVOKE INSERT, UPDATE, DELETE ON public.b2b_assembly_components FROM authenticated;
REVOKE INSERT, UPDATE, DELETE ON public.b2b_assembly_3pgs_requirements FROM authenticated;
REVOKE INSERT, UPDATE, DELETE ON public.b2b_assembly_handovers FROM authenticated;

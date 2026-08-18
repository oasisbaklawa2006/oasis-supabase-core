-- Forward-only replacement of supabase/migrations/20260817100000_rgs_production_governed_authority.sql.
-- The original was merged to Core main (PR #83) but never applied to production
-- (tcxvcatsqqertcnycuop) because its historical timestamp sits below the current
-- production ledger max (20260817211610, from an unrelated WhatsApp deploy that
-- landed out of band). Per the Controlled Supabase Production Release runbook,
-- a migration below production max must never be pushed under its original
-- timestamp; this is the same content, forward-timestamped, unmodified.
-- Original: supabase/migrations/20260817100000_rgs_production_governed_authority.sql -- content preserved verbatim below.

-- RGS + Production reconciliation, step 2: governed core authority.
--
-- The census found the legacy "execution-OS" inventory model (inventory_reservations,
-- production_jobs, production_rgs_transfers) schema-complete but RPC-empty: every
-- write path was a raw table INSERT/UPDATE gated only by a blanket
-- is_internal_staff() RLS policy, with no atomic reservation, no reconciled
-- quantity custody between Production and RGS, and no idempotency/concurrency
-- guarantees. Central's ReadyGoodsStore.tsx was deliberately left read-only
-- pending exactly this authority.
--
-- This migration does not create a third inventory model. It reuses the
-- existing inventory_reservations / inventory_stock_balances / inventory_movements
-- ledger (the same tables the governed B2B receiving pipeline posts to) and the
-- existing production_jobs / production_rgs_transfers tables, and adds the
-- governed RPC layer that was missing, following the exact pattern already
-- proven in record_b2b_inventory_receipt / accept_b2b_inventory_receipt:
-- SECURITY DEFINER, advisory-lock + optimistic-version CAS on stock balances,
-- correlation-id idempotency, forward-only status transitions, RPC-only writes.
--
-- Quantity truth (declared vs dispatched vs accepted vs variance) is modelled
-- explicitly on production_rgs_transfers and is never collapsed into a single
-- number: accepting 49.5kg of a 49.8kg dispatch of a 50.0kg declaration leaves
-- all three quantities on the row, posts exactly 49.5kg to RGS stock, and
-- records the 0.3kg gap as an explicit, queryable variance.

SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '60s';

-- =================================================================================
-- 1. Schema additions (additive only; no existing column is dropped or renamed)
-- =================================================================================

-- 1a. Reservations gain a shortage-routing link so a production shortage demand
--     can be traced back to the exact reservation that created it, and so we can
--     detect an already-open shortage demand instead of duplicating it.
ALTER TABLE public.inventory_reservations
  ADD COLUMN IF NOT EXISTS location_code text NOT NULL DEFAULT 'FINISHED_GOODS';

-- 1b. inventory_stock_balances gains a picked bucket, matching the ON_HAND /
--     AVAILABLE / RESERVED / PICKED / IN_TRANSIT state model the handover requires.
--     (EXPECTED/BLOCKED/QC_HOLD already map to inventory_stock_balances.quarantine_qty
--     and to reservation_status='blocked'; ISSUED is represented by a reservation's
--     fulfilled_qty, not a balance bucket, since issued stock has left the store.)
ALTER TABLE public.inventory_stock_balances
  ADD COLUMN IF NOT EXISTS picked_qty numeric NOT NULL DEFAULT 0
    CONSTRAINT inventory_stock_balances_picked_qty_check CHECK (picked_qty >= 0);

-- 1c. Widen (never narrow) the movement-type vocabulary to cover the pick/issue
--     steps the census found declared in prose but never implemented as an RPC.
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
    'stock_picked', 'stock_unpicked', 'stock_issued'
  ]));

-- 1d. production_jobs gains a reservation link (so shortage demand is traceable
--     and not duplicated) and a requesting actor, without touching any existing
--     column or constraint.
ALTER TABLE public.production_jobs
  ADD COLUMN IF NOT EXISTS reservation_id uuid NULL REFERENCES public.inventory_reservations(id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS requested_by uuid NULL REFERENCES public.users(id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS correlation_id text NULL;

CREATE INDEX IF NOT EXISTS idx_production_jobs_reservation_id ON public.production_jobs (reservation_id);

-- One open (non-terminal) production job per reservation+department: this is the
-- database-level guarantee behind "do not create duplicate Production demand
-- when an existing open demand already covers the shortage."
CREATE UNIQUE INDEX IF NOT EXISTS uq_production_jobs_open_shortage_per_reservation
  ON public.production_jobs (reservation_id, canonical_department)
  WHERE reservation_id IS NOT NULL
    AND status NOT IN ('rejected', 'completed', 'transferred');

-- 1e. production_job_outputs: an append-only, correlation-id-deduplicated ledger
--     backing production_jobs.produced_qty/wasted_qty, so retried output entries
--     can never double-count (unlike a raw UPDATE ... SET produced_qty = produced_qty + x).
CREATE TABLE IF NOT EXISTS public.production_job_outputs (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  job_id uuid NOT NULL REFERENCES public.production_jobs(id) ON DELETE CASCADE,
  produced_qty numeric NOT NULL DEFAULT 0 CHECK (produced_qty >= 0),
  wasted_qty numeric NOT NULL DEFAULT 0 CHECK (wasted_qty >= 0),
  batch_number text NULL,
  notes text NULL,
  recorded_by uuid NULL REFERENCES public.users(id) ON DELETE SET NULL,
  correlation_id text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT uq_production_job_outputs_correlation UNIQUE (correlation_id)
);
CREATE INDEX IF NOT EXISTS idx_production_job_outputs_job_id ON public.production_job_outputs (job_id);
ALTER TABLE public.production_job_outputs ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Staff can read production_job_outputs" ON public.production_job_outputs
  FOR SELECT TO authenticated USING (public.is_internal_staff(auth.uid()));
REVOKE ALL ON public.production_job_outputs FROM anon, authenticated;
GRANT SELECT ON public.production_job_outputs TO authenticated;

-- 1f. Extend production_rgs_transfers into the full declared/dispatched/received/
--     accepted quantity-custody record the handover's golden scenario requires.
--     Existing columns (job_id, product_id, quantity, batch_number, transferred_by,
--     rgs_notified, created_at) are untouched; "quantity" becomes the *dispatched*
--     quantity going forward, which is exactly what it already meant.
ALTER TABLE public.production_rgs_transfers
  ADD COLUMN IF NOT EXISTS status text NOT NULL DEFAULT 'in_transit'
    CONSTRAINT production_rgs_transfers_status_check
    CHECK (status IN ('in_transit', 'received', 'accepted', 'partially_accepted', 'rejected', 'cancelled')),
  ADD COLUMN IF NOT EXISTS destination_store_code text NOT NULL DEFAULT 'FINISHED_GOODS',
  ADD COLUMN IF NOT EXISTS declared_qty numeric NULL,
  ADD COLUMN IF NOT EXISTS received_qty numeric NULL,
  ADD COLUMN IF NOT EXISTS accepted_qty numeric NULL,
  ADD COLUMN IF NOT EXISTS rejected_qty numeric NULL,
  ADD COLUMN IF NOT EXISTS hold_qty numeric NULL,
  ADD COLUMN IF NOT EXISTS received_by uuid NULL REFERENCES public.users(id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS received_at timestamptz NULL,
  ADD COLUMN IF NOT EXISTS accepted_by uuid NULL REFERENCES public.users(id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS accepted_at timestamptz NULL,
  ADD COLUMN IF NOT EXISTS correlation_id text NULL,
  ADD COLUMN IF NOT EXISTS sku text NULL;

ALTER TABLE public.production_rgs_transfers
  ADD CONSTRAINT production_rgs_transfers_disposition_check
  CHECK (
    accepted_qty IS NULL
    OR (rejected_qty IS NOT NULL AND hold_qty IS NOT NULL
        AND accepted_qty + rejected_qty + hold_qty = received_qty)
  ) NOT VALID;

-- Exactly one open (non-terminal) transfer per production job: a completed job
-- dispatches its output to RGS once. Re-dispatch after rejection is a new job.
CREATE UNIQUE INDEX IF NOT EXISTS uq_production_rgs_transfers_open_per_job
  ON public.production_rgs_transfers (job_id)
  WHERE status NOT IN ('rejected', 'cancelled');

CREATE INDEX IF NOT EXISTS idx_production_rgs_transfers_correlation ON public.production_rgs_transfers (correlation_id);

COMMENT ON TABLE public.production_rgs_transfers IS
  'Governed Production -> RGS custody transfer. quantity/declared_qty = what Production declared ready; quantity = what was physically dispatched; received_qty = what RGS physically received; accepted_qty = what RGS accepted into permanent stock. The gaps between these are the explicit, auditable variance -- never collapsed into one number.';

-- 1g. Outward custody: RGS -> receiver (P&A / B2B dispatch / outlet / internal)
--     handover + acknowledgement record. Mirrors production_rgs_transfers on the
--     outward side rather than inventing an unrelated ticketing model.
CREATE TABLE IF NOT EXISTS public.rgs_issue_events (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  reservation_id uuid NOT NULL REFERENCES public.inventory_reservations(id) ON DELETE RESTRICT,
  product_id uuid NOT NULL,
  sku text NOT NULL,
  issued_qty numeric NOT NULL CHECK (issued_qty > 0),
  source_location text NOT NULL DEFAULT 'FINISHED_GOODS',
  destination_type text NOT NULL CHECK (destination_type IN ('b2b', 'pna', 'outlet', 'internal')),
  destination_reference text NULL,
  status text NOT NULL DEFAULT 'issued' CHECK (status IN ('issued', 'acknowledged', 'variance')),
  issued_by uuid NULL REFERENCES public.users(id) ON DELETE SET NULL,
  issued_at timestamptz NOT NULL DEFAULT now(),
  acknowledged_qty numeric NULL,
  acknowledged_by uuid NULL REFERENCES public.users(id) ON DELETE SET NULL,
  acknowledged_at timestamptz NULL,
  correlation_id text NOT NULL,
  CONSTRAINT uq_rgs_issue_events_correlation UNIQUE (correlation_id)
);
CREATE INDEX IF NOT EXISTS idx_rgs_issue_events_reservation_id ON public.rgs_issue_events (reservation_id);
ALTER TABLE public.rgs_issue_events ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Staff can read rgs_issue_events" ON public.rgs_issue_events
  FOR SELECT TO authenticated USING (public.is_internal_staff(auth.uid()));
REVOKE ALL ON public.rgs_issue_events FROM anon, authenticated;
GRANT SELECT ON public.rgs_issue_events TO authenticated;

COMMENT ON TABLE public.rgs_issue_events IS
  'Governed RGS -> receiver custody handover and acknowledgement. destination_type never carries commercial/customer detail -- only what a receiving department needs.';

-- Legacy execution-OS RLS on these tables used the same blanket is_internal_staff()
-- predicate as every other legacy table; retire it in favour of RPC-only mutation
-- for the tables this migration governs, matching the B2B receiving precedent.
DROP POLICY IF EXISTS "Staff can manage rgs_transfers" ON public.production_rgs_transfers;
CREATE POLICY "Staff can read production_rgs_transfers" ON public.production_rgs_transfers
  FOR SELECT TO authenticated USING (public.is_internal_staff(auth.uid()));
REVOKE INSERT, UPDATE, DELETE ON public.production_rgs_transfers FROM authenticated, anon;
REVOKE INSERT, UPDATE, DELETE ON public.inventory_reservations FROM authenticated, anon;
REVOKE INSERT, UPDATE, DELETE ON public.inventory_stock_balances FROM authenticated, anon;
REVOKE INSERT, UPDATE, DELETE ON public.production_jobs FROM authenticated, anon;

COMMENT ON TABLE public.inventory_reservations IS
  'Phase 4A governed inventory reservations. Writes via governed RPCs only (reserve_rgs_stock / release_rgs_reservation / pick_rgs_reservation / issue_rgs_stock) -- direct table writes are revoked.';
COMMENT ON TABLE public.production_jobs IS
  'Production execution jobs. Writes via governed RPCs only (create_production_shortage_demand / start_production_job / record_production_output / declare_production_ready) -- direct table writes are revoked.';

-- =================================================================================
-- 2. Governed RPCs
-- =================================================================================

-- ---------------------------------------------------------------------------------
-- 2a. reserve_rgs_stock: RGS demand intake + atomic allocation against available
--     stock. Never reserves more than is available; the gap becomes the shortage
--     the caller routes to create_production_shortage_demand.
-- ---------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.reserve_rgs_stock(
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
  p_customer_id uuid DEFAULT NULL
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
    source_department, location_code, reserved_by, correlation_id
  ) VALUES (
    p_reservation_number, p_order_id, p_queue_item_id, p_customer_id, p_product_id, p_sku,
    p_requested_qty, v_reserve_qty, v_status, coalesce(p_priority, 'normal'),
    p_source_department, p_location_code, v_actor_id, p_correlation_id
  )
  RETURNING * INTO v_existing;

  IF v_reserve_qty > 0 THEN
    INSERT INTO public.inventory_movements (
      movement_type, reservation_id, product_id, sku, quantity, source_location,
      actor_id, correlation_id, metadata
    ) VALUES (
      'reservation_created', v_existing.id, p_product_id, p_sku, v_reserve_qty, p_location_code,
      v_actor_id, p_correlation_id, jsonb_build_object('requested_qty', p_requested_qty)
    );
  END IF;

  RETURN v_existing;
END;
$$;

COMMENT ON FUNCTION public.reserve_rgs_stock(text, uuid, uuid, text, numeric, text, text, text, text, uuid, uuid) IS
  'Atomic RGS demand intake + allocation. Reserves min(requested, available); the difference is the exact shortage a caller routes to create_production_shortage_demand. Idempotent by correlation_id.';

-- ---------------------------------------------------------------------------------
-- 2b. release_rgs_reservation: governed release of some/all reserved quantity
--     back to available stock (order cancelled, demand reduced, expiry, etc).
-- ---------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.release_rgs_reservation(
  p_reservation_id uuid,
  p_release_qty numeric,
  p_reason_code text,
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
    RAISE EXCEPTION 'Not authorised to release RGS reservations' USING ERRCODE = '42501';
  END IF;
  IF nullif(btrim(p_correlation_id), '') IS NULL THEN
    RAISE EXCEPTION 'A correlation id is required';
  END IF;
  IF EXISTS (SELECT 1 FROM public.inventory_movements WHERE correlation_id = p_correlation_id) THEN
    SELECT * INTO v_reservation FROM public.inventory_reservations WHERE id = p_reservation_id;
    RETURN v_reservation;
  END IF;

  SELECT * INTO v_reservation FROM public.inventory_reservations WHERE id = p_reservation_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Reservation not found'; END IF;
  IF v_reservation.reservation_status NOT IN ('reserved', 'partially_reserved', 'pending') THEN
    RAISE EXCEPTION 'Reservation is not in a releasable state';
  END IF;
  IF p_release_qty IS NULL OR p_release_qty <= 0 OR p_release_qty > v_reservation.reserved_qty THEN
    RAISE EXCEPTION 'Release quantity must be positive and cannot exceed reserved quantity';
  END IF;

  PERFORM pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(v_reservation.product_id::text || ':' || v_reservation.sku || ':' || v_reservation.location_code, 0)
  );

  UPDATE public.inventory_stock_balances
  SET available_qty = available_qty + p_release_qty,
      reserved_qty = reserved_qty - p_release_qty,
      version = version + 1,
      updated_at = now()
  WHERE product_id = v_reservation.product_id AND sku = v_reservation.sku AND location_code = v_reservation.location_code;
  IF NOT FOUND THEN RAISE EXCEPTION 'Stock balance not found for reservation %', p_reservation_id; END IF;

  UPDATE public.inventory_reservations
  SET reserved_qty = reserved_qty - p_release_qty,
      released_qty = released_qty + p_release_qty,
      reservation_status = CASE
        WHEN released_qty + p_release_qty + fulfilled_qty >= requested_qty THEN 'released'
        WHEN reserved_qty - p_release_qty > 0 THEN 'partially_reserved'
        ELSE 'pending'
      END,
      updated_at = now()
  WHERE id = p_reservation_id
  RETURNING * INTO v_reservation;

  INSERT INTO public.inventory_movements (
    movement_type, reservation_id, product_id, sku, quantity, destination_location,
    actor_id, reason_code, correlation_id
  ) VALUES (
    'reservation_released', p_reservation_id, v_reservation.product_id, v_reservation.sku, p_release_qty,
    v_reservation.location_code, v_actor_id, p_reason_code, p_correlation_id
  );

  RETURN v_reservation;
END;
$$;

-- ---------------------------------------------------------------------------------
-- 2c. create_production_shortage_demand: RGS routes EXACT shortage to Production.
--     Never the full requirement -- and never a duplicate if one is already open.
-- ---------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.create_production_shortage_demand(
  p_reservation_id uuid,
  p_department text,
  p_priority text,
  p_correlation_id text
)
RETURNS public.production_jobs
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_actor_id uuid := auth.uid();
  v_reservation public.inventory_reservations%ROWTYPE;
  v_canonical_department text;
  v_shortage numeric;
  v_job public.production_jobs%ROWTYPE;
BEGIN
  IF v_actor_id IS NULL OR NOT public.is_inventory_manage_role((SELECT role FROM public.users WHERE id = v_actor_id)) THEN
    RAISE EXCEPTION 'Not authorised to create production shortage demand' USING ERRCODE = '42501';
  END IF;
  IF nullif(btrim(p_correlation_id), '') IS NULL THEN
    RAISE EXCEPTION 'A correlation id is required';
  END IF;

  v_canonical_department := public.canonical_production_department(p_department);
  IF v_canonical_department IS NULL THEN
    RAISE EXCEPTION 'Unknown production department %', p_department;
  END IF;

  SELECT * INTO v_reservation FROM public.inventory_reservations WHERE id = p_reservation_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Reservation not found'; END IF;

  v_shortage := v_reservation.requested_qty - v_reservation.reserved_qty - v_reservation.fulfilled_qty - v_reservation.released_qty;
  IF v_shortage <= 0 THEN
    RAISE EXCEPTION 'Reservation % has no shortage to route to production', p_reservation_id;
  END IF;

  -- Do not duplicate an already-open shortage job for this reservation+department.
  SELECT * INTO v_job
  FROM public.production_jobs
  WHERE reservation_id = p_reservation_id
    AND canonical_department = v_canonical_department
    AND status NOT IN ('rejected', 'completed', 'transferred');
  IF FOUND THEN
    RETURN v_job;
  END IF;

  INSERT INTO public.production_jobs (
    order_id, product_id, department, reservation_id, requested_by, assigned_qty,
    priority, status, stage, correlation_id
  ) VALUES (
    v_reservation.order_id, v_reservation.product_id, v_canonical_department, p_reservation_id, v_actor_id,
    v_shortage, coalesce(p_priority, 'normal'), 'pending', 'prep', p_correlation_id
  )
  RETURNING * INTO v_job;

  RETURN v_job;
END;
$$;

COMMENT ON FUNCTION public.create_production_shortage_demand(uuid, text, text, text) IS
  'Routes the EXACT unreserved shortage of a reservation to the mapped Production department. Never the full requirement, and never a duplicate of an already-open shortage job for the same reservation+department (enforced by uq_production_jobs_open_shortage_per_reservation).';

-- ---------------------------------------------------------------------------------
-- 2d. start_production_job: department-scoped start of an assigned job.
-- ---------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.start_production_job(
  p_job_id uuid,
  p_correlation_id text
)
RETURNS public.production_jobs
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_actor_id uuid := auth.uid();
  v_actor_role text;
  v_job public.production_jobs%ROWTYPE;
BEGIN
  SELECT role INTO v_actor_role FROM public.users WHERE id = v_actor_id;
  IF v_actor_id IS NULL OR NOT (public.is_staff_role(v_actor_role)) THEN
    RAISE EXCEPTION 'Not authorised' USING ERRCODE = '42501';
  END IF;

  SELECT * INTO v_job FROM public.production_jobs WHERE id = p_job_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Production job not found'; END IF;

  IF public.role_canonical_department(v_actor_role) IS DISTINCT FROM v_job.canonical_department
     AND upper(coalesce(v_actor_role,'')) NOT IN ('SUPER_ADMIN','ADMIN','OPERATIONS_MANAGER','PRODUCTION_MANAGER') THEN
    RAISE EXCEPTION 'Actor is not authorised for department %', v_job.canonical_department USING ERRCODE = '42501';
  END IF;
  IF v_job.status = 'in_production' THEN
    RETURN v_job; -- idempotent replay: already started
  END IF;
  IF v_job.status NOT IN ('pending', 'accepted') THEN
    RAISE EXCEPTION 'Job is not in a startable state';
  END IF;

  UPDATE public.production_jobs
  SET status = 'in_production', stage = 'processing', started_at = now(),
      assigned_to = coalesce(assigned_to, v_actor_id), updated_at = now()
  WHERE id = p_job_id
  RETURNING * INTO v_job;

  RETURN v_job;
END;
$$;

-- ---------------------------------------------------------------------------------
-- 2e. record_production_output: append-only, idempotent output entry; aggregates
--     roll up onto production_jobs via trigger below.
-- ---------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.record_production_output(
  p_job_id uuid,
  p_produced_qty numeric,
  p_wasted_qty numeric,
  p_batch_number text,
  p_correlation_id text,
  p_notes text DEFAULT NULL
)
RETURNS public.production_job_outputs
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_actor_id uuid := auth.uid();
  v_job public.production_jobs%ROWTYPE;
  v_output public.production_job_outputs%ROWTYPE;
BEGIN
  IF v_actor_id IS NULL OR NOT public.is_internal_staff(v_actor_id) THEN
    RAISE EXCEPTION 'Not authorised' USING ERRCODE = '42501';
  END IF;
  IF nullif(btrim(p_correlation_id), '') IS NULL THEN
    RAISE EXCEPTION 'A correlation id is required';
  END IF;
  IF coalesce(p_produced_qty, 0) < 0 OR coalesce(p_wasted_qty, 0) < 0 THEN
    RAISE EXCEPTION 'Quantities cannot be negative';
  END IF;

  SELECT * INTO v_job FROM public.production_jobs WHERE id = p_job_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Production job not found'; END IF;
  IF v_job.status <> 'in_production' THEN
    RAISE EXCEPTION 'Job is not in production';
  END IF;

  INSERT INTO public.production_job_outputs (
    job_id, produced_qty, wasted_qty, batch_number, notes, recorded_by, correlation_id
  ) VALUES (
    p_job_id, coalesce(p_produced_qty, 0), coalesce(p_wasted_qty, 0), p_batch_number, p_notes, v_actor_id, p_correlation_id
  )
  ON CONFLICT (correlation_id) DO NOTHING
  RETURNING * INTO v_output;

  IF v_output.id IS NULL THEN
    -- Idempotent replay: identical retried call, return what was already recorded.
    SELECT * INTO v_output FROM public.production_job_outputs WHERE correlation_id = p_correlation_id;
  END IF;

  RETURN v_output;
END;
$$;

CREATE OR REPLACE FUNCTION public.production_job_outputs_rollup()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = ''
AS $$
BEGIN
  UPDATE public.production_jobs
  SET produced_qty = coalesce((SELECT sum(produced_qty) FROM public.production_job_outputs WHERE job_id = NEW.job_id), 0),
      wasted_qty = coalesce((SELECT sum(wasted_qty) FROM public.production_job_outputs WHERE job_id = NEW.job_id), 0),
      batch_number = coalesce(NEW.batch_number, batch_number),
      updated_at = now()
  WHERE id = NEW.job_id;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS production_job_outputs_rollup_trigger ON public.production_job_outputs;
CREATE TRIGGER production_job_outputs_rollup_trigger
  AFTER INSERT ON public.production_job_outputs
  FOR EACH ROW EXECUTE FUNCTION public.production_job_outputs_rollup();

-- ---------------------------------------------------------------------------------
-- 2f. declare_production_ready: Production says it is ready. RGS stock is NOT
--     touched here -- this only changes Production's own status (per the
--     handover's non-negotiable quantity-ownership rule).
-- ---------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.declare_production_ready(
  p_job_id uuid,
  p_correlation_id text
)
RETURNS public.production_jobs
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_actor_id uuid := auth.uid();
  v_job public.production_jobs%ROWTYPE;
BEGIN
  IF v_actor_id IS NULL OR NOT public.is_internal_staff(v_actor_id) THEN
    RAISE EXCEPTION 'Not authorised' USING ERRCODE = '42501';
  END IF;

  SELECT * INTO v_job FROM public.production_jobs WHERE id = p_job_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Production job not found'; END IF;
  IF v_job.status = 'completed' THEN
    RETURN v_job; -- idempotent replay: already declared ready
  END IF;
  IF v_job.status <> 'in_production' THEN
    RAISE EXCEPTION 'Job is not in production';
  END IF;
  IF v_job.produced_qty IS NULL OR v_job.produced_qty <= 0 THEN
    RAISE EXCEPTION 'Cannot declare ready with no recorded output';
  END IF;
  IF v_job.produced_qty + coalesce(v_job.wasted_qty, 0) > v_job.assigned_qty * 1.1 THEN
    RAISE EXCEPTION 'Produced + wasted exceeds assigned quantity tolerance';
  END IF;

  UPDATE public.production_jobs
  SET status = 'completed', stage = 'ready', completed_at = now(), locked = true, updated_at = now()
  WHERE id = p_job_id
  RETURNING * INTO v_job;

  RETURN v_job;
END;
$$;

-- ---------------------------------------------------------------------------------
-- 2g. dispatch_production_to_rgs: Production -> RGS custody transfer begins.
--     RGS stock is NOT touched here either -- only physical acceptance posts stock.
-- ---------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.dispatch_production_to_rgs(
  p_job_id uuid,
  p_dispatched_qty numeric,
  p_correlation_id text,
  p_destination_store_code text DEFAULT 'FINISHED_GOODS'
)
RETURNS public.production_rgs_transfers
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_actor_id uuid := auth.uid();
  v_job public.production_jobs%ROWTYPE;
  v_transfer public.production_rgs_transfers%ROWTYPE;
  v_product_sku text;
BEGIN
  IF v_actor_id IS NULL OR NOT public.is_internal_staff(v_actor_id) THEN
    RAISE EXCEPTION 'Not authorised' USING ERRCODE = '42501';
  END IF;
  IF nullif(btrim(p_correlation_id), '') IS NULL THEN
    RAISE EXCEPTION 'A correlation id is required';
  END IF;

  SELECT * INTO v_transfer FROM public.production_rgs_transfers WHERE correlation_id = p_correlation_id;
  IF FOUND THEN RETURN v_transfer; END IF;

  SELECT * INTO v_job FROM public.production_jobs WHERE id = p_job_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Production job not found'; END IF;
  IF v_job.status <> 'completed' OR NOT v_job.locked THEN
    RAISE EXCEPTION 'Job must be declared ready before dispatch to RGS';
  END IF;
  IF p_dispatched_qty IS NULL OR p_dispatched_qty <= 0 OR p_dispatched_qty > v_job.produced_qty THEN
    RAISE EXCEPTION 'Dispatched quantity must be positive and cannot exceed declared output';
  END IF;

  SELECT sku INTO v_product_sku FROM public.products WHERE id = v_job.product_id;

  INSERT INTO public.production_rgs_transfers (
    job_id, product_id, sku, quantity, declared_qty, batch_number, transferred_by,
    status, destination_store_code, correlation_id
  ) VALUES (
    p_job_id, v_job.product_id, v_product_sku, p_dispatched_qty, v_job.produced_qty, v_job.batch_number, v_actor_id,
    'in_transit', p_destination_store_code, p_correlation_id
  )
  RETURNING * INTO v_transfer;

  UPDATE public.production_jobs SET status = 'transferred', updated_at = now() WHERE id = p_job_id;

  RETURN v_transfer;
END;
$$;

-- ---------------------------------------------------------------------------------
-- 2h. record_rgs_receipt: physical arrival at RGS. Does not create stock.
-- ---------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.record_rgs_receipt(
  p_transfer_id uuid,
  p_received_qty numeric,
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
BEGIN
  IF v_actor_id IS NULL OR NOT public.is_inventory_receive_role((SELECT role FROM public.users WHERE id = v_actor_id)) THEN
    RAISE EXCEPTION 'Not authorised to record RGS receipts' USING ERRCODE = '42501';
  END IF;
  IF p_received_qty IS NULL OR p_received_qty < 0 THEN
    RAISE EXCEPTION 'Received quantity cannot be negative';
  END IF;

  SELECT * INTO v_transfer FROM public.production_rgs_transfers WHERE id = p_transfer_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Transfer not found'; END IF;
  IF v_transfer.status <> 'in_transit' THEN
    RAISE EXCEPTION 'Transfer has already been received or closed';
  END IF;

  UPDATE public.production_rgs_transfers
  SET status = 'received', received_qty = p_received_qty, received_by = v_actor_id, received_at = now()
  WHERE id = p_transfer_id
  RETURNING * INTO v_transfer;

  RETURN v_transfer;
END;
$$;

-- ---------------------------------------------------------------------------------
-- 2i. accept_rgs_production_receipt: THE quantity-truth-critical action. Every
--     received unit must be dispositioned accepted/rejected/hold; only
--     accepted_qty ever posts to permanent RGS stock, exactly once, via the
--     same advisory-lock + optimistic-version CAS pattern as accept_b2b_inventory_receipt.
-- ---------------------------------------------------------------------------------
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
  v_current_version integer;
BEGIN
  IF v_actor_id IS NULL OR NOT public.is_inventory_receive_role((SELECT role FROM public.users WHERE id = v_actor_id)) THEN
    RAISE EXCEPTION 'Not authorised to accept RGS receipts' USING ERRCODE = '42501';
  END IF;
  IF nullif(btrim(p_correlation_id), '') IS NULL THEN
    RAISE EXCEPTION 'A correlation id is required';
  END IF;

  SELECT * INTO v_transfer FROM public.production_rgs_transfers WHERE id = p_transfer_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Transfer not found'; END IF;
  -- Once a transfer has been dispositioned, it is settled: return the recorded
  -- truth idempotently rather than raising on retry, and never re-derive a
  -- different outcome from a later, differently-shaped call.
  IF v_transfer.accepted_qty IS NOT NULL THEN
    RETURN v_transfer;
  END IF;
  IF v_transfer.status <> 'received' THEN
    RAISE EXCEPTION 'Transfer is not awaiting acceptance';
  END IF;

  IF least(coalesce(p_accepted_qty,-1), coalesce(p_rejected_qty,-1), coalesce(p_hold_qty,-1)) < 0
     OR coalesce(p_accepted_qty,0) + coalesce(p_rejected_qty,0) + coalesce(p_hold_qty,0) <> v_transfer.received_qty THEN
    RAISE EXCEPTION 'Accepted + rejected + hold must equal the received quantity exactly';
  END IF;
  IF p_accepted_qty > 0 AND p_expected_balance_version IS NULL THEN
    RAISE EXCEPTION 'An expected balance version is required when accepting stock';
  END IF;

  IF p_accepted_qty > 0 THEN
    PERFORM pg_catalog.pg_advisory_xact_lock(
      pg_catalog.hashtextextended(v_transfer.product_id::text || ':' || v_transfer.sku || ':' || v_transfer.destination_store_code, 0)
    );

    SELECT version INTO v_current_version
    FROM public.inventory_stock_balances
    WHERE product_id = v_transfer.product_id AND sku = v_transfer.sku AND location_code = v_transfer.destination_store_code
    FOR UPDATE;

    IF FOUND THEN
      IF v_current_version <> p_expected_balance_version THEN
        RAISE EXCEPTION 'Stale stock balance version for % / %', v_transfer.product_id, v_transfer.sku USING ERRCODE = '40001';
      END IF;
      UPDATE public.inventory_stock_balances
      SET available_qty = available_qty + p_accepted_qty, version = version + 1, updated_at = now()
      WHERE product_id = v_transfer.product_id AND sku = v_transfer.sku AND location_code = v_transfer.destination_store_code
        AND version = p_expected_balance_version;
      IF NOT FOUND THEN
        RAISE EXCEPTION 'Stock balance update did not apply for % / %', v_transfer.product_id, v_transfer.sku USING ERRCODE = '40001';
      END IF;
    ELSE
      IF p_expected_balance_version <> 0 THEN
        RAISE EXCEPTION 'Stock balance does not exist at expected version %', p_expected_balance_version USING ERRCODE = '40001';
      END IF;
      INSERT INTO public.inventory_stock_balances (product_id, sku, location_code, available_qty)
      VALUES (v_transfer.product_id, v_transfer.sku, v_transfer.destination_store_code, p_accepted_qty);
    END IF;

    INSERT INTO public.inventory_movements (
      movement_type, product_id, sku, quantity, destination_location, actor_id,
      reason_code, correlation_id, source_document_type, source_document_reference,
      batch_lot, metadata
    ) VALUES (
      'production_receipt_accepted', v_transfer.product_id, v_transfer.sku, p_accepted_qty,
      v_transfer.destination_store_code, v_actor_id, 'rgs_production_acceptance', p_correlation_id,
      'production_rgs_transfer', v_transfer.id::text, v_transfer.batch_number,
      jsonb_build_object(
        'transfer_id', v_transfer.id, 'job_id', v_transfer.job_id,
        'declared_qty', v_transfer.declared_qty, 'dispatched_qty', v_transfer.quantity,
        'received_qty', v_transfer.received_qty, 'accepted_qty', p_accepted_qty,
        'variance_dispatched_vs_accepted', v_transfer.quantity - p_accepted_qty
      )
    );
  END IF;

  UPDATE public.production_rgs_transfers
  SET accepted_qty = p_accepted_qty, rejected_qty = p_rejected_qty, hold_qty = p_hold_qty,
      status = CASE WHEN p_accepted_qty = 0 THEN 'rejected'
                     WHEN p_accepted_qty < v_transfer.received_qty THEN 'partially_accepted'
                     ELSE 'accepted' END,
      accepted_by = v_actor_id, accepted_at = now(), rgs_notified = true
  WHERE id = p_transfer_id
  RETURNING * INTO v_transfer;

  RETURN v_transfer;
END;
$$;

COMMENT ON FUNCTION public.accept_rgs_production_receipt(uuid, numeric, numeric, numeric, integer, text) IS
  'Posts exactly accepted_qty to permanent RGS stock, once, with an optimistic-lock CAS matching accept_b2b_inventory_receipt. declared_qty (Production''s claim), quantity (dispatched), received_qty (physically arrived) and accepted_qty (posted) all remain on the row -- the golden 50.0/49.8/49.5 scenario is never collapsed into a single figure.';

-- ---------------------------------------------------------------------------------
-- 2j. pick_rgs_reservation / issue_rgs_stock / acknowledge_rgs_issue: the
--     allocation -> pick -> issue -> receiver-acknowledgement leg.
-- ---------------------------------------------------------------------------------
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
  IF EXISTS (SELECT 1 FROM public.inventory_movements WHERE correlation_id = p_correlation_id) THEN
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

CREATE OR REPLACE FUNCTION public.issue_rgs_stock(
  p_reservation_id uuid,
  p_issue_qty numeric,
  p_destination_type text,
  p_destination_reference text,
  p_correlation_id text
)
RETURNS public.rgs_issue_events
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_actor_id uuid := auth.uid();
  v_reservation public.inventory_reservations%ROWTYPE;
  v_issue public.rgs_issue_events%ROWTYPE;
BEGIN
  IF v_actor_id IS NULL OR NOT public.is_internal_staff(v_actor_id) THEN
    RAISE EXCEPTION 'Not authorised' USING ERRCODE = '42501';
  END IF;
  IF p_destination_type NOT IN ('b2b', 'pna', 'outlet', 'internal') THEN
    RAISE EXCEPTION 'Unknown destination type %', p_destination_type;
  END IF;

  SELECT * INTO v_issue FROM public.rgs_issue_events WHERE correlation_id = p_correlation_id;
  IF FOUND THEN RETURN v_issue; END IF;

  SELECT * INTO v_reservation FROM public.inventory_reservations WHERE id = p_reservation_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Reservation not found'; END IF;
  IF p_issue_qty IS NULL OR p_issue_qty <= 0 OR p_issue_qty > v_reservation.reserved_qty THEN
    RAISE EXCEPTION 'Issue quantity must be positive and cannot exceed reserved quantity';
  END IF;

  PERFORM pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(v_reservation.product_id::text || ':' || v_reservation.sku || ':' || v_reservation.location_code, 0)
  );

  -- Issue from picked stock if available, otherwise directly from reserved stock
  -- (pick is an optional intermediate step, not mandatory for every workflow).
  UPDATE public.inventory_stock_balances
  SET picked_qty = greatest(picked_qty - least(picked_qty, p_issue_qty), 0),
      reserved_qty = reserved_qty - greatest(p_issue_qty - least(picked_qty, p_issue_qty), 0),
      version = version + 1, updated_at = now()
  WHERE product_id = v_reservation.product_id AND sku = v_reservation.sku AND location_code = v_reservation.location_code;
  IF NOT FOUND THEN RAISE EXCEPTION 'Stock balance not found'; END IF;

  UPDATE public.inventory_reservations
  SET reserved_qty = reserved_qty - p_issue_qty,
      fulfilled_qty = fulfilled_qty + p_issue_qty,
      reservation_status = CASE WHEN fulfilled_qty + p_issue_qty + released_qty >= requested_qty THEN 'fulfilled' ELSE reservation_status END,
      updated_at = now()
  WHERE id = p_reservation_id;

  INSERT INTO public.inventory_movements (
    movement_type, reservation_id, product_id, sku, quantity, source_location, actor_id, correlation_id, metadata
  ) VALUES (
    'stock_issued', p_reservation_id, v_reservation.product_id, v_reservation.sku, p_issue_qty,
    v_reservation.location_code, v_actor_id, p_correlation_id,
    jsonb_build_object('destination_type', p_destination_type, 'destination_reference', p_destination_reference)
  );

  INSERT INTO public.rgs_issue_events (
    reservation_id, product_id, sku, issued_qty, source_location, destination_type,
    destination_reference, status, issued_by, correlation_id
  ) VALUES (
    p_reservation_id, v_reservation.product_id, v_reservation.sku, p_issue_qty, v_reservation.location_code,
    p_destination_type, p_destination_reference, 'issued', v_actor_id, p_correlation_id
  )
  RETURNING * INTO v_issue;

  RETURN v_issue;
END;
$$;

CREATE OR REPLACE FUNCTION public.acknowledge_rgs_issue(
  p_issue_id uuid,
  p_acknowledged_qty numeric,
  p_correlation_id text
)
RETURNS public.rgs_issue_events
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_actor_id uuid := auth.uid();
  v_issue public.rgs_issue_events%ROWTYPE;
BEGIN
  IF v_actor_id IS NULL OR NOT public.is_internal_staff(v_actor_id) THEN
    RAISE EXCEPTION 'Not authorised' USING ERRCODE = '42501';
  END IF;

  SELECT * INTO v_issue FROM public.rgs_issue_events WHERE id = p_issue_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Issue event not found'; END IF;
  IF v_issue.status <> 'issued' THEN
    RAISE EXCEPTION 'Issue has already been acknowledged';
  END IF;

  UPDATE public.rgs_issue_events
  SET acknowledged_qty = p_acknowledged_qty, acknowledged_by = v_actor_id, acknowledged_at = now(),
      status = CASE WHEN p_acknowledged_qty = issued_qty THEN 'acknowledged' ELSE 'variance' END
  WHERE id = p_issue_id
  RETURNING * INTO v_issue;

  RETURN v_issue;
END;
$$;

-- =================================================================================
-- 3. Privileges: RPC-only mutation, matching the B2B receiving precedent.
-- =================================================================================

REVOKE ALL ON FUNCTION public.reserve_rgs_stock(text, uuid, uuid, text, numeric, text, text, text, text, uuid, uuid) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.release_rgs_reservation(uuid, numeric, text, text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.create_production_shortage_demand(uuid, text, text, text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.start_production_job(uuid, text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.record_production_output(uuid, numeric, numeric, text, text, text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.declare_production_ready(uuid, text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.dispatch_production_to_rgs(uuid, numeric, text, text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.record_rgs_receipt(uuid, numeric, text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.accept_rgs_production_receipt(uuid, numeric, numeric, numeric, integer, text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.pick_rgs_reservation(uuid, numeric, text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.issue_rgs_stock(uuid, numeric, text, text, text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.acknowledge_rgs_issue(uuid, numeric, text) FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION public.reserve_rgs_stock(text, uuid, uuid, text, numeric, text, text, text, text, uuid, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.release_rgs_reservation(uuid, numeric, text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.create_production_shortage_demand(uuid, text, text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.start_production_job(uuid, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.record_production_output(uuid, numeric, numeric, text, text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.declare_production_ready(uuid, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.dispatch_production_to_rgs(uuid, numeric, text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.record_rgs_receipt(uuid, numeric, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.accept_rgs_production_receipt(uuid, numeric, numeric, numeric, integer, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.pick_rgs_reservation(uuid, numeric, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.issue_rgs_stock(uuid, numeric, text, text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.acknowledge_rgs_issue(uuid, numeric, text) TO authenticated;

-- =================================================================================
-- 4. Day-close reconciliation views (read-only; day-close never silently
--    auto-closes an exception -- it only exposes what remains open).
-- =================================================================================

CREATE OR REPLACE VIEW public.rgs_day_close_exceptions AS
SELECT 'unaccepted_transfer'::text AS exception_type, t.id AS reference_id, t.job_id AS related_job_id,
       NULL::uuid AS related_reservation_id, t.destination_store_code AS location_code,
       t.quantity AS quantity, t.created_at AS opened_at
FROM public.production_rgs_transfers t
WHERE t.status IN ('in_transit', 'received')
UNION ALL
SELECT 'ready_not_dispatched'::text, j.id, j.id, j.reservation_id, NULL::text, j.produced_qty, j.completed_at
FROM public.production_jobs j
WHERE j.status = 'completed' AND j.locked = true
  AND NOT EXISTS (SELECT 1 FROM public.production_rgs_transfers t WHERE t.job_id = j.id AND t.status NOT IN ('rejected','cancelled'))
UNION ALL
SELECT 'unacknowledged_issue'::text, e.id, NULL::uuid, e.reservation_id, e.source_location, e.issued_qty, e.issued_at
FROM public.rgs_issue_events e
WHERE e.status = 'issued'
UNION ALL
SELECT 'open_reservation_no_stock'::text, r.id, NULL::uuid, r.id, r.location_code,
       r.requested_qty - r.reserved_qty - r.fulfilled_qty - r.released_qty, r.created_at
FROM public.inventory_reservations r
WHERE r.reservation_status = 'pending'
  AND r.requested_qty - r.reserved_qty - r.fulfilled_qty - r.released_qty > 0;

ALTER VIEW public.rgs_day_close_exceptions SET (security_invoker = true);
COMMENT ON VIEW public.rgs_day_close_exceptions IS
  'Everything a day-close must resolve or explicitly carry forward as a governed exception. Never auto-closed by any RPC in this migration.';
GRANT SELECT ON public.rgs_day_close_exceptions TO authenticated;

-- Forward-only defect closure: RGS authorization and idempotency hardening.
-- Closes four defects surfaced by PR #89 review and deliberately deferred
-- (byte-faithful lineage preservation forbade fixing them in the
-- already-merged/recovered files that introduced them). Each defect is
-- documented in docs/reconciliation/production-migration-lineage-recovery-2026-08-18.md
-- under "Pre-existing production bugs surfaced by review".
--
-- Read-only production check confirmed zero duplicate non-null
-- correlation_id values in inventory_reservations (10/10 rows distinct)
-- before this migration was written, so the unique index below is safe to
-- add without a reconciliation step.

-- =================================================================================
-- 1. inventory_reservations.correlation_id: check-then-insert idempotency in
--    reserve_rgs_stock has no database uniqueness backing it. Two concurrent
--    retries of the same reservation request can both pass the SELECT guard
--    and both reserve stock, double-reserving inventory. The sibling tables
--    in the same migration (production_job_outputs, rgs_issue_events)
--    already carry this defense; this closes the last gap.
-- =================================================================================

CREATE UNIQUE INDEX IF NOT EXISTS uq_inventory_reservations_correlation
  ON public.inventory_reservations (correlation_id)
  WHERE correlation_id IS NOT NULL;

-- =================================================================================
-- 2. release_rgs_reservation / pick_rgs_reservation: replay guards key on any
--    inventory_movements row sharing the correlation id, regardless of
--    movement_type. reserve_rgs_stock also writes an inventory_movements row
--    under the reservation's own correlation id. A caller that reuses one
--    business correlation id across a reserve and a later release/pick turns
--    the later operation into a silent no-op that returns success without
--    moving quantity. Scope each guard to its own movement_type. Also add
--    the non-empty correlation-id validation to pick_rgs_reservation that
--    its siblings (reserve_rgs_stock, release_rgs_reservation) already have.
--
-- Full definitions reproduced from the last effective version
-- (supabase/migrations/20260817215000_fwd_rgs_production_governed_authority.sql)
-- with only the guard predicate and the missing validation changed.
-- =================================================================================

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
  IF EXISTS (
    SELECT 1 FROM public.inventory_movements
    WHERE correlation_id = p_correlation_id AND movement_type = 'reservation_released'
  ) THEN
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
-- 3. accept_production_job: the SECURITY DEFINER RPC returned an already-
--    accepted job (idempotent-replay branch) BEFORE checking department
--    authorization. Any staff member in ANY department could retrieve a
--    job's details from another department merely by hitting the replay
--    path on an already-accepted job -- the authorization gate was never
--    reached on that path. Move the department check before every return.
--
-- Full definition reproduced from the last effective version
-- (supabase/migrations/20260817221000_fwd_rgs_production_intake_rpcs.sql)
-- with only the check ordering changed.
-- =================================================================================

CREATE OR REPLACE FUNCTION public.accept_production_job(
  p_job_id uuid,
  p_batch_number text,
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
  IF v_actor_id IS NULL OR NOT public.is_staff_role(v_actor_role) THEN
    RAISE EXCEPTION 'Not authorised' USING ERRCODE = '42501';
  END IF;

  SELECT * INTO v_job FROM public.production_jobs WHERE id = p_job_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Production job not found'; END IF;
  IF public.role_canonical_department(v_actor_role) IS DISTINCT FROM v_job.canonical_department
     AND upper(coalesce(v_actor_role,'')) NOT IN ('SUPER_ADMIN','ADMIN','OPERATIONS_MANAGER','PRODUCTION_MANAGER') THEN
    RAISE EXCEPTION 'Actor is not authorised for department %', v_job.canonical_department USING ERRCODE = '42501';
  END IF;
  IF v_job.status = 'accepted' THEN
    RETURN v_job; -- idempotent replay
  END IF;
  IF v_job.status <> 'pending' THEN
    RAISE EXCEPTION 'Job is not pending';
  END IF;

  UPDATE public.production_jobs
  SET status = 'accepted', assigned_to = v_actor_id,
      batch_number = coalesce(p_batch_number, batch_number), updated_at = now()
  WHERE id = p_job_id
  RETURNING * INTO v_job;

  RETURN v_job;
END;
$$;

-- =================================================================================
-- 4. pause_production_job: `p_reason NOT IN (...)` evaluates to NULL (not
--    TRUE) when p_reason is NULL, so the validation silently passes and a
--    NULL pause reason gets inserted, bypassing the "reason required"
--    contract. Reject NULL explicitly, alongside unknown non-NULL values.
--
-- Full definition reproduced from the last effective version
-- (supabase/migrations/20260817224000_fwd_rgs_authority_hardening.sql)
-- with only the reason validation changed.
-- =================================================================================

CREATE OR REPLACE FUNCTION public.pause_production_job(
  p_job_id uuid,
  p_reason text,
  p_comment text,
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
  IF v_actor_id IS NULL OR NOT public.is_internal_staff(v_actor_id) THEN
    RAISE EXCEPTION 'Not authorised' USING ERRCODE = '42501';
  END IF;
  IF p_reason IS NULL OR p_reason NOT IN ('machine_breakdown', 'material_shortage', 'other') THEN
    RAISE EXCEPTION 'Unknown pause reason %', p_reason;
  END IF;

  SELECT * INTO v_job FROM public.production_jobs WHERE id = p_job_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Production job not found'; END IF;
  IF public.role_canonical_department(v_actor_role) IS DISTINCT FROM v_job.canonical_department
     AND upper(coalesce(v_actor_role,'')) NOT IN ('SUPER_ADMIN','ADMIN','OPERATIONS_MANAGER','PRODUCTION_MANAGER') THEN
    RAISE EXCEPTION 'Actor is not authorised for department %', v_job.canonical_department USING ERRCODE = '42501';
  END IF;
  IF v_job.status = 'paused' THEN
    RETURN v_job; -- idempotent replay
  END IF;
  IF v_job.status <> 'in_production' THEN
    RAISE EXCEPTION 'Job is not in production';
  END IF;

  INSERT INTO public.production_pauses (job_id, reason, comment, paused_by)
  VALUES (p_job_id, p_reason, p_comment, v_actor_id);

  UPDATE public.production_jobs SET status = 'paused', updated_at = now() WHERE id = p_job_id
  RETURNING * INTO v_job;

  RETURN v_job;
END;
$$;

-- =================================================================================
-- Grants unchanged from the last effective version of each function
-- (CREATE OR REPLACE FUNCTION preserves existing ACLs, so these are
-- functionally no-ops); restated explicitly per migration governance, which
-- requires every migration creating SECURITY DEFINER code to carry its own
-- REVOKE ALL / GRANT EXECUTE pair rather than relying on inherited grants.
-- =================================================================================

REVOKE ALL ON FUNCTION public.release_rgs_reservation(uuid, numeric, text, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.release_rgs_reservation(uuid, numeric, text, text) TO authenticated;

REVOKE ALL ON FUNCTION public.pick_rgs_reservation(uuid, numeric, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.pick_rgs_reservation(uuid, numeric, text) TO authenticated;

REVOKE ALL ON FUNCTION public.accept_production_job(uuid, text, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.accept_production_job(uuid, text, text) TO authenticated;

REVOKE ALL ON FUNCTION public.pause_production_job(uuid, text, text, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.pause_production_job(uuid, text, text, text) TO authenticated;

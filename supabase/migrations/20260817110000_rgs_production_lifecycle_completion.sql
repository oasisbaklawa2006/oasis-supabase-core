-- RGS + Production reconciliation, step 2b: close two gaps found while wiring
-- Central's Production Handheld (PHH) app onto the governed authority added in
-- 20260817100000:
--
-- 1. That migration revoked direct INSERT/UPDATE/DELETE on production_jobs for
--    `authenticated`, but only shipped RPCs for the start/output/ready/dispatch
--    path -- not pause/resume/stage-advance, which PHH's JobExecutionTab.tsx
--    also performs as direct writes. Add governed equivalents so PHH keeps
--    working under the new authority instead of breaking.
--
-- 2. PHH's completion handler was incrementing public.factory_inventory at
--    production-completion time -- before RGS had received or accepted
--    anything. That is exactly the premature-posting behaviour the handover
--    forbids ("Production declared ready: RGS inventory effect = NONE").
--    factory_inventory is also what ReadyGoodsTV.tsx's live "Low Stock" column
--    reads, so it cannot simply stop being written -- it must start being
--    written at the correct point (RGS acceptance) with the correct quantity
--    (accepted net, not declared). accept_rgs_production_receipt is extended
--    to project accepted_qty onto factory_inventory alongside the canonical
--    inventory_stock_balances update it already performs.

SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '60s';

-- ---------------------------------------------------------------------------------
-- pause_production_job / resume_production_job: replace PHH's two
-- separate, non-transactional direct writes (production_pauses insert +
-- production_jobs update) with one governed, atomic action.
-- ---------------------------------------------------------------------------------
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
  v_job public.production_jobs%ROWTYPE;
BEGIN
  IF v_actor_id IS NULL OR NOT public.is_internal_staff(v_actor_id) THEN
    RAISE EXCEPTION 'Not authorised' USING ERRCODE = '42501';
  END IF;
  IF p_reason NOT IN ('machine_breakdown', 'material_shortage', 'other') THEN
    RAISE EXCEPTION 'Unknown pause reason %', p_reason;
  END IF;

  SELECT * INTO v_job FROM public.production_jobs WHERE id = p_job_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Production job not found'; END IF;
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

CREATE OR REPLACE FUNCTION public.resume_production_job(
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
  IF v_job.status = 'in_production' THEN
    RETURN v_job; -- idempotent replay
  END IF;
  IF v_job.status <> 'paused' THEN
    RAISE EXCEPTION 'Job is not paused';
  END IF;

  UPDATE public.production_pauses SET resumed_at = now() WHERE job_id = p_job_id AND resumed_at IS NULL;
  UPDATE public.production_jobs SET status = 'in_production', updated_at = now() WHERE id = p_job_id
  RETURNING * INTO v_job;

  RETURN v_job;
END;
$$;

-- ---------------------------------------------------------------------------------
-- advance_production_job_stage: prep -> processing -> finishing -> ready.
-- ---------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.advance_production_job_stage(
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
  v_stages text[] := ARRAY['prep', 'processing', 'finishing', 'ready'];
  v_idx integer;
BEGIN
  IF v_actor_id IS NULL OR NOT public.is_internal_staff(v_actor_id) THEN
    RAISE EXCEPTION 'Not authorised' USING ERRCODE = '42501';
  END IF;

  SELECT * INTO v_job FROM public.production_jobs WHERE id = p_job_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Production job not found'; END IF;
  IF v_job.status NOT IN ('in_production', 'paused') THEN
    RAISE EXCEPTION 'Job is not active';
  END IF;

  v_idx := array_position(v_stages, v_job.stage);
  IF v_idx IS NULL OR v_idx >= array_length(v_stages, 1) THEN
    RETURN v_job; -- already at the final stage; no-op rather than error
  END IF;

  UPDATE public.production_jobs SET stage = v_stages[v_idx + 1], updated_at = now() WHERE id = p_job_id
  RETURNING * INTO v_job;

  RETURN v_job;
END;
$$;

REVOKE ALL ON FUNCTION public.pause_production_job(uuid, text, text, text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.resume_production_job(uuid, text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.advance_production_job_stage(uuid, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.pause_production_job(uuid, text, text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.resume_production_job(uuid, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.advance_production_job_stage(uuid, text) TO authenticated;

-- ---------------------------------------------------------------------------------
-- Extend accept_rgs_production_receipt: project accepted_qty onto
-- factory_inventory too, at acceptance time (not declaration time), so
-- existing consumers (ReadyGoodsTV.tsx's Low Stock column) see correct,
-- non-premature quantities without needing to be rewritten in this pass.
-- factory_inventory has no unique constraint on product_id and existing rows
-- may already be duplicated by legacy direct writes, so this mirrors the
-- same "find one, else insert" shape the application code already used
-- rather than assuming uniqueness the schema never enforced.
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
  v_factory_inventory_id uuid;
BEGIN
  IF v_actor_id IS NULL OR NOT public.is_inventory_receive_role((SELECT role FROM public.users WHERE id = v_actor_id)) THEN
    RAISE EXCEPTION 'Not authorised to accept RGS receipts' USING ERRCODE = '42501';
  END IF;
  IF nullif(btrim(p_correlation_id), '') IS NULL THEN
    RAISE EXCEPTION 'A correlation id is required';
  END IF;

  SELECT * INTO v_transfer FROM public.production_rgs_transfers WHERE id = p_transfer_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Transfer not found'; END IF;
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

    -- Legacy factory_inventory projection, kept in sync at the correct point
    -- (acceptance) with the correct quantity (accepted, not declared) for
    -- existing read-only consumers (e.g. ReadyGoodsTV.tsx).
    IF v_transfer.product_id IS NOT NULL THEN
      SELECT id INTO v_factory_inventory_id FROM public.factory_inventory WHERE product_id = v_transfer.product_id LIMIT 1;
      IF v_factory_inventory_id IS NOT NULL THEN
        UPDATE public.factory_inventory
        SET quantity = coalesce(quantity, 0) + p_accepted_qty, last_updated = now()
        WHERE id = v_factory_inventory_id;
      ELSE
        INSERT INTO public.factory_inventory (product_id, quantity) VALUES (v_transfer.product_id, p_accepted_qty);
      END IF;
    END IF;
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
  'Posts exactly accepted_qty to permanent RGS stock (inventory_stock_balances) and the legacy factory_inventory projection, once, with an optimistic-lock CAS matching accept_b2b_inventory_receipt. declared_qty, quantity (dispatched), received_qty and accepted_qty all remain on the row -- the golden 50.0/49.8/49.5 scenario is never collapsed into a single figure.';

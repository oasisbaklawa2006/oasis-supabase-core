-- FACT-C2: governed Dispatch Packing List (DPL) authority.
--
-- The b2b_dispatch_contract migration (20260804103000) already modelled the
-- canonical DPL table -- b2b_dispatch_packing_list_versions (version_number,
-- status draft/generated/submitted_to_finance/finance_verified/superseded,
-- self-referencing superseded_by, submitted_to_finance_at, finance_check_state,
-- unique correlation_id) -- but no RPC ever wrote to it, and it was left
-- reachable by direct client INSERT/UPDATE/DELETE via a role-gated "FOR ALL"
-- RLS policy with no server-side cross-validation against the FACT-C1 locked
-- carton truth. A browser could fabricate an arbitrary packing-list snapshot,
-- submit a DPL for a consignment with unlocked or nonexistent cartons, or
-- silently overwrite an already-submitted version.
--
-- This migration closes that gap with three governed RPCs against the
-- EXISTING table (no competing schema, no new state machine) and locks the
-- table to RPC-only mutation:
--
--   * create_b2b_dispatch_packing_list   -- first version, from locked cartons
--   * supersede_b2b_dispatch_packing_list -- governed correction, reasoned
--   * submit_b2b_dispatch_packing_list_to_finance -- explicit, auditable
--
-- Scope is intentionally narrow to carton-truth -> DPL version -> submission
-- to Finance. FACT-C2 does not implement Finance's own verification/approval
-- of a submitted DPL (finance_check_state stays 'pending' after submission --
-- a future, separate Finance-side authority moves it to 'verified'/
-- 'discrepancy'/'repack_required'), and does not touch
-- b2b_dispatch_consignments.status transitions (packing_list_generated /
-- finance_check are part of a broader consignment lifecycle this PR does not
-- redesign or drive).

-- =============================================================================
-- A. Governed DPL creation from FACT-C1 locked carton truth.
--
-- The physical_truth_snapshot is always computed server-side from the
-- consignment's own consignment_lines/cartons/carton_items -- the caller
-- supplies only the consignment_id and a correlation_id, never any
-- product/quantity/carton content directly, so a browser-composed total can
-- never become the operational DPL truth.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.compute_b2b_dispatch_packing_list_snapshot(p_consignment_id uuid)
RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT jsonb_build_object(
    'consignment_id', p_consignment_id,
    'computed_at', now(),
    'lines', (
      SELECT coalesce(jsonb_agg(jsonb_build_object(
        'consignment_line_id', cl.id,
        'order_item_id', cl.order_item_id,
        'product_id', cl.product_id,
        'product_code', cl.product_code,
        'uom', cl.uom,
        'selected_qty', cl.selected_qty,
        'accepted_ready_qty', cl.accepted_ready_qty,
        'packed_qty', cl.packed_qty
      ) ORDER BY cl.product_code), '[]'::jsonb)
      FROM public.b2b_dispatch_consignment_lines cl
      WHERE cl.consignment_id = p_consignment_id
    ),
    'cartons', (
      SELECT coalesce(jsonb_agg(jsonb_build_object(
        'carton_id', c.id,
        'carton_code', c.carton_code,
        'carton_sequence', c.carton_sequence,
        'status', c.status,
        'net_weight', c.net_weight,
        'gross_weight', c.gross_weight,
        'items', (
          SELECT coalesce(jsonb_agg(jsonb_build_object(
            'product_id', ci.product_id,
            'product_code', ci.product_code,
            'batch_lot', ci.batch_lot,
            'quantity', ci.quantity,
            'uom', ci.uom
          ) ORDER BY ci.product_code, ci.batch_lot), '[]'::jsonb)
          FROM public.b2b_dispatch_carton_items ci
          WHERE ci.carton_id = c.id
        )
      ) ORDER BY c.carton_sequence), '[]'::jsonb)
      FROM public.b2b_dispatch_cartons c
      WHERE c.consignment_id = p_consignment_id
    )
  );
$$;

COMMENT ON FUNCTION public.compute_b2b_dispatch_packing_list_snapshot(uuid) IS
  'Server-computed physical_truth_snapshot for a DPL version: consignment lines and locked-carton contents, never client-supplied.';

REVOKE ALL ON FUNCTION public.compute_b2b_dispatch_packing_list_snapshot(uuid) FROM PUBLIC, anon, authenticated;

-- Shared precondition: every carton in the consignment must be locked (or
-- further along), and at least one carton must exist, and every consignment
-- line's packed_qty must reconcile with what was actually scanned into its
-- cartons -- before any DPL version (initial or corrective) can be produced.
CREATE OR REPLACE FUNCTION public.validate_b2b_dispatch_packing_list_readiness(p_consignment_id uuid)
RETURNS void
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_total_cartons integer;
  v_unlocked_cartons integer;
  v_mismatch record;
BEGIN
  SELECT count(*),
    count(*) FILTER (
      WHERE status NOT IN ('locked', 'finance_check_open', 'verified', 'labelled', 'ready_to_load', 'loaded', 'handed_over')
    )
  INTO v_total_cartons, v_unlocked_cartons
  FROM public.b2b_dispatch_cartons
  WHERE consignment_id = p_consignment_id;

  IF v_total_cartons = 0 THEN
    RAISE EXCEPTION 'Consignment % has no cartons and cannot generate a packing list', p_consignment_id USING ERRCODE = '22023';
  END IF;
  IF v_unlocked_cartons > 0 THEN
    RAISE EXCEPTION 'Consignment % has % unlocked carton(s); lock all cartons before generating a packing list', p_consignment_id, v_unlocked_cartons USING ERRCODE = '22023';
  END IF;

  SELECT cl.id, cl.packed_qty, coalesce(sum(ci.quantity), 0) AS scanned_qty
  INTO v_mismatch
  FROM public.b2b_dispatch_consignment_lines cl
  LEFT JOIN public.b2b_dispatch_carton_items ci ON ci.consignment_line_id = cl.id
  WHERE cl.consignment_id = p_consignment_id
  GROUP BY cl.id, cl.packed_qty
  HAVING abs(cl.packed_qty - coalesce(sum(ci.quantity), 0)) > 0.0001
  LIMIT 1;

  IF FOUND THEN
    RAISE EXCEPTION 'Consignment line % packed_qty (%) does not reconcile with scanned carton contents (%)', v_mismatch.id, v_mismatch.packed_qty, v_mismatch.scanned_qty USING ERRCODE = '22023';
  END IF;
END;
$$;

COMMENT ON FUNCTION public.validate_b2b_dispatch_packing_list_readiness(uuid) IS
  'Fail-closed precondition for DPL generation/correction: every carton locked, at least one carton, packed_qty reconciles with scanned carton contents.';

REVOKE ALL ON FUNCTION public.validate_b2b_dispatch_packing_list_readiness(uuid) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.create_b2b_dispatch_packing_list(
  p_consignment_id uuid,
  p_correlation_id text
)
RETURNS public.b2b_dispatch_packing_list_versions
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_actor_id uuid := auth.uid();
  v_correlation_id text := nullif(btrim(p_correlation_id), '');
  v_existing public.b2b_dispatch_packing_list_versions%ROWTYPE;
  v_consignment public.b2b_dispatch_consignments%ROWTYPE;
  v_next_version integer;
  v_snapshot jsonb;
  v_version public.b2b_dispatch_packing_list_versions%ROWTYPE;
BEGIN
  IF v_actor_id IS NULL OR NOT public.can_manage_b2b_dispatch(v_actor_id) THEN
    RAISE EXCEPTION 'Not authorised to create a dispatch packing list' USING ERRCODE = '42501';
  END IF;
  IF v_correlation_id IS NULL THEN
    RAISE EXCEPTION 'A correlation id is required';
  END IF;

  SELECT * INTO v_existing FROM public.b2b_dispatch_packing_list_versions WHERE correlation_id = v_correlation_id;
  IF FOUND THEN
    RETURN v_existing;
  END IF;

  -- Serialise all DPL lifecycle operations (create/supersede/submit) for the
  -- same consignment so a concurrent caller cannot create two competing
  -- "first" versions or race a supersession against a submission.
  PERFORM pg_advisory_xact_lock(hashtextextended(p_consignment_id::text, 1001));

  SELECT * INTO v_consignment FROM public.b2b_dispatch_consignments WHERE id = p_consignment_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Consignment not found';
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.b2b_dispatch_packing_list_versions
    WHERE consignment_id = p_consignment_id AND status <> 'superseded'
  ) THEN
    RAISE EXCEPTION 'Consignment % already has a current packing list version; use supersede to correct it', p_consignment_id USING ERRCODE = '22023';
  END IF;

  PERFORM public.validate_b2b_dispatch_packing_list_readiness(p_consignment_id);

  SELECT coalesce(max(version_number), 0) + 1 INTO v_next_version
  FROM public.b2b_dispatch_packing_list_versions
  WHERE consignment_id = p_consignment_id;

  v_snapshot := public.compute_b2b_dispatch_packing_list_snapshot(p_consignment_id);

  INSERT INTO public.b2b_dispatch_packing_list_versions (
    consignment_id, version_number, status, physical_truth_snapshot, generated_by, correlation_id
  ) VALUES (
    p_consignment_id, v_next_version, 'generated', v_snapshot, v_actor_id, v_correlation_id
  ) RETURNING * INTO v_version;

  INSERT INTO public.b2b_dispatch_events (
    order_id, consignment_id, event_type, actor_id, actor_role,
    source_record_type, source_record_id, document_version_id, correlation_id
  )
  SELECT c.order_id, p_consignment_id, 'packing_list_generated', v_actor_id, public.get_user_role(v_actor_id),
    'b2b_dispatch_packing_list_versions', v_version.id, v_version.id, v_correlation_id
  FROM public.b2b_dispatch_consignments c WHERE c.id = p_consignment_id;

  RETURN v_version;
END;
$$;

COMMENT ON FUNCTION public.create_b2b_dispatch_packing_list(uuid, text) IS
  'Creates the first governed DPL version for a consignment from FACT-C1 locked carton truth. Rejects unlocked/absent cartons, quantity mismatches, and a consignment that already has a current version.';

REVOKE ALL ON FUNCTION public.create_b2b_dispatch_packing_list(uuid, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.create_b2b_dispatch_packing_list(uuid, text) TO authenticated;

-- =============================================================================
-- B. Governed correction / supersession.
--
-- The only way an existing version's content is ever superseded: a reasoned,
-- attributed, correlation-evidenced new version replaces it. The prior
-- version is never edited in place -- it is marked 'superseded' and kept.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.supersede_b2b_dispatch_packing_list(
  p_consignment_id uuid,
  p_current_version_id uuid,
  p_reason text,
  p_correlation_id text
)
RETURNS public.b2b_dispatch_packing_list_versions
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_actor_id uuid := auth.uid();
  v_reason text := nullif(btrim(p_reason), '');
  v_correlation_id text := nullif(btrim(p_correlation_id), '');
  v_existing public.b2b_dispatch_packing_list_versions%ROWTYPE;
  v_consignment public.b2b_dispatch_consignments%ROWTYPE;
  v_current public.b2b_dispatch_packing_list_versions%ROWTYPE;
  v_next_version integer;
  v_snapshot jsonb;
  v_version public.b2b_dispatch_packing_list_versions%ROWTYPE;
BEGIN
  IF v_actor_id IS NULL OR NOT public.can_manage_b2b_dispatch(v_actor_id) THEN
    RAISE EXCEPTION 'Not authorised to correct a dispatch packing list' USING ERRCODE = '42501';
  END IF;
  IF v_correlation_id IS NULL THEN
    RAISE EXCEPTION 'A correlation id is required';
  END IF;
  IF v_reason IS NULL THEN
    RAISE EXCEPTION 'A reason is required to correct or supersede a packing list version';
  END IF;

  SELECT * INTO v_existing FROM public.b2b_dispatch_packing_list_versions WHERE correlation_id = v_correlation_id;
  IF FOUND THEN
    RETURN v_existing;
  END IF;

  PERFORM pg_advisory_xact_lock(hashtextextended(p_consignment_id::text, 1001));

  SELECT * INTO v_consignment FROM public.b2b_dispatch_consignments WHERE id = p_consignment_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Consignment not found';
  END IF;

  SELECT * INTO v_current FROM public.b2b_dispatch_packing_list_versions WHERE id = p_current_version_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Packing list version not found';
  END IF;
  IF v_current.consignment_id <> p_consignment_id THEN
    RAISE EXCEPTION 'Packing list version does not belong to consignment %', p_consignment_id USING ERRCODE = '22023';
  END IF;
  IF v_current.status = 'superseded' OR v_current.superseded_by IS NOT NULL THEN
    RAISE EXCEPTION 'Packing list version % has already been superseded; reload the current version and retry', p_current_version_id USING ERRCODE = '40001';
  END IF;

  PERFORM public.validate_b2b_dispatch_packing_list_readiness(p_consignment_id);

  SELECT coalesce(max(version_number), 0) + 1 INTO v_next_version
  FROM public.b2b_dispatch_packing_list_versions
  WHERE consignment_id = p_consignment_id;

  v_snapshot := public.compute_b2b_dispatch_packing_list_snapshot(p_consignment_id);

  INSERT INTO public.b2b_dispatch_packing_list_versions (
    consignment_id, version_number, status, physical_truth_snapshot, generated_by, correlation_id
  ) VALUES (
    p_consignment_id, v_next_version, 'generated', v_snapshot, v_actor_id, v_correlation_id
  ) RETURNING * INTO v_version;

  UPDATE public.b2b_dispatch_packing_list_versions
  SET status = 'superseded', superseded_by = v_version.id
  WHERE id = p_current_version_id AND status <> 'superseded';

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Packing list version % has already been superseded; reload the current version and retry', p_current_version_id USING ERRCODE = '40001';
  END IF;

  INSERT INTO public.b2b_dispatch_events (
    order_id, consignment_id, event_type, actor_id, actor_role, reason,
    source_record_type, source_record_id, document_version_id, correlation_id
  )
  SELECT c.order_id, p_consignment_id, 'packing_list_superseded', v_actor_id, public.get_user_role(v_actor_id), v_reason,
    'b2b_dispatch_packing_list_versions', v_version.id, v_version.id, v_correlation_id
  FROM public.b2b_dispatch_consignments c WHERE c.id = p_consignment_id;

  RETURN v_version;
END;
$$;

COMMENT ON FUNCTION public.supersede_b2b_dispatch_packing_list(uuid, uuid, text, text) IS
  'Governed DPL correction: creates a new version from current locked-carton truth and marks the given current version superseded. Requires a reason; rejects a stale/already-superseded current-version id.';

REVOKE ALL ON FUNCTION public.supersede_b2b_dispatch_packing_list(uuid, uuid, text, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.supersede_b2b_dispatch_packing_list(uuid, uuid, text, text) TO authenticated;

-- =============================================================================
-- C. Explicit, auditable submission to Finance.
--
-- This is the FACT-E2E boundary: submission only. No downstream Finance
-- approval/verification/release is implemented by this authority.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.submit_b2b_dispatch_packing_list_to_finance(
  p_consignment_id uuid,
  p_version_id uuid,
  p_correlation_id text
)
RETURNS public.b2b_dispatch_packing_list_versions
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_actor_id uuid := auth.uid();
  v_correlation_id text := nullif(btrim(p_correlation_id), '');
  v_existing public.b2b_dispatch_packing_list_versions%ROWTYPE;
  v_consignment public.b2b_dispatch_consignments%ROWTYPE;
  v_current public.b2b_dispatch_packing_list_versions%ROWTYPE;
  v_version public.b2b_dispatch_packing_list_versions%ROWTYPE;
BEGIN
  IF v_actor_id IS NULL OR NOT public.can_manage_b2b_dispatch(v_actor_id) THEN
    RAISE EXCEPTION 'Not authorised to submit a dispatch packing list to Finance' USING ERRCODE = '42501';
  END IF;
  IF v_correlation_id IS NULL THEN
    RAISE EXCEPTION 'A correlation id is required';
  END IF;

  SELECT * INTO v_existing FROM public.b2b_dispatch_packing_list_versions WHERE correlation_id = v_correlation_id;
  IF FOUND THEN
    RETURN v_existing;
  END IF;

  PERFORM pg_advisory_xact_lock(hashtextextended(p_consignment_id::text, 1001));

  SELECT * INTO v_consignment FROM public.b2b_dispatch_consignments WHERE id = p_consignment_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Consignment not found';
  END IF;

  SELECT * INTO v_current FROM public.b2b_dispatch_packing_list_versions WHERE id = p_version_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Packing list version not found';
  END IF;
  IF v_current.consignment_id <> p_consignment_id THEN
    RAISE EXCEPTION 'Packing list version does not belong to consignment %', p_consignment_id USING ERRCODE = '22023';
  END IF;
  IF v_current.status = 'superseded' OR v_current.superseded_by IS NOT NULL THEN
    RAISE EXCEPTION 'Packing list version % has been superseded and is not eligible for submission', p_version_id USING ERRCODE = '22023';
  END IF;
  IF v_current.status <> 'generated' THEN
    RAISE EXCEPTION 'Packing list version % is % and has already been submitted to Finance', p_version_id, v_current.status USING ERRCODE = '22023';
  END IF;

  UPDATE public.b2b_dispatch_packing_list_versions
  SET status = 'submitted_to_finance', submitted_to_finance_at = now(), finance_check_state = 'pending'
  WHERE id = p_version_id AND status = 'generated'
  RETURNING * INTO v_version;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Packing list version % is no longer eligible for submission; reload and retry', p_version_id USING ERRCODE = '40001';
  END IF;

  INSERT INTO public.b2b_dispatch_events (
    order_id, consignment_id, event_type, actor_id, actor_role,
    source_record_type, source_record_id, document_version_id, correlation_id
  )
  SELECT c.order_id, p_consignment_id, 'packing_list_submitted_to_finance', v_actor_id, public.get_user_role(v_actor_id),
    'b2b_dispatch_packing_list_versions', v_version.id, v_version.id, v_correlation_id
  FROM public.b2b_dispatch_consignments c WHERE c.id = p_consignment_id;

  RETURN v_version;
END;
$$;

COMMENT ON FUNCTION public.submit_b2b_dispatch_packing_list_to_finance(uuid, uuid, text) IS
  'Explicit, auditable submission of a generated (non-superseded) DPL version to Finance. Sets finance_check_state=pending; Finance''s own verification/approval is a separate, later authority not implemented here.';

REVOKE ALL ON FUNCTION public.submit_b2b_dispatch_packing_list_to_finance(uuid, uuid, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.submit_b2b_dispatch_packing_list_to_finance(uuid, uuid, text) TO authenticated;

-- =============================================================================
-- D. Close the direct-write gap: RPC-only mutation from here on. SELECT
--    access for internal staff (granted by the base migration's blanket read
--    policy) is untouched.
-- =============================================================================

REVOKE INSERT, UPDATE, DELETE ON public.b2b_dispatch_packing_list_versions FROM authenticated;

DROP POLICY IF EXISTS "Dispatch operators maintain packing list versions" ON public.b2b_dispatch_packing_list_versions;

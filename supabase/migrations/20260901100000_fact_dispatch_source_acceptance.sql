-- FACT-E2E Core repair (oasis-supabase-core#173): govern source-to-Dispatch
-- accepted-ready custody.
--
-- Defect closed by this migration: b2b_dispatch_consignment_lines.
-- accepted_ready_qty defaults to 0 and, until now, no governed RPC ever
-- advanced it. create_b2b_dispatch_consignment (20260822140000) only sets
-- selected_qty. record_b2b_dispatch_carton_item_scan (FACT-C1, 20260830110000)
-- correctly enforces packed_qty <= accepted_ready_qty, so a freshly created
-- consignment line could never accept a positive scan through the governed
-- runtime -- confirmed independently against canonical production by Mission
-- Control and evidenced by Central FACT-E2E Gate 1B (Oasis-Baklawa-Central#433).
--
-- Design constraint (explicit, from issue #173): do NOT set
-- accepted_ready_qty = selected_qty at consignment creation. The schema
-- already models a real physical custody chain via the existing
-- b2b_dispatch_handoffs / b2b_dispatch_handoff_lines tables (added
-- 20260804103000, zero RPCs, zero callers, same "modelled but unreachable"
-- pattern already closed for consignments/cartons by the two migrations
-- above). This migration adds exactly the three governed RPCs needed to
-- drive that existing custody chain and nothing else:
--
--   1. declare_b2b_dispatch_source_handoff  -- a Factory source department
--      (PRODUCTION / RGS / 3PGS / PACKING_ASSEMBLY / QUALITY) declares it is
--      releasing a quantity for an exact consignment line.
--   2. record_b2b_dispatch_handoff_receipt  -- Dispatch records what it
--      physically received against that declaration.
--   3. accept_b2b_dispatch_handoff          -- Dispatch reconciles received
--      quantity into accepted / held / rejected, and only the accepted
--      portion is what cumulatively advances
--      b2b_dispatch_consignment_lines.accepted_ready_qty (bounded by
--      selected_qty, enforced by the pre-existing
--      b2b_dispatch_consignment_line_progress_check CHECK).
--
-- Direct authenticated INSERT/UPDATE/DELETE on b2b_dispatch_handoffs,
-- b2b_dispatch_handoff_lines and b2b_dispatch_consignment_lines is revoked
-- below (mirroring the RGS/production lockdown in
-- 20260817100000_rgs_production_governed_authority.sql) so accepted_ready_qty
-- becomes reachable only through the governed RPCs; SELECT remains available
-- to authenticated internal staff via the existing RLS policies.

-- =============================================================================
-- A. Role authority: who may declare a source handoff, per department.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.can_declare_b2b_dispatch_handoff(
  _user_id uuid,
  _source_department text
)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.users
    WHERE id = _user_id
      AND (
        upper(coalesce(role, '')) = ANY (ARRAY['SUPER_ADMIN', 'ADMIN', 'OPERATIONS_MANAGER'])
        OR (
          upper(coalesce(_source_department, '')) = 'PRODUCTION'
          AND upper(coalesce(role, '')) = 'PRODUCTION_MANAGER'
        )
        OR (
          upper(coalesce(_source_department, '')) = 'RGS'
          AND upper(coalesce(role, '')) = ANY (ARRAY['RGS_ADMIN', 'STORE_READY_GOODS', 'STORE_INCHARGE', 'INVENTORY_MANAGER'])
        )
        OR (
          upper(coalesce(_source_department, '')) = '3PGS'
          AND upper(coalesce(role, '')) = 'STORE_3RD_PARTY'
        )
        OR (
          upper(coalesce(_source_department, '')) = 'PACKING_ASSEMBLY'
          AND upper(coalesce(role, '')) = 'HOD_ASSEMBLY'
        )
      )
  );
$$;

COMMENT ON FUNCTION public.can_declare_b2b_dispatch_handoff(uuid, text) IS
  'Per-department authority for declaring a source-to-Dispatch handoff. Each Factory source department (PRODUCTION, RGS, 3PGS, PACKING_ASSEMBLY) is gated to its own operating role; QUALITY has no dedicated staff role today and so is reachable only by SUPER_ADMIN/ADMIN/OPERATIONS_MANAGER. This is deliberately narrower than can_manage_b2b_dispatch, which governs Dispatch-side receipt/acceptance -- a source actor authorised to declare must not also be treated as authorised to accept its own declaration into Dispatch custody.';

REVOKE ALL ON FUNCTION public.can_declare_b2b_dispatch_handoff(uuid, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.can_declare_b2b_dispatch_handoff(uuid, text) TO authenticated;

-- =============================================================================
-- B. Source declares/releases quantity for an exact consignment line.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.declare_b2b_dispatch_source_handoff(
  p_consignment_id uuid,
  p_source_department text,
  p_source_location text,
  p_lines jsonb,
  p_correlation_id text
)
RETURNS public.b2b_dispatch_handoffs
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_actor_id uuid := auth.uid();
  v_correlation_id text := nullif(btrim(p_correlation_id), '');
  v_source_department text := upper(coalesce(nullif(btrim(p_source_department), ''), ''));
  v_source_location text := nullif(btrim(p_source_location), '');
  v_consignment public.b2b_dispatch_consignments%ROWTYPE;
  v_existing public.b2b_dispatch_handoffs%ROWTYPE;
  v_handoff public.b2b_dispatch_handoffs%ROWTYPE;
  v_handoff_number text;
  v_next_sequence integer;
  v_line jsonb;
  v_order_item_id uuid;
  v_declared_qty numeric;
  v_batch_lot text;
  v_expiry_date date;
  v_consignment_line public.b2b_dispatch_consignment_lines%ROWTYPE;
  v_remaining numeric;
BEGIN
  IF v_actor_id IS NULL OR NOT public.can_declare_b2b_dispatch_handoff(v_actor_id, v_source_department) THEN
    RAISE EXCEPTION 'Not authorised to declare a % dispatch handoff', coalesce(v_source_department, '<none>') USING ERRCODE = '42501';
  END IF;
  IF v_correlation_id IS NULL THEN
    RAISE EXCEPTION 'A correlation id is required';
  END IF;
  IF v_source_location IS NULL THEN
    RAISE EXCEPTION 'A source location is required';
  END IF;
  IF p_lines IS NULL OR jsonb_typeof(p_lines) <> 'array' OR jsonb_array_length(p_lines) = 0 THEN
    RAISE EXCEPTION 'At least one handoff line is required';
  END IF;

  SELECT * INTO v_existing FROM public.b2b_dispatch_handoffs WHERE correlation_id = v_correlation_id;
  IF FOUND THEN
    RETURN v_existing;
  END IF;

  SELECT * INTO v_consignment FROM public.b2b_dispatch_consignments WHERE id = p_consignment_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Consignment not found';
  END IF;
  IF v_consignment.status IN ('dispatched', 'delivery_exception', 'delivered', 'closed', 'cancelled') THEN
    RAISE EXCEPTION 'Consignment % is % and cannot accept a new source handoff', p_consignment_id, v_consignment.status;
  END IF;

  SELECT * INTO v_existing FROM public.b2b_dispatch_handoffs WHERE correlation_id = v_correlation_id;
  IF FOUND THEN
    RETURN v_existing;
  END IF;

  SELECT coalesce(count(*), 0) + 1 INTO v_next_sequence
  FROM public.b2b_dispatch_handoffs WHERE consignment_id = p_consignment_id;
  v_handoff_number := v_consignment.consignment_number || '-HO-' || lpad(v_next_sequence::text, 2, '0');

  BEGIN
    INSERT INTO public.b2b_dispatch_handoffs (
      handoff_number, order_id, consignment_id, source_department, source_location,
      status, issued_by, correlation_id
    ) VALUES (
      v_handoff_number, v_consignment.order_id, p_consignment_id, v_source_department, v_source_location,
      'declared_ready', v_actor_id, v_correlation_id
    ) RETURNING * INTO v_handoff;
  EXCEPTION WHEN unique_violation THEN
    SELECT * INTO v_existing FROM public.b2b_dispatch_handoffs WHERE correlation_id = v_correlation_id;
    IF FOUND THEN
      RETURN v_existing;
    END IF;
    RAISE;
  END;

  FOR v_line IN SELECT * FROM jsonb_array_elements(p_lines) ORDER BY (value ->> 'order_item_id')
  LOOP
    v_order_item_id := nullif(v_line ->> 'order_item_id', '')::uuid;
    IF v_order_item_id IS NULL THEN
      RAISE EXCEPTION 'order_item_id is required for every handoff line';
    END IF;

    v_declared_qty := nullif(v_line ->> 'declared_qty', '')::numeric;
    IF v_declared_qty IS NULL OR v_declared_qty <= 0 THEN
      RAISE EXCEPTION 'declared_qty must be a positive number for order_item %', v_order_item_id;
    END IF;
    v_batch_lot := nullif(btrim(v_line ->> 'batch_lot'), '');
    v_expiry_date := nullif(v_line ->> 'expiry_date', '')::date;

    SELECT * INTO v_consignment_line
    FROM public.b2b_dispatch_consignment_lines
    WHERE consignment_id = p_consignment_id AND order_item_id = v_order_item_id
    FOR UPDATE;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'order_item % has no consignment line on consignment %', v_order_item_id, p_consignment_id;
    END IF;

    v_remaining := v_consignment_line.selected_qty - v_consignment_line.accepted_ready_qty;
    IF v_declared_qty > v_remaining + 0.0001 THEN
      RAISE EXCEPTION 'declared_qty % for order_item % exceeds the remaining unaccepted selection (% of % already accepted-ready)',
        v_declared_qty, v_order_item_id, v_consignment_line.accepted_ready_qty, v_consignment_line.selected_qty;
    END IF;

    INSERT INTO public.b2b_dispatch_handoff_lines (
      handoff_id, order_item_id, product_id, product_code, batch_lot, expiry_date, uom, declared_qty
    ) VALUES (
      v_handoff.id, v_order_item_id, v_consignment_line.product_id, v_consignment_line.product_code,
      v_batch_lot, v_expiry_date, v_consignment_line.uom, v_declared_qty
    );
  END LOOP;

  INSERT INTO public.b2b_dispatch_events (
    order_id, order_item_id, consignment_id, event_type, new_status,
    actor_id, actor_role, source_record_type, source_record_id, correlation_id
  ) VALUES (
    v_consignment.order_id, NULL, p_consignment_id, 'dispatch_source_handoff_declared', 'declared_ready',
    v_actor_id, public.get_user_role(v_actor_id), 'b2b_dispatch_handoffs', v_handoff.id, v_correlation_id
  );

  RETURN v_handoff;
END;
$$;

COMMENT ON FUNCTION public.declare_b2b_dispatch_source_handoff(uuid, text, text, jsonb, text) IS
  'A Factory source department (PRODUCTION/RGS/3PGS/PACKING_ASSEMBLY/QUALITY) declares it is releasing quantity for exact consignment lines. p_lines is a jsonb array of {order_item_id, declared_qty, batch_lot?, expiry_date?}. Fail-closes on unauthorised department/actor, a terminal consignment, a missing consignment line, or a declared_qty exceeding the line''s remaining unaccepted selection. Idempotent by correlation_id. This is a declaration only: it never itself advances accepted_ready_qty.';

REVOKE ALL ON FUNCTION public.declare_b2b_dispatch_source_handoff(uuid, text, text, jsonb, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.declare_b2b_dispatch_source_handoff(uuid, text, text, jsonb, text) TO authenticated;

-- =============================================================================
-- C. Dispatch records physical receipt of a declared handoff.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.record_b2b_dispatch_handoff_receipt(
  p_handoff_id uuid,
  p_lines jsonb,
  p_correlation_id text
)
RETURNS public.b2b_dispatch_handoffs
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_actor_id uuid := auth.uid();
  v_correlation_id text := nullif(btrim(p_correlation_id), '');
  v_handoff public.b2b_dispatch_handoffs%ROWTYPE;
  v_line jsonb;
  v_order_item_id uuid;
  v_received_qty numeric;
  v_handoff_line public.b2b_dispatch_handoff_lines%ROWTYPE;
  v_all_received boolean;
BEGIN
  IF v_actor_id IS NULL OR NOT public.can_manage_b2b_dispatch(v_actor_id) THEN
    RAISE EXCEPTION 'Not authorised to record a dispatch handoff receipt' USING ERRCODE = '42501';
  END IF;
  IF v_correlation_id IS NULL THEN
    RAISE EXCEPTION 'A correlation id is required';
  END IF;
  IF p_lines IS NULL OR jsonb_typeof(p_lines) <> 'array' OR jsonb_array_length(p_lines) = 0 THEN
    RAISE EXCEPTION 'At least one receipt line is required';
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.b2b_dispatch_events
    WHERE source_record_type = 'b2b_dispatch_handoffs' AND source_record_id = p_handoff_id
      AND correlation_id = v_correlation_id AND event_type = 'dispatch_source_handoff_received'
  ) THEN
    SELECT * INTO v_handoff FROM public.b2b_dispatch_handoffs WHERE id = p_handoff_id;
    RETURN v_handoff;
  END IF;

  SELECT * INTO v_handoff FROM public.b2b_dispatch_handoffs WHERE id = p_handoff_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Handoff not found';
  END IF;
  IF v_handoff.status NOT IN ('declared_ready', 'pickup_acknowledged', 'receiving') THEN
    RAISE EXCEPTION 'Handoff % is % and cannot record a physical receipt', p_handoff_id, v_handoff.status;
  END IF;
  IF v_actor_id = v_handoff.issued_by THEN
    RAISE EXCEPTION 'The declaring source actor cannot also record Dispatch''s physical receipt' USING ERRCODE = '42501';
  END IF;

  FOR v_line IN SELECT * FROM jsonb_array_elements(p_lines) ORDER BY (value ->> 'order_item_id')
  LOOP
    v_order_item_id := nullif(v_line ->> 'order_item_id', '')::uuid;
    IF v_order_item_id IS NULL THEN
      RAISE EXCEPTION 'order_item_id is required for every receipt line';
    END IF;
    v_received_qty := nullif(v_line ->> 'physically_received_qty', '')::numeric;
    IF v_received_qty IS NULL OR v_received_qty < 0 THEN
      RAISE EXCEPTION 'physically_received_qty must be a non-negative number for order_item %', v_order_item_id;
    END IF;

    SELECT * INTO v_handoff_line
    FROM public.b2b_dispatch_handoff_lines
    WHERE handoff_id = p_handoff_id AND order_item_id = v_order_item_id
    FOR UPDATE;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'order_item % has no line on handoff %', v_order_item_id, p_handoff_id;
    END IF;
    IF v_received_qty < v_handoff_line.physically_received_qty - 0.0001 THEN
      RAISE EXCEPTION 'physically_received_qty cannot decrease (currently %, got %) for order_item %',
        v_handoff_line.physically_received_qty, v_received_qty, v_order_item_id;
    END IF;
    IF v_received_qty > v_handoff_line.declared_qty + 0.0001 THEN
      RAISE EXCEPTION 'physically_received_qty % for order_item % exceeds declared_qty %',
        v_received_qty, v_order_item_id, v_handoff_line.declared_qty;
    END IF;

    UPDATE public.b2b_dispatch_handoff_lines
    SET physically_received_qty = v_received_qty
    WHERE id = v_handoff_line.id;
  END LOOP;

  SELECT bool_and(physically_received_qty >= declared_qty - 0.0001) INTO v_all_received
  FROM public.b2b_dispatch_handoff_lines WHERE handoff_id = p_handoff_id;

  UPDATE public.b2b_dispatch_handoffs
  SET status = 'receiving', received_by = v_actor_id, received_at = now()
  WHERE id = p_handoff_id
  RETURNING * INTO v_handoff;

  INSERT INTO public.b2b_dispatch_events (
    order_id, consignment_id, event_type, new_status,
    actor_id, actor_role, source_record_type, source_record_id, correlation_id
  ) VALUES (
    v_handoff.order_id, v_handoff.consignment_id, 'dispatch_source_handoff_received', 'receiving',
    v_actor_id, public.get_user_role(v_actor_id), 'b2b_dispatch_handoffs', p_handoff_id, v_correlation_id
  );

  RETURN v_handoff;
END;
$$;

COMMENT ON FUNCTION public.record_b2b_dispatch_handoff_receipt(uuid, jsonb, text) IS
  'Dispatch records physical receipt against a declared source handoff. p_lines is {order_item_id, physically_received_qty} with cumulative absolute values, bounded by declared_qty and non-decreasing. Rejects a terminal/unstarted handoff and rejects the declaring actor recording their own receipt. Idempotent by correlation_id.';

REVOKE ALL ON FUNCTION public.record_b2b_dispatch_handoff_receipt(uuid, jsonb, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.record_b2b_dispatch_handoff_receipt(uuid, jsonb, text) TO authenticated;

-- =============================================================================
-- D. Dispatch accepts/holds/rejects reconciled quantity. Only the accepted
--    portion advances b2b_dispatch_consignment_lines.accepted_ready_qty.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.accept_b2b_dispatch_handoff(
  p_handoff_id uuid,
  p_lines jsonb,
  p_correlation_id text
)
RETURNS public.b2b_dispatch_handoffs
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_actor_id uuid := auth.uid();
  v_correlation_id text := nullif(btrim(p_correlation_id), '');
  v_handoff public.b2b_dispatch_handoffs%ROWTYPE;
  v_line jsonb;
  v_order_item_id uuid;
  v_accepted_qty numeric;
  v_held_qty numeric;
  v_rejected_qty numeric;
  v_handoff_line public.b2b_dispatch_handoff_lines%ROWTYPE;
  v_consignment_line public.b2b_dispatch_consignment_lines%ROWTYPE;
  v_delta numeric;
  v_total_received numeric := 0;
  v_total_accepted numeric := 0;
  v_total_held numeric := 0;
  v_total_rejected numeric := 0;
  v_all_reconciled boolean;
  v_final_status text;
BEGIN
  IF v_actor_id IS NULL OR NOT public.can_manage_b2b_dispatch(v_actor_id) THEN
    RAISE EXCEPTION 'Not authorised to accept a dispatch handoff' USING ERRCODE = '42501';
  END IF;
  IF v_correlation_id IS NULL THEN
    RAISE EXCEPTION 'A correlation id is required';
  END IF;
  IF p_lines IS NULL OR jsonb_typeof(p_lines) <> 'array' OR jsonb_array_length(p_lines) = 0 THEN
    RAISE EXCEPTION 'At least one acceptance line is required';
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.b2b_dispatch_events
    WHERE source_record_type = 'b2b_dispatch_handoffs' AND source_record_id = p_handoff_id
      AND correlation_id = v_correlation_id AND event_type = 'dispatch_source_handoff_accepted'
  ) THEN
    SELECT * INTO v_handoff FROM public.b2b_dispatch_handoffs WHERE id = p_handoff_id;
    RETURN v_handoff;
  END IF;

  SELECT * INTO v_handoff FROM public.b2b_dispatch_handoffs WHERE id = p_handoff_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Handoff not found';
  END IF;
  IF v_handoff.status NOT IN ('receiving', 'partially_accepted') THEN
    RAISE EXCEPTION 'Handoff % is % and has no recorded physical receipt to reconcile', p_handoff_id, v_handoff.status;
  END IF;
  IF v_actor_id = v_handoff.issued_by THEN
    RAISE EXCEPTION 'The declaring source actor cannot also accept their own handoff' USING ERRCODE = '42501';
  END IF;

  FOR v_line IN SELECT * FROM jsonb_array_elements(p_lines) ORDER BY (value ->> 'order_item_id')
  LOOP
    v_order_item_id := nullif(v_line ->> 'order_item_id', '')::uuid;
    IF v_order_item_id IS NULL THEN
      RAISE EXCEPTION 'order_item_id is required for every acceptance line';
    END IF;
    v_accepted_qty := coalesce(nullif(v_line ->> 'accepted_qty', '')::numeric, 0);
    v_held_qty := coalesce(nullif(v_line ->> 'held_qty', '')::numeric, 0);
    v_rejected_qty := coalesce(nullif(v_line ->> 'rejected_qty', '')::numeric, 0);
    IF v_accepted_qty < 0 OR v_held_qty < 0 OR v_rejected_qty < 0 THEN
      RAISE EXCEPTION 'accepted_qty/held_qty/rejected_qty must be non-negative for order_item %', v_order_item_id;
    END IF;

    SELECT * INTO v_handoff_line
    FROM public.b2b_dispatch_handoff_lines
    WHERE handoff_id = p_handoff_id AND order_item_id = v_order_item_id
    FOR UPDATE;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'order_item % has no line on handoff %', v_order_item_id, p_handoff_id;
    END IF;

    IF v_accepted_qty < v_handoff_line.accepted_qty - 0.0001 THEN
      RAISE EXCEPTION 'accepted_qty cannot decrease (currently %, got %) for order_item %',
        v_handoff_line.accepted_qty, v_accepted_qty, v_order_item_id;
    END IF;
    IF v_accepted_qty + v_held_qty + v_rejected_qty > v_handoff_line.physically_received_qty + 0.0001 THEN
      RAISE EXCEPTION 'accepted_qty + held_qty + rejected_qty (%) exceeds physically_received_qty (%) for order_item %',
        v_accepted_qty + v_held_qty + v_rejected_qty, v_handoff_line.physically_received_qty, v_order_item_id;
    END IF;

    v_delta := v_accepted_qty - v_handoff_line.accepted_qty;

    SELECT * INTO v_consignment_line
    FROM public.b2b_dispatch_consignment_lines
    WHERE consignment_id = v_handoff.consignment_id AND order_item_id = v_order_item_id
    FOR UPDATE;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'order_item % has no consignment line on consignment %', v_order_item_id, v_handoff.consignment_id;
    END IF;
    IF v_consignment_line.accepted_ready_qty + v_delta > v_consignment_line.selected_qty + 0.0001 THEN
      RAISE EXCEPTION 'accepting % more for order_item % would push accepted_ready_qty above selected_qty %',
        v_delta, v_order_item_id, v_consignment_line.selected_qty;
    END IF;

    UPDATE public.b2b_dispatch_handoff_lines
    SET accepted_qty = v_accepted_qty, held_qty = v_held_qty, rejected_qty = v_rejected_qty
    WHERE id = v_handoff_line.id;

    IF v_delta <> 0 THEN
      UPDATE public.b2b_dispatch_consignment_lines
      SET accepted_ready_qty = accepted_ready_qty + v_delta
      WHERE id = v_consignment_line.id;
    END IF;

    INSERT INTO public.b2b_dispatch_events (
      order_id, order_item_id, consignment_id, event_type, quantity, uom,
      actor_id, actor_role, source_record_type, source_record_id, correlation_id
    ) VALUES (
      v_handoff.order_id, v_order_item_id, v_handoff.consignment_id, 'dispatch_source_handoff_accepted', v_delta,
      v_consignment_line.uom, v_actor_id, public.get_user_role(v_actor_id), 'b2b_dispatch_consignment_lines',
      v_consignment_line.id, v_correlation_id
    );
  END LOOP;

  SELECT
    bool_and(accepted_qty + held_qty + rejected_qty >= physically_received_qty - 0.0001),
    coalesce(sum(physically_received_qty), 0),
    coalesce(sum(accepted_qty), 0),
    coalesce(sum(held_qty), 0),
    coalesce(sum(rejected_qty), 0)
  INTO v_all_reconciled, v_total_received, v_total_accepted, v_total_held, v_total_rejected
  FROM public.b2b_dispatch_handoff_lines WHERE handoff_id = p_handoff_id;

  -- A handoff is only 'accepted' once every physically received unit is
  -- cleanly accepted with nothing held or rejected. Any residual hold or
  -- rejection -- even once every line's receipt has been fully disposed of
  -- (accepted + held + rejected == received) -- keeps the handoff
  -- 'partially_accepted' so it is visibly not a clean full acceptance.
  IF NOT v_all_reconciled THEN
    v_final_status := 'partially_accepted';
  ELSIF v_total_received > 0 AND v_total_accepted <= 0.0001 THEN
    v_final_status := 'rejected';
  ELSIF v_total_held > 0.0001 OR v_total_rejected > 0.0001 THEN
    v_final_status := 'partially_accepted';
  ELSE
    v_final_status := 'accepted';
  END IF;

  UPDATE public.b2b_dispatch_handoffs
  SET status = v_final_status
  WHERE id = p_handoff_id
  RETURNING * INTO v_handoff;

  RETURN v_handoff;
END;
$$;

COMMENT ON FUNCTION public.accept_b2b_dispatch_handoff(uuid, jsonb, text) IS
  'Dispatch reconciles a physically received handoff into accepted/held/rejected quantities. p_lines is {order_item_id, accepted_qty?, held_qty?, rejected_qty?} with cumulative absolute values; accepted_qty can only increase and the increase (delta) is the only thing that ever advances b2b_dispatch_consignment_lines.accepted_ready_qty, bounded by selected_qty (also enforced by the pre-existing progress CHECK). Rejects a handoff with no recorded physical receipt, a declaring actor accepting their own handoff, reconciliation above physically_received_qty, and acceptance above the consignment line''s selected_qty. Idempotent by correlation_id.';

REVOKE ALL ON FUNCTION public.accept_b2b_dispatch_handoff(uuid, jsonb, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.accept_b2b_dispatch_handoff(uuid, jsonb, text) TO authenticated;

-- =============================================================================
-- E. Close the direct-write path: accepted_ready_qty (and the rest of the
--    custody chain) becomes reachable only through the RPCs above. SELECT
--    remains available to authenticated internal staff via the existing RLS
--    policies (20260804103000); this only removes INSERT/UPDATE/DELETE
--    privilege, mirroring the RGS/production lockdown pattern.
-- =============================================================================

REVOKE INSERT, UPDATE, DELETE ON public.b2b_dispatch_handoffs FROM authenticated, anon;
REVOKE INSERT, UPDATE, DELETE ON public.b2b_dispatch_handoff_lines FROM authenticated, anon;
REVOKE INSERT, UPDATE, DELETE ON public.b2b_dispatch_consignment_lines FROM authenticated, anon;

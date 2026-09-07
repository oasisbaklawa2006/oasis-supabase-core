-- MACRO INVENTORY + FACTORY: reservation/lot RPC wiring, production hold_qty,
-- inventory command facts. Companion to 20260907144000.

SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '120s';

-- allocate_lots_to_reservation: store isolation + exact correlation idempotency
CREATE OR REPLACE FUNCTION public.allocate_lots_to_reservation(
  p_reservation_id uuid, p_allocate_qty numeric, p_selection_mode text, p_correlation_id text
)
RETURNS SETOF public.inventory_reservation_allocations
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_actor uuid := auth.uid();
  v_reservation public.inventory_reservations%ROWTYPE;
  v_candidate public.inventory_lot_positions%ROWTYPE;
  v_remaining numeric; v_take numeric; v_already_allocated numeric;
  v_alloc public.inventory_reservation_allocations%ROWTYPE;
BEGIN
  IF v_actor IS NULL OR NOT (public.is_inventory_manage_role((SELECT role FROM public.users WHERE id = v_actor))
    OR public.is_inventory_receive_role((SELECT role FROM public.users WHERE id = v_actor))) THEN
    RAISE EXCEPTION 'Not authorised to allocate lots' USING ERRCODE = '42501';
  END IF;
  IF p_allocate_qty IS NULL OR p_allocate_qty <= 0 THEN RAISE EXCEPTION 'Allocate quantity must be positive'; END IF;
  IF p_selection_mode NOT IN ('fefo', 'fifo') THEN RAISE EXCEPTION 'Selection mode must be fefo or fifo'; END IF;
  IF nullif(btrim(p_correlation_id), '') IS NULL THEN RAISE EXCEPTION 'A correlation id is required'; END IF;
  IF EXISTS (SELECT 1 FROM public.inventory_movements WHERE correlation_id = p_correlation_id AND movement_type = 'lot_allocated') THEN
    RETURN QUERY SELECT a.* FROM public.inventory_reservation_allocations a
      WHERE a.reservation_id = p_reservation_id AND a.inventory_entity_type = 'lot_position' AND a.allocation_status = 'active';
    RETURN;
  END IF;
  SELECT * INTO v_reservation FROM public.inventory_reservations WHERE id = p_reservation_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Reservation not found'; END IF;
  PERFORM public.assert_inventory_store_mutation_access(v_actor, v_reservation.location_code);
  IF v_reservation.reservation_status NOT IN ('reserved', 'partially_reserved') THEN RAISE EXCEPTION 'Reservation is not in an allocatable state'; END IF;
  SELECT coalesce(sum(allocated_qty), 0) INTO v_already_allocated FROM public.inventory_reservation_allocations
    WHERE reservation_id = p_reservation_id AND allocation_status = 'active';
  IF p_allocate_qty > v_reservation.reserved_qty - v_already_allocated THEN RAISE EXCEPTION 'Allocate quantity exceeds unallocated reserved quantity'; END IF;
  PERFORM pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(v_reservation.product_id::text || ':' || v_reservation.sku || ':' || v_reservation.location_code, 0));
  v_remaining := p_allocate_qty;
  FOR v_candidate IN SELECT * FROM public.select_inventory_lot_candidates(v_reservation.product_id, v_reservation.sku, v_reservation.location_code, p_selection_mode, NULL) LOOP
    EXIT WHEN v_remaining <= 0;
    SELECT * INTO v_candidate FROM public.inventory_lot_positions WHERE id = v_candidate.id FOR UPDATE;
    IF v_candidate.available_qty <= 0 THEN CONTINUE; END IF;
    v_take := least(v_remaining, v_candidate.available_qty);
    UPDATE public.inventory_lot_positions SET available_qty = available_qty - v_take, reserved_qty = reserved_qty + v_take, version = version + 1, updated_at = now() WHERE id = v_candidate.id;
    INSERT INTO public.inventory_reservation_allocations (reservation_id, inventory_entity_type, inventory_entity_id, allocated_qty)
      VALUES (p_reservation_id, 'lot_position', v_candidate.id, v_take) RETURNING * INTO v_alloc;
    INSERT INTO public.inventory_movements (movement_type, reservation_id, product_id, sku, quantity, source_location, actor_id, correlation_id, batch_lot, expiry_date, metadata)
      VALUES ('lot_allocated', p_reservation_id, v_reservation.product_id, v_reservation.sku, v_take, v_reservation.location_code, v_actor, p_correlation_id, v_candidate.batch_lot, v_candidate.expiry_date, jsonb_build_object('lot_position_id', v_candidate.id, 'selection_mode', p_selection_mode));
    v_remaining := v_remaining - v_take; RETURN NEXT v_alloc;
  END LOOP;
  IF v_remaining > 0 THEN RAISE EXCEPTION 'Insufficient eligible lot stock: short by %', v_remaining; END IF;
  RETURN;
END;
$$;

CREATE OR REPLACE FUNCTION public.fulfill_lot_allocations_on_pick(p_reservation_id uuid, p_pick_qty numeric, p_correlation_id text)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_alloc record; v_remaining numeric := p_pick_qty; v_take numeric;
BEGIN
  IF EXISTS (SELECT 1 FROM public.inventory_movements WHERE correlation_id = p_correlation_id AND movement_type = 'lot_picked') THEN RETURN; END IF;
  FOR v_alloc IN SELECT a.*, lp.batch_lot, lp.expiry_date, lp.product_id, lp.sku, lp.location_code
    FROM public.inventory_reservation_allocations a JOIN public.inventory_lot_positions lp ON lp.id = a.inventory_entity_id
    WHERE a.reservation_id = p_reservation_id AND a.inventory_entity_type = 'lot_position' AND a.allocation_status = 'active' ORDER BY a.allocated_at LOOP
    EXIT WHEN v_remaining <= 0; v_take := least(v_remaining, v_alloc.allocated_qty);
    UPDATE public.inventory_lot_positions SET reserved_qty = reserved_qty - v_take, picked_qty = picked_qty + v_take,
      position_status = CASE WHEN available_qty = 0 AND reserved_qty - v_take <= 0 THEN 'depleted' ELSE position_status END,
      version = version + 1, updated_at = now() WHERE id = v_alloc.inventory_entity_id;
    IF v_take >= v_alloc.allocated_qty THEN UPDATE public.inventory_reservation_allocations SET allocation_status = 'fulfilled' WHERE id = v_alloc.id;
    ELSE UPDATE public.inventory_reservation_allocations SET allocated_qty = allocated_qty - v_take WHERE id = v_alloc.id; END IF;
    INSERT INTO public.inventory_movements (movement_type, reservation_id, product_id, sku, quantity, source_location, correlation_id, batch_lot, expiry_date, metadata)
      VALUES ('lot_picked', p_reservation_id, v_alloc.product_id, v_alloc.sku, v_take, v_alloc.location_code, p_correlation_id, v_alloc.batch_lot, v_alloc.expiry_date, jsonb_build_object('lot_position_id', v_alloc.inventory_entity_id));
    v_remaining := v_remaining - v_take;
  END LOOP;
  IF v_remaining > 0 AND EXISTS (SELECT 1 FROM public.inventory_reservation_allocations WHERE reservation_id = p_reservation_id AND inventory_entity_type = 'lot_position' AND allocation_status = 'active') THEN
    RAISE EXCEPTION 'Pick quantity exceeds active lot allocation total';
  END IF;
END;
$$;

CREATE OR REPLACE FUNCTION public.pick_rgs_reservation(p_reservation_id uuid, p_pick_qty numeric, p_correlation_id text)
RETURNS public.inventory_reservations LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_actor_id uuid := auth.uid(); v_reservation public.inventory_reservations%ROWTYPE;
BEGIN
  IF v_actor_id IS NULL OR NOT public.is_internal_staff(v_actor_id) THEN RAISE EXCEPTION 'Not authorised' USING ERRCODE = '42501'; END IF;
  IF nullif(btrim(p_correlation_id), '') IS NULL THEN RAISE EXCEPTION 'A correlation id is required'; END IF;
  IF EXISTS (SELECT 1 FROM public.inventory_movements WHERE correlation_id = p_correlation_id AND movement_type = 'stock_picked') THEN
    SELECT * INTO v_reservation FROM public.inventory_reservations WHERE id = p_reservation_id; RETURN v_reservation;
  END IF;
  SELECT * INTO v_reservation FROM public.inventory_reservations WHERE id = p_reservation_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Reservation not found'; END IF;
  PERFORM public.assert_inventory_store_mutation_access(v_actor_id, v_reservation.location_code);
  IF p_pick_qty IS NULL OR p_pick_qty <= 0 OR p_pick_qty > v_reservation.reserved_qty THEN RAISE EXCEPTION 'Pick quantity must be positive and cannot exceed reserved quantity'; END IF;
  PERFORM public.assert_lot_allocation_covers_qty(p_reservation_id, p_pick_qty, 'pick');
  PERFORM pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(v_reservation.product_id::text || ':' || v_reservation.sku || ':' || v_reservation.location_code, 0));
  IF EXISTS (SELECT 1 FROM public.inventory_reservation_allocations WHERE reservation_id = p_reservation_id AND inventory_entity_type = 'lot_position' AND allocation_status = 'active') THEN
    PERFORM public.fulfill_lot_allocations_on_pick(p_reservation_id, p_pick_qty, p_correlation_id);
  END IF;
  UPDATE public.inventory_stock_balances SET reserved_qty = reserved_qty - p_pick_qty, picked_qty = picked_qty + p_pick_qty, version = version + 1, updated_at = now()
    WHERE product_id = v_reservation.product_id AND sku = v_reservation.sku AND location_code = v_reservation.location_code;
  IF NOT FOUND THEN RAISE EXCEPTION 'Stock balance not found'; END IF;
  INSERT INTO public.inventory_movements (movement_type, reservation_id, product_id, sku, quantity, source_location, actor_id, correlation_id)
    VALUES ('stock_picked', p_reservation_id, v_reservation.product_id, v_reservation.sku, p_pick_qty, v_reservation.location_code, v_actor_id, p_correlation_id);
  RETURN v_reservation;
END;
$$;

CREATE OR REPLACE FUNCTION public.release_rgs_reservation(p_reservation_id uuid, p_release_qty numeric, p_reason_code text, p_correlation_id text)
RETURNS public.inventory_reservations LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_actor_id uuid := auth.uid(); v_reservation public.inventory_reservations%ROWTYPE;
BEGIN
  IF v_actor_id IS NULL OR NOT public.is_internal_staff(v_actor_id) THEN RAISE EXCEPTION 'Not authorised' USING ERRCODE = '42501'; END IF;
  IF nullif(btrim(p_correlation_id), '') IS NULL THEN RAISE EXCEPTION 'A correlation id is required'; END IF;
  IF EXISTS (
    SELECT 1 FROM public.inventory_movements
    WHERE correlation_id = p_correlation_id AND movement_type = 'reservation_released'
  ) THEN
    SELECT * INTO v_reservation FROM public.inventory_reservations WHERE id = p_reservation_id; RETURN v_reservation;
  END IF;
  SELECT * INTO v_reservation FROM public.inventory_reservations WHERE id = p_reservation_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Reservation not found'; END IF;
  PERFORM public.assert_inventory_store_mutation_access(v_actor_id, v_reservation.location_code);
  IF v_reservation.reservation_status NOT IN ('reserved', 'partially_reserved', 'pending') THEN RAISE EXCEPTION 'Reservation is not in a releasable state'; END IF;
  IF p_release_qty IS NULL OR p_release_qty <= 0 OR p_release_qty > v_reservation.reserved_qty THEN RAISE EXCEPTION 'Release quantity must be positive and cannot exceed reserved quantity'; END IF;
  PERFORM pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(v_reservation.product_id::text || ':' || v_reservation.sku || ':' || v_reservation.location_code, 0));
  IF EXISTS (SELECT 1 FROM public.inventory_reservation_allocations WHERE reservation_id = p_reservation_id AND inventory_entity_type = 'lot_position' AND allocation_status = 'active') THEN
    PERFORM public.release_lot_allocations_from_reservation(p_reservation_id, p_release_qty, p_correlation_id);
  END IF;
  UPDATE public.inventory_stock_balances SET available_qty = available_qty + p_release_qty, reserved_qty = reserved_qty - p_release_qty, version = version + 1, updated_at = now()
    WHERE product_id = v_reservation.product_id AND sku = v_reservation.sku AND location_code = v_reservation.location_code;
  IF NOT FOUND THEN RAISE EXCEPTION 'Stock balance not found for reservation %', p_reservation_id; END IF;
  UPDATE public.inventory_reservations SET reserved_qty = reserved_qty - p_release_qty, released_qty = released_qty + p_release_qty,
    reservation_status = CASE WHEN released_qty + p_release_qty + fulfilled_qty >= requested_qty THEN 'released' WHEN reserved_qty - p_release_qty > 0 THEN 'partially_reserved' ELSE 'pending' END, updated_at = now()
    WHERE id = p_reservation_id RETURNING * INTO v_reservation;
  INSERT INTO public.inventory_movements (movement_type, reservation_id, product_id, sku, quantity, destination_location, actor_id, reason_code, correlation_id)
    VALUES ('reservation_released', p_reservation_id, v_reservation.product_id, v_reservation.sku, p_release_qty, v_reservation.location_code, v_actor_id, p_reason_code, p_correlation_id);
  RETURN v_reservation;
END;
$$;

CREATE OR REPLACE FUNCTION public.issue_rgs_stock(p_reservation_id uuid, p_issue_qty numeric, p_destination_type text, p_destination_reference text, p_correlation_id text)
RETURNS public.rgs_issue_events LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_actor_id uuid := auth.uid(); v_reservation public.inventory_reservations%ROWTYPE; v_issue public.rgs_issue_events%ROWTYPE; v_picked numeric;
BEGIN
  IF v_actor_id IS NULL OR NOT public.is_internal_staff(v_actor_id) THEN RAISE EXCEPTION 'Not authorised' USING ERRCODE = '42501'; END IF;
  IF p_destination_type NOT IN ('b2b', 'pna', 'outlet', 'internal') THEN RAISE EXCEPTION 'Unknown destination type %', p_destination_type; END IF;
  SELECT * INTO v_issue FROM public.rgs_issue_events WHERE correlation_id = p_correlation_id; IF FOUND THEN RETURN v_issue; END IF;
  SELECT * INTO v_reservation FROM public.inventory_reservations WHERE id = p_reservation_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Reservation not found'; END IF;
  PERFORM public.assert_inventory_store_mutation_access(v_actor_id, v_reservation.location_code);
  IF p_issue_qty IS NULL OR p_issue_qty <= 0 OR p_issue_qty > v_reservation.reserved_qty THEN RAISE EXCEPTION 'Issue quantity must be positive and cannot exceed reserved quantity'; END IF;
  PERFORM public.assert_lot_allocation_covers_qty(p_reservation_id, p_issue_qty, 'issue');
  PERFORM pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(v_reservation.product_id::text || ':' || v_reservation.sku || ':' || v_reservation.location_code, 0));
  SELECT picked_qty INTO v_picked FROM public.inventory_stock_balances WHERE product_id = v_reservation.product_id AND sku = v_reservation.sku AND location_code = v_reservation.location_code FOR UPDATE;
  IF EXISTS (SELECT 1 FROM public.inventory_reservation_allocations WHERE reservation_id = p_reservation_id AND inventory_entity_type = 'lot_position' AND allocation_status = 'fulfilled') THEN
    PERFORM public.consume_lot_allocations_on_issue(p_reservation_id, p_issue_qty, p_correlation_id);
  END IF;
  UPDATE public.inventory_stock_balances SET picked_qty = greatest(picked_qty - least(picked_qty, p_issue_qty), 0),
    reserved_qty = reserved_qty - greatest(p_issue_qty - least(picked_qty, p_issue_qty), 0), version = version + 1, updated_at = now()
    WHERE product_id = v_reservation.product_id AND sku = v_reservation.sku AND location_code = v_reservation.location_code;
  IF NOT FOUND THEN RAISE EXCEPTION 'Stock balance not found'; END IF;
  UPDATE public.inventory_reservations SET reserved_qty = reserved_qty - p_issue_qty, fulfilled_qty = fulfilled_qty + p_issue_qty,
    reservation_status = CASE WHEN fulfilled_qty + p_issue_qty + released_qty >= requested_qty THEN 'fulfilled' ELSE reservation_status END, updated_at = now() WHERE id = p_reservation_id;
  INSERT INTO public.inventory_movements (movement_type, reservation_id, product_id, sku, quantity, source_location, actor_id, correlation_id, metadata)
    VALUES ('stock_issued', p_reservation_id, v_reservation.product_id, v_reservation.sku, p_issue_qty, v_reservation.location_code, v_actor_id, p_correlation_id, jsonb_build_object('destination_type', p_destination_type, 'destination_reference', p_destination_reference));
  INSERT INTO public.rgs_issue_events (reservation_id, product_id, sku, issued_qty, source_location, destination_type, destination_reference, status, issued_by, correlation_id)
    VALUES (p_reservation_id, v_reservation.product_id, v_reservation.sku, p_issue_qty, v_reservation.location_code, p_destination_type, p_destination_reference, 'issued', v_actor_id, p_correlation_id)
    RETURNING * INTO v_issue;
  RETURN v_issue;
END;
$$;

CREATE OR REPLACE FUNCTION public.reserve_rgs_stock(
  p_reservation_number text, p_order_id uuid, p_product_id uuid, p_sku text, p_requested_qty numeric,
  p_source_department text, p_correlation_id text, p_priority text DEFAULT 'normal',
  p_location_code text DEFAULT 'FINISHED_GOODS', p_queue_item_id uuid DEFAULT NULL, p_customer_id uuid DEFAULT NULL,
  p_demand_source_type text DEFAULT 'b2b', p_demand_reference text DEFAULT NULL
)
RETURNS public.inventory_reservations LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_actor_id uuid := auth.uid(); v_existing public.inventory_reservations%ROWTYPE; v_balance record; v_reserve_qty numeric; v_status text;
BEGIN
  IF v_actor_id IS NULL OR NOT public.is_inventory_manage_role((SELECT role FROM public.users WHERE id = v_actor_id))
     AND NOT public.is_inventory_receive_role((SELECT role FROM public.users WHERE id = v_actor_id)) THEN
    RAISE EXCEPTION 'Not authorised to reserve RGS stock' USING ERRCODE = '42501';
  END IF;
  PERFORM public.assert_inventory_store_mutation_access(v_actor_id, p_location_code);
  IF p_requested_qty IS NULL OR p_requested_qty <= 0 THEN RAISE EXCEPTION 'Requested quantity must be positive'; END IF;
  IF nullif(btrim(p_correlation_id), '') IS NULL THEN RAISE EXCEPTION 'A correlation id is required'; END IF;
  IF p_demand_source_type NOT IN ('b2b', 'pna', 'outlet', 'internal') THEN RAISE EXCEPTION 'Unknown demand source type %', p_demand_source_type; END IF;
  IF p_demand_source_type = 'b2b' AND p_order_id IS NULL THEN RAISE EXCEPTION 'order_id is required for a b2b demand source'; END IF;
  IF p_demand_source_type <> 'b2b' AND p_order_id IS NOT NULL THEN RAISE EXCEPTION 'order_id must be null for a non-b2b demand source'; END IF;
  SELECT * INTO v_existing FROM public.inventory_reservations WHERE correlation_id = p_correlation_id; IF FOUND THEN RETURN v_existing; END IF;
  PERFORM pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(p_product_id::text || ':' || p_sku || ':' || p_location_code, 0));
  SELECT * INTO v_balance FROM public.inventory_stock_balances WHERE product_id = p_product_id AND sku = p_sku AND location_code = p_location_code FOR UPDATE;
  v_reserve_qty := least(p_requested_qty, coalesce(v_balance.available_qty, 0));
  IF v_reserve_qty > 0 THEN
    IF FOUND THEN UPDATE public.inventory_stock_balances SET available_qty = available_qty - v_reserve_qty, reserved_qty = reserved_qty + v_reserve_qty, version = version + 1, updated_at = now()
      WHERE product_id = p_product_id AND sku = p_sku AND location_code = p_location_code;
    ELSE RAISE EXCEPTION 'Stock balance disappeared during reservation' USING ERRCODE = '40001'; END IF;
  END IF;
  v_status := CASE WHEN v_reserve_qty >= p_requested_qty THEN 'reserved' WHEN v_reserve_qty > 0 THEN 'partially_reserved' ELSE 'pending' END;
  INSERT INTO public.inventory_reservations (reservation_number, order_id, queue_item_id, customer_id, product_id, sku, requested_qty, reserved_qty, reservation_status, reservation_priority, source_department, location_code, reserved_by, correlation_id, demand_source_type, demand_reference)
    VALUES (p_reservation_number, p_order_id, p_queue_item_id, p_customer_id, p_product_id, p_sku, p_requested_qty, v_reserve_qty, v_status, coalesce(p_priority, 'normal'), p_source_department, p_location_code, v_actor_id, p_correlation_id, p_demand_source_type, p_demand_reference)
    RETURNING * INTO v_existing;
  IF v_reserve_qty > 0 THEN INSERT INTO public.inventory_movements (movement_type, reservation_id, product_id, sku, quantity, source_location, actor_id, correlation_id, metadata)
    VALUES ('reservation_created', v_existing.id, p_product_id, p_sku, v_reserve_qty, p_location_code, v_actor_id, p_correlation_id, jsonb_build_object('requested_qty', p_requested_qty, 'demand_source_type', p_demand_source_type)); END IF;
  RETURN v_existing;
END;
$$;

-- Production receipt: post hold_qty to quarantine bucket
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
      UPDATE public.inventory_stock_balances SET quarantine_qty = quarantine_qty + p_hold_qty, version = version + 1, updated_at = now()
        WHERE product_id = v_transfer.product_id AND sku = v_transfer.sku AND location_code = v_transfer.destination_store_code;
      INSERT INTO public.inventory_movements (movement_type, product_id, sku, quantity, destination_location, actor_id, reason_code, correlation_id, metadata)
        VALUES ('stock_quarantined', v_transfer.product_id, v_transfer.sku, p_hold_qty, v_transfer.destination_store_code, v_actor_id, 'production_qc_hold', p_correlation_id || ':hold', jsonb_build_object('transfer_id', v_transfer.id, 'hold_qty', p_hold_qty));
    END IF;
  END IF;
  UPDATE public.production_rgs_transfers SET accepted_qty = p_accepted_qty, rejected_qty = p_rejected_qty, hold_qty = p_hold_qty,
    status = CASE WHEN p_accepted_qty = 0 THEN 'rejected' WHEN p_accepted_qty < v_transfer.received_qty THEN 'partially_accepted' ELSE 'accepted' END,
    accepted_by = v_actor_id, accepted_at = now(), rgs_notified = true WHERE id = p_transfer_id RETURNING * INTO v_transfer;
  RETURN v_transfer;
END;
$$;

CREATE OR REPLACE VIEW public.inventory_lot_aggregate_reconciliation WITH (security_invoker=true) AS
WITH lot_agg AS (
  SELECT location_code, product_id, sku,
    sum(available_qty) FILTER (WHERE position_status = 'available') AS lot_available_qty,
    sum(reserved_qty) AS lot_reserved_qty, sum(picked_qty) AS lot_picked_qty,
    sum(CASE WHEN position_status = 'available' THEN available_qty ELSE 0 END + reserved_qty + picked_qty) AS lot_total_qty
  FROM public.inventory_lot_positions GROUP BY location_code, product_id, sku
)
SELECT coalesce(l.location_code, b.location_code) AS location_code, coalesce(l.product_id, b.product_id) AS product_id, coalesce(l.sku, b.sku) AS sku,
  coalesce(l.lot_available_qty, 0) AS lot_available_qty, coalesce(l.lot_reserved_qty, 0) AS lot_reserved_qty, coalesce(l.lot_picked_qty, 0) AS lot_picked_qty, coalesce(l.lot_total_qty, 0) AS lot_total_qty,
  b.available_qty AS balance_available_qty, b.reserved_qty AS balance_reserved_qty, b.picked_qty AS balance_picked_qty,
  (b.available_qty + b.reserved_qty + b.picked_qty) AS balance_total_qty,
  CASE WHEN b.product_id IS NULL THEN 'balance_missing' WHEN coalesce(l.lot_total_qty, 0) = 0 THEN 'legacy_aggregate_only'
    WHEN coalesce(l.lot_available_qty, 0) > b.available_qty + 0.0001 OR coalesce(l.lot_reserved_qty, 0) > b.reserved_qty + 0.0001 OR coalesce(l.lot_picked_qty, 0) > b.picked_qty + 0.0001 THEN 'lot_exceeds_balance'
    ELSE 'reconciled' END AS reconciliation_status
FROM public.inventory_stock_balances b FULL OUTER JOIN lot_agg l ON l.product_id = b.product_id AND l.sku = b.sku AND l.location_code = b.location_code;

CREATE OR REPLACE VIEW public.inventory_command_facts WITH (security_invoker=true) AS
SELECT r.id AS reservation_id, r.reservation_number, r.location_code, r.product_id, r.sku,
  r.requested_qty, r.reserved_qty, r.fulfilled_qty, r.released_qty, r.reservation_status,
  greatest(r.requested_qty - r.reserved_qty - r.fulfilled_qty - r.released_qty, 0) AS shortage_qty,
  coalesce(alloc.active_lot_allocated_qty, 0) AS active_lot_allocated_qty,
  coalesce(alloc.fulfilled_lot_allocated_qty, 0) AS fulfilled_lot_allocated_qty,
  rec.reconciliation_status, rec.lot_available_qty, rec.balance_available_qty,
  pj.id AS production_job_id, pj.status AS production_job_status, pj.assigned_qty AS production_assigned_qty
FROM public.inventory_reservations r
LEFT JOIN LATERAL (
  SELECT sum(allocated_qty) FILTER (WHERE allocation_status = 'active') AS active_lot_allocated_qty,
         sum(allocated_qty) FILTER (WHERE allocation_status = 'fulfilled') AS fulfilled_lot_allocated_qty
  FROM public.inventory_reservation_allocations a WHERE a.reservation_id = r.id AND a.inventory_entity_type = 'lot_position'
) alloc ON true
LEFT JOIN public.inventory_lot_aggregate_reconciliation rec ON rec.product_id = r.product_id AND rec.sku = r.sku AND rec.location_code = r.location_code
LEFT JOIN public.production_jobs pj ON pj.reservation_id = r.id AND pj.status NOT IN ('rejected', 'completed', 'transferred');

COMMENT ON VIEW public.inventory_command_facts IS 'Central bind surface: reservations, shortage derivation, lot allocations, reconciliation flags, and linked production shortage jobs per store/SKU.';

REVOKE ALL ON FUNCTION public.assert_inventory_store_mutation_access(uuid, text), public.inventory_lot_positions_exist(uuid, text, text), public.assert_lot_allocation_covers_qty(uuid, numeric, text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.release_lot_allocations_from_reservation(uuid, numeric, text), public.reverse_grn_inventory_lot_positions(uuid, text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.consume_lot_allocations_on_issue(uuid, numeric, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.record_inventory_lot_exception(uuid, text, numeric, text, text) TO authenticated;
REVOKE ALL ON FUNCTION public.record_inventory_lot_exception(uuid, text, numeric, text, text) FROM PUBLIC, anon;
REVOKE ALL ON public.inventory_command_facts FROM PUBLIC, anon;
GRANT SELECT ON public.inventory_command_facts TO authenticated;

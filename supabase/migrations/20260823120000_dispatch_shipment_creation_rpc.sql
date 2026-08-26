-- Dispatch migration G4 (continuing the one-operation-at-a-time programme:
-- 20260822140000 create_b2b_dispatch_consignment, 20260822150000
-- open_b2b_dispatch_carton): the next real, evidence-backed gap is
-- b2b_dispatch_shipments, which has had zero RPCs and zero callers since it
-- was created (20260804103000). Its columns -- transporter_name,
-- tracking_lr_awb, vehicle_number, driver_name, driver_phone -- map 1:1
-- onto shipment/transport fields legacy dispatch tooling already captures
-- today (transporter name, LR/Bilty/AWB number, driver name/phone) when
-- recording a dispatch leg. This migration gives that real, already-
-- captured evidence a governed home.
--
-- Deliberately NOT included: consignment.status is permanently stuck at
-- 'draft' -- confirmed by inventory, no RPC anywhere transitions it past
-- creation. The 13 intermediate states between 'draft' and 'dispatched'
-- (awaiting_products, receiving, verification_hold, under_cartonisation,
-- packing_list_generated, finance_check, pi_generated, payment_hold,
-- commercially_released, transport_confirmed, ready_to_load, loaded) each
-- represent a distinct real-world business event this repo has no
-- confirmed evidence source for today -- the existing Central finance gate
-- (canReleaseOrderToDispatch/getFinanceReleaseBlockers) operates entirely
-- on the legacy orders table, not on this state machine at all. Deciding
-- what drives each of those transitions is a genuine, separate owner
-- business-process decision, not something to fabricate here. This
-- migration therefore does not touch b2b_dispatch_consignments.status at
-- all -- it only gives real shipment evidence a governed record,
-- independent of that unresolved question. Narrower is correct here.
--
-- No client wiring, no legacy table touched, no legacy path disabled.
-- Pure additive capability; main stays coherent.

CREATE OR REPLACE FUNCTION public.create_b2b_dispatch_shipment(
  p_consignment_id uuid,
  p_transporter_name text,
  p_tracking_lr_awb text,
  p_correlation_id text,
  p_vehicle_number text DEFAULT NULL,
  p_driver_name text DEFAULT NULL,
  p_driver_phone text DEFAULT NULL
)
RETURNS public.b2b_dispatch_shipments
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_actor_id uuid := auth.uid();
  v_consignment public.b2b_dispatch_consignments%ROWTYPE;
  v_existing public.b2b_dispatch_shipments%ROWTYPE;
  v_shipment public.b2b_dispatch_shipments%ROWTYPE;
  v_transporter_name text := nullif(btrim(p_transporter_name), '');
  v_tracking_lr_awb text := nullif(btrim(p_tracking_lr_awb), '');
  v_correlation_id text := nullif(btrim(p_correlation_id), '');
BEGIN
  IF v_actor_id IS NULL OR NOT public.can_manage_b2b_dispatch(v_actor_id) THEN
    RAISE EXCEPTION 'Not authorised to create a dispatch shipment' USING ERRCODE = '42501';
  END IF;
  IF v_transporter_name IS NULL THEN
    RAISE EXCEPTION 'A transporter name is required';
  END IF;
  IF v_tracking_lr_awb IS NULL THEN
    RAISE EXCEPTION 'A tracking / LR / AWB number is required';
  END IF;
  IF v_correlation_id IS NULL THEN
    RAISE EXCEPTION 'A correlation id is required';
  END IF;

  -- consignment_id is UNIQUE on b2b_dispatch_shipments -- one shipment per
  -- consignment, exactly matching the legacy model (one dispatches row per
  -- leg). Idempotent replay by consignment_id, checked before locking the
  -- consignment: a retry of an already-successful call must return that
  -- shipment, never attempt (and fail) a second insert for the same
  -- consignment.
  SELECT * INTO v_existing FROM public.b2b_dispatch_shipments WHERE consignment_id = p_consignment_id;
  IF FOUND THEN
    RETURN v_existing;
  END IF;

  SELECT * INTO v_consignment FROM public.b2b_dispatch_consignments WHERE id = p_consignment_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Consignment not found';
  END IF;
  IF v_consignment.status IN ('dispatched', 'delivery_exception', 'delivered', 'closed', 'cancelled') THEN
    RAISE EXCEPTION 'Consignment % is % and can no longer have a shipment created against it', p_consignment_id, v_consignment.status USING ERRCODE = '42501';
  END IF;

  -- Re-check now that the consignment row is locked, same race-protection
  -- pattern as open_b2b_dispatch_carton: a concurrent call that raced past
  -- the fast-path check above and committed first while we waited on the
  -- lock must be caught here too.
  SELECT * INTO v_existing FROM public.b2b_dispatch_shipments WHERE consignment_id = p_consignment_id;
  IF FOUND THEN
    RETURN v_existing;
  END IF;

  BEGIN
    INSERT INTO public.b2b_dispatch_shipments (
      consignment_id, shipment_number, transporter_name, tracking_lr_awb,
      vehicle_number, driver_name, driver_phone, correlation_id
    ) VALUES (
      p_consignment_id, v_consignment.consignment_number || '-SHP', v_transporter_name, v_tracking_lr_awb,
      nullif(btrim(p_vehicle_number), ''), nullif(btrim(p_driver_name), ''), nullif(btrim(p_driver_phone), ''), v_correlation_id
    )
    RETURNING * INTO v_shipment;
  EXCEPTION WHEN unique_violation THEN
    -- A concurrent call for the same consignment committed between our
    -- re-check and this INSERT.
    SELECT * INTO v_existing FROM public.b2b_dispatch_shipments WHERE consignment_id = p_consignment_id;
    IF FOUND THEN
      RETURN v_existing;
    END IF;
    RAISE;
  END;

  RETURN v_shipment;
END;
$$;

COMMENT ON FUNCTION public.create_b2b_dispatch_shipment(uuid, text, text, text, text, text, text) IS
  'Records real, already-captured shipment/transport evidence (transporter, tracking LR/AWB, optional vehicle/driver detail) against a governed b2b_dispatch consignment -- the same fields the legacy dispatches table already captures per leg. Does not transition consignment.status: no RPC in this repo advances it past draft yet, and fabricating that state machine without a real evidence source per transition is deliberately out of scope. Idempotent by consignment_id (one shipment per consignment).';

REVOKE ALL ON FUNCTION public.create_b2b_dispatch_shipment(uuid, text, text, text, text, text, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.create_b2b_dispatch_shipment(uuid, text, text, text, text, text, text) TO authenticated;

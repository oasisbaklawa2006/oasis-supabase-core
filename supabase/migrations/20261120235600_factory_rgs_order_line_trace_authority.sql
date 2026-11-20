-- Factory F04/F07/F44: typed, exact SO-line lineage on the existing
-- Core reservation -> production job path. No shadow Factory order table.
-- Existing historical unlinked reservations/jobs remain intact and are NOT
-- guessed/backfilled by order_id+product_id (same SKU may occur many times).
SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '60s';

ALTER TABLE public.inventory_reservations
  ADD COLUMN IF NOT EXISTS order_item_id uuid NULL;

DO $migration$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_catalog.pg_constraint
    WHERE conname='inventory_reservations_order_item_id_fkey'
      AND conrelid='public.inventory_reservations'::regclass
  ) THEN
    ALTER TABLE public.inventory_reservations
      ADD CONSTRAINT inventory_reservations_order_item_id_fkey
      FOREIGN KEY (order_item_id) REFERENCES public.order_items(id) NOT VALID;
  END IF;
END;
$migration$;

-- One RGS intake reservation per source SO line + location; the constraint
-- includes terminal reservations to prevent accidental recreation after a
-- cancelled line without explicit amendment/reversal authority.
CREATE UNIQUE INDEX IF NOT EXISTS uq_rgs_b2b_source_line_location
 ON public.inventory_reservations(order_item_id, location_code)
 WHERE order_item_id IS NOT NULL AND demand_source_type='b2b';

CREATE OR REPLACE FUNCTION public.enforce_rgs_factory_line_reference_v1()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_line public.order_items%ROWTYPE;
  v_order public.orders%ROWTYPE;
  v_line_id uuid;
BEGIN
  IF NEW.demand_source_type <> 'b2b' THEN
    IF NEW.order_item_id IS NOT NULL THEN
      RAISE EXCEPTION 'FACTORY_ORDER_LINE_SOURCE_MUST_BE_B2B' USING ERRCODE='23514';
    END IF;
    RETURN NEW;
  END IF;
  SELECT * INTO v_order FROM public.orders WHERE id=NEW.order_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'FACTORY_ORDER_NOT_FOUND' USING ERRCODE='23503';
  END IF;
  IF NEW.demand_reference IS NULL OR NEW.demand_reference NOT LIKE 'order_item:%' THEN
    -- Legacy ERP reservations with missing line data remain readable. For
    -- new governed in-production orders, never accept an unanchored RGS
    -- reservation; routing without an original line is forbidden.
    IF v_order.order_origin <> 'LEGACY_ERP'
      AND v_order.status IN ('manufacturing','in_production','partial_ready')
    THEN
      RAISE EXCEPTION 'FACTORY_ORDER_LINE_REFERENCE_REQUIRED' USING ERRCODE='23514';
    END IF;
    IF NEW.order_item_id IS NOT NULL THEN
      RAISE EXCEPTION 'FACTORY_LINE_REFERENCE_AND_ID_MUST_AGREE' USING ERRCODE='23514';
    END IF;
    RETURN NEW;
  END IF;

  v_line_id := substring(NEW.demand_reference from length('order_item:') + 1)::uuid;
  SELECT * INTO v_line FROM public.order_items WHERE id = v_line_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'FACTORY_ORDER_LINE_NOT_FOUND' USING ERRCODE='23503';
  END IF;
  IF v_line.order_id IS DISTINCT FROM NEW.order_id
    OR v_line.product_id IS DISTINCT FROM NEW.product_id
    OR NEW.requested_qty <= 0 OR NEW.requested_qty > v_line.quantity
  THEN
    RAISE EXCEPTION 'FACTORY_ORDER_LINE_BINDING_MISMATCH' USING ERRCODE='23514';
  END IF;
  IF NEW.order_item_id IS NOT NULL AND NEW.order_item_id <> v_line_id THEN
    RAISE EXCEPTION 'FACTORY_ORDER_LINE_ID_MISMATCH' USING ERRCODE='23514';
  END IF;

  IF v_order.order_origin <> 'LEGACY_ERP' THEN
    IF v_order.status NOT IN ('manufacturing','in_production','partial_ready') THEN
      RAISE EXCEPTION 'FINANCE_RELEASE_REQUIRED_BEFORE_FACTORY_RESERVATION' USING ERRCODE='55000';
    END IF;
    -- Status alone is not a Finance clearance; verify the current version/PI.
    PERFORM public.assert_active_operations_clearance_v1(v_order.id);
  END IF;
  NEW.order_item_id := v_line_id;
  RETURN NEW;
END;
$function$;

REVOKE ALL ON FUNCTION public.enforce_rgs_factory_line_reference_v1()
 FROM PUBLIC, anon, authenticated, service_role;

DROP TRIGGER IF EXISTS trg_factory_rgs_line_reference ON public.inventory_reservations;
CREATE TRIGGER trg_factory_rgs_line_reference
 BEFORE INSERT OR UPDATE OF order_id, product_id, sku, requested_qty, demand_source_type,
   demand_reference, order_item_id
 ON public.inventory_reservations FOR EACH ROW
 EXECUTE FUNCTION public.enforce_rgs_factory_line_reference_v1();

CREATE OR REPLACE FUNCTION public.bind_factory_production_job_line_v1()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_reservation public.inventory_reservations%ROWTYPE;
BEGIN
  IF NEW.reservation_id IS NULL THEN RETURN NEW; END IF;

  SELECT * INTO v_reservation FROM public.inventory_reservations
  WHERE id=NEW.reservation_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'FACTORY_PRODUCTION_RESERVATION_NOT_FOUND' USING ERRCODE='23503'; END IF;
  IF v_reservation.order_id IS NOT NULL
    AND NEW.order_id IS DISTINCT FROM v_reservation.order_id
  THEN
    RAISE EXCEPTION 'FACTORY_PRODUCTION_ORDER_MISMATCH' USING ERRCODE='23514';
  END IF;
  -- Do not let a reservation-linked job retain an unrelated lineage when
  -- its new reservation is an historical row with no original SO line.
  -- Reject instead of silently erasing traceability; quick-log jobs without
  -- any reservation are handled by the early return above.
  IF v_reservation.order_item_id IS NULL THEN
    IF NEW.order_item_id IS NOT NULL THEN
      RAISE EXCEPTION 'FACTORY_PRODUCTION_ORDER_LINE_MISMATCH' USING ERRCODE='23514';
    END IF;
  ELSE
    IF NEW.order_item_id IS NOT NULL
      AND NEW.order_item_id <> v_reservation.order_item_id
    THEN
      RAISE EXCEPTION 'FACTORY_PRODUCTION_ORDER_LINE_MISMATCH' USING ERRCODE='23514';
    END IF;
    NEW.order_item_id := v_reservation.order_item_id;
  END IF;
  RETURN NEW;
END;
$function$;

REVOKE ALL ON FUNCTION public.bind_factory_production_job_line_v1()
 FROM PUBLIC, anon, authenticated, service_role;

DROP TRIGGER IF EXISTS trg_factory_production_job_line ON public.production_jobs;
CREATE TRIGGER trg_factory_production_job_line
 BEFORE INSERT OR UPDATE OF reservation_id, order_id, order_item_id
 ON public.production_jobs FOR EACH ROW
 EXECUTE FUNCTION public.bind_factory_production_job_line_v1();

COMMENT ON COLUMN public.inventory_reservations.order_item_id IS
 'Canonical B2B sales order line; derived only from server-validated order_item:<uuid> reference, not SKU matching. Historical NULL values remain unassigned.';
COMMENT ON FUNCTION public.enforce_rgs_factory_line_reference_v1() IS
 'Factory F07: line-to-order/product/quantity/Finance validated before reservation enters Core.';

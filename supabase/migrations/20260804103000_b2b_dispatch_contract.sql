-- B2B Dispatch contract — approved dispatch handover, Phase 1.
--
-- Scope: confirmed B2B Sales Orders, including fragmented consignments,
-- B2B direct/special delivery, customer pickup, transporter dispatch and
-- limited failed-delivery/return intake.
--
-- Explicitly excluded: outlet dispatch/replenishment, internal stock movement,
-- general fleet management and full returns/claims/rework processing.
--
-- This migration is additive. The legacy dispatches, dispatch_cartons and
-- packing_lists relations remain available for compatibility, but new governed
-- workflows must use the b2b_dispatch_* contract below.

-- =============================================================================
-- A. Consignment and immutable SO-line allocation
-- =============================================================================

CREATE TABLE IF NOT EXISTS public.b2b_dispatch_consignments (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  consignment_number text NOT NULL UNIQUE,
  order_id uuid NOT NULL REFERENCES public.orders (id) ON DELETE RESTRICT,
  sequence_number integer NOT NULL CHECK (sequence_number > 0),
  status text NOT NULL DEFAULT 'draft',
  dispatch_mode text NOT NULL,
  fragmentation_reason text NULL,
  fragmentation_origin text NULL,
  customer_instruction_ref text NULL,
  destination_snapshot jsonb NOT NULL DEFAULT '{}'::jsonb,
  handling_instructions jsonb NOT NULL DEFAULT '{}'::jsonb,
  committed_cutoff timestamptz NULL,
  planned_departure_at timestamptz NULL,
  actual_departure_at timestamptz NULL,
  created_by uuid NULL,
  approved_by uuid NULL,
  correlation_id text NOT NULL UNIQUE,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT b2b_dispatch_consignment_order_sequence_unique
    UNIQUE (order_id, sequence_number),
  CONSTRAINT b2b_dispatch_consignment_status_check CHECK (
    status IN (
      'draft', 'awaiting_products', 'receiving', 'verification_hold',
      'under_cartonisation', 'packing_list_generated', 'finance_check',
      'pi_generated', 'payment_hold', 'commercially_released',
      'transport_confirmed', 'ready_to_load', 'loaded', 'dispatched',
      'delivery_exception', 'delivered', 'closed', 'cancelled'
    )
  ),
  CONSTRAINT b2b_dispatch_consignment_mode_check CHECK (
    dispatch_mode IN (
      'road_transporter', 'courier', 'air', 'train', 'direct_special_delivery',
      'customer_pickup', 'approved_special'
    )
  ),
  CONSTRAINT b2b_dispatch_fragmentation_check CHECK (
    (fragmentation_origin IS NULL AND fragmentation_reason IS NULL)
    OR (
      fragmentation_origin IN ('oasis_operational', 'customer_request', 'mixed', 'mode_split')
      AND nullif(btrim(fragmentation_reason), '') IS NOT NULL
    )
  ),
  CONSTRAINT b2b_dispatch_departure_state_check CHECK (
    status NOT IN ('dispatched', 'delivery_exception', 'delivered', 'closed')
    OR actual_departure_at IS NOT NULL
  )
);

CREATE INDEX IF NOT EXISTS idx_b2b_dispatch_consignments_order
  ON public.b2b_dispatch_consignments (order_id, sequence_number);
CREATE INDEX IF NOT EXISTS idx_b2b_dispatch_consignments_queue
  ON public.b2b_dispatch_consignments (status, committed_cutoff);

CREATE TABLE IF NOT EXISTS public.b2b_dispatch_consignment_lines (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  consignment_id uuid NOT NULL REFERENCES public.b2b_dispatch_consignments (id) ON DELETE RESTRICT,
  order_item_id uuid NOT NULL REFERENCES public.order_items (id) ON DELETE RESTRICT,
  product_id uuid NOT NULL REFERENCES public.products (id) ON DELETE RESTRICT,
  product_code text NOT NULL,
  uom text NOT NULL,
  original_order_qty numeric NOT NULL CHECK (original_order_qty > 0),
  selected_qty numeric NOT NULL CHECK (selected_qty > 0),
  accepted_ready_qty numeric NOT NULL DEFAULT 0 CHECK (accepted_ready_qty >= 0),
  packed_qty numeric NOT NULL DEFAULT 0 CHECK (packed_qty >= 0),
  loaded_qty numeric NOT NULL DEFAULT 0 CHECK (loaded_qty >= 0),
  dispatched_qty numeric NOT NULL DEFAULT 0 CHECK (dispatched_qty >= 0),
  delivered_qty numeric NOT NULL DEFAULT 0 CHECK (delivered_qty >= 0),
  held_qty numeric NOT NULL DEFAULT 0 CHECK (held_qty >= 0),
  rejected_qty numeric NOT NULL DEFAULT 0 CHECK (rejected_qty >= 0),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT b2b_dispatch_consignment_line_unique UNIQUE (consignment_id, order_item_id),
  CONSTRAINT b2b_dispatch_consignment_line_progress_check CHECK (
    accepted_ready_qty <= selected_qty + 0.0001
    AND packed_qty <= accepted_ready_qty + 0.0001
    AND loaded_qty <= packed_qty + 0.0001
    AND dispatched_qty <= loaded_qty + 0.0001
    AND delivered_qty <= dispatched_qty + 0.0001
    AND held_qty + rejected_qty <= selected_qty + 0.0001
  )
);

-- =============================================================================
-- B. Quantity-specific source readiness and custody acceptance
-- =============================================================================

CREATE TABLE IF NOT EXISTS public.b2b_dispatch_handoffs (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  handoff_number text NOT NULL UNIQUE,
  order_id uuid NOT NULL REFERENCES public.orders (id) ON DELETE RESTRICT,
  consignment_id uuid NULL REFERENCES public.b2b_dispatch_consignments (id) ON DELETE RESTRICT,
  source_department text NOT NULL,
  source_location text NOT NULL,
  destination_location text NOT NULL DEFAULT 'SOURCE_PICKUP',
  status text NOT NULL DEFAULT 'declared_ready',
  issued_by uuid NULL,
  received_by uuid NULL,
  declared_at timestamptz NOT NULL DEFAULT now(),
  received_at timestamptz NULL,
  correlation_id text NOT NULL UNIQUE,
  notes text NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT b2b_dispatch_handoff_source_check CHECK (
    source_department IN ('PRODUCTION', 'RGS', '3PGS', 'PACKING_ASSEMBLY', 'QUALITY')
  ),
  CONSTRAINT b2b_dispatch_handoff_status_check CHECK (
    status IN ('declared_ready', 'pickup_acknowledged', 'receiving', 'partially_accepted', 'accepted', 'rejected', 'verification_hold', 'cancelled')
  )
);

CREATE TABLE IF NOT EXISTS public.b2b_dispatch_handoff_lines (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  handoff_id uuid NOT NULL REFERENCES public.b2b_dispatch_handoffs (id) ON DELETE RESTRICT,
  order_item_id uuid NOT NULL REFERENCES public.order_items (id) ON DELETE RESTRICT,
  product_id uuid NOT NULL REFERENCES public.products (id) ON DELETE RESTRICT,
  product_code text NOT NULL,
  batch_lot text NULL,
  expiry_date date NULL,
  uom text NOT NULL,
  declared_qty numeric NOT NULL CHECK (declared_qty > 0),
  physically_received_qty numeric NOT NULL DEFAULT 0 CHECK (physically_received_qty >= 0),
  accepted_qty numeric NOT NULL DEFAULT 0 CHECK (accepted_qty >= 0),
  held_qty numeric NOT NULL DEFAULT 0 CHECK (held_qty >= 0),
  rejected_qty numeric NOT NULL DEFAULT 0 CHECK (rejected_qty >= 0),
  discrepancy_reason text NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT b2b_dispatch_handoff_line_identity
    UNIQUE NULLS NOT DISTINCT (handoff_id, order_item_id, product_code, batch_lot),
  CONSTRAINT b2b_dispatch_handoff_line_reconcile_check CHECK (
    accepted_qty + held_qty + rejected_qty <= physically_received_qty + 0.0001
  )
);

-- =============================================================================
-- C. Carton truth, scanned contents and visible-condition verification
-- =============================================================================

CREATE TABLE IF NOT EXISTS public.b2b_dispatch_cartons (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  carton_code text NOT NULL UNIQUE,
  consignment_id uuid NOT NULL REFERENCES public.b2b_dispatch_consignments (id) ON DELETE RESTRICT,
  carton_sequence integer NOT NULL CHECK (carton_sequence > 0),
  status text NOT NULL DEFAULT 'open',
  physical_location text NOT NULL DEFAULT 'CONSOLIDATION_ZONE',
  net_weight numeric NULL CHECK (net_weight IS NULL OR net_weight >= 0),
  gross_weight numeric NULL CHECK (gross_weight IS NULL OR gross_weight >= 0),
  weight_uom text NOT NULL DEFAULT 'kg',
  open_photo_ref text NULL,
  seal_reference text NULL,
  handling_labels jsonb NOT NULL DEFAULT '[]'::jsonb,
  locked_by uuid NULL,
  locked_at timestamptz NULL,
  reopen_count integer NOT NULL DEFAULT 0 CHECK (reopen_count >= 0),
  current_version integer NOT NULL DEFAULT 1 CHECK (current_version > 0),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT b2b_dispatch_carton_sequence_unique UNIQUE (consignment_id, carton_sequence),
  CONSTRAINT b2b_dispatch_carton_status_check CHECK (
    status IN (
      'open', 'under_packing', 'photo_required', 'locked', 'finance_check_open',
      'repacking_required', 'verified', 'labelled', 'ready_to_load', 'loaded',
      'handed_over', 'returned', 'damaged'
    )
  ),
  CONSTRAINT b2b_dispatch_carton_location_check CHECK (
    physical_location IN (
      'SOURCE_PICKUP', 'RECEIVING_BAY', 'VERIFICATION_HOLD', 'CONSOLIDATION_ZONE',
      'TRANSIT_PACKING', 'FINANCE_CHECK', 'READY_TO_LOAD_BAY', 'LOADED',
      'QUARANTINE_RETURN'
    )
  ),
  CONSTRAINT b2b_dispatch_carton_weight_check CHECK (
    gross_weight IS NULL OR net_weight IS NULL OR gross_weight + 0.0001 >= net_weight
  ),
  CONSTRAINT b2b_dispatch_carton_lock_evidence_check CHECK (
    status NOT IN ('locked', 'verified', 'labelled', 'ready_to_load', 'loaded', 'handed_over')
    OR (
      open_photo_ref IS NOT NULL AND net_weight IS NOT NULL AND gross_weight IS NOT NULL
      AND locked_by IS NOT NULL AND locked_at IS NOT NULL
    )
  )
);

CREATE TABLE IF NOT EXISTS public.b2b_dispatch_carton_items (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  carton_id uuid NOT NULL REFERENCES public.b2b_dispatch_cartons (id) ON DELETE RESTRICT,
  consignment_line_id uuid NOT NULL REFERENCES public.b2b_dispatch_consignment_lines (id) ON DELETE RESTRICT,
  order_item_id uuid NOT NULL REFERENCES public.order_items (id) ON DELETE RESTRICT,
  product_id uuid NOT NULL REFERENCES public.products (id) ON DELETE RESTRICT,
  product_code text NOT NULL,
  barcode_value text NOT NULL,
  batch_lot text NOT NULL,
  expiry_date date NULL,
  uom text NOT NULL,
  quantity numeric NOT NULL CHECK (quantity > 0),
  scan_status text NOT NULL DEFAULT 'verified',
  scanned_by uuid NULL,
  scanned_at timestamptz NOT NULL DEFAULT now(),
  scan_device_id text NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT b2b_dispatch_carton_item_barcode_unique UNIQUE (carton_id, barcode_value),
  CONSTRAINT b2b_dispatch_carton_item_scan_check CHECK (scan_status = 'verified')
);

CREATE TABLE IF NOT EXISTS public.b2b_dispatch_product_scan_events (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  carton_id uuid NOT NULL REFERENCES public.b2b_dispatch_cartons (id) ON DELETE RESTRICT,
  barcode_value text NOT NULL,
  scan_result text NOT NULL,
  resolved_product_id uuid NULL REFERENCES public.products (id) ON DELETE RESTRICT,
  resolved_batch_lot text NULL,
  scanned_by uuid NULL,
  scanned_at timestamptz NOT NULL DEFAULT now(),
  device_id text NULL,
  reason text NULL,
  correlation_id text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT b2b_dispatch_product_scan_result_check CHECK (
    scan_result IN ('verified', 'blocked_wrong_so', 'blocked_wrong_product', 'blocked_wrong_batch', 'blocked_duplicate', 'blocked_expired', 'blocked_unreleased', 'blocked_excess')
  )
);

CREATE TABLE IF NOT EXISTS public.b2b_dispatch_quality_checks (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  handoff_id uuid NULL REFERENCES public.b2b_dispatch_handoffs (id) ON DELETE RESTRICT,
  carton_id uuid NULL REFERENCES public.b2b_dispatch_cartons (id) ON DELETE RESTRICT,
  check_family text NOT NULL,
  checklist_version text NOT NULL,
  result text NOT NULL,
  sampled_qty numeric NULL CHECK (sampled_qty IS NULL OR sampled_qty > 0),
  policy_snapshot jsonb NOT NULL DEFAULT '{}'::jsonb,
  exception_type text NULL,
  severity text NULL,
  evidence_ref text NULL,
  responsible_source text NULL,
  checked_by uuid NULL,
  checked_at timestamptz NOT NULL DEFAULT now(),
  correlation_id text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT b2b_dispatch_quality_target_check CHECK (
    (handoff_id IS NOT NULL)::integer + (carton_id IS NOT NULL)::integer = 1
  ),
  CONSTRAINT b2b_dispatch_quality_family_check CHECK (
    check_family IN ('order_identity', 'pack_integrity', 'product_condition', 'labels', 'traceability', 'shelf_life', 'quantity_uom', 'transit_suitability', 'documents')
  ),
  CONSTRAINT b2b_dispatch_quality_result_check CHECK (
    result IN ('pass', 'hold', 'rework', 'reprint', 'reject', 'add_protection')
  ),
  CONSTRAINT b2b_dispatch_quality_failure_evidence_check CHECK (
    result = 'pass'
    OR (exception_type IS NOT NULL AND severity IN ('S1', 'S2', 'S3', 'S4') AND evidence_ref IS NOT NULL)
  )
);

-- =============================================================================
-- D. Versioned packing truth, commercial release and physical shipment
-- =============================================================================

CREATE TABLE IF NOT EXISTS public.b2b_dispatch_packing_list_versions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  consignment_id uuid NOT NULL REFERENCES public.b2b_dispatch_consignments (id) ON DELETE RESTRICT,
  version_number integer NOT NULL CHECK (version_number > 0),
  status text NOT NULL DEFAULT 'draft',
  document_ref text NULL,
  physical_truth_snapshot jsonb NOT NULL DEFAULT '{}'::jsonb,
  generated_by uuid NULL,
  generated_at timestamptz NOT NULL DEFAULT now(),
  superseded_by uuid NULL REFERENCES public.b2b_dispatch_packing_list_versions (id) ON DELETE RESTRICT,
  submitted_to_finance_at timestamptz NULL,
  finance_check_state text NOT NULL DEFAULT 'not_requested',
  correlation_id text NOT NULL UNIQUE,
  CONSTRAINT b2b_dispatch_dpl_version_unique UNIQUE (consignment_id, version_number),
  CONSTRAINT b2b_dispatch_dpl_status_check CHECK (
    status IN ('draft', 'generated', 'submitted_to_finance', 'finance_verified', 'superseded')
  ),
  CONSTRAINT b2b_dispatch_dpl_finance_check CHECK (
    finance_check_state IN ('not_requested', 'pending', 'verified', 'discrepancy', 'repack_required')
  )
);

CREATE TABLE IF NOT EXISTS public.b2b_dispatch_releases (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  consignment_id uuid NOT NULL REFERENCES public.b2b_dispatch_consignments (id) ON DELETE RESTRICT,
  packing_list_version_id uuid NOT NULL REFERENCES public.b2b_dispatch_packing_list_versions (id) ON DELETE RESTRICT,
  release_state text NOT NULL,
  pi_reference text NULL,
  invoice_reference text NULL,
  finance_evidence_ref text NULL,
  released_by uuid NULL,
  released_at timestamptz NULL,
  expires_at timestamptz NULL,
  correlation_id text NOT NULL UNIQUE,
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT b2b_dispatch_release_state_check CHECK (
    release_state IN ('finance_hold', 'document_hold', 'qc_hold', 'management_hold', 'awaiting_balance_payment', 'approved_credit_dispatch', 'cod_collection_instruction', 'commercially_clear', 'exception_approved', 'revoked')
  ),
  CONSTRAINT b2b_dispatch_release_evidence_check CHECK (
    release_state NOT IN ('commercially_clear', 'approved_credit_dispatch', 'cod_collection_instruction', 'exception_approved')
    OR (released_by IS NOT NULL AND released_at IS NOT NULL AND finance_evidence_ref IS NOT NULL)
  )
);

CREATE TABLE IF NOT EXISTS public.b2b_dispatch_shipments (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  consignment_id uuid NOT NULL UNIQUE REFERENCES public.b2b_dispatch_consignments (id) ON DELETE RESTRICT,
  shipment_number text NOT NULL UNIQUE,
  transporter_name text NULL,
  tracking_lr_awb text NULL,
  vehicle_number text NULL,
  driver_name text NULL,
  driver_phone text NULL,
  vehicle_suitability_state text NOT NULL DEFAULT 'pending',
  gate_arrival_ref text NULL,
  gate_exit_ref text NULL,
  loading_evidence_ref text NULL,
  transporter_ack_ref text NULL,
  loaded_at timestamptz NULL,
  departed_at timestamptz NULL,
  pod_ref text NULL,
  delivered_at timestamptz NULL,
  delivery_state text NOT NULL DEFAULT 'not_dispatched',
  correlation_id text NOT NULL UNIQUE,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT b2b_dispatch_vehicle_state_check CHECK (
    vehicle_suitability_state IN ('pending', 'suitable', 'unsuitable', 'capacity_short', 'temperature_hold')
  ),
  CONSTRAINT b2b_dispatch_delivery_state_check CHECK (
    delivery_state IN ('not_dispatched', 'in_transit', 'delivery_exception', 'delivered', 'refused', 'lost', 'damaged', 'short_delivered', 'returned_to_quarantine')
  ),
  CONSTRAINT b2b_dispatch_departure_evidence_check CHECK (
    departed_at IS NULL
    OR (loading_evidence_ref IS NOT NULL AND transporter_ack_ref IS NOT NULL)
  ),
  CONSTRAINT b2b_dispatch_delivery_evidence_check CHECK (
    delivery_state <> 'delivered' OR (departed_at IS NOT NULL AND pod_ref IS NOT NULL AND delivered_at IS NOT NULL)
  )
);

CREATE TABLE IF NOT EXISTS public.b2b_dispatch_load_scans (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  shipment_id uuid NOT NULL REFERENCES public.b2b_dispatch_shipments (id) ON DELETE RESTRICT,
  carton_id uuid NOT NULL REFERENCES public.b2b_dispatch_cartons (id) ON DELETE RESTRICT,
  scan_result text NOT NULL,
  scanned_by uuid NULL,
  scanned_at timestamptz NOT NULL DEFAULT now(),
  device_id text NULL,
  correlation_id text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT b2b_dispatch_load_scan_unique UNIQUE (shipment_id, carton_id),
  CONSTRAINT b2b_dispatch_load_scan_result_check CHECK (
    scan_result IN ('verified', 'blocked_wrong_consignment', 'blocked_unreleased', 'blocked_unverified', 'blocked_duplicate', 'removed_before_departure')
  )
);

-- =============================================================================
-- E. Residual authority, exceptions and immutable operational event history
-- =============================================================================

CREATE TABLE IF NOT EXISTS public.b2b_dispatch_residual_closures (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  order_item_id uuid NOT NULL REFERENCES public.order_items (id) ON DELETE RESTRICT,
  approved_closed_qty numeric NOT NULL CHECK (approved_closed_qty > 0),
  reason text NOT NULL,
  customer_evidence_ref text NOT NULL,
  finance_adjustment_ref text NOT NULL,
  requested_by uuid NULL,
  approved_by uuid NOT NULL,
  approved_at timestamptz NOT NULL DEFAULT now(),
  correlation_id text NOT NULL UNIQUE,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.b2b_dispatch_exceptions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  order_id uuid NOT NULL REFERENCES public.orders (id) ON DELETE RESTRICT,
  consignment_id uuid NULL REFERENCES public.b2b_dispatch_consignments (id) ON DELETE RESTRICT,
  carton_id uuid NULL REFERENCES public.b2b_dispatch_cartons (id) ON DELETE RESTRICT,
  exception_type text NOT NULL,
  source_department text NULL,
  severity text NOT NULL,
  status text NOT NULL DEFAULT 'open',
  owner_id uuid NULL,
  evidence_ref text NOT NULL,
  detected_at timestamptz NOT NULL DEFAULT now(),
  resolution_due_at timestamptz NULL,
  resolved_at timestamptz NULL,
  decision_authority uuid NULL,
  final_disposition text NULL,
  commitment_effect text NULL,
  correlation_id text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT b2b_dispatch_exception_severity_check CHECK (severity IN ('S1', 'S2', 'S3', 'S4')),
  CONSTRAINT b2b_dispatch_exception_status_check CHECK (
    status IN ('open', 'acknowledged', 'in_resolution', 'resolved', 'voided', 'under_appeal')
  )
);

CREATE TABLE IF NOT EXISTS public.b2b_dispatch_events (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  order_id uuid NOT NULL REFERENCES public.orders (id) ON DELETE RESTRICT,
  order_item_id uuid NULL REFERENCES public.order_items (id) ON DELETE RESTRICT,
  consignment_id uuid NULL REFERENCES public.b2b_dispatch_consignments (id) ON DELETE RESTRICT,
  carton_id uuid NULL REFERENCES public.b2b_dispatch_cartons (id) ON DELETE RESTRICT,
  shipment_id uuid NULL REFERENCES public.b2b_dispatch_shipments (id) ON DELETE RESTRICT,
  event_type text NOT NULL,
  old_status text NULL,
  new_status text NULL,
  quantity numeric NULL,
  uom text NULL,
  location_code text NULL,
  custodian_id uuid NULL,
  actor_id uuid NULL,
  actor_role text NULL,
  device_id text NULL,
  server_event_at timestamptz NOT NULL DEFAULT now(),
  device_event_at timestamptz NULL,
  source_record_type text NULL,
  source_record_id uuid NULL,
  evidence_refs jsonb NOT NULL DEFAULT '[]'::jsonb,
  reason text NULL,
  authority_id uuid NULL,
  document_version_id uuid NULL REFERENCES public.b2b_dispatch_packing_list_versions (id) ON DELETE RESTRICT,
  correlation_id text NOT NULL,
  metadata jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_b2b_dispatch_events_order_time
  ON public.b2b_dispatch_events (order_id, server_event_at DESC);
CREATE INDEX IF NOT EXISTS idx_b2b_dispatch_exceptions_queue
  ON public.b2b_dispatch_exceptions (status, severity, resolution_due_at);
CREATE INDEX IF NOT EXISTS idx_b2b_dispatch_consignment_lines_order_item
  ON public.b2b_dispatch_consignment_lines (order_item_id);
CREATE INDEX IF NOT EXISTS idx_b2b_dispatch_releases_consignment
  ON public.b2b_dispatch_releases (consignment_id);
CREATE INDEX IF NOT EXISTS idx_b2b_dispatch_exceptions_consignment
  ON public.b2b_dispatch_exceptions (consignment_id);

-- =============================================================================
-- F. Guardrails: retained records, immutable identity, forward-only states
-- =============================================================================

CREATE OR REPLACE FUNCTION public.prevent_b2b_dispatch_delete()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  RAISE EXCEPTION 'B2B dispatch records are retained; reverse, supersede or close with an evidenced event';
END;
$$;

CREATE OR REPLACE FUNCTION public.protect_b2b_dispatch_line_identity()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  IF NEW.consignment_id IS DISTINCT FROM OLD.consignment_id
     OR NEW.order_item_id IS DISTINCT FROM OLD.order_item_id
     OR NEW.product_id IS DISTINCT FROM OLD.product_id
     OR NEW.product_code IS DISTINCT FROM OLD.product_code
     OR NEW.uom IS DISTINCT FROM OLD.uom
     OR NEW.original_order_qty IS DISTINCT FROM OLD.original_order_qty
     OR NEW.selected_qty IS DISTINCT FROM OLD.selected_qty THEN
    RAISE EXCEPTION 'B2B consignment line identity and selected quantity are immutable; create a superseding consignment line';
  END IF;
  RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION public.validate_b2b_dispatch_line_allocation()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  item_order_id uuid;
  item_product_id uuid;
  item_order_qty numeric;
  consignment_order_id uuid;
  allocated_qty numeric;
BEGIN
  -- Serialise allocations for the same SO line so concurrent consignments
  -- cannot over-allocate the immutable ordered quantity.
  PERFORM pg_advisory_xact_lock(hashtextextended(NEW.order_item_id::text, 0));

  SELECT oi.order_id, oi.product_id, oi.quantity::numeric
    INTO item_order_id, item_product_id, item_order_qty
  FROM public.order_items oi
  WHERE oi.id = NEW.order_item_id;

  SELECT c.order_id INTO consignment_order_id
  FROM public.b2b_dispatch_consignments c
  WHERE c.id = NEW.consignment_id;

  IF item_order_id IS DISTINCT FROM consignment_order_id
     OR item_product_id IS DISTINCT FROM NEW.product_id THEN
    RAISE EXCEPTION 'B2B consignment line must reference an item and product from the same Sales Order';
  END IF;

  IF NEW.original_order_qty IS DISTINCT FROM item_order_qty THEN
    RAISE EXCEPTION 'B2B consignment original quantity must equal the immutable Sales Order line quantity';
  END IF;

  SELECT coalesce(sum(line.selected_qty), 0::numeric)
    INTO allocated_qty
  FROM public.b2b_dispatch_consignment_lines line
  JOIN public.b2b_dispatch_consignments allocation_consignment
    ON allocation_consignment.id = line.consignment_id
  WHERE line.order_item_id = NEW.order_item_id
    AND line.id IS DISTINCT FROM NEW.id
    AND allocation_consignment.status <> 'cancelled';

  IF allocated_qty + NEW.selected_qty > item_order_qty + 0.0001 THEN
    RAISE EXCEPTION 'B2B consignments cannot allocate more than the Sales Order line quantity';
  END IF;
  RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION public.validate_b2b_dispatch_consignment_transition()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
  allowed boolean := false;
BEGIN
  IF NEW.status = OLD.status THEN
    RETURN NEW;
  END IF;
  allowed := CASE OLD.status
    WHEN 'draft' THEN NEW.status IN ('awaiting_products', 'cancelled')
    WHEN 'awaiting_products' THEN NEW.status IN ('receiving', 'verification_hold', 'cancelled')
    WHEN 'receiving' THEN NEW.status IN ('verification_hold', 'under_cartonisation', 'cancelled')
    WHEN 'verification_hold' THEN NEW.status IN ('receiving', 'under_cartonisation', 'cancelled')
    WHEN 'under_cartonisation' THEN NEW.status IN ('verification_hold', 'packing_list_generated')
    WHEN 'packing_list_generated' THEN NEW.status IN ('under_cartonisation', 'finance_check')
    WHEN 'finance_check' THEN NEW.status IN ('under_cartonisation', 'pi_generated', 'payment_hold')
    WHEN 'pi_generated' THEN NEW.status IN ('payment_hold', 'commercially_released')
    WHEN 'payment_hold' THEN NEW.status IN ('pi_generated', 'commercially_released')
    WHEN 'commercially_released' THEN NEW.status IN ('transport_confirmed', 'payment_hold')
    WHEN 'transport_confirmed' THEN NEW.status IN ('ready_to_load', 'commercially_released')
    WHEN 'ready_to_load' THEN NEW.status IN ('loaded', 'commercially_released')
    WHEN 'loaded' THEN NEW.status IN ('ready_to_load', 'dispatched')
    WHEN 'dispatched' THEN NEW.status IN ('delivery_exception', 'delivered')
    WHEN 'delivery_exception' THEN NEW.status IN ('dispatched', 'delivered', 'closed')
    WHEN 'delivered' THEN NEW.status = 'closed'
    ELSE false
  END;
  IF NOT allowed THEN
    RAISE EXCEPTION 'Invalid B2B dispatch consignment transition: % -> %', OLD.status, NEW.status;
  END IF;
  RETURN NEW;
END;
$$;

CREATE OR REPLACE TRIGGER trg_b2b_dispatch_consignment_transition
  BEFORE UPDATE OF status ON public.b2b_dispatch_consignments
  FOR EACH ROW EXECUTE FUNCTION public.validate_b2b_dispatch_consignment_transition();
CREATE OR REPLACE TRIGGER trg_b2b_dispatch_line_identity
  BEFORE UPDATE ON public.b2b_dispatch_consignment_lines
  FOR EACH ROW EXECUTE FUNCTION public.protect_b2b_dispatch_line_identity();
CREATE OR REPLACE TRIGGER trg_b2b_dispatch_line_allocation
  BEFORE INSERT OR UPDATE ON public.b2b_dispatch_consignment_lines
  FOR EACH ROW EXECUTE FUNCTION public.validate_b2b_dispatch_line_allocation();

DO $$
DECLARE
  relation_name text;
BEGIN
  FOREACH relation_name IN ARRAY ARRAY[
    'b2b_dispatch_consignments', 'b2b_dispatch_consignment_lines',
    'b2b_dispatch_handoffs', 'b2b_dispatch_handoff_lines',
    'b2b_dispatch_cartons', 'b2b_dispatch_carton_items', 'b2b_dispatch_product_scan_events',
    'b2b_dispatch_quality_checks', 'b2b_dispatch_packing_list_versions',
    'b2b_dispatch_releases', 'b2b_dispatch_shipments', 'b2b_dispatch_load_scans',
    'b2b_dispatch_residual_closures', 'b2b_dispatch_exceptions', 'b2b_dispatch_events'
  ] LOOP
    EXECUTE format('CREATE OR REPLACE TRIGGER %I BEFORE DELETE ON public.%I FOR EACH ROW EXECUTE FUNCTION public.prevent_b2b_dispatch_delete()',
      'trg_' || relation_name || '_no_delete', relation_name);
  END LOOP;
END;
$$;

-- Append-only objects: corrections are new events/versions, never overwrites.
CREATE OR REPLACE FUNCTION public.prevent_b2b_dispatch_append_only_update()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  RAISE EXCEPTION 'B2B dispatch evidence is append-only; create a reversal, superseding version or adjudication event';
END;
$$;

CREATE OR REPLACE FUNCTION public.touch_b2b_dispatch_updated_at()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$;

DO $$
DECLARE relation_name text;
BEGIN
  FOREACH relation_name IN ARRAY ARRAY[
    'b2b_dispatch_consignments', 'b2b_dispatch_consignment_lines',
    'b2b_dispatch_handoffs', 'b2b_dispatch_cartons',
    'b2b_dispatch_shipments', 'b2b_dispatch_exceptions'
  ] LOOP
    EXECUTE format(
      'CREATE OR REPLACE TRIGGER %I BEFORE UPDATE ON public.%I FOR EACH ROW EXECUTE FUNCTION public.touch_b2b_dispatch_updated_at()',
      'trg_' || relation_name || '_touch_updated_at', relation_name
    );
  END LOOP;
END;
$$;

CREATE OR REPLACE TRIGGER trg_b2b_dispatch_events_no_update
  BEFORE UPDATE ON public.b2b_dispatch_events
  FOR EACH ROW EXECUTE FUNCTION public.prevent_b2b_dispatch_append_only_update();
CREATE OR REPLACE TRIGGER trg_b2b_dispatch_quality_checks_no_update
  BEFORE UPDATE ON public.b2b_dispatch_quality_checks
  FOR EACH ROW EXECUTE FUNCTION public.prevent_b2b_dispatch_append_only_update();
CREATE OR REPLACE TRIGGER trg_b2b_dispatch_product_scan_events_no_update
  BEFORE UPDATE ON public.b2b_dispatch_product_scan_events
  FOR EACH ROW EXECUTE FUNCTION public.prevent_b2b_dispatch_append_only_update();
CREATE OR REPLACE TRIGGER trg_b2b_dispatch_load_scans_no_update
  BEFORE UPDATE ON public.b2b_dispatch_load_scans
  FOR EACH ROW EXECUTE FUNCTION public.prevent_b2b_dispatch_append_only_update();
CREATE OR REPLACE TRIGGER trg_b2b_dispatch_residual_closures_no_update
  BEFORE UPDATE ON public.b2b_dispatch_residual_closures
  FOR EACH ROW EXECUTE FUNCTION public.prevent_b2b_dispatch_append_only_update();

-- =============================================================================
-- G. Residual truth and dispatch command projection
-- =============================================================================

CREATE OR REPLACE VIEW public.b2b_dispatch_so_line_fulfilment
WITH (security_invoker = true)
AS
SELECT
  oi.order_id,
  oi.id AS order_item_id,
  oi.product_id,
  oi.quantity::numeric AS original_order_qty,
  coalesce(sum(cl.dispatched_qty), 0::numeric) AS cumulative_dispatched_qty,
  coalesce(rc.approved_closed_qty, 0::numeric) AS approved_closed_qty,
  greatest(
    oi.quantity::numeric
      - coalesce(sum(cl.dispatched_qty), 0::numeric)
      - coalesce(rc.approved_closed_qty, 0::numeric),
    0::numeric
  ) AS residual_qty
FROM public.order_items oi
LEFT JOIN public.b2b_dispatch_consignment_lines cl ON cl.order_item_id = oi.id
LEFT JOIN (
  SELECT order_item_id, sum(approved_closed_qty) AS approved_closed_qty
  FROM public.b2b_dispatch_residual_closures
  GROUP BY order_item_id
) rc ON rc.order_item_id = oi.id
GROUP BY oi.order_id, oi.id, oi.product_id, oi.quantity, rc.approved_closed_qty;

CREATE OR REPLACE VIEW public.b2b_dispatch_command_queue
WITH (security_invoker = true)
AS
SELECT
  c.id AS consignment_id,
  c.consignment_number,
  c.order_id,
  c.sequence_number,
  c.status,
  c.dispatch_mode,
  c.fragmentation_origin,
  c.committed_cutoff,
  c.planned_departure_at,
  c.actual_departure_at,
  coalesce(carton.carton_count, 0::bigint) AS carton_count,
  coalesce(line.selected_qty, 0::numeric) AS selected_qty,
  coalesce(line.packed_qty, 0::numeric) AS packed_qty,
  coalesce(line.dispatched_qty, 0::numeric) AS dispatched_qty,
  release.release_state,
  shipment.vehicle_number,
  shipment.transporter_name,
  shipment.delivery_state,
  coalesce(exception.open_exception_count, 0::bigint) AS open_exception_count
FROM public.b2b_dispatch_consignments c
LEFT JOIN LATERAL (
  SELECT count(*) AS carton_count
  FROM public.b2b_dispatch_cartons bc
  WHERE bc.consignment_id = c.id
) carton ON true
LEFT JOIN LATERAL (
  SELECT
    sum(cl.selected_qty) AS selected_qty,
    sum(cl.packed_qty) AS packed_qty,
    sum(cl.dispatched_qty) AS dispatched_qty
  FROM public.b2b_dispatch_consignment_lines cl
  WHERE cl.consignment_id = c.id
) line ON true
LEFT JOIN LATERAL (
  SELECT r.release_state
  FROM public.b2b_dispatch_releases r
  WHERE r.consignment_id = c.id
  ORDER BY r.created_at DESC
  LIMIT 1
) release ON true
LEFT JOIN public.b2b_dispatch_shipments shipment ON shipment.consignment_id = c.id
LEFT JOIN LATERAL (
  SELECT count(*) AS open_exception_count
  FROM public.b2b_dispatch_exceptions be
  WHERE be.consignment_id = c.id
    AND be.status NOT IN ('resolved', 'voided')
) exception ON true;

-- =============================================================================
-- H. Role-scoped access. Customers and anonymous users have no table access.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.can_manage_b2b_dispatch(_user_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.users
    WHERE id = _user_id
      AND upper(coalesce(role, '')) = ANY (ARRAY[
        'SUPER_ADMIN', 'ADMIN', 'OPERATIONS_MANAGER',
        'DISPATCH_MANAGER', 'DISPATCH_INCHARGE', 'DISPATCH_HEAD'
      ])
  );
$$;

CREATE OR REPLACE FUNCTION public.can_verify_b2b_dispatch_finance(_user_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.users
    WHERE id = _user_id
      AND upper(coalesce(role, '')) = ANY (ARRAY[
        'SUPER_ADMIN', 'ADMIN', 'FINANCE_HEAD', 'FINANCE_MANAGER', 'ACCOUNTS_MANAGER'
      ])
  );
$$;

-- Functions are executable by PUBLIC by default in Postgres. Only the two RLS
-- predicates need authenticated execution; trigger functions remain private.
REVOKE ALL ON FUNCTION public.can_manage_b2b_dispatch(uuid) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.can_verify_b2b_dispatch_finance(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.can_manage_b2b_dispatch(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.can_verify_b2b_dispatch_finance(uuid) TO authenticated;

REVOKE ALL ON FUNCTION public.prevent_b2b_dispatch_delete() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.protect_b2b_dispatch_line_identity() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.validate_b2b_dispatch_line_allocation() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.validate_b2b_dispatch_consignment_transition() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.prevent_b2b_dispatch_append_only_update() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.touch_b2b_dispatch_updated_at() FROM PUBLIC, anon, authenticated;

DO $$
DECLARE relation_name text;
BEGIN
  FOREACH relation_name IN ARRAY ARRAY[
    'b2b_dispatch_consignments', 'b2b_dispatch_consignment_lines',
    'b2b_dispatch_handoffs', 'b2b_dispatch_handoff_lines',
    'b2b_dispatch_cartons', 'b2b_dispatch_carton_items', 'b2b_dispatch_product_scan_events',
    'b2b_dispatch_quality_checks', 'b2b_dispatch_packing_list_versions',
    'b2b_dispatch_releases', 'b2b_dispatch_shipments', 'b2b_dispatch_load_scans',
    'b2b_dispatch_residual_closures', 'b2b_dispatch_exceptions', 'b2b_dispatch_events'
  ] LOOP
    EXECUTE format('ALTER TABLE public.%I ENABLE ROW LEVEL SECURITY', relation_name);
    EXECUTE format('REVOKE ALL ON public.%I FROM anon', relation_name);
    EXECUTE format('DROP POLICY IF EXISTS %I ON public.%I',
      'Internal staff read ' || relation_name, relation_name);
    EXECUTE format(
      'CREATE POLICY %I ON public.%I FOR SELECT TO authenticated USING (public.is_internal_staff(auth.uid()))',
      'Internal staff read ' || relation_name, relation_name
    );
  END LOOP;
END;
$$;

DROP POLICY IF EXISTS "Dispatch operators maintain consignments" ON public.b2b_dispatch_consignments;
DROP POLICY IF EXISTS "Dispatch operators maintain consignment lines" ON public.b2b_dispatch_consignment_lines;
DROP POLICY IF EXISTS "Dispatch operators maintain handoffs" ON public.b2b_dispatch_handoffs;
DROP POLICY IF EXISTS "Dispatch operators maintain handoff lines" ON public.b2b_dispatch_handoff_lines;
DROP POLICY IF EXISTS "Dispatch operators maintain cartons" ON public.b2b_dispatch_cartons;
DROP POLICY IF EXISTS "Dispatch operators maintain carton items" ON public.b2b_dispatch_carton_items;
DROP POLICY IF EXISTS "Dispatch operators record product scan events" ON public.b2b_dispatch_product_scan_events;
DROP POLICY IF EXISTS "Dispatch operators record quality checks" ON public.b2b_dispatch_quality_checks;
DROP POLICY IF EXISTS "Dispatch operators maintain packing list versions" ON public.b2b_dispatch_packing_list_versions;
DROP POLICY IF EXISTS "Finance verifies dispatch releases" ON public.b2b_dispatch_releases;
DROP POLICY IF EXISTS "Dispatch operators maintain shipments" ON public.b2b_dispatch_shipments;
DROP POLICY IF EXISTS "Dispatch operators record load scans" ON public.b2b_dispatch_load_scans;
DROP POLICY IF EXISTS "Management closes residuals" ON public.b2b_dispatch_residual_closures;
DROP POLICY IF EXISTS "Dispatch operators maintain exceptions" ON public.b2b_dispatch_exceptions;
DROP POLICY IF EXISTS "Dispatch operators record events" ON public.b2b_dispatch_events;

CREATE POLICY "Dispatch operators maintain consignments"
  ON public.b2b_dispatch_consignments FOR ALL TO authenticated
  USING (public.can_manage_b2b_dispatch(auth.uid()))
  WITH CHECK (public.can_manage_b2b_dispatch(auth.uid()));
CREATE POLICY "Dispatch operators maintain consignment lines"
  ON public.b2b_dispatch_consignment_lines FOR ALL TO authenticated
  USING (public.can_manage_b2b_dispatch(auth.uid()))
  WITH CHECK (public.can_manage_b2b_dispatch(auth.uid()));
CREATE POLICY "Dispatch operators maintain handoffs"
  ON public.b2b_dispatch_handoffs FOR ALL TO authenticated
  USING (public.can_manage_b2b_dispatch(auth.uid()))
  WITH CHECK (public.can_manage_b2b_dispatch(auth.uid()));
CREATE POLICY "Dispatch operators maintain handoff lines"
  ON public.b2b_dispatch_handoff_lines FOR ALL TO authenticated
  USING (public.can_manage_b2b_dispatch(auth.uid()))
  WITH CHECK (public.can_manage_b2b_dispatch(auth.uid()));
CREATE POLICY "Dispatch operators maintain cartons"
  ON public.b2b_dispatch_cartons FOR ALL TO authenticated
  USING (public.can_manage_b2b_dispatch(auth.uid()))
  WITH CHECK (public.can_manage_b2b_dispatch(auth.uid()));
CREATE POLICY "Dispatch operators maintain carton items"
  ON public.b2b_dispatch_carton_items FOR ALL TO authenticated
  USING (public.can_manage_b2b_dispatch(auth.uid()))
  WITH CHECK (public.can_manage_b2b_dispatch(auth.uid()));
CREATE POLICY "Dispatch operators record product scan events"
  ON public.b2b_dispatch_product_scan_events FOR INSERT TO authenticated
  WITH CHECK (public.can_manage_b2b_dispatch(auth.uid()) AND scanned_by = auth.uid());
CREATE POLICY "Dispatch operators record quality checks"
  ON public.b2b_dispatch_quality_checks FOR INSERT TO authenticated
  WITH CHECK (public.can_manage_b2b_dispatch(auth.uid()) AND checked_by = auth.uid());
CREATE POLICY "Dispatch operators maintain packing list versions"
  ON public.b2b_dispatch_packing_list_versions FOR ALL TO authenticated
  USING (public.can_manage_b2b_dispatch(auth.uid()) OR public.can_verify_b2b_dispatch_finance(auth.uid()))
  WITH CHECK (public.can_manage_b2b_dispatch(auth.uid()) OR public.can_verify_b2b_dispatch_finance(auth.uid()));
CREATE POLICY "Finance verifies dispatch releases"
  ON public.b2b_dispatch_releases FOR INSERT TO authenticated
  WITH CHECK (public.can_verify_b2b_dispatch_finance(auth.uid()) AND released_by = auth.uid());
CREATE POLICY "Dispatch operators maintain shipments"
  ON public.b2b_dispatch_shipments FOR ALL TO authenticated
  USING (public.can_manage_b2b_dispatch(auth.uid()))
  WITH CHECK (public.can_manage_b2b_dispatch(auth.uid()));
CREATE POLICY "Dispatch operators record load scans"
  ON public.b2b_dispatch_load_scans FOR INSERT TO authenticated
  WITH CHECK (public.can_manage_b2b_dispatch(auth.uid()) AND scanned_by = auth.uid());
CREATE POLICY "Management closes residuals"
  ON public.b2b_dispatch_residual_closures FOR INSERT TO authenticated
  WITH CHECK (
    upper(public.get_user_role(auth.uid())) = ANY (ARRAY['SUPER_ADMIN', 'ADMIN', 'CMD', 'MD', 'OPERATIONS_MANAGER'])
    AND approved_by = auth.uid()
  );
CREATE POLICY "Dispatch operators maintain exceptions"
  ON public.b2b_dispatch_exceptions FOR ALL TO authenticated
  USING (public.can_manage_b2b_dispatch(auth.uid()))
  WITH CHECK (public.can_manage_b2b_dispatch(auth.uid()));
CREATE POLICY "Dispatch operators record events"
  ON public.b2b_dispatch_events FOR INSERT TO authenticated
  WITH CHECK (
    (public.can_manage_b2b_dispatch(auth.uid()) OR public.can_verify_b2b_dispatch_finance(auth.uid()))
    AND actor_id = auth.uid()
    AND upper(actor_role) = upper(public.get_user_role(auth.uid()))
    AND (authority_id IS NULL OR authority_id = auth.uid())
  );

REVOKE ALL ON public.b2b_dispatch_so_line_fulfilment FROM anon;
REVOKE ALL ON public.b2b_dispatch_command_queue FROM anon;
GRANT SELECT ON public.b2b_dispatch_so_line_fulfilment TO authenticated;
GRANT SELECT ON public.b2b_dispatch_command_queue TO authenticated;

COMMENT ON TABLE public.b2b_dispatch_consignments IS
  'Canonical B2B consignment subordinate to an immutable Sales Order; excludes outlet dispatch and internal movements.';
COMMENT ON TABLE public.b2b_dispatch_cartons IS
  'Unique B2B handling units. Lock requires open-carton evidence and NW/GW; reopen is a versioned governed action.';
COMMENT ON VIEW public.b2b_dispatch_so_line_fulfilment IS
  'Original SO quantity, cumulative physically dispatched quantity, approved closure and exact residual by SO line.';
COMMENT ON TABLE public.b2b_dispatch_events IS
  'Append-only SO-to-consignment-to-carton-to-shipment custody and audit history.';

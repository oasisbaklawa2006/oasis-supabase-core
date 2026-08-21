-- Lane 3 (3PGS) 3PGS-B: governed 3PGS fulfilment authority.
--
-- 3PGS-A (discovery) found that "3PGS exists" is true only at the level of
-- its department/routing/UI surfaces (ThirdPartyStore.tsx, third-party.ts,
-- departmentClassifier.ts) and its canonical store identity
-- (b2b_inventory_stores.store_code = '3PGS'). None of that is touched here.
--
-- CORRECTION during 3PGS-B build: b2b_inventory_receipts / receipt_lines are
-- NOT ungoverned. 20260805120000_phase3_inventory_receiving_actions.sql
-- already shipped record_b2b_inventory_receipt / accept_b2b_inventory_receipt
-- (both SECURITY DEFINER, role-gated via can_receive_b2b_inventory,
-- optimistic-locked against inventory_stock_balances.version, append the same
-- inventory_movements ledger) and already REVOKEd direct INSERT/UPDATE/DELETE
-- on both tables from authenticated/anon. This migration REUSES those RPCs
-- verbatim -- it does not duplicate them. The one genuine gap in that inward
-- lifecycle: nothing creates the initial b2b_inventory_receipts row itself
-- (direct INSERT is revoked, and no RPC opens one) -- see
-- create_b2b_inventory_receipt below, the only new inward RPC this migration
-- adds.
--
-- What else was genuinely missing:
--   * No procurement/vendor-shortage table existed for ANY b2b store.
--   * P&A's b2b_assembly_3pgs_requirements (PR B) can be CREATED and marked
--     FULFILLED, but nothing wired that fulfilment to an actual stock
--     movement -- fulfil_assembly_3pgs_requirement was a bare status flag.
--
-- This migration does NOT rebuild 3PGS from zero. reserve_rgs_stock /
-- issue_rgs_stock / acknowledge_rgs_issue (20260817xxxxxx) are already
-- location_code-agnostic and demand_source_type-agnostic ('b2b','pna',
-- 'outlet','internal') -- "RGS" in their name is historical, not a scope
-- restriction. Outlet/B2B/internal 3PGS demand can call them TODAY,
-- unmodified, with location_code IN ('3PGS','PACKING_ASSEMBLY','B2B_RAW').
-- This migration adds only what was genuinely missing:
--   1. create_b2b_inventory_receipt: the one missing step in an otherwise
--      already-governed inward lifecycle (create -> record_b2b_inventory_receipt
--      -> accept_b2b_inventory_receipt, the latter two REUSED unmodified).
--   2. A minimal, generic procurement/shortage-to-vendor bridge (no vendor
--      master, no full ERP purchasing system -- text vendor/ETA fields, as
--      instructed).
--   3. A bridge connecting P&A's b2b_assembly_3pgs_requirements into the
--      SAME reserve_rgs_stock/issue_rgs_stock pipeline every other demand
--      source already uses, with receiver-acknowledged custody transfer
--      finalising the requirement via the EXISTING, unmodified
--      fulfil_assembly_3pgs_requirement (PR B's contract is preserved
--      verbatim; it is called, never altered).
--   4. A read-only priority-ordering view for 3PGS's own operator queue.
--
-- AUTHORITY REUSED, NOT DUPLICATED: can_manage_b2b_inventory (3PGS
-- custodian) and can_receive_b2b_inventory (receiver) -- the same roles
-- already governing RGS and P&A. No new role model introduced.
--
-- ONE BUSINESS RULE DELIBERATELY LEFT UNRESOLVED (see report, not a
-- blocker): automatic PREEMPTIVE reallocation of an already-granted
-- reservation when a higher-priority demand arrives later is NOT
-- implemented. Priority (P&A > Outlet > B2B > Internal) governs the
-- allocation of currently-UNRESERVED stock (both in the priority view
-- below, for operator sequencing, and implicitly in that reserve_rgs_stock
-- only ever allocates what is actually available) and is never used to
-- revoke a reservation already granted to a lower-priority demand. Whether
-- 3PGS should ever support forced preemption is a real operational-policy
-- question with fairness/disruption consequences; this migration does not
-- decide it, and nothing here requires that decision to be safe.

SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '60s';

-- =================================================================================
-- 1. The one missing step in the b2b_inventory_receipts inward lifecycle:
--    opening the receipt itself. record_b2b_inventory_receipt and
--    accept_b2b_inventory_receipt (20260805120000) already govern everything
--    downstream of this and are REUSED unmodified -- see the file header.
-- =================================================================================
CREATE OR REPLACE FUNCTION public.create_b2b_inventory_receipt(
  p_receipt_number text,
  p_receipt_source text,
  p_destination_store_code text,
  p_source_document_type text,
  p_source_document_reference text,
  p_lines jsonb,
  p_correlation_id text,
  p_supplier_id uuid DEFAULT NULL,
  p_production_job_id uuid DEFAULT NULL,
  p_notes text DEFAULT NULL
)
RETURNS public.b2b_inventory_receipts
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_actor_id uuid := auth.uid();
  v_receipt public.b2b_inventory_receipts%ROWTYPE;
  v_line jsonb;
BEGIN
  IF v_actor_id IS NULL OR NOT public.can_receive_b2b_inventory(v_actor_id) THEN
    RAISE EXCEPTION 'Not authorised to create an inventory receipt' USING ERRCODE = '42501';
  END IF;
  IF nullif(btrim(p_correlation_id), '') IS NULL THEN
    RAISE EXCEPTION 'A correlation id is required';
  END IF;
  IF p_lines IS NULL OR jsonb_typeof(p_lines) <> 'array' OR jsonb_array_length(p_lines) = 0 THEN
    RAISE EXCEPTION 'At least one receipt line is required';
  END IF;

  SELECT * INTO v_receipt FROM public.b2b_inventory_receipts WHERE correlation_id = p_correlation_id;
  IF FOUND THEN
    RETURN v_receipt;
  END IF;

  INSERT INTO public.b2b_inventory_receipts (
    receipt_number, receipt_source, destination_store_code, source_document_type,
    source_document_reference, supplier_id, production_job_id, status, correlation_id, notes
  ) VALUES (
    p_receipt_number, p_receipt_source, p_destination_store_code, p_source_document_type,
    p_source_document_reference, p_supplier_id, p_production_job_id, 'expected', p_correlation_id, p_notes
  )
  RETURNING * INTO v_receipt;

  FOR v_line IN SELECT * FROM jsonb_array_elements(p_lines)
  LOOP
    IF NOT (v_line ? 'product_id' AND v_line ? 'sku' AND v_line ? 'expected_qty') THEN
      RAISE EXCEPTION 'Each receipt line requires product_id, sku and expected_qty';
    END IF;
    INSERT INTO public.b2b_inventory_receipt_lines (
      receipt_id, product_id, sku, supplier_batch_lot, expiry_date, expected_qty
    ) VALUES (
      v_receipt.id,
      (v_line->>'product_id')::uuid,
      v_line->>'sku',
      nullif(v_line->>'supplier_batch_lot', ''),
      nullif(v_line->>'expiry_date', '')::date,
      (v_line->>'expected_qty')::numeric
    );
  END LOOP;

  RETURN v_receipt;
END;
$$;

COMMENT ON FUNCTION public.create_b2b_inventory_receipt(text, text, text, text, text, jsonb, text, uuid, uuid, text) IS
  'Opens a governed inward receipt (generic across every b2b store, including 3PGS) with its expected lines. Idempotent by correlation_id.';

REVOKE ALL ON FUNCTION public.create_b2b_inventory_receipt(text, text, text, text, text, jsonb, text, uuid, uuid, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.create_b2b_inventory_receipt(text, text, text, text, text, jsonb, text, uuid, uuid, text) TO authenticated;

-- The Phase 2 "Inventory receivers maintain B2B receipts/lines" FOR ALL
-- policies are already inert (20260805120000 REVOKEd the underlying
-- INSERT/UPDATE/DELETE grants entirely), but leaving a FOR ALL policy in
-- place reads as if raw writes were still governed by RLS alone. Drop the
-- stale policy for clarity; the "Internal staff read" SELECT policy and the
-- REVOKEs already in force are unaffected and unchanged.
DROP POLICY IF EXISTS "Inventory receivers maintain B2B receipts" ON public.b2b_inventory_receipts;
DROP POLICY IF EXISTS "Inventory receivers maintain B2B receipt lines" ON public.b2b_inventory_receipt_lines;

-- =================================================================================
-- 2. Procurement / vendor-shortage bridge (generic across b2b stores).
--    Minimal by design: text vendor/ETA fields, no vendor master table, no
--    purchase-order line items beyond what a single shortage needs -- not a
--    purchasing ERP.
-- =================================================================================
CREATE TABLE IF NOT EXISTS public.b2b_procurement_requirements (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  requirement_number text NOT NULL UNIQUE,
  source_type text NOT NULL,
  source_reference text NOT NULL,
  product_id uuid NOT NULL REFERENCES public.products (id) ON DELETE RESTRICT,
  sku text NOT NULL,
  destination_store_code text NOT NULL REFERENCES public.b2b_inventory_stores (store_code),
  shortage_qty numeric NOT NULL CHECK (shortage_qty > 0),
  fulfilled_qty numeric NOT NULL DEFAULT 0 CHECK (fulfilled_qty >= 0),
  vendor_reference text NULL,
  expected_at timestamptz NULL,
  status text NOT NULL DEFAULT 'open',
  raised_by uuid NULL REFERENCES public.users (id) ON DELETE RESTRICT,
  correlation_id text NOT NULL UNIQUE,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT b2b_procurement_requirements_source_check CHECK (
    source_type IN ('assembly_3pgs_requirement', 'inventory_reservation', 'manual')
  ),
  CONSTRAINT b2b_procurement_requirements_status_check CHECK (
    status IN ('open', 'vendor_assigned', 'partially_received', 'received', 'cancelled')
  ),
  CONSTRAINT b2b_procurement_requirements_fulfil_check CHECK (fulfilled_qty <= shortage_qty)
);

COMMENT ON TABLE public.b2b_procurement_requirements IS
  'Governed shortage-to-vendor bridge for any b2b store (3PGS today). Deliberately minimal: text vendor_reference/expected_at, no vendor master, no purchase-order-line model. Not a purchasing ERP.';

CREATE INDEX IF NOT EXISTS idx_b2b_procurement_requirements_destination
  ON public.b2b_procurement_requirements (destination_store_code, status);

ALTER TABLE public.b2b_procurement_requirements ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "B2B procurement requirements are readable by inventory staff" ON public.b2b_procurement_requirements;
CREATE POLICY "B2B procurement requirements are readable by inventory staff"
  ON public.b2b_procurement_requirements FOR SELECT TO authenticated
  USING (public.can_manage_b2b_inventory(auth.uid()) OR public.can_receive_b2b_inventory(auth.uid()));

-- This is a brand-new table: ALTER DEFAULT PRIVILEGES (legacy baseline) grants
-- ALL on every new public table to anon/authenticated at creation time. RLS
-- with only a SELECT policy already blocks INSERT/UPDATE/DELETE for both
-- roles, but every other governed table in this schema also revokes the
-- table-level grant explicitly (defense in depth, not reliance on RLS alone)
-- -- match that here rather than leaving this one table as the exception.
REVOKE ALL ON public.b2b_procurement_requirements FROM anon;
REVOKE INSERT, UPDATE, DELETE ON public.b2b_procurement_requirements FROM authenticated;

CREATE OR REPLACE FUNCTION public.prevent_b2b_procurement_delete()
RETURNS trigger
LANGUAGE plpgsql
SET search_path TO 'public'
AS $$
BEGIN
  RAISE EXCEPTION 'B2B procurement requirements are retained; cancel with a status change, not deletion (% on %)', TG_OP, TG_TABLE_NAME;
END;
$$;

DROP TRIGGER IF EXISTS trg_b2b_procurement_requirements_no_delete ON public.b2b_procurement_requirements;
CREATE TRIGGER trg_b2b_procurement_requirements_no_delete
  BEFORE DELETE ON public.b2b_procurement_requirements
  FOR EACH ROW EXECUTE FUNCTION public.prevent_b2b_procurement_delete();

-- link_procurement_receipt's double-linkage / idempotency guard: without a
-- durable record of which receipts have already been linked to which
-- requirement, the same receipt could be linked twice (each with a fresh
-- correlation_id) and double-count fulfilled_qty. The primary key IS the
-- guard -- a second link attempt for the same (requirement, receipt) pair
-- fails the existence check below before any UPDATE runs.
CREATE TABLE IF NOT EXISTS public.b2b_procurement_requirement_receipts (
  requirement_id uuid NOT NULL REFERENCES public.b2b_procurement_requirements (id) ON DELETE RESTRICT,
  receipt_id uuid NOT NULL REFERENCES public.b2b_inventory_receipts (id) ON DELETE RESTRICT,
  fulfilled_qty numeric NOT NULL CHECK (fulfilled_qty > 0),
  correlation_id text NOT NULL UNIQUE,
  linked_by uuid NULL REFERENCES public.users (id) ON DELETE RESTRICT,
  linked_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (requirement_id, receipt_id)
);

ALTER TABLE public.b2b_procurement_requirement_receipts ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "B2B procurement requirement receipts are readable by inventory staff" ON public.b2b_procurement_requirement_receipts;
CREATE POLICY "B2B procurement requirement receipts are readable by inventory staff"
  ON public.b2b_procurement_requirement_receipts FOR SELECT TO authenticated
  USING (public.can_manage_b2b_inventory(auth.uid()) OR public.can_receive_b2b_inventory(auth.uid()));

REVOKE ALL ON public.b2b_procurement_requirement_receipts FROM anon;
REVOKE INSERT, UPDATE, DELETE ON public.b2b_procurement_requirement_receipts FROM authenticated;

CREATE OR REPLACE FUNCTION public.create_procurement_requirement(
  p_source_type text,
  p_source_reference text,
  p_product_id uuid,
  p_sku text,
  p_destination_store_code text,
  p_shortage_qty numeric,
  p_correlation_id text
)
RETURNS public.b2b_procurement_requirements
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_actor_id uuid := auth.uid();
  v_requirement public.b2b_procurement_requirements%ROWTYPE;
BEGIN
  IF v_actor_id IS NULL OR NOT public.can_manage_b2b_inventory(v_actor_id) THEN
    RAISE EXCEPTION 'Not authorised to raise a procurement requirement' USING ERRCODE = '42501';
  END IF;
  IF nullif(btrim(p_correlation_id), '') IS NULL THEN
    RAISE EXCEPTION 'A correlation id is required';
  END IF;
  IF p_shortage_qty IS NULL OR p_shortage_qty <= 0 THEN
    RAISE EXCEPTION 'Shortage quantity must be positive';
  END IF;

  SELECT * INTO v_requirement FROM public.b2b_procurement_requirements WHERE correlation_id = p_correlation_id;
  IF FOUND THEN
    RETURN v_requirement;
  END IF;

  INSERT INTO public.b2b_procurement_requirements (
    requirement_number, source_type, source_reference, product_id, sku,
    destination_store_code, shortage_qty, raised_by, correlation_id
  ) VALUES (
    p_source_reference || ':PROC:' || p_correlation_id,
    p_source_type, p_source_reference, p_product_id, p_sku,
    p_destination_store_code, p_shortage_qty, v_actor_id, p_correlation_id
  )
  RETURNING * INTO v_requirement;

  RETURN v_requirement;
END;
$$;

REVOKE ALL ON FUNCTION public.create_procurement_requirement(text, text, uuid, text, text, numeric, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.create_procurement_requirement(text, text, uuid, text, text, numeric, text) TO authenticated;

CREATE OR REPLACE FUNCTION public.assign_procurement_vendor(
  p_requirement_id uuid,
  p_vendor_reference text,
  p_expected_at timestamptz,
  p_correlation_id text
)
RETURNS public.b2b_procurement_requirements
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_actor_id uuid := auth.uid();
  v_requirement public.b2b_procurement_requirements%ROWTYPE;
BEGIN
  IF v_actor_id IS NULL OR NOT public.can_manage_b2b_inventory(v_actor_id) THEN
    RAISE EXCEPTION 'Not authorised to assign a procurement vendor' USING ERRCODE = '42501';
  END IF;
  IF nullif(btrim(p_vendor_reference), '') IS NULL THEN
    RAISE EXCEPTION 'A vendor reference is required';
  END IF;

  SELECT * INTO v_requirement FROM public.b2b_procurement_requirements WHERE id = p_requirement_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Procurement requirement not found'; END IF;
  IF v_requirement.status NOT IN ('open', 'vendor_assigned') THEN
    RAISE EXCEPTION 'Procurement requirement is not open for vendor assignment';
  END IF;

  UPDATE public.b2b_procurement_requirements
  SET vendor_reference = p_vendor_reference, expected_at = p_expected_at,
      status = 'vendor_assigned', updated_at = now()
  WHERE id = p_requirement_id
  RETURNING * INTO v_requirement;

  RETURN v_requirement;
END;
$$;

REVOKE ALL ON FUNCTION public.assign_procurement_vendor(uuid, text, timestamptz, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.assign_procurement_vendor(uuid, text, timestamptz, text) TO authenticated;

-- link_procurement_receipt: records that an ACCEPTED b2b_inventory_receipt
-- (via accept_b2b_receipt_lines above) satisfied some or all of a
-- procurement requirement. Does not itself move any stock -- acceptance
-- already did that; this is bookkeeping linkage only.
CREATE OR REPLACE FUNCTION public.link_procurement_receipt(
  p_requirement_id uuid,
  p_receipt_id uuid,
  p_fulfilled_qty numeric,
  p_correlation_id text
)
RETURNS public.b2b_procurement_requirements
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_actor_id uuid := auth.uid();
  v_requirement public.b2b_procurement_requirements%ROWTYPE;
  v_receipt public.b2b_inventory_receipts%ROWTYPE;
BEGIN
  IF v_actor_id IS NULL OR NOT public.can_manage_b2b_inventory(v_actor_id) THEN
    RAISE EXCEPTION 'Not authorised to link a procurement receipt' USING ERRCODE = '42501';
  END IF;
  IF nullif(btrim(p_correlation_id), '') IS NULL THEN
    RAISE EXCEPTION 'A correlation id is required';
  END IF;
  IF p_fulfilled_qty IS NULL OR p_fulfilled_qty <= 0 THEN
    RAISE EXCEPTION 'Fulfilled quantity must be positive';
  END IF;

  -- Idempotent replay AND double-linkage protection: a (requirement, receipt)
  -- pair can only ever be linked once, by primary key, regardless of
  -- correlation_id -- this is what actually prevents the same receipt from
  -- fulfilling the same requirement twice.
  IF EXISTS (
    SELECT 1 FROM public.b2b_procurement_requirement_receipts
    WHERE requirement_id = p_requirement_id AND receipt_id = p_receipt_id
  ) THEN
    SELECT * INTO v_requirement FROM public.b2b_procurement_requirements WHERE id = p_requirement_id;
    RETURN v_requirement;
  END IF;

  SELECT * INTO v_receipt FROM public.b2b_inventory_receipts WHERE id = p_receipt_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Receipt not found'; END IF;
  IF v_receipt.status NOT IN ('accepted', 'partially_accepted') THEN
    RAISE EXCEPTION 'Only an accepted or partially accepted receipt can be linked to a procurement requirement';
  END IF;

  SELECT * INTO v_requirement FROM public.b2b_procurement_requirements WHERE id = p_requirement_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Procurement requirement not found'; END IF;
  IF v_requirement.status IN ('received', 'cancelled') THEN
    RAISE EXCEPTION 'Procurement requirement is already % and cannot accept a new receipt linkage', v_requirement.status;
  END IF;
  IF v_requirement.fulfilled_qty + p_fulfilled_qty > v_requirement.shortage_qty THEN
    RAISE EXCEPTION 'Linked fulfilled quantity would exceed the procurement shortage';
  END IF;

  INSERT INTO public.b2b_procurement_requirement_receipts (
    requirement_id, receipt_id, fulfilled_qty, correlation_id, linked_by
  ) VALUES (
    p_requirement_id, p_receipt_id, p_fulfilled_qty, p_correlation_id, v_actor_id
  );

  UPDATE public.b2b_procurement_requirements
  SET fulfilled_qty = fulfilled_qty + p_fulfilled_qty,
      status = CASE WHEN fulfilled_qty + p_fulfilled_qty >= shortage_qty THEN 'received' ELSE 'partially_received' END,
      updated_at = now()
  WHERE id = p_requirement_id
  RETURNING * INTO v_requirement;

  RETURN v_requirement;
END;
$$;

REVOKE ALL ON FUNCTION public.link_procurement_receipt(uuid, uuid, numeric, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.link_procurement_receipt(uuid, uuid, numeric, text) TO authenticated;

-- =================================================================================
-- 3. Bridge: P&A's b2b_assembly_3pgs_requirements into the SAME
--    reserve_rgs_stock / issue_rgs_stock pipeline every other 3PGS demand
--    source (outlet/b2b/internal) already uses unmodified. Finalises via
--    the EXISTING, UNCHANGED fulfil_assembly_3pgs_requirement (PR B).
-- =================================================================================
CREATE OR REPLACE FUNCTION public.reserve_3pgs_requirement_stock(
  p_requirement_id uuid,
  p_priority text,
  p_correlation_id text
)
RETURNS public.inventory_reservations
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_actor_id uuid := auth.uid();
  v_requirement public.b2b_assembly_3pgs_requirements%ROWTYPE;
  v_reservation public.inventory_reservations%ROWTYPE;
  v_already_reserved numeric;
  v_target_qty numeric;
BEGIN
  IF v_actor_id IS NULL OR NOT public.can_manage_b2b_inventory(v_actor_id) THEN
    RAISE EXCEPTION 'Not authorised to reserve 3PGS stock against a requirement' USING ERRCODE = '42501';
  END IF;

  -- Idempotent replay by correlation_id, checked before anything else: an
  -- exact retry of an already-successful call must return that reservation,
  -- never be rejected by the already-reserved computation below (which
  -- would otherwise see this very reservation as "already reserved" and
  -- refuse a legitimate replay).
  SELECT * INTO v_reservation FROM public.inventory_reservations WHERE correlation_id = p_correlation_id;
  IF FOUND THEN
    RETURN v_reservation;
  END IF;

  SELECT * INTO v_requirement FROM public.b2b_assembly_3pgs_requirements WHERE id = p_requirement_id;
  IF NOT FOUND THEN RAISE EXCEPTION '3PGS requirement not found'; END IF;
  IF v_requirement.status IN ('fulfilled', 'cancelled') THEN
    RAISE EXCEPTION '3PGS requirement is already % and cannot be reserved against', v_requirement.status;
  END IF;

  -- A requirement can legitimately be reserved against more than once (e.g.
  -- a first call only partially covers it; a second call is made once more
  -- stock arrives). Each such call creates its OWN inventory_reservations
  -- row (reservation_number is suffixed by correlation_id -- see below), so
  -- the amount already held by every still-active prior reservation must be
  -- subtracted here, or a retry/second attempt would over-reserve on top of
  -- stock this requirement already has a claim on.
  SELECT coalesce(sum(reserved_qty - fulfilled_qty - released_qty), 0) INTO v_already_reserved
  FROM public.inventory_reservations
  WHERE demand_source_type = 'pna' AND demand_reference = v_requirement.requirement_number
    AND reservation_status NOT IN ('released', 'expired', 'cancelled');

  v_target_qty := v_requirement.requested_qty - v_requirement.fulfilled_qty - v_already_reserved;
  IF v_target_qty <= 0 THEN
    RAISE EXCEPTION 'The full outstanding quantity for this 3PGS requirement is already reserved';
  END IF;

  -- Suffixed with the correlation id (not the bare requirement_number, which
  -- never changes): a partially-reserved requirement legitimately supports a
  -- second, later reservation attempt once more stock arrives, and
  -- inventory_reservations.reservation_number is unique -- reusing the bare
  -- requirement_number would collide on that constraint for any such retry.
  v_reservation := public.reserve_rgs_stock(
    p_reservation_number := v_requirement.requirement_number || ':' || p_correlation_id,
    p_order_id := NULL,
    p_product_id := v_requirement.product_id,
    p_sku := v_requirement.sku,
    p_requested_qty := v_target_qty,
    p_source_department := '3PGS',
    p_correlation_id := p_correlation_id,
    p_priority := coalesce(p_priority, 'normal'),
    p_location_code := v_requirement.source_store_code,
    p_demand_source_type := 'pna',
    p_demand_reference := v_requirement.requirement_number
  );

  RETURN v_reservation;
END;
$$;

COMMENT ON FUNCTION public.reserve_3pgs_requirement_stock(uuid, text, text) IS
  'Bridges a P&A b2b_assembly_3pgs_requirements row into the existing, unmodified reserve_rgs_stock pipeline -- the SAME reservation mechanism outlet/b2b/internal 3PGS demand already uses. Does not duplicate reservation logic.';

REVOKE ALL ON FUNCTION public.reserve_3pgs_requirement_stock(uuid, text, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.reserve_3pgs_requirement_stock(uuid, text, text) TO authenticated;

CREATE OR REPLACE FUNCTION public.issue_3pgs_requirement_stock(
  p_requirement_id uuid,
  p_reservation_id uuid,
  p_issue_qty numeric,
  p_correlation_id text
)
RETURNS public.rgs_issue_events
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_actor_id uuid := auth.uid();
  v_requirement public.b2b_assembly_3pgs_requirements%ROWTYPE;
  v_reservation public.inventory_reservations%ROWTYPE;
  v_issue public.rgs_issue_events%ROWTYPE;
BEGIN
  IF v_actor_id IS NULL OR NOT public.can_manage_b2b_inventory(v_actor_id) THEN
    RAISE EXCEPTION 'Not authorised to issue 3PGS requirement stock' USING ERRCODE = '42501';
  END IF;

  SELECT * INTO v_requirement FROM public.b2b_assembly_3pgs_requirements WHERE id = p_requirement_id;
  IF NOT FOUND THEN RAISE EXCEPTION '3PGS requirement not found'; END IF;

  -- The caller identifies exactly which reservation to issue against
  -- (matching issue_rgs_stock's own explicit-reservation contract) --
  -- guessing "the most recent one" would orphan any earlier reservation
  -- still holding stock for a requirement reserved against more than once.
  SELECT * INTO v_reservation FROM public.inventory_reservations WHERE id = p_reservation_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Reservation not found'; END IF;
  IF v_reservation.demand_source_type <> 'pna' OR v_reservation.demand_reference <> v_requirement.requirement_number THEN
    RAISE EXCEPTION 'Reservation % does not belong to 3PGS requirement %', p_reservation_id, v_requirement.requirement_number;
  END IF;

  v_issue := public.issue_rgs_stock(
    p_reservation_id := p_reservation_id,
    p_issue_qty := p_issue_qty,
    p_destination_type := 'pna',
    p_destination_reference := v_requirement.requirement_number,
    p_correlation_id := p_correlation_id
  );

  RETURN v_issue;
END;
$$;

COMMENT ON FUNCTION public.issue_3pgs_requirement_stock(uuid, uuid, numeric, text) IS
  'Bridges a P&A 3PGS requirement''s reserved stock into the existing, unmodified issue_rgs_stock pipeline. Takes an explicit p_reservation_id (never guesses the "latest" one) so a requirement reserved against more than once can issue against each reservation individually. Dispatch alone does not fulfil the requirement -- see acknowledge_3pgs_requirement_receipt, which requires a distinct receiver.';

REVOKE ALL ON FUNCTION public.issue_3pgs_requirement_stock(uuid, uuid, numeric, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.issue_3pgs_requirement_stock(uuid, uuid, numeric, text) TO authenticated;

-- acknowledge_3pgs_requirement_receipt: the ONLY path that advances a P&A
-- 3PGS requirement's fulfilled_qty. Calls the EXISTING, UNCHANGED
-- acknowledge_rgs_issue and fulfil_assembly_3pgs_requirement internally --
-- neither PR B's contract nor the shared RGS acknowledgment RPC is
-- modified. Adds one thing neither of those enforces on its own: the
-- receiver must be a DIFFERENT actor than whoever issued it, so P&A can
-- never self-fulfil its own requirement by having the same identity both
-- dispatch and "receive" the stock.
CREATE OR REPLACE FUNCTION public.acknowledge_3pgs_requirement_receipt(
  p_issue_event_id uuid,
  p_received_qty numeric,
  p_correlation_id text
)
RETURNS public.b2b_assembly_3pgs_requirements
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_actor_id uuid := auth.uid();
  v_issue public.rgs_issue_events%ROWTYPE;
  v_requirement public.b2b_assembly_3pgs_requirements%ROWTYPE;
BEGIN
  IF v_actor_id IS NULL OR NOT public.can_receive_b2b_inventory(v_actor_id) THEN
    RAISE EXCEPTION 'Not authorised to acknowledge a 3PGS requirement receipt' USING ERRCODE = '42501';
  END IF;

  SELECT * INTO v_issue FROM public.rgs_issue_events WHERE id = p_issue_event_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Issue event not found'; END IF;
  IF v_actor_id = v_issue.issued_by THEN
    RAISE EXCEPTION 'The 3PGS requirement receiver must be a different actor than whoever issued it -- P&A cannot self-fulfil its own requirement' USING ERRCODE = '42501';
  END IF;
  IF v_issue.destination_type <> 'pna' THEN
    RAISE EXCEPTION 'This issue event was not dispatched against a P&A 3PGS requirement';
  END IF;

  PERFORM public.acknowledge_rgs_issue(p_issue_event_id, p_received_qty, p_correlation_id);

  SELECT * INTO v_requirement
  FROM public.b2b_assembly_3pgs_requirements
  WHERE requirement_number = v_issue.destination_reference;
  IF NOT FOUND THEN RAISE EXCEPTION 'Linked 3PGS requirement not found for %', v_issue.destination_reference; END IF;

  RETURN public.fulfil_assembly_3pgs_requirement(v_requirement.id, p_received_qty, p_correlation_id || ':fulfil');
END;
$$;

COMMENT ON FUNCTION public.acknowledge_3pgs_requirement_receipt(uuid, numeric, text) IS
  'Receiver-side finalisation of a P&A 3PGS requirement. Requires a DIFFERENT actor than the dispatcher (fails closed on self-acknowledgement). Calls the existing acknowledge_rgs_issue and fulfil_assembly_3pgs_requirement RPCs verbatim -- neither is modified by this migration.';

REVOKE ALL ON FUNCTION public.acknowledge_3pgs_requirement_receipt(uuid, numeric, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.acknowledge_3pgs_requirement_receipt(uuid, numeric, text) TO authenticated;

-- =================================================================================
-- 4. Read-only deterministic priority view for 3PGS operator sequencing.
--    Governs allocation of CURRENTLY UNRESERVED stock (display/processing
--    order for operators and reserve_3pgs_requirement_stock/reserve_rgs_stock
--    calls made in this order); never revokes an already-granted reservation.
-- =================================================================================
CREATE OR REPLACE VIEW public.b2b_3pgs_pending_demand_priority
WITH (security_invoker = true)
AS
SELECT
  'pna'::text AS demand_source_type,
  1 AS priority_rank,
  r.id AS demand_id,
  r.requirement_number AS demand_reference,
  r.product_id,
  r.sku,
  r.source_store_code AS location_code,
  (r.requested_qty - r.fulfilled_qty) AS outstanding_qty,
  r.priority,
  r.created_at
FROM public.b2b_assembly_3pgs_requirements r
WHERE r.status IN ('open', 'partially_fulfilled')

UNION ALL

SELECT
  ir.demand_source_type,
  CASE ir.demand_source_type
    WHEN 'outlet' THEN 2
    WHEN 'b2b' THEN 3
    WHEN 'internal' THEN 4
    ELSE 5
  END AS priority_rank,
  ir.id AS demand_id,
  coalesce(ir.demand_reference, ir.reservation_number) AS demand_reference,
  ir.product_id,
  ir.sku,
  ir.location_code,
  (ir.requested_qty - ir.reserved_qty - ir.fulfilled_qty - ir.released_qty) AS outstanding_qty,
  ir.reservation_priority AS priority,
  ir.created_at
FROM public.inventory_reservations ir
WHERE ir.location_code IN ('3PGS', 'PACKING_ASSEMBLY', 'B2B_RAW')
  AND ir.demand_source_type IN ('outlet', 'b2b', 'internal')
  AND ir.reservation_status IN ('pending', 'partially_reserved')
  AND (ir.requested_qty - ir.reserved_qty - ir.fulfilled_qty - ir.released_qty) > 0;

COMMENT ON VIEW public.b2b_3pgs_pending_demand_priority IS
  'Deterministic priority ordering (P&A=1, Outlet=2, B2B=3, Internal=4) of currently-unresolved 3PGS demand, for 3PGS operator sequencing. Read-only: does not allocate, reserve, or preempt anything. security_invoker=true so it is bound by the querying user''s own RLS, not this view definer''s.';

REVOKE ALL ON public.b2b_3pgs_pending_demand_priority FROM PUBLIC, anon;
GRANT SELECT ON public.b2b_3pgs_pending_demand_priority TO authenticated;

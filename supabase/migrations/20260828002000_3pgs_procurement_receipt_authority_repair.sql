-- R4 3PGS launch-readiness: repair the existing vendor-procurement inward
-- bridge without creating a new receipt, stock, supplier, or audit model.
--
-- The existing 3PGS procurement UI has a truthful procurement requirement
-- reference but Core's receipt constraint previously required supplier_id for
-- every supplier receipt even though no canonical supplier UUID exists in the
-- minimal procurement bridge (it deliberately stores vendor_reference text).
-- This migration allows that one governed provenance shape, keeps ordinary
-- supplier receipts unchanged, scopes STORE_3RD_PARTY to 3PGS only, and makes
-- procurement-receipt linkage prove destination/product/accepted-quantity
-- identity server-side.

SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '60s';

-- Keep the established receipt_source vocabulary. A procurement-backed vendor
-- inward is still a supplier receipt; its source document is the governed
-- b2b_procurement_requirements row instead of a not-yet-canonical supplier UUID.
-- Install the replacement as NOT VALID so this migration's transaction only
-- performs the short metadata lock. Historical validation is deliberately in
-- the next migration so the ACCESS EXCLUSIVE lock is released before the
-- validation scan begins. New writes are checked immediately while NOT VALID.
ALTER TABLE public.b2b_inventory_receipts
  DROP CONSTRAINT IF EXISTS b2b_inventory_receipts_source_reference_check;

ALTER TABLE public.b2b_inventory_receipts
  ADD CONSTRAINT b2b_inventory_receipts_source_reference_check CHECK (
    (
      receipt_source = 'supplier'
      AND (
        supplier_id IS NOT NULL
        OR (
          source_document_type = 'procurement_requirement'
          AND nullif(btrim(source_document_reference), '') IS NOT NULL
        )
      )
    )
    OR (receipt_source = 'production' AND production_job_id IS NOT NULL)
    OR receipt_source IN ('opening_balance', 'return_from_assembly')
  ) NOT VALID;

COMMENT ON CONSTRAINT b2b_inventory_receipts_source_reference_check ON public.b2b_inventory_receipts IS
  'Supplier receipts require supplier_id unless they are explicitly backed by a governed procurement_requirement source document; production and existing non-supplier source rules are unchanged.';

-- STORE_3RD_PARTY is the canonical 3PGS operator role. Earlier role-parity
-- work added it to can_manage/can_receive but the later Phase-4 store-scope
-- helper still required a hidden manual assignment. Give the role implicit
-- authority only for the 3PGS store; all other stores still require the
-- existing global-role or explicit-assignment paths.
CREATE OR REPLACE FUNCTION public.can_access_b2b_inventory_store(
  p_user_id uuid,
  p_store_code text,
  p_required_authority text
)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.users u
    WHERE u.id = p_user_id
      AND upper(coalesce(u.role, '')) IN ('SUPER_ADMIN', 'ADMIN', 'OPERATIONS_MANAGER', 'INVENTORY_MANAGER')
  )
  OR EXISTS (
    SELECT 1
    FROM public.users u
    WHERE u.id = p_user_id
      AND upper(coalesce(u.role, '')) = 'STORE_3RD_PARTY'
      AND upper(coalesce(p_store_code, '')) = '3PGS'
  )
  OR EXISTS (
    SELECT 1
    FROM public.b2b_inventory_store_assignments a
    WHERE a.user_id = p_user_id
      AND a.store_code = p_store_code
      AND (p_required_authority = 'receive' OR a.authority = 'manage')
  );
$$;

REVOKE ALL ON FUNCTION public.can_access_b2b_inventory_store(uuid, text, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.can_access_b2b_inventory_store(uuid, text, text) TO authenticated;

COMMENT ON FUNCTION public.can_access_b2b_inventory_store(uuid, text, text) IS
  'Store-scoped B2B inventory authority. STORE_3RD_PARTY has implicit access only to 3PGS; global roles and explicit store assignments retain their prior semantics.';

-- Harden the existing bookkeeping link. Stock movement remains owned by
-- accept_b2b_inventory_receipt; this RPC only links accepted physical truth to
-- the shortage it actually satisfies. Procurement-document receipts without a
-- canonical supplier UUID must bind to the exact requirement number. Existing
-- supplier-identity receipts remain compatible, but still have to match the
-- requirement store, product/SKU and accepted quantity server-side.
--
-- Concurrency contract:
--   * requirement row locks serialize updates to one shortage;
--   * receipt row locks serialize consumption of one physical receipt across
--     different shortages;
--   * replay is checked only after both locks and must match the stored qty;
--   * aggregate links for the receipt/product/SKU may never exceed accepted
--     physical quantity, preventing the same receipt from being double-spent.
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
  v_accepted_qty numeric := 0;
  v_already_linked_qty numeric := 0;
  v_existing_link_qty numeric;
BEGIN
  -- Require an authenticated actor before touching authority-owned rows. The
  -- actual authorization decision is destination-store scoped after the
  -- requirement is locked and its canonical destination is known.
  IF v_actor_id IS NULL THEN
    RAISE EXCEPTION 'Not authorised to link a procurement receipt' USING ERRCODE = '42501';
  END IF;
  IF nullif(btrim(p_correlation_id), '') IS NULL THEN
    RAISE EXCEPTION 'A correlation id is required';
  END IF;
  IF p_fulfilled_qty IS NULL OR p_fulfilled_qty <= 0 THEN
    RAISE EXCEPTION 'Fulfilled quantity must be positive';
  END IF;

  SELECT * INTO v_requirement
  FROM public.b2b_procurement_requirements
  WHERE id = p_requirement_id
  FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Procurement requirement not found'; END IF;

  IF NOT public.can_access_b2b_inventory_store(
    v_actor_id,
    v_requirement.destination_store_code,
    'manage'
  ) THEN
    RAISE EXCEPTION 'Not authorised to link a procurement receipt for store %', v_requirement.destination_store_code
      USING ERRCODE = '42501';
  END IF;

  -- Lock the physical receipt as the shared consumption authority. Different
  -- requirements attempting to consume the same receipt now serialize here.
  SELECT * INTO v_receipt
  FROM public.b2b_inventory_receipts
  WHERE id = p_receipt_id
  FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Receipt not found'; END IF;

  -- Idempotent replay is evaluated only after the requirement + receipt locks.
  -- Same pair + same qty is a no-op; same pair + changed qty is an explicit
  -- conflict rather than a false success.
  SELECT l.fulfilled_qty
  INTO v_existing_link_qty
  FROM public.b2b_procurement_requirement_receipts l
  WHERE l.requirement_id = p_requirement_id
    AND l.receipt_id = p_receipt_id;

  IF FOUND THEN
    IF v_existing_link_qty <> p_fulfilled_qty THEN
      RAISE EXCEPTION 'Procurement receipt replay quantity mismatch: existing %, requested %',
        v_existing_link_qty, p_fulfilled_qty;
    END IF;
    RETURN v_requirement;
  END IF;

  IF v_requirement.status IN ('received', 'cancelled') THEN
    RAISE EXCEPTION 'Procurement requirement is already % and cannot accept a new receipt linkage', v_requirement.status;
  END IF;

  IF v_receipt.status NOT IN ('accepted', 'partially_accepted') THEN
    RAISE EXCEPTION 'Only an accepted or partially accepted receipt can be linked to a procurement requirement';
  END IF;
  IF v_receipt.receipt_source <> 'supplier' THEN
    RAISE EXCEPTION 'Receipt provenance does not match the procurement requirement';
  END IF;
  IF v_receipt.supplier_id IS NULL
     AND NOT (
       v_receipt.source_document_type = 'procurement_requirement'
       AND v_receipt.source_document_reference = v_requirement.requirement_number
     ) THEN
    RAISE EXCEPTION 'Receipt provenance does not match the procurement requirement';
  END IF;
  IF v_receipt.destination_store_code <> v_requirement.destination_store_code THEN
    RAISE EXCEPTION 'Receipt destination does not match the procurement requirement';
  END IF;

  SELECT coalesce(sum(l.accepted_qty), 0)
  INTO v_accepted_qty
  FROM public.b2b_inventory_receipt_lines l
  WHERE l.receipt_id = p_receipt_id
    AND l.product_id = v_requirement.product_id
    AND l.sku = v_requirement.sku;

  -- Count every prior procurement allocation of this same physical receipt for
  -- the same product/SKU, including allocations to other requirements. The
  -- receipt FOR UPDATE lock makes this aggregate stable for the transaction.
  SELECT coalesce(sum(link.fulfilled_qty), 0)
  INTO v_already_linked_qty
  FROM public.b2b_procurement_requirement_receipts link
  JOIN public.b2b_procurement_requirements linked_requirement
    ON linked_requirement.id = link.requirement_id
  WHERE link.receipt_id = p_receipt_id
    AND linked_requirement.product_id = v_requirement.product_id
    AND linked_requirement.sku = v_requirement.sku;

  IF v_already_linked_qty + p_fulfilled_qty > v_accepted_qty THEN
    RAISE EXCEPTION 'Linked fulfilled quantity exceeds remaining accepted matching receipt quantity';
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
      status = CASE
        WHEN fulfilled_qty + p_fulfilled_qty >= shortage_qty THEN 'received'
        ELSE 'partially_received'
      END,
      updated_at = now()
  WHERE id = p_requirement_id
  RETURNING * INTO v_requirement;

  RETURN v_requirement;
END;
$$;

REVOKE ALL ON FUNCTION public.link_procurement_receipt(uuid, uuid, numeric, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.link_procurement_receipt(uuid, uuid, numeric, text) TO authenticated;

COMMENT ON FUNCTION public.link_procurement_receipt(uuid, uuid, numeric, text) IS
  'Links accepted quantity from one locked supplier receipt to a store-scoped procurement requirement. Replays must preserve quantity and aggregate receipt/product allocation cannot exceed accepted physical quantity. Does not move stock.';

-- Phase 2: B2B store fulfilment contract for Central v1.
--
-- Scope is deliberately limited to customer-order fulfilment:
--   * restricted B2B raw materials;
--   * Oasis-manufactured finished goods;
--   * 3PGS packaging/dry-store goods plus selected sourced ready products; and
--   * packing and assembly work.
--
-- This is not an outlet, website-order, procurement, accounting, or full ERP model.

-- =============================================================================
-- A. Canonical stores and item classification
-- =============================================================================

CREATE TABLE IF NOT EXISTS public.b2b_inventory_stores (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  store_code text NOT NULL UNIQUE,
  store_name text NOT NULL,
  store_type text NOT NULL,
  active boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT b2b_inventory_stores_code_check CHECK (
    store_code IN ('B2B_RAW', 'FINISHED_GOODS', '3PGS', 'PACKING_ASSEMBLY')
  ),
  CONSTRAINT b2b_inventory_stores_type_check CHECK (
    store_type IN ('restricted_raw_material', 'finished_goods', 'packaging_and_sourced_goods', 'packing_assembly')
  ),
  CONSTRAINT b2b_inventory_stores_code_type_pair_check CHECK (
    (store_code = 'B2B_RAW' AND store_type = 'restricted_raw_material')
    OR (store_code = 'FINISHED_GOODS' AND store_type = 'finished_goods')
    OR (store_code = '3PGS' AND store_type = 'packaging_and_sourced_goods')
    OR (store_code = 'PACKING_ASSEMBLY' AND store_type = 'packing_assembly')
  )
);

INSERT INTO public.b2b_inventory_stores (store_code, store_name, store_type)
VALUES
  ('B2B_RAW', 'B2B Raw Material Store', 'restricted_raw_material'),
  ('FINISHED_GOODS', 'Finished Goods Store', 'finished_goods'),
  ('3PGS', '3PGS — Packaging Goods & Third-Party Products Store', 'packaging_and_sourced_goods'),
  ('PACKING_ASSEMBLY', 'Packing & Assembly Store', 'packing_assembly')
ON CONFLICT (store_code) DO UPDATE
SET store_name = EXCLUDED.store_name,
    store_type = EXCLUDED.store_type,
    updated_at = now();

CREATE TABLE IF NOT EXISTS public.b2b_inventory_item_profiles (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  product_id uuid NOT NULL REFERENCES public.products (id) ON DELETE RESTRICT,
  sku text NOT NULL,
  item_class text NOT NULL,
  primary_store_code text NOT NULL REFERENCES public.b2b_inventory_stores (store_code) ON UPDATE CASCADE,
  b2b_relevant boolean NOT NULL DEFAULT true,
  b2b_saleable boolean NOT NULL DEFAULT false,
  may_issue_to_production boolean NOT NULL DEFAULT false,
  may_issue_to_assembly boolean NOT NULL DEFAULT false,
  provenance_required boolean NOT NULL DEFAULT false,
  -- Supplier master is not yet canonical in Central. Add an ON DELETE RESTRICT
  -- foreign key when that governed master is introduced; until then this UUID
  -- is external provenance and must be validated by the write RPC.
  supplier_id uuid NULL,
  branding_status text NULL,
  metadata jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT b2b_inventory_item_profiles_unique UNIQUE (product_id, sku),
  CONSTRAINT b2b_inventory_item_class_check CHECK (
    item_class IN (
      'b2b_raw_material',
      'oasis_manufactured_finished',
      'packaging_material',
      'sourced_ready_product',
      'assembly_output'
    )
  ),
  CONSTRAINT b2b_inventory_branding_status_check CHECK (
    branding_status IS NULL OR branding_status IN ('unbranded', 'supplier_brand', 'oasis_brand', 'private_label')
  ),
  CONSTRAINT b2b_inventory_3pgs_class_check CHECK (
    primary_store_code <> '3PGS'
    OR item_class IN ('packaging_material', 'sourced_ready_product')
  ),
  CONSTRAINT b2b_inventory_sourced_provenance_check CHECK (
    item_class <> 'sourced_ready_product' OR provenance_required
  )
);

CREATE INDEX IF NOT EXISTS idx_b2b_inventory_item_profiles_store
  ON public.b2b_inventory_item_profiles (primary_store_code, item_class);

-- =============================================================================
-- B. Source-document receipts and packing/assembly jobs
-- =============================================================================

CREATE TABLE IF NOT EXISTS public.b2b_inventory_receipts (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  receipt_number text NOT NULL UNIQUE,
  receipt_source text NOT NULL,
  destination_store_code text NOT NULL REFERENCES public.b2b_inventory_stores (store_code),
  source_document_type text NOT NULL,
  source_document_reference text NOT NULL,
  -- Same deferred supplier-master dependency as b2b_inventory_item_profiles.
  supplier_id uuid NULL,
  production_job_id uuid NULL REFERENCES public.production_jobs (id) ON DELETE RESTRICT,
  status text NOT NULL DEFAULT 'expected',
  received_by uuid NULL REFERENCES public.users (id) ON DELETE RESTRICT,
  accepted_by uuid NULL REFERENCES public.users (id) ON DELETE RESTRICT,
  received_at timestamptz NULL,
  accepted_at timestamptz NULL,
  correlation_id text NOT NULL,
  notes text NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT b2b_inventory_receipts_source_check CHECK (
    receipt_source IN ('supplier', 'production', 'opening_balance', 'return_from_assembly')
  ),
  CONSTRAINT b2b_inventory_receipts_status_check CHECK (
    status IN ('expected', 'received', 'partially_accepted', 'accepted', 'rejected', 'cancelled')
  ),
  CONSTRAINT b2b_inventory_receipts_source_reference_check CHECK (
    (receipt_source = 'supplier' AND supplier_id IS NOT NULL)
    OR (receipt_source = 'production' AND production_job_id IS NOT NULL)
    OR receipt_source IN ('opening_balance', 'return_from_assembly')
  )
);

CREATE TABLE IF NOT EXISTS public.b2b_inventory_receipt_lines (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  receipt_id uuid NOT NULL REFERENCES public.b2b_inventory_receipts (id) ON DELETE RESTRICT,
  product_id uuid NOT NULL REFERENCES public.products (id) ON DELETE RESTRICT,
  sku text NOT NULL,
  supplier_batch_lot text NULL,
  oasis_batch_lot text NULL,
  expiry_date date NULL,
  expected_qty numeric NOT NULL DEFAULT 0 CHECK (expected_qty >= 0),
  received_qty numeric NOT NULL DEFAULT 0 CHECK (received_qty >= 0),
  accepted_qty numeric NOT NULL DEFAULT 0 CHECK (accepted_qty >= 0),
  damaged_qty numeric NOT NULL DEFAULT 0 CHECK (damaged_qty >= 0),
  rejected_qty numeric NOT NULL DEFAULT 0 CHECK (rejected_qty >= 0),
  shortage_qty numeric GENERATED ALWAYS AS (greatest(expected_qty - received_qty, 0::numeric)) STORED,
  excess_qty numeric GENERATED ALWAYS AS (greatest(received_qty - expected_qty, 0::numeric)) STORED,
  notes text NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT b2b_inventory_receipt_lines_reconcile_check CHECK (
    accepted_qty + damaged_qty + rejected_qty <= received_qty
  )
);

CREATE UNIQUE INDEX IF NOT EXISTS idx_b2b_receipt_lines_supplier_batch
  ON public.b2b_inventory_receipt_lines (
    receipt_id, product_id, sku, supplier_batch_lot
  )
  WHERE supplier_batch_lot IS NOT NULL;

CREATE UNIQUE INDEX IF NOT EXISTS idx_b2b_receipt_lines_oasis_batch
  ON public.b2b_inventory_receipt_lines (
    receipt_id, product_id, sku, oasis_batch_lot
  )
  WHERE oasis_batch_lot IS NOT NULL;

CREATE TABLE IF NOT EXISTS public.b2b_assembly_jobs (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  assembly_job_number text NOT NULL UNIQUE,
  order_id uuid NOT NULL REFERENCES public.orders (id) ON DELETE RESTRICT,
  output_product_id uuid NOT NULL REFERENCES public.products (id) ON DELETE RESTRICT,
  output_sku text NOT NULL,
  planned_qty numeric NOT NULL CHECK (planned_qty > 0),
  completed_qty numeric NOT NULL DEFAULT 0 CHECK (completed_qty >= 0),
  accepted_qty numeric NOT NULL DEFAULT 0 CHECK (accepted_qty >= 0),
  rejected_qty numeric NOT NULL DEFAULT 0 CHECK (rejected_qty >= 0),
  status text NOT NULL DEFAULT 'planned',
  started_by uuid NULL REFERENCES public.users (id) ON DELETE RESTRICT,
  completed_by uuid NULL REFERENCES public.users (id) ON DELETE RESTRICT,
  qc_accepted_by uuid NULL REFERENCES public.users (id) ON DELETE RESTRICT,
  correlation_id text NOT NULL,
  started_at timestamptz NULL,
  completed_at timestamptz NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT b2b_assembly_jobs_status_check CHECK (
    status IN ('planned', 'materials_reserved', 'issued', 'in_progress', 'qc_pending', 'accepted', 'partially_accepted', 'rejected', 'cancelled')
  ),
  CONSTRAINT b2b_assembly_jobs_output_check CHECK (
    accepted_qty + rejected_qty <= completed_qty
  )
);

CREATE INDEX IF NOT EXISTS idx_b2b_assembly_jobs_order
  ON public.b2b_assembly_jobs (order_id, status);

CREATE TABLE IF NOT EXISTS public.b2b_assembly_components (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  assembly_job_id uuid NOT NULL REFERENCES public.b2b_assembly_jobs (id) ON DELETE RESTRICT,
  product_id uuid NOT NULL REFERENCES public.products (id) ON DELETE RESTRICT,
  sku text NOT NULL,
  source_store_code text NOT NULL REFERENCES public.b2b_inventory_stores (store_code),
  required_qty numeric NOT NULL CHECK (required_qty > 0),
  reserved_qty numeric NOT NULL DEFAULT 0 CHECK (reserved_qty >= 0),
  issued_qty numeric NOT NULL DEFAULT 0 CHECK (issued_qty >= 0),
  consumed_qty numeric NOT NULL DEFAULT 0 CHECK (consumed_qty >= 0),
  wasted_qty numeric NOT NULL DEFAULT 0 CHECK (wasted_qty >= 0),
  returned_qty numeric NOT NULL DEFAULT 0 CHECK (returned_qty >= 0),
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT b2b_assembly_components_unique UNIQUE (assembly_job_id, product_id, sku, source_store_code),
  CONSTRAINT b2b_assembly_components_issue_check CHECK (
    consumed_qty + wasted_qty + returned_qty <= issued_qty
  )
);

-- =============================================================================
-- C. Extend the existing append-only ledger for v1 physical operations
-- =============================================================================

ALTER TABLE public.inventory_movements
  ADD COLUMN IF NOT EXISTS source_document_type text NULL,
  ADD COLUMN IF NOT EXISTS source_document_reference text NULL,
  ADD COLUMN IF NOT EXISTS batch_lot text NULL,
  ADD COLUMN IF NOT EXISTS expiry_date date NULL;

ALTER TABLE public.inventory_movements
  DROP CONSTRAINT IF EXISTS inventory_movements_type_check;

ALTER TABLE public.inventory_movements
  ADD CONSTRAINT inventory_movements_type_check CHECK (
    movement_type IN (
      'reservation_created', 'reservation_adjusted', 'reservation_released',
      'reservation_expired', 'reservation_fulfilled', 'inventory_hold',
      'inventory_unhold', 'dispatch_consumption_confirmed',
      'dispatch_consumption_reversed', 'stock_variance_recorded',
      'stock_quarantined', 'stock_quarantine_released',
      'supplier_receipt_accepted', 'production_receipt_accepted',
      'opening_balance_accepted', 'issued_to_production',
      'issued_to_assembly', 'returned_from_assembly',
      'assembly_output_accepted', 'dispatch_issue_confirmed',
      'correction_in', 'correction_out'
    )
  ) NOT VALID;


ALTER TABLE public.inventory_movements
  DROP CONSTRAINT IF EXISTS inventory_movements_physical_source_check;

ALTER TABLE public.inventory_movements
  ADD CONSTRAINT inventory_movements_physical_source_check CHECK (
    movement_type NOT IN (
      'supplier_receipt_accepted', 'production_receipt_accepted',
      'opening_balance_accepted', 'issued_to_production',
      'issued_to_assembly', 'returned_from_assembly',
      'assembly_output_accepted', 'dispatch_issue_confirmed',
      'correction_in', 'correction_out'
    )
    OR (
      nullif(btrim(source_document_type), '') IS NOT NULL
      AND nullif(btrim(source_document_reference), '') IS NOT NULL
    )
  ) NOT VALID;

-- Deliberately leave this constraint NOT VALID for legacy rows. It still
-- governs every new/updated row immediately. A controlled deployment must
-- identify and backfill trustworthy source evidence before separately running:
-- ALTER TABLE public.inventory_movements
--   VALIDATE CONSTRAINT inventory_movements_physical_source_check;

-- State changes are forward-only. Corrections are new ledger movements, not
-- deletion or reopening of accepted operational evidence.
CREATE OR REPLACE FUNCTION public.validate_b2b_receipt_transition()
RETURNS trigger
LANGUAGE plpgsql
SET search_path TO 'public'
AS $$
BEGIN
  IF NEW.status IS NOT DISTINCT FROM OLD.status THEN
    RETURN NEW;
  END IF;

  IF NOT (
    (OLD.status = 'expected' AND NEW.status IN ('received', 'cancelled'))
    OR (OLD.status = 'received' AND NEW.status IN ('partially_accepted', 'accepted', 'rejected'))
    OR (OLD.status = 'partially_accepted' AND NEW.status IN ('accepted', 'rejected'))
  ) THEN
    RAISE EXCEPTION 'Invalid B2B receipt transition: % -> %', OLD.status, NEW.status;
  END IF;
  RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION public.validate_b2b_assembly_transition()
RETURNS trigger
LANGUAGE plpgsql
SET search_path TO 'public'
AS $$
BEGIN
  IF NEW.status IS NOT DISTINCT FROM OLD.status THEN
    RETURN NEW;
  END IF;

  IF NOT (
    (OLD.status = 'planned' AND NEW.status IN ('materials_reserved', 'cancelled'))
    OR (OLD.status = 'materials_reserved' AND NEW.status IN ('issued', 'cancelled'))
    OR (OLD.status = 'issued' AND NEW.status IN ('in_progress', 'cancelled'))
    OR (OLD.status = 'in_progress' AND NEW.status = 'qc_pending')
    OR (OLD.status = 'qc_pending' AND NEW.status IN ('accepted', 'partially_accepted', 'rejected'))
    OR (OLD.status = 'partially_accepted' AND NEW.status IN ('accepted', 'rejected'))
  ) THEN
    RAISE EXCEPTION 'Invalid B2B assembly transition: % -> %', OLD.status, NEW.status;
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_b2b_receipt_transition ON public.b2b_inventory_receipts;
CREATE TRIGGER trg_b2b_receipt_transition
  BEFORE UPDATE OF status ON public.b2b_inventory_receipts
  FOR EACH ROW EXECUTE FUNCTION public.validate_b2b_receipt_transition();

DROP TRIGGER IF EXISTS trg_b2b_assembly_transition ON public.b2b_assembly_jobs;
CREATE TRIGGER trg_b2b_assembly_transition
  BEFORE UPDATE OF status ON public.b2b_assembly_jobs
  FOR EACH ROW EXECUTE FUNCTION public.validate_b2b_assembly_transition();

CREATE OR REPLACE FUNCTION public.prevent_b2b_fulfilment_delete()
RETURNS trigger
LANGUAGE plpgsql
SET search_path TO 'public'
AS $$
BEGIN
  RAISE EXCEPTION 'B2B fulfilment records are retained; cancel or correct with a new movement (% on %)', TG_OP, TG_TABLE_NAME;
END;
$$;

DROP TRIGGER IF EXISTS trg_b2b_stores_no_delete ON public.b2b_inventory_stores;
CREATE TRIGGER trg_b2b_stores_no_delete
  BEFORE DELETE ON public.b2b_inventory_stores
  FOR EACH ROW EXECUTE FUNCTION public.prevent_b2b_fulfilment_delete();
DROP TRIGGER IF EXISTS trg_b2b_item_profiles_no_delete ON public.b2b_inventory_item_profiles;
CREATE TRIGGER trg_b2b_item_profiles_no_delete
  BEFORE DELETE ON public.b2b_inventory_item_profiles
  FOR EACH ROW EXECUTE FUNCTION public.prevent_b2b_fulfilment_delete();
DROP TRIGGER IF EXISTS trg_b2b_receipts_no_delete ON public.b2b_inventory_receipts;
CREATE TRIGGER trg_b2b_receipts_no_delete
  BEFORE DELETE ON public.b2b_inventory_receipts
  FOR EACH ROW EXECUTE FUNCTION public.prevent_b2b_fulfilment_delete();
DROP TRIGGER IF EXISTS trg_b2b_receipt_lines_no_delete ON public.b2b_inventory_receipt_lines;
CREATE TRIGGER trg_b2b_receipt_lines_no_delete
  BEFORE DELETE ON public.b2b_inventory_receipt_lines
  FOR EACH ROW EXECUTE FUNCTION public.prevent_b2b_fulfilment_delete();
DROP TRIGGER IF EXISTS trg_b2b_assembly_jobs_no_delete ON public.b2b_assembly_jobs;
CREATE TRIGGER trg_b2b_assembly_jobs_no_delete
  BEFORE DELETE ON public.b2b_assembly_jobs
  FOR EACH ROW EXECUTE FUNCTION public.prevent_b2b_fulfilment_delete();
DROP TRIGGER IF EXISTS trg_b2b_assembly_components_no_delete ON public.b2b_assembly_components;
CREATE TRIGGER trg_b2b_assembly_components_no_delete
  BEFORE DELETE ON public.b2b_assembly_components
  FOR EACH ROW EXECUTE FUNCTION public.prevent_b2b_fulfilment_delete();

-- =============================================================================
-- D. B2B availability read model
-- =============================================================================

CREATE OR REPLACE VIEW public.b2b_order_availability
WITH (security_invoker = true)
AS
SELECT
  balance.id AS balance_id,
  balance.product_id,
  balance.sku,
  balance.location_code AS store_code,
  profile.item_class,
  profile.b2b_saleable,
  profile.provenance_required,
  balance.available_qty,
  balance.reserved_qty,
  balance.damaged_qty,
  balance.expired_qty,
  balance.quarantine_qty,
  greatest(balance.available_qty, 0::numeric) AS available_for_b2b_qty,
  (balance.damaged_qty + balance.expired_qty + balance.quarantine_qty) AS unavailable_qty,
  balance.version,
  balance.updated_at
FROM public.inventory_stock_balances balance
JOIN public.b2b_inventory_item_profiles profile
  ON profile.product_id = balance.product_id
 AND profile.sku = balance.sku
 AND profile.b2b_relevant
JOIN public.b2b_inventory_stores store
  ON store.store_code = balance.location_code
 AND store.active;

COMMENT ON VIEW public.b2b_order_availability IS
  'Central v1 B2B availability only. available_qty is the existing governed available bucket; damaged, expired and quarantine quantities are reported separately and are not deducted twice.';

-- =============================================================================
-- E. Role-scoped RLS; no customer access and no anonymous access
-- =============================================================================

CREATE OR REPLACE FUNCTION public.can_manage_b2b_inventory(_user_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.users
    WHERE id = _user_id
      AND upper(coalesce(role, '')) = ANY (
        ARRAY[
          'SUPER_ADMIN', 'ADMIN', 'OPERATIONS_MANAGER', 'PRODUCTION_MANAGER',
          'HOD_ASSEMBLY', 'STORE_INCHARGE', 'STORE_READY_GOODS', 'RGS_ADMIN',
          'INVENTORY_MANAGER'
        ]
      )
  );
$$;

CREATE OR REPLACE FUNCTION public.can_receive_b2b_inventory(_user_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.users
    WHERE id = _user_id
      AND upper(coalesce(role, '')) = ANY (
        ARRAY[
          'SUPER_ADMIN', 'ADMIN', 'OPERATIONS_MANAGER', 'PRODUCTION_MANAGER',
          'STORE_INCHARGE', 'STORE_READY_GOODS', 'RGS_ADMIN', 'INVENTORY_MANAGER'
        ]
      )
  );
$$;

REVOKE ALL ON FUNCTION public.can_manage_b2b_inventory(uuid) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.can_receive_b2b_inventory(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.can_manage_b2b_inventory(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.can_receive_b2b_inventory(uuid) TO authenticated;

ALTER TABLE public.b2b_inventory_stores ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.b2b_inventory_item_profiles ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.b2b_inventory_receipts ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.b2b_inventory_receipt_lines ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.b2b_assembly_jobs ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.b2b_assembly_components ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Internal staff read B2B stores" ON public.b2b_inventory_stores;
CREATE POLICY "Internal staff read B2B stores"
  ON public.b2b_inventory_stores FOR SELECT TO authenticated
  USING (public.is_internal_staff(auth.uid()));
DROP POLICY IF EXISTS "Inventory managers maintain B2B stores" ON public.b2b_inventory_stores;
CREATE POLICY "Inventory managers maintain B2B stores"
  ON public.b2b_inventory_stores FOR ALL TO authenticated
  USING (public.can_manage_b2b_inventory(auth.uid()))
  WITH CHECK (public.can_manage_b2b_inventory(auth.uid()));

DROP POLICY IF EXISTS "Internal staff read B2B item profiles" ON public.b2b_inventory_item_profiles;
CREATE POLICY "Internal staff read B2B item profiles"
  ON public.b2b_inventory_item_profiles FOR SELECT TO authenticated
  USING (public.is_internal_staff(auth.uid()));
DROP POLICY IF EXISTS "Inventory managers maintain B2B item profiles" ON public.b2b_inventory_item_profiles;
CREATE POLICY "Inventory managers maintain B2B item profiles"
  ON public.b2b_inventory_item_profiles FOR ALL TO authenticated
  USING (public.can_manage_b2b_inventory(auth.uid()))
  WITH CHECK (public.can_manage_b2b_inventory(auth.uid()));

DROP POLICY IF EXISTS "Internal staff read B2B receipts" ON public.b2b_inventory_receipts;
CREATE POLICY "Internal staff read B2B receipts"
  ON public.b2b_inventory_receipts FOR SELECT TO authenticated
  USING (public.is_internal_staff(auth.uid()));
DROP POLICY IF EXISTS "Inventory receivers maintain B2B receipts" ON public.b2b_inventory_receipts;
CREATE POLICY "Inventory receivers maintain B2B receipts"
  ON public.b2b_inventory_receipts FOR ALL TO authenticated
  USING (public.can_receive_b2b_inventory(auth.uid()))
  WITH CHECK (public.can_receive_b2b_inventory(auth.uid()));

DROP POLICY IF EXISTS "Internal staff read B2B receipt lines" ON public.b2b_inventory_receipt_lines;
CREATE POLICY "Internal staff read B2B receipt lines"
  ON public.b2b_inventory_receipt_lines FOR SELECT TO authenticated
  USING (public.is_internal_staff(auth.uid()));
DROP POLICY IF EXISTS "Inventory receivers maintain B2B receipt lines" ON public.b2b_inventory_receipt_lines;
CREATE POLICY "Inventory receivers maintain B2B receipt lines"
  ON public.b2b_inventory_receipt_lines FOR ALL TO authenticated
  USING (public.can_receive_b2b_inventory(auth.uid()))
  WITH CHECK (public.can_receive_b2b_inventory(auth.uid()));

DROP POLICY IF EXISTS "Internal staff read B2B assembly jobs" ON public.b2b_assembly_jobs;
CREATE POLICY "Internal staff read B2B assembly jobs"
  ON public.b2b_assembly_jobs FOR SELECT TO authenticated
  USING (public.is_internal_staff(auth.uid()));
DROP POLICY IF EXISTS "Assembly operators maintain B2B assembly jobs" ON public.b2b_assembly_jobs;
CREATE POLICY "Assembly operators maintain B2B assembly jobs"
  ON public.b2b_assembly_jobs FOR ALL TO authenticated
  USING (public.can_manage_b2b_inventory(auth.uid()))
  WITH CHECK (public.can_manage_b2b_inventory(auth.uid()));

DROP POLICY IF EXISTS "Internal staff read B2B assembly components" ON public.b2b_assembly_components;
CREATE POLICY "Internal staff read B2B assembly components"
  ON public.b2b_assembly_components FOR SELECT TO authenticated
  USING (public.is_internal_staff(auth.uid()));
DROP POLICY IF EXISTS "Assembly operators maintain B2B assembly components" ON public.b2b_assembly_components;
CREATE POLICY "Assembly operators maintain B2B assembly components"
  ON public.b2b_assembly_components FOR ALL TO authenticated
  USING (public.can_manage_b2b_inventory(auth.uid()))
  WITH CHECK (public.can_manage_b2b_inventory(auth.uid()));

REVOKE ALL ON public.b2b_inventory_stores FROM anon;
REVOKE ALL ON public.b2b_inventory_item_profiles FROM anon;
REVOKE ALL ON public.b2b_inventory_receipts FROM anon;
REVOKE ALL ON public.b2b_inventory_receipt_lines FROM anon;
REVOKE ALL ON public.b2b_assembly_jobs FROM anon;
REVOKE ALL ON public.b2b_assembly_components FROM anon;
REVOKE ALL ON public.b2b_order_availability FROM anon;

COMMENT ON TABLE public.b2b_inventory_stores IS
  'The four Central v1 stores used only for B2B customer-order fulfilment.';
COMMENT ON TABLE public.b2b_inventory_item_profiles IS
  'Classifies B2B-relevant stock and preserves the distinction between 3PGS packaging material and sourced ready products.';
COMMENT ON TABLE public.b2b_inventory_receipts IS
  'Source-document controlled inward header for supplier, production, opening-balance or assembly-return receipts.';
COMMENT ON TABLE public.b2b_assembly_jobs IS
  'Customer-order-linked packing and assembly work; not a general manufacturing planning model.';

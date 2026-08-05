-- Bring the earlier production Phase 2 variant to the reviewed contract.
-- The affected operational tables were verified empty before this migration.

SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '60s';

-- Preserve all legacy staff roles while adding inventory authority.
CREATE OR REPLACE FUNCTION public.is_staff_role(_role text)
RETURNS boolean LANGUAGE sql STABLE SET search_path TO 'public'
AS $$
  SELECT upper(coalesce(_role, '')) = ANY (ARRAY[
    'SUPER_ADMIN', 'ADMIN', 'FINANCE_HEAD', 'FINANCE_EXEC',
    'OPERATIONS_MANAGER', 'PRODUCTION_MANAGER', 'ASSEMBLY_MANAGER',
    'PACKING_SUPERVISOR', 'PROD_MANAGER', 'PROD_ARABIC', 'PROD_CHOCOLATE',
    'PROD_FUSION', 'PROD_NUTS', 'PROD_DATES', 'PROD_BAKERY',
    'HOD_ARABIC', 'HOD_FUSION', 'HOD_CHOCOLATE', 'HOD_DRAGEES',
    'HOD_BAKERY', 'HOD_NUTS', 'HOD_ASSEMBLY',
    'STORE_INCHARGE', 'STORE_READY_GOODS', 'STORE_3RD_PARTY', 'RGS_ADMIN',
    'INVENTORY_MANAGER', 'DISPATCH_MANAGER', 'DISPATCH_INCHARGE',
    'DISPATCH_HEAD', 'SECURITY_CONTROL', 'GATE_SECURITY',
    'SUPPORT_EXECUTIVE', 'SALES_EXECUTIVE'
  ]);
$$;

CREATE OR REPLACE FUNCTION public.is_inventory_manage_role(_role text)
RETURNS boolean LANGUAGE sql IMMUTABLE SET search_path = ''
AS $$
  SELECT upper(coalesce(_role, '')) = ANY (ARRAY[
    'SUPER_ADMIN', 'ADMIN', 'OPERATIONS_MANAGER', 'PRODUCTION_MANAGER',
    'HOD_ASSEMBLY', 'STORE_INCHARGE', 'STORE_READY_GOODS', 'RGS_ADMIN',
    'INVENTORY_MANAGER'
  ]);
$$;

CREATE OR REPLACE FUNCTION public.is_inventory_receive_role(_role text)
RETURNS boolean LANGUAGE sql IMMUTABLE SET search_path = ''
AS $$
  SELECT upper(coalesce(_role, '')) = ANY (ARRAY[
    'SUPER_ADMIN', 'ADMIN', 'OPERATIONS_MANAGER', 'PRODUCTION_MANAGER',
    'STORE_INCHARGE', 'STORE_READY_GOODS', 'RGS_ADMIN', 'INVENTORY_MANAGER'
  ]);
$$;

CREATE OR REPLACE FUNCTION public.can_manage_b2b_inventory(_user_id uuid)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.users
    WHERE id = _user_id AND public.is_inventory_manage_role(role)
  );
$$;

CREATE OR REPLACE FUNCTION public.can_receive_b2b_inventory(_user_id uuid)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.users
    WHERE id = _user_id AND public.is_inventory_receive_role(role)
  );
$$;

REVOKE ALL ON FUNCTION public.can_manage_b2b_inventory(uuid) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.can_receive_b2b_inventory(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.can_manage_b2b_inventory(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.can_receive_b2b_inventory(uuid) TO authenticated;

-- Attach authenticated authorship to the canonical user directory.
ALTER TABLE public.b2b_inventory_receipts
  DROP CONSTRAINT IF EXISTS b2b_inventory_receipts_received_by_fkey,
  DROP CONSTRAINT IF EXISTS b2b_inventory_receipts_accepted_by_fkey,
  ADD CONSTRAINT b2b_inventory_receipts_received_by_fkey
    FOREIGN KEY (received_by) REFERENCES public.users(id) ON DELETE RESTRICT,
  ADD CONSTRAINT b2b_inventory_receipts_accepted_by_fkey
    FOREIGN KEY (accepted_by) REFERENCES public.users(id) ON DELETE RESTRICT;

ALTER TABLE public.b2b_assembly_jobs
  DROP CONSTRAINT IF EXISTS b2b_assembly_jobs_started_by_fkey,
  DROP CONSTRAINT IF EXISTS b2b_assembly_jobs_completed_by_fkey,
  DROP CONSTRAINT IF EXISTS b2b_assembly_jobs_qc_accepted_by_fkey,
  ADD CONSTRAINT b2b_assembly_jobs_started_by_fkey
    FOREIGN KEY (started_by) REFERENCES public.users(id) ON DELETE RESTRICT,
  ADD CONSTRAINT b2b_assembly_jobs_completed_by_fkey
    FOREIGN KEY (completed_by) REFERENCES public.users(id) ON DELETE RESTRICT,
  ADD CONSTRAINT b2b_assembly_jobs_qc_accepted_by_fkey
    FOREIGN KEY (qc_accepted_by) REFERENCES public.users(id) ON DELETE RESTRICT;

-- Unknown batches may repeat before receiving; populated batches must be unique.
DROP INDEX IF EXISTS public.idx_b2b_inventory_receipt_lines_identity;
DROP INDEX IF EXISTS public.idx_b2b_receipt_lines_supplier_batch;
DROP INDEX IF EXISTS public.idx_b2b_receipt_lines_oasis_batch;

CREATE UNIQUE INDEX idx_b2b_receipt_lines_supplier_batch
  ON public.b2b_inventory_receipt_lines
    (receipt_id, product_id, sku, supplier_batch_lot)
  WHERE supplier_batch_lot IS NOT NULL;

CREATE UNIQUE INDEX idx_b2b_receipt_lines_oasis_batch
  ON public.b2b_inventory_receipt_lines
    (receipt_id, product_id, sku, oasis_batch_lot)
  WHERE oasis_batch_lot IS NOT NULL;

ALTER TABLE public.b2b_inventory_receipt_lines
  DROP CONSTRAINT IF EXISTS b2b_inventory_receipt_lines_reconcile_check,
  ADD CONSTRAINT b2b_inventory_receipt_lines_reconcile_check CHECK (
    accepted_qty + damaged_qty + rejected_qty <= received_qty
  );

ALTER TABLE public.b2b_assembly_jobs
  DROP CONSTRAINT IF EXISTS b2b_assembly_jobs_output_check,
  ADD CONSTRAINT b2b_assembly_jobs_output_check CHECK (
    accepted_qty + rejected_qty <= completed_qty
  );

ALTER TABLE public.b2b_assembly_components
  DROP CONSTRAINT IF EXISTS b2b_assembly_components_issue_check,
  ADD CONSTRAINT b2b_assembly_components_issue_check CHECK (
    consumed_qty + wasted_qty + returned_qty <= issued_qty
  );

ALTER TABLE public.inventory_movements
  DROP CONSTRAINT IF EXISTS inventory_movements_physical_source_check,
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

-- Validation is separated from the Phase 2 constraint replacement transaction.
ALTER TABLE public.inventory_movements
  VALIDATE CONSTRAINT inventory_movements_type_check;

CREATE OR REPLACE FUNCTION public.touch_b2b_updated_at()
RETURNS trigger LANGUAGE plpgsql SET search_path = ''
AS $$
BEGIN
  NEW.updated_at := now();
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_b2b_stores_touch ON public.b2b_inventory_stores;
CREATE TRIGGER trg_b2b_stores_touch
  BEFORE UPDATE ON public.b2b_inventory_stores
  FOR EACH ROW EXECUTE FUNCTION public.touch_b2b_updated_at();
DROP TRIGGER IF EXISTS trg_b2b_item_profiles_touch ON public.b2b_inventory_item_profiles;
CREATE TRIGGER trg_b2b_item_profiles_touch
  BEFORE UPDATE ON public.b2b_inventory_item_profiles
  FOR EACH ROW EXECUTE FUNCTION public.touch_b2b_updated_at();
DROP TRIGGER IF EXISTS trg_b2b_receipts_touch ON public.b2b_inventory_receipts;
CREATE TRIGGER trg_b2b_receipts_touch
  BEFORE UPDATE ON public.b2b_inventory_receipts
  FOR EACH ROW EXECUTE FUNCTION public.touch_b2b_updated_at();
DROP TRIGGER IF EXISTS trg_b2b_assembly_jobs_touch ON public.b2b_assembly_jobs;
CREATE TRIGGER trg_b2b_assembly_jobs_touch
  BEFORE UPDATE ON public.b2b_assembly_jobs
  FOR EACH ROW EXECUTE FUNCTION public.touch_b2b_updated_at();

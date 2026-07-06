-- Product Master governance: archive, permanent delete safeguards, audit log.
-- Does not modify inventory, order, finance, or sync pipelines.

-- ---------------------------------------------------------------------------
-- 1) Archive columns on products
-- ---------------------------------------------------------------------------
ALTER TABLE public.products
  ADD COLUMN IF NOT EXISTS archived_at TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS archived_by UUID REFERENCES auth.users(id);

CREATE INDEX IF NOT EXISTS idx_products_archived_at
  ON public.products (archived_at)
  WHERE archived_at IS NOT NULL;

COMMENT ON COLUMN public.products.archived_at IS 'When set, product is archived and hidden from default Product Master views.';
COMMENT ON COLUMN public.products.archived_by IS 'User who archived the product.';

-- ---------------------------------------------------------------------------
-- 2) Governance audit log (archive + permanent delete)
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.product_governance_audit (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  product_id UUID NOT NULL,
  sku TEXT NOT NULL,
  product_name TEXT,
  action TEXT NOT NULL CHECK (action IN ('archived', 'permanently_deleted')),
  performed_by UUID NOT NULL REFERENCES auth.users(id),
  performed_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  metadata JSONB NOT NULL DEFAULT '{}'::jsonb
);

CREATE INDEX IF NOT EXISTS idx_product_governance_audit_product_id
  ON public.product_governance_audit (product_id);

CREATE INDEX IF NOT EXISTS idx_product_governance_audit_performed_at
  ON public.product_governance_audit (performed_at DESC);

ALTER TABLE public.product_governance_audit ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Team read product governance audit" ON public.product_governance_audit;
CREATE POLICY "Team read product governance audit"
  ON public.product_governance_audit
  FOR SELECT
  TO authenticated
  USING (public.is_team_member(auth.uid()));

DROP POLICY IF EXISTS "Team insert product governance audit" ON public.product_governance_audit;
CREATE POLICY "Team insert product governance audit"
  ON public.product_governance_audit
  FOR INSERT
  TO authenticated
  WITH CHECK (public.is_team_member(auth.uid()));

-- ---------------------------------------------------------------------------
-- 3) Super-admin helper (Central roles + Studio owner fallback)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.is_super_admin()
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF auth.uid() IS NULL THEN
    RETURN false;
  END IF;

  IF to_regclass('public.roles') IS NOT NULL AND to_regclass('public.user_role_map') IS NOT NULL THEN
    IF EXISTS (
      SELECT 1
      FROM public.user_role_map urm
      JOIN public.roles r ON r.id = urm.role_id
      WHERE urm.user_id = auth.uid()
        AND r.role_key = 'super_admin'
    ) THEN
      RETURN true;
    END IF;
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.user_roles ur
    WHERE ur.user_id = auth.uid()
      AND ur.role::text = 'owner'
  ) THEN
    RETURN true;
  END IF;

  RETURN false;
END;
$$;

GRANT EXECUTE ON FUNCTION public.is_super_admin() TO authenticated;

-- ---------------------------------------------------------------------------
-- 4) Delete eligibility assessment
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.assess_product_delete_eligibility(_product_id UUID)
RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  p RECORD;
  blockers TEXT[] := ARRAY[]::TEXT[];
  inv_count BIGINT := 0;
  order_count BIGINT := 0;
BEGIN
  SELECT
    id,
    sku,
    COALESCE(product_name, name) AS product_name,
    label_status,
    archived_at
  INTO p
  FROM public.products
  WHERE id = _product_id;

  IF NOT FOUND THEN
    RETURN jsonb_build_object(
      'eligible', false,
      'blockers', jsonb_build_array('Product not found')
    );
  END IF;

  IF COALESCE(p.label_status, 'draft') <> 'draft' THEN
    blockers := array_append(blockers, 'Product label status must be draft');
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.catalogue_versions cv
    WHERE cv.product_id = _product_id
      AND (
        cv.status IN ('synced', 'published', 'approved')
        OR cv.synced_to_central_at IS NOT NULL
      )
  ) THEN
    blockers := array_append(blockers, 'Product has Central sync or approved catalogue snapshot');
  END IF;

  IF to_regclass('public.inventory_transactions') IS NOT NULL THEN
    EXECUTE
      'SELECT COUNT(*)::bigint FROM public.inventory_transactions WHERE product_id = $1'
      INTO inv_count
      USING _product_id;
    IF inv_count > 0 THEN
      blockers := array_append(blockers, 'Product has inventory transactions');
    END IF;
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.catalogue_products cp WHERE cp.product_id = _product_id
  ) THEN
    blockers := array_append(blockers, 'Product is referenced by a catalogue');
  END IF;

  IF to_regclass('public.catalogue_collection_items') IS NOT NULL AND EXISTS (
    SELECT 1 FROM public.catalogue_collection_items cci WHERE cci.product_id = _product_id
  ) THEN
    blockers := array_append(blockers, 'Product is referenced by a catalogue collection');
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.labels l
    WHERE l.product_id = _product_id
      AND (
        COALESCE(l.status, 'draft') <> 'draft'
        OR NULLIF(BTRIM(l.barcode), '') IS NOT NULL
      )
  ) THEN
    blockers := array_append(blockers, 'Product has non-draft label version or barcode');
  END IF;

  IF to_regclass('public.sales_orders') IS NOT NULL THEN
    EXECUTE
      'SELECT COUNT(*)::bigint FROM public.sales_orders WHERE product_id = $1'
      INTO order_count
      USING _product_id;
    IF order_count > 0 THEN
      blockers := array_append(blockers, 'Product is referenced by sales orders');
    END IF;
  ELSIF to_regclass('public.sales_order_lines') IS NOT NULL THEN
    EXECUTE
      'SELECT COUNT(*)::bigint FROM public.sales_order_lines WHERE product_id = $1'
      INTO order_count
      USING _product_id;
    IF order_count > 0 THEN
      blockers := array_append(blockers, 'Product is referenced by sales order lines');
    END IF;
  END IF;

  RETURN jsonb_build_object(
    'eligible', COALESCE(array_length(blockers, 1), 0) = 0,
    'blockers', to_jsonb(blockers),
    'sku', p.sku,
    'product_name', p.product_name
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.assess_product_delete_eligibility(UUID) TO authenticated;

-- ---------------------------------------------------------------------------
-- 5) Archive product (team members)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.archive_product(_product_id UUID)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  p RECORD;
BEGIN
  IF auth.uid() IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'message', 'Authentication required');
  END IF;

  IF NOT public.is_team_member(auth.uid()) THEN
    RETURN jsonb_build_object('ok', false, 'message', 'Team membership required');
  END IF;

  SELECT id, sku, COALESCE(product_name, name) AS product_name, archived_at
  INTO p
  FROM public.products
  WHERE id = _product_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'message', 'Product not found');
  END IF;

  IF p.archived_at IS NOT NULL THEN
    RETURN jsonb_build_object('ok', false, 'message', 'Product is already archived');
  END IF;

  UPDATE public.products
  SET
    is_active = false,
    archived_at = now(),
    archived_by = auth.uid()
  WHERE id = _product_id;

  INSERT INTO public.product_governance_audit (
    product_id, sku, product_name, action, performed_by, metadata
  ) VALUES (
    _product_id,
    p.sku,
    p.product_name,
    'archived',
    auth.uid(),
    jsonb_build_object('source', 'product_master')
  );

  RETURN jsonb_build_object('ok', true, 'message', 'Product archived');
END;
$$;

GRANT EXECUTE ON FUNCTION public.archive_product(UUID) TO authenticated;

-- ---------------------------------------------------------------------------
-- 6) Permanent delete (super admin only, safeguarded)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.permanently_delete_product(_product_id UUID)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  p RECORD;
  assessment JSONB;
  blockers JSONB;
BEGIN
  IF auth.uid() IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'message', 'Authentication required');
  END IF;

  IF NOT public.is_super_admin() THEN
    RETURN jsonb_build_object('ok', false, 'message', 'SUPER_ADMIN role required for permanent delete');
  END IF;

  assessment := public.assess_product_delete_eligibility(_product_id);
  blockers := assessment -> 'blockers';

  IF COALESCE((assessment ->> 'eligible')::boolean, false) IS NOT TRUE THEN
    RETURN jsonb_build_object(
      'ok', false,
      'message', 'Product cannot be permanently deleted',
      'blockers', blockers
    );
  END IF;

  SELECT id, sku, COALESCE(product_name, name) AS product_name
  INTO p
  FROM public.products
  WHERE id = _product_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'message', 'Product not found');
  END IF;

  INSERT INTO public.product_governance_audit (
    product_id, sku, product_name, action, performed_by, metadata
  ) VALUES (
    _product_id,
    p.sku,
    p.product_name,
    'permanently_deleted',
    auth.uid(),
    jsonb_build_object('source', 'product_master', 'assessment', assessment)
  );

  DELETE FROM public.products WHERE id = _product_id;

  RETURN jsonb_build_object('ok', true, 'message', 'Product permanently deleted', 'sku', p.sku);
END;
$$;

GRANT EXECUTE ON FUNCTION public.permanently_delete_product(UUID) TO authenticated;

-- ---------------------------------------------------------------------------
-- 7) RLS: restrict direct DELETE to super admin (RPC is preferred path)
-- ---------------------------------------------------------------------------
DROP POLICY IF EXISTS "Team delete products" ON public.products;
CREATE POLICY "Super admin delete products"
  ON public.products
  FOR DELETE
  TO authenticated
  USING (public.is_super_admin());

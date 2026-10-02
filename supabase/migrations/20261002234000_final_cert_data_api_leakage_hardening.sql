-- FINAL CERTIFICATION — P0 DATA API LEAKAGE HARDENING
--
-- Objective:
--   1. Remove generic authenticated reads of raw commercial Product/Pricing/MOQ truth.
--   2. Remove permissive authenticated reads from Trace ols_* operational tables.
--   3. Remove blanket authenticated ALL authority from legacy public.dispatches.
--   4. Prevent Buyer identities from reading legacy dispatch rows directly.
--   5. Preserve internal-staff compatibility and existing governed RPC/projection authority.
--
-- Buyer commercial access remains through:
--   public.published_products_v1()
--   public.buyer_product_prices_v1()
--
-- Canonical Dispatch/Gate authority remains in the governed Dispatch/Gate RPC programme.
-- This migration does NOT alter commercial data, trace data, orders, cartons or Gate evidence.

BEGIN;

SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '60s';

-- 1. PRODUCT MASTER
ALTER TABLE public.products ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Authenticated read products"
  ON public.products;

DROP POLICY IF EXISTS "Internal staff read products"
  ON public.products;

CREATE POLICY "Internal staff read products"
ON public.products
FOR SELECT
TO authenticated
USING (
  public.is_internal_staff(auth.uid())
);

-- 2. PRODUCT PRICING RULES
ALTER TABLE public.product_pricing_rules ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Authenticated read product_pricing_rules"
  ON public.product_pricing_rules;

DROP POLICY IF EXISTS "Internal staff read product_pricing_rules"
  ON public.product_pricing_rules;

CREATE POLICY "Internal staff read product_pricing_rules"
ON public.product_pricing_rules
FOR SELECT
TO authenticated
USING (
  public.is_internal_staff(auth.uid())
);

-- 3. PRODUCT MOQ RULES
ALTER TABLE public.product_moq_rules ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Authenticated read product_moq_rules"
  ON public.product_moq_rules;

DROP POLICY IF EXISTS "Internal staff read product_moq_rules"
  ON public.product_moq_rules;

CREATE POLICY "Internal staff read product_moq_rules"
ON public.product_moq_rules
FOR SELECT
TO authenticated
USING (
  public.is_internal_staff(auth.uid())
);

-- 4. TRACE — REMOVE PERMISSIVE AUTHENTICATED READ POLICIES
ALTER TABLE public.ols_orders_cache ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.ols_products_cache ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.ols_production_batches ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.ols_production_labels ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS ols_auth_read
  ON public.ols_orders_cache;

DROP POLICY IF EXISTS ols_auth_read
  ON public.ols_products_cache;

DROP POLICY IF EXISTS ols_auth_read
  ON public.ols_production_batches;

DROP POLICY IF EXISTS ols_auth_read
  ON public.ols_production_labels;

-- 5. LEGACY DISPATCH TABLE
ALTER TABLE public.dispatches ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Allow authenticated full access on dispatches"
  ON public.dispatches;

DROP POLICY IF EXISTS "Users can view their dispatches"
  ON public.dispatches;

DROP POLICY IF EXISTS "Admin All Access Dispatches"
  ON public.dispatches;

DROP POLICY IF EXISTS "Internal staff read legacy dispatches"
  ON public.dispatches;

DROP POLICY IF EXISTS "Dispatch authority insert legacy dispatches"
  ON public.dispatches;

DROP POLICY IF EXISTS "Dispatch authority update legacy dispatches"
  ON public.dispatches;

DROP POLICY IF EXISTS "Dispatch authority delete legacy dispatches"
  ON public.dispatches;

CREATE POLICY "Internal staff read legacy dispatches"
ON public.dispatches
FOR SELECT
TO authenticated
USING (
  public.is_internal_staff(auth.uid())
);

CREATE POLICY "Dispatch authority insert legacy dispatches"
ON public.dispatches
FOR INSERT
TO authenticated
WITH CHECK (
  public.is_internal_staff(auth.uid())
  AND upper(coalesce(public.get_user_role(auth.uid()), '')) IN (
    'DISPATCH_MANAGER',
    'DISPATCH_HEAD',
    'DISPATCH_INCHARGE',
    'OPERATIONS_MANAGER',
    'ADMIN',
    'SUPER_ADMIN',
    'OWNER'
  )
);

CREATE POLICY "Dispatch authority update legacy dispatches"
ON public.dispatches
FOR UPDATE
TO authenticated
USING (
  public.is_internal_staff(auth.uid())
  AND upper(coalesce(public.get_user_role(auth.uid()), '')) IN (
    'DISPATCH_MANAGER',
    'DISPATCH_HEAD',
    'DISPATCH_INCHARGE',
    'OPERATIONS_MANAGER',
    'ADMIN',
    'SUPER_ADMIN',
    'OWNER'
  )
)
WITH CHECK (
  public.is_internal_staff(auth.uid())
  AND upper(coalesce(public.get_user_role(auth.uid()), '')) IN (
    'DISPATCH_MANAGER',
    'DISPATCH_HEAD',
    'DISPATCH_INCHARGE',
    'OPERATIONS_MANAGER',
    'ADMIN',
    'SUPER_ADMIN',
    'OWNER'
  )
);

CREATE POLICY "Dispatch authority delete legacy dispatches"
ON public.dispatches
FOR DELETE
TO authenticated
USING (
  public.is_internal_staff(auth.uid())
  AND upper(coalesce(public.get_user_role(auth.uid()), '')) IN (
    'DISPATCH_MANAGER',
    'DISPATCH_HEAD',
    'DISPATCH_INCHARGE',
    'OPERATIONS_MANAGER',
    'ADMIN',
    'SUPER_ADMIN',
    'OWNER'
  )
);

-- 6. DEFENCE IN DEPTH FOR ANON
REVOKE SELECT ON public.products
  FROM anon;

REVOKE SELECT ON public.product_pricing_rules
  FROM anon;

REVOKE SELECT ON public.product_moq_rules
  FROM anon;

REVOKE SELECT ON public.dispatches
  FROM anon;

REVOKE SELECT ON public.ols_orders_cache
  FROM anon;

REVOKE SELECT ON public.ols_products_cache
  FROM anon;

REVOKE SELECT ON public.ols_production_batches
  FROM anon;

REVOKE SELECT ON public.ols_production_labels
  FROM anon;

COMMIT;

-- Target 1: approved launch-blocker Data API leakage lockdown.
-- Remove generic authenticated raw-master/Trace access while preserving
-- internal-staff reads and governed Buyer projections/RPCs.

DROP POLICY IF EXISTS "Authenticated read products" ON public.products;
CREATE POLICY "Internal staff read products"
ON public.products
FOR SELECT
TO authenticated
USING (public.is_internal_staff(auth.uid()));

DROP POLICY IF EXISTS "Authenticated read product_pricing_rules" ON public.product_pricing_rules;
CREATE POLICY "Internal staff read product_pricing_rules"
ON public.product_pricing_rules
FOR SELECT
TO authenticated
USING (public.is_internal_staff(auth.uid()));

DROP POLICY IF EXISTS "Authenticated read product_moq_rules" ON public.product_moq_rules;
CREATE POLICY "Internal staff read product_moq_rules"
ON public.product_moq_rules
FOR SELECT
TO authenticated
USING (public.is_internal_staff(auth.uid()));

DROP POLICY IF EXISTS "Allow authenticated full access on dispatches" ON public.dispatches;

DROP POLICY IF EXISTS ols_auth_read ON public.ols_orders_cache;
DROP POLICY IF EXISTS ols_auth_read ON public.ols_products_cache;
DROP POLICY IF EXISTS ols_auth_read ON public.ols_production_batches;
DROP POLICY IF EXISTS ols_auth_read ON public.ols_production_labels;

-- UAT run #52 / Role C triage (FAIL-GRANT-0098, FAIL-GRANT-0060, FAIL-GRANT-0093,
-- FAIL-QUERY-0087): restore authenticated SELECT on governed B2B inventory and
-- dispatch base tables whose RLS policies already exist, complete the dispatch
-- execution view base-table grant gap left by 20260915190000, add a Sales-only
-- 3PGS satellite demand projection, and repair the PostgREST embed path for the
-- RGS TV low-stock query by adding the missing inventory_stock_balances FK.
--
-- PostgreSQL requires both relation privileges and RLS; without the table-level
-- GRANT, authenticated callers fail with 42501 before row policies run (see
-- 20260915190000_dispatch_execution_view_select_grant.sql). No new write grants.
-- SALES_EXECUTIVE is excluded from direct operator-table reads and receives only
-- the dedicated b2b_3pgs_sales_satellite_demand projection.

-- =================================================================================
-- 1. Predicate: internal staff excluding Sales from operator satellite reads.
-- =================================================================================
CREATE OR REPLACE FUNCTION public.is_b2b_operator_satellite_reader(_user_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT public.is_internal_staff(_user_id)
    AND upper(coalesce(public.get_user_role(_user_id), '')) <> 'SALES_EXECUTIVE';
$$;

COMMENT ON FUNCTION public.is_b2b_operator_satellite_reader(uuid) IS
  'Internal staff who may read governed B2B inventory/dispatch operator tables directly. Excludes SALES_EXECUTIVE, who must use b2b_3pgs_sales_satellite_demand instead.';

REVOKE ALL ON FUNCTION public.is_b2b_operator_satellite_reader(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.is_b2b_operator_satellite_reader(uuid) TO authenticated;

-- =================================================================================
-- 2. Tighten operator-table SELECT policies so Sales cannot bypass the projection.
-- =================================================================================
DROP POLICY IF EXISTS "Internal staff read B2B receipts" ON public.b2b_inventory_receipts;
CREATE POLICY "Internal staff read B2B receipts"
  ON public.b2b_inventory_receipts FOR SELECT TO authenticated
  USING (public.is_b2b_operator_satellite_reader(auth.uid()));

DROP POLICY IF EXISTS "Internal staff read B2B receipt lines" ON public.b2b_inventory_receipt_lines;
CREATE POLICY "Internal staff read B2B receipt lines"
  ON public.b2b_inventory_receipt_lines FOR SELECT TO authenticated
  USING (public.is_b2b_operator_satellite_reader(auth.uid()));

DROP POLICY IF EXISTS "Internal staff read B2B assembly jobs" ON public.b2b_assembly_jobs;
CREATE POLICY "Internal staff read B2B assembly jobs"
  ON public.b2b_assembly_jobs FOR SELECT TO authenticated
  USING (public.is_b2b_operator_satellite_reader(auth.uid()));

DROP POLICY IF EXISTS "Internal staff read B2B assembly components" ON public.b2b_assembly_components;
CREATE POLICY "Internal staff read B2B assembly components"
  ON public.b2b_assembly_components FOR SELECT TO authenticated
  USING (public.is_b2b_operator_satellite_reader(auth.uid()));

DROP POLICY IF EXISTS "Internal staff read Phase 4 GRNs" ON public.b2b_inventory_grns;
CREATE POLICY "Internal staff read Phase 4 GRNs"
  ON public.b2b_inventory_grns FOR SELECT TO authenticated
  USING (public.is_b2b_operator_satellite_reader(auth.uid()));

DROP POLICY IF EXISTS "Staff read stock balances" ON public.inventory_stock_balances;
CREATE POLICY "Staff read stock balances"
  ON public.inventory_stock_balances FOR SELECT TO authenticated
  USING (public.is_b2b_operator_satellite_reader(auth.uid()));

-- Legacy baseline policy "Staff read inventory reservations" allowed every
-- is_internal_staff role (including SALES_EXECUTIVE) with no buyer/company scope.
-- Dispatch hardening added inventory_reservations_internal_read with the same
-- predicate; both are consolidated here into one operator-reader policy.
DROP POLICY IF EXISTS "Staff read inventory reservations" ON public.inventory_reservations;
DROP POLICY IF EXISTS inventory_reservations_internal_read ON public.inventory_reservations;
CREATE POLICY inventory_reservations_internal_read
  ON public.inventory_reservations FOR SELECT TO authenticated
  USING (public.is_b2b_operator_satellite_reader(auth.uid()));

-- =================================================================================
-- 3. Restore authenticated SELECT on governed B2B inventory tables (writes remain revoked).
-- =================================================================================
REVOKE ALL ON TABLE public.b2b_assembly_3pgs_requirements FROM anon;
GRANT SELECT ON TABLE public.b2b_assembly_3pgs_requirements TO authenticated;

REVOKE ALL ON TABLE public.b2b_procurement_requirements FROM anon;
GRANT SELECT ON TABLE public.b2b_procurement_requirements TO authenticated;

REVOKE ALL ON TABLE public.b2b_inventory_receipts FROM anon;
GRANT SELECT ON TABLE public.b2b_inventory_receipts TO authenticated;

REVOKE ALL ON TABLE public.b2b_inventory_receipt_lines FROM anon;
GRANT SELECT ON TABLE public.b2b_inventory_receipt_lines TO authenticated;

REVOKE ALL ON TABLE public.b2b_assembly_jobs FROM anon;
GRANT SELECT ON TABLE public.b2b_assembly_jobs TO authenticated;

REVOKE ALL ON TABLE public.b2b_assembly_components FROM anon;
GRANT SELECT ON TABLE public.b2b_assembly_components TO authenticated;

REVOKE ALL ON TABLE public.b2b_3pgs_packing_material_catalogue FROM PUBLIC, anon;
GRANT SELECT ON TABLE public.b2b_3pgs_packing_material_catalogue TO authenticated;

-- =================================================================================
-- 4. Complete dispatch execution view base-table grants (FAIL-GRANT-0093).
--    security_invoker=true on the view relies on these underlying tables.
-- =================================================================================
REVOKE ALL ON TABLE public.b2b_dispatch_consignments FROM anon;
GRANT SELECT ON TABLE public.b2b_dispatch_consignments TO authenticated;

REVOKE ALL ON TABLE public.b2b_dispatch_consignment_lines FROM anon;
GRANT SELECT ON TABLE public.b2b_dispatch_consignment_lines TO authenticated;

REVOKE ALL ON TABLE public.b2b_dispatch_cartons FROM anon;
GRANT SELECT ON TABLE public.b2b_dispatch_cartons TO authenticated;

REVOKE ALL ON TABLE public.b2b_dispatch_releases FROM anon;
GRANT SELECT ON TABLE public.b2b_dispatch_releases TO authenticated;

REVOKE ALL ON TABLE public.b2b_dispatch_shipments FROM anon;
GRANT SELECT ON TABLE public.b2b_dispatch_shipments TO authenticated;

REVOKE ALL ON TABLE public.b2b_dispatch_exceptions FROM anon;
GRANT SELECT ON TABLE public.b2b_dispatch_exceptions TO authenticated;

-- =================================================================================
-- 5. Sales-only B2B 3PGS satellite demand projection (Central /sales/3pgs-visibility).
--    Definer view with an explicit role gate; exposes only B2B advance-order demand
--    at the 3PGS store. No procurement queue, receipts, assembly operator rows,
--    or stock balances.
-- =================================================================================
CREATE OR REPLACE VIEW public.b2b_3pgs_sales_satellite_demand
WITH (security_invoker = false)
AS
SELECT
  ir.id AS demand_id,
  coalesce(ir.demand_reference, ir.reservation_number) AS demand_reference,
  ir.demand_source_type,
  3 AS priority_rank,
  ir.sku,
  ir.location_code,
  (ir.requested_qty - ir.reserved_qty - ir.fulfilled_qty - ir.released_qty) AS outstanding_qty
FROM public.inventory_reservations ir
WHERE upper(public.get_user_role(auth.uid())) = 'SALES_EXECUTIVE'
  AND ir.location_code = '3PGS'
  AND ir.demand_source_type = 'b2b'
  AND ir.reservation_status IN ('pending', 'partially_reserved')
  AND (ir.requested_qty - ir.reserved_qty - ir.fulfilled_qty - ir.released_qty) > 0;

COMMENT ON VIEW public.b2b_3pgs_sales_satellite_demand IS
  'Sales-only read-only B2B 3PGS satellite projection backing Central /sales/3pgs-visibility. Exposes only outstanding B2B advance-order demand at 3PGS; definer view with an explicit SALES_EXECUTIVE role gate. Operator procurement/assembly/receipt tables remain inaccessible to Sales.';

REVOKE ALL ON TABLE public.b2b_3pgs_sales_satellite_demand FROM PUBLIC, anon;
GRANT SELECT ON TABLE public.b2b_3pgs_sales_satellite_demand TO authenticated;

CREATE OR REPLACE VIEW public.b2b_3pgs_sales_satellite_stock_summary
WITH (security_invoker = false)
AS
SELECT
  coalesce(sum(b.available_qty), 0) AS available_qty,
  coalesce(sum(b.reserved_qty), 0) AS reserved_qty
FROM public.inventory_stock_balances b
WHERE upper(public.get_user_role(auth.uid())) = 'SALES_EXECUTIVE'
  AND b.location_code = '3PGS';

COMMENT ON VIEW public.b2b_3pgs_sales_satellite_stock_summary IS
  'Sales-only aggregate 3PGS stock metrics for Central /sales/3pgs-visibility. Exposes only summed available_qty and reserved_qty at 3PGS; definer view with an explicit SALES_EXECUTIVE role gate.';

REVOKE ALL ON TABLE public.b2b_3pgs_sales_satellite_stock_summary FROM PUBLIC, anon;
GRANT SELECT ON TABLE public.b2b_3pgs_sales_satellite_stock_summary TO authenticated;

-- =================================================================================
-- 6. PostgREST embed repair for RGS TV low-stock query (FAIL-QUERY-0087).
--    Central ReadyGoodsTV.tsx embeds product:products(name,sku) on
--    inventory_stock_balances; PostgREST requires a declared FK relationship.
-- =================================================================================
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_constraint
    WHERE conname = 'inventory_stock_balances_product_id_fkey'
      AND conrelid = 'public.inventory_stock_balances'::regclass
  ) THEN
    ALTER TABLE public.inventory_stock_balances
      ADD CONSTRAINT inventory_stock_balances_product_id_fkey
      FOREIGN KEY (product_id) REFERENCES public.products(id) ON DELETE RESTRICT
      NOT VALID;

    ALTER TABLE public.inventory_stock_balances
      VALIDATE CONSTRAINT inventory_stock_balances_product_id_fkey;
  END IF;
END;
$$;

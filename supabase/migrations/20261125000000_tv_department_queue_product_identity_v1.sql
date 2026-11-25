-- Department TV boards: human-readable product identity (name + SKU).
--
-- public.tv_department_production_queue() returns SETOF public.production_jobs, which carries only product_id, and a
-- TV device identity cannot read public.products (it is not is_internal_staff()). The department boards therefore
-- could not show what is being produced and fell back to an abbreviated UUID.
--
-- This adds a read-only companion RPC rather than changing the existing function: a RETURNS SETOF composite cannot
-- gain columns without DROP FUNCTION, and any caller bound to the production_jobs row shape would break. The existing
-- function, its grants and its contract are untouched.
--
-- Scope and exposure are identical to tv_department_production_queue(): rows only for the caller's own
-- current_tv_group() (an enabled, non-revoked device), never for RGS (which has its own read surface), never for a
-- non-TV caller, and only the same active job statuses. The only addition is products.name and products.sku for the
-- job's own product -- no pricing, cost or any other product column is exposed.

CREATE OR REPLACE FUNCTION public.tv_department_production_queue_named_v1()
RETURNS TABLE (
  id uuid,
  order_id uuid,
  product_id uuid,
  department text,
  assigned_qty numeric,
  produced_qty numeric,
  batch_number text,
  priority text,
  stage text,
  status text,
  created_at timestamptz,
  product_name text,
  sku text
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  WITH caller AS (SELECT public.current_tv_group() AS tv_group)
  SELECT j.id, j.order_id, j.product_id, j.department, j.assigned_qty, j.produced_qty, j.batch_number,
         j.priority, j.stage, j.status, j.created_at, p.name, p.sku
  FROM public.production_jobs j
  CROSS JOIN caller
  LEFT JOIN public.products p ON p.id = j.product_id
  WHERE caller.tv_group IS NOT NULL
    AND caller.tv_group <> 'RGS'
    AND j.canonical_department = caller.tv_group
    AND j.status IN ('pending', 'accepted', 'in_production', 'paused');
$$;
COMMENT ON FUNCTION public.tv_department_production_queue_named_v1() IS
  'Read-only production queue for the caller''s own current_tv_group(), like tv_department_production_queue(), plus the job''s product name and SKU. Empty for any non-TV caller, a disabled/revoked device, or the RGS group. Exposes only products.name and products.sku.';

REVOKE ALL ON FUNCTION public.tv_department_production_queue_named_v1() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.tv_department_production_queue_named_v1() TO authenticated;

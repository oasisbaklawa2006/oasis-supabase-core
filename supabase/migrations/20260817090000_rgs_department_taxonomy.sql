-- RGS + Production reconciliation, step 1: canonical department taxonomy.
--
-- The repository currently carries four independent, unreconciled department
-- vocabularies: products.production_department (free-text CHECK, includes
-- 'dragees', has no 'dates' value and no distinct 'semi-prepared' value),
-- the is_staff_role() RBAC string list (which itself is internally
-- inconsistent -- PROD_DATES exists but the matching HOD role is
-- HOD_DRAGEES), the standalone ols_departments lookup table, and free-text
-- department columns on production_jobs / daily_production_logs /
-- product_bom with no CHECK constraint at all.
--
-- This migration introduces one canonical department master
-- (production_departments) and a pure mapping function
-- (canonical_production_department) that normalises every legacy spelling
-- to it, without renaming or deleting any existing data. Nothing already
-- stored as 'dragees' is rewritten -- it continues to satisfy the existing
-- products_production_department_check constraint and is mapped to the
-- CHOCOLATES_CONFECTIONERY canonical department (dragees are a coated
-- confectionery line; there is no repository or handover evidence of an
-- independently operated Dragees production floor distinct from
-- Chocolates & Confectionery, and the target six-department model in the
-- handover has no separate Dragees department). 'dates' is added as a new,
-- previously-unused value so products can be assigned to it going forward;
-- the PROD_DATES role already existed in is_staff_role() with no
-- corresponding department value to select, so this closes that gap rather
-- than opening a new one.

SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '60s';

-- 1. Canonical department master -------------------------------------------------

CREATE TABLE IF NOT EXISTS public.production_departments (
  code text PRIMARY KEY,
  display_name text NOT NULL,
  legacy_values text[] NOT NULL DEFAULT '{}',
  active boolean NOT NULL DEFAULT true,
  sort_order integer NOT NULL DEFAULT 0,
  created_at timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE public.production_departments IS
  'Canonical six-department production master. Single source of truth for department identity across product mapping, production jobs, RGS shortage routing, TV filtering and RBAC.';
COMMENT ON COLUMN public.production_departments.legacy_values IS
  'Historical products.production_department / production_jobs.department free-text spellings that resolve to this canonical department. Preserved for backward-compatible normalisation; never used to rewrite stored data.';

INSERT INTO public.production_departments (code, display_name, legacy_values, sort_order) VALUES
  ('ARABIC_SWEETS', 'Arabic Sweets Production', ARRAY['arabic_sweets'], 1),
  ('CHOCOLATES_CONFECTIONERY', 'Chocolates & Confectionery', ARRAY['chocolates_confectionery', 'dragees'], 2),
  ('FUSION_SWEETS', 'Fusion Sweets', ARRAY['fusion_sweets'], 3),
  ('SEASONED_NUTS_MIXES', 'Seasoned Nuts & Mixes', ARRAY['seasoned_nuts_mixes'], 4),
  ('DATES', 'Dates', ARRAY['dates'], 5),
  ('BAKERY_SEMI_PREPARED', 'Bakery & Semi-Prepared', ARRAY['bakery', 'semi_prepared'], 6)
ON CONFLICT (code) DO UPDATE SET
  display_name = EXCLUDED.display_name,
  legacy_values = EXCLUDED.legacy_values,
  sort_order = EXCLUDED.sort_order;

ALTER TABLE public.production_departments ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Staff can read production_departments" ON public.production_departments;
CREATE POLICY "Staff can read production_departments" ON public.production_departments
  FOR SELECT TO authenticated
  USING (public.is_internal_staff(auth.uid()));

REVOKE ALL ON public.production_departments FROM anon, authenticated;
GRANT SELECT ON public.production_departments TO authenticated;

-- 2. Canonical mapping function --------------------------------------------------

CREATE OR REPLACE FUNCTION public.canonical_production_department(_value text)
RETURNS text
LANGUAGE sql
STABLE
SET search_path = ''
AS $$
  SELECT code
  FROM public.production_departments
  WHERE lower(_value) = ANY (SELECT lower(unnest(legacy_values)))
     OR upper(_value) = code
  LIMIT 1;
$$;

COMMENT ON FUNCTION public.canonical_production_department(text) IS
  'Normalises any legacy or canonical department spelling to its canonical production_departments.code. Returns NULL for unmapped/unknown input -- callers must treat NULL as "needs reconciliation", never silently default it.';

REVOKE ALL ON FUNCTION public.canonical_production_department(text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.canonical_production_department(text) TO authenticated, service_role;

-- 3. Widen (never narrow) the product department CHECK constraint ---------------
-- Existing 'dragees' rows remain valid and unrewritten; 'dates' becomes an
-- assignable value going forward, closing the gap where the PROD_DATES role
-- already existed with no department value it could ever match.

ALTER TABLE public.products DROP CONSTRAINT IF EXISTS products_production_department_check;
ALTER TABLE public.products ADD CONSTRAINT products_production_department_check
  CHECK (production_department IS NULL OR production_department = ANY (ARRAY[
    'arabic_sweets', 'dragees', 'fusion_sweets', 'chocolates_confectionery',
    'seasoned_nuts_mixes', 'bakery', 'dates', 'semi_prepared'
  ]));

-- 4. Canonical department projection view for products --------------------------

CREATE OR REPLACE VIEW public.products_canonical_department AS
SELECT
  p.id AS product_id,
  p.sku,
  p.production_department AS legacy_production_department,
  public.canonical_production_department(p.production_department) AS canonical_department
FROM public.products p
WHERE p.production_department IS NOT NULL;

ALTER VIEW public.products_canonical_department SET (security_invoker = true);

COMMENT ON VIEW public.products_canonical_department IS
  'Read projection resolving every product with a production department to exactly one canonical_department code. A NULL canonical_department here means a product has a legacy department spelling that production_departments.legacy_values does not yet cover and needs explicit reconciliation, not a silent default.';

GRANT SELECT ON public.products_canonical_department TO authenticated;

-- 5. Close the PROD_DATES / HOD_DRAGEES role-naming gap --------------------------
-- Add HOD_DATES so every canonical department has both a worker-level and an
-- HOD-level role. HOD_DRAGEES is preserved (not renamed) since it may still
-- be assigned to existing user rows; it now explicitly maps to
-- CHOCOLATES_CONFECTIONERY via role_canonical_department() below rather than
-- floating as an unmapped department name.

CREATE OR REPLACE FUNCTION public.is_staff_role(_role text)
RETURNS boolean LANGUAGE sql STABLE SET search_path TO 'public', 'pg_temp'
AS $$
  SELECT upper(coalesce(_role, '')) = ANY (ARRAY[
    'SUPER_ADMIN', 'ADMIN', 'FINANCE_HEAD', 'FINANCE_EXEC',
    'OPERATIONS_MANAGER', 'PRODUCTION_MANAGER', 'ASSEMBLY_MANAGER',
    'PACKING_SUPERVISOR', 'PROD_MANAGER', 'PROD_ARABIC', 'PROD_CHOCOLATE',
    'PROD_FUSION', 'PROD_NUTS', 'PROD_DATES', 'PROD_BAKERY',
    'HOD_ARABIC', 'HOD_FUSION', 'HOD_CHOCOLATE', 'HOD_DRAGEES', 'HOD_DATES',
    'HOD_BAKERY', 'HOD_NUTS', 'HOD_ASSEMBLY',
    'STORE_INCHARGE', 'STORE_READY_GOODS', 'STORE_3RD_PARTY', 'RGS_ADMIN',
    'INVENTORY_MANAGER', 'DISPATCH_MANAGER', 'DISPATCH_INCHARGE',
    'DISPATCH_HEAD', 'SECURITY_CONTROL', 'GATE_SECURITY',
    'SUPPORT_EXECUTIVE', 'SALES_EXECUTIVE'
  ]);
$$;

-- Role -> canonical department, for RLS scoping and TV/handheld routing.
CREATE OR REPLACE FUNCTION public.role_canonical_department(_role text)
RETURNS text
LANGUAGE sql
IMMUTABLE
SET search_path = ''
AS $$
  SELECT CASE upper(coalesce(_role, ''))
    WHEN 'PROD_ARABIC' THEN 'ARABIC_SWEETS'
    WHEN 'HOD_ARABIC' THEN 'ARABIC_SWEETS'
    WHEN 'PROD_CHOCOLATE' THEN 'CHOCOLATES_CONFECTIONERY'
    WHEN 'HOD_CHOCOLATE' THEN 'CHOCOLATES_CONFECTIONERY'
    WHEN 'HOD_DRAGEES' THEN 'CHOCOLATES_CONFECTIONERY'
    WHEN 'PROD_FUSION' THEN 'FUSION_SWEETS'
    WHEN 'HOD_FUSION' THEN 'FUSION_SWEETS'
    WHEN 'PROD_NUTS' THEN 'SEASONED_NUTS_MIXES'
    WHEN 'HOD_NUTS' THEN 'SEASONED_NUTS_MIXES'
    WHEN 'PROD_DATES' THEN 'DATES'
    WHEN 'HOD_DATES' THEN 'DATES'
    WHEN 'PROD_BAKERY' THEN 'BAKERY_SEMI_PREPARED'
    WHEN 'HOD_BAKERY' THEN 'BAKERY_SEMI_PREPARED'
    ELSE NULL
  END;
$$;

COMMENT ON FUNCTION public.role_canonical_department(text) IS
  'Maps a department-scoped staff role to its canonical production_departments.code. Returns NULL for roles that are not department-scoped (e.g. RGS_ADMIN, OPERATIONS_MANAGER).';

REVOKE ALL ON FUNCTION public.role_canonical_department(text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.role_canonical_department(text) TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.user_canonical_department(_user_id uuid)
RETURNS text
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT public.role_canonical_department(role)
  FROM public.users
  WHERE id = _user_id;
$$;

COMMENT ON FUNCTION public.user_canonical_department(uuid) IS
  'Resolves a user to the single canonical department their role is scoped to, or NULL if their role is not department-scoped.';

REVOKE ALL ON FUNCTION public.user_canonical_department(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.user_canonical_department(uuid) TO authenticated;

-- 6. Give production_jobs a governed, trigger-maintained canonical department ---
-- production_jobs.department is free text with no CHECK constraint and
-- pre-existing rows of unknown shape; we do not retroactively rewrite it.
-- Instead we add a nullable canonical_department column, keep it in sync via
-- trigger on every insert/update, and backfill existing rows opportunistically
-- (NULL where the legacy department string cannot be mapped, which is then
-- visible as an explicit reconciliation item rather than a silent guess).

ALTER TABLE public.production_jobs ADD COLUMN IF NOT EXISTS canonical_department text;

CREATE OR REPLACE FUNCTION public.production_jobs_set_canonical_department()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = ''
AS $$
BEGIN
  NEW.canonical_department := public.canonical_production_department(NEW.department);
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS production_jobs_canonical_department_sync ON public.production_jobs;
CREATE TRIGGER production_jobs_canonical_department_sync
  BEFORE INSERT OR UPDATE OF department ON public.production_jobs
  FOR EACH ROW EXECUTE FUNCTION public.production_jobs_set_canonical_department();

UPDATE public.production_jobs
SET canonical_department = public.canonical_production_department(department)
WHERE canonical_department IS DISTINCT FROM public.canonical_production_department(department);

CREATE INDEX IF NOT EXISTS idx_production_jobs_canonical_department
  ON public.production_jobs (canonical_department);

COMMENT ON COLUMN public.production_jobs.canonical_department IS
  'Trigger-maintained normalisation of department into production_departments.code. NULL means the stored department string could not be mapped and needs reconciliation -- do not treat NULL as "no department".';

-- 7. Same treatment for daily_production_logs.department -------------------------

ALTER TABLE public.daily_production_logs ADD COLUMN IF NOT EXISTS canonical_department text;

CREATE OR REPLACE FUNCTION public.daily_production_logs_set_canonical_department()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = ''
AS $$
BEGIN
  NEW.canonical_department := public.canonical_production_department(NEW.department);
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS daily_production_logs_canonical_department_sync ON public.daily_production_logs;
CREATE TRIGGER daily_production_logs_canonical_department_sync
  BEFORE INSERT OR UPDATE OF department ON public.daily_production_logs
  FOR EACH ROW EXECUTE FUNCTION public.daily_production_logs_set_canonical_department();

UPDATE public.daily_production_logs
SET canonical_department = public.canonical_production_department(department)
WHERE canonical_department IS DISTINCT FROM public.canonical_production_department(department);

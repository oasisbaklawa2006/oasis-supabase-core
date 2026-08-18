-- Owner correction (Central issue #368) to the six-department/six-TV model
-- introduced in 20260817090000_rgs_department_taxonomy.sql. Forward-only:
-- that migration is not edited or rewritten.
--
-- Owner's final six-TV estate is:
--   1. Bakery                       -- bakery only, no semi-prepared.
--   2. Chocolate & Confectionery    -- includes Dragees (unchanged).
--   3. Fusion Sweets                -- includes Dates.
--   4. Arabic Sweets                -- includes Arabic sweets, frozen,
--                                      semi-finished and semi-prepared
--                                      sellable material.
--   5. Seasoned Nuts & Mixes        -- unchanged.
--   6. RGS (Ready Goods Store)      -- not a production department, modelled
--                                      separately; unaffected by this file.
--
-- Two corrections to the previous mapping:
--   - 'semi_prepared' moves from BAKERY_SEMI_PREPARED to ARABIC_SWEETS.
--   - 'dates' moves from its own standalone DATES department to FUSION_SWEETS
--     (the prior migration's DATES department is retired; PROD_DATES/
--     HOD_DATES remain real, distinct roles -- same pattern as HOD_DRAGEES --
--     but now route to FUSION_SWEETS instead of a department of their own).
--   - BAKERY_SEMI_PREPARED is renamed to BAKERY (bakery-only) to match.
--
-- No products.production_department raw values are renamed or removed --
-- 'dates', 'semi_prepared' and 'bakery' remain valid raw values; only which
-- canonical department they resolve to changes. No FK references
-- production_departments.code, so updating/removing rows here is safe.

SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '60s';

-- 1. Re-point Arabic Sweets and Fusion Sweets legacy_values ----------------------

UPDATE public.production_departments
SET legacy_values = ARRAY['arabic_sweets', 'semi_prepared']
WHERE code = 'ARABIC_SWEETS';

UPDATE public.production_departments
SET legacy_values = ARRAY['fusion_sweets', 'dates']
WHERE code = 'FUSION_SWEETS';

-- 2. Rename BAKERY_SEMI_PREPARED -> BAKERY, bakery-only --------------------------

UPDATE public.production_departments
SET code = 'BAKERY', display_name = 'Bakery Production', legacy_values = ARRAY['bakery']
WHERE code = 'BAKERY_SEMI_PREPARED';

-- 3. Retire the standalone DATES department --------------------------------------
-- (its sole legacy value 'dates' now belongs to FUSION_SWEETS, set above)

DELETE FROM public.production_departments WHERE code = 'DATES';

-- 4. role_canonical_department(): PROD_DATES/HOD_DATES -> FUSION_SWEETS,
--    PROD_BAKERY/HOD_BAKERY -> BAKERY. Same signature as before -- plain
--    CREATE OR REPLACE is safe (no parameter list change).
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
    WHEN 'PROD_DATES' THEN 'FUSION_SWEETS'
    WHEN 'HOD_DATES' THEN 'FUSION_SWEETS'
    WHEN 'PROD_NUTS' THEN 'SEASONED_NUTS_MIXES'
    WHEN 'HOD_NUTS' THEN 'SEASONED_NUTS_MIXES'
    WHEN 'PROD_BAKERY' THEN 'BAKERY'
    WHEN 'HOD_BAKERY' THEN 'BAKERY'
    ELSE NULL
  END;
$$;

COMMENT ON FUNCTION public.role_canonical_department(text) IS
  'Maps a department-scoped staff role to its canonical production_departments.code. PROD_DATES/HOD_DATES and PROD_BAKERY/HOD_BAKERY are distinct roles (same pattern as HOD_DRAGEES) that route to FUSION_SWEETS and BAKERY respectively per the owner six-TV model (Central issue #368). Returns NULL for roles that are not department-scoped (e.g. RGS_ADMIN, OPERATIONS_MANAGER).';

-- 5. Re-run canonical_department backfill on the two synced tables so already-
--    stored rows pick up the corrected mapping (canonical_production_department
--    itself needs no code change -- it already queries production_departments
--    directly, so it already reflects the corrected data above).

UPDATE public.production_jobs
SET canonical_department = public.canonical_production_department(department)
WHERE canonical_department IS DISTINCT FROM public.canonical_production_department(department);

UPDATE public.daily_production_logs
SET canonical_department = public.canonical_production_department(department)
WHERE canonical_department IS DISTINCT FROM public.canonical_production_department(department);

-- Factory Operations certification defect closure: Production role alias parity.
--
-- Central's canonical Production TV routes and the governed staff provisioning
-- authority both use PROD_ARABIC_SWEETS and PROD_DRAGEES. The currently
-- effective is_staff_role()/role_canonical_department() functions predate those
-- two provisionable aliases and still recognize only PROD_ARABIC plus the
-- HOD_DRAGEES alias. As a result, a correctly provisioned PROD_ARABIC_SWEETS or
-- PROD_DRAGEES identity can pass Central route authorization but fail Core's
-- production_jobs RLS / department-scoped RPC authority.
--
-- This is forward-only role-vocabulary parity. It adds no table grant, no new
-- role, no write path, and deliberately does NOT classify tv_display/tv_ready/
-- tv_assembly as internal staff: Lane 1 B1 device authority requires those TV
-- identities to remain orthogonal to is_internal_staff().

SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '60s';

CREATE OR REPLACE FUNCTION public.is_staff_role(_role text)
RETURNS boolean
LANGUAGE sql
STABLE
SET search_path TO 'public', 'pg_temp'
AS $$
  SELECT upper(coalesce(_role, '')) = ANY (ARRAY[
    'SUPER_ADMIN', 'ADMIN', 'FINANCE_HEAD', 'FINANCE_EXEC',
    'OPERATIONS_MANAGER', 'PRODUCTION_MANAGER', 'ASSEMBLY_MANAGER',
    'PACKING_SUPERVISOR', 'PROD_MANAGER',
    'PROD_ARABIC', 'PROD_ARABIC_SWEETS',
    'PROD_CHOCOLATE', 'PROD_DRAGEES',
    'PROD_FUSION', 'PROD_NUTS', 'PROD_DATES', 'PROD_BAKERY',
    'HOD_ARABIC', 'HOD_FUSION', 'HOD_CHOCOLATE', 'HOD_DRAGEES', 'HOD_DATES',
    'HOD_BAKERY', 'HOD_NUTS', 'HOD_ASSEMBLY',
    'STORE_INCHARGE', 'STORE_READY_GOODS', 'STORE_3RD_PARTY', 'RGS_ADMIN',
    'INVENTORY_MANAGER', 'DISPATCH_MANAGER', 'DISPATCH_INCHARGE',
    'DISPATCH_HEAD', 'SECURITY_CONTROL', 'GATE_SECURITY',
    'SUPPORT_EXECUTIVE', 'SALES_EXECUTIVE'
  ]);
$$;

COMMENT ON FUNCTION public.is_staff_role(text) IS
  'Canonical internal-role predicate shared by application and inventory RLS. Includes the provisioned Production aliases PROD_ARABIC_SWEETS and PROD_DRAGEES; dedicated tv_* device roles remain non-staff by design.';

CREATE OR REPLACE FUNCTION public.role_canonical_department(_role text)
RETURNS text
LANGUAGE sql
IMMUTABLE
SET search_path = ''
AS $$
  SELECT CASE upper(coalesce(_role, ''))
    WHEN 'PROD_ARABIC' THEN 'ARABIC_SWEETS'
    WHEN 'PROD_ARABIC_SWEETS' THEN 'ARABIC_SWEETS'
    WHEN 'HOD_ARABIC' THEN 'ARABIC_SWEETS'
    WHEN 'PROD_CHOCOLATE' THEN 'CHOCOLATES_CONFECTIONERY'
    WHEN 'PROD_DRAGEES' THEN 'CHOCOLATES_CONFECTIONERY'
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
  'Maps a department-scoped staff role to its owner-corrected six-TV canonical Production department. PROD_ARABIC_SWEETS aliases legacy PROD_ARABIC; PROD_DRAGEES shares CHOCOLATES_CONFECTIONERY. Dedicated tv_* device roles remain separate device authority.';

REVOKE ALL ON FUNCTION public.role_canonical_department(text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.role_canonical_department(text) TO authenticated, service_role;

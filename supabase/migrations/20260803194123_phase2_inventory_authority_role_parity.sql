-- Phase 2: align database staff predicates with the inventory authority model.
--
-- This migration changes only role classification. It does not broaden table
-- policies, add write paths, or enable any Wave 2 UI action by itself.

CREATE OR REPLACE FUNCTION public.is_staff_role(_role text)
RETURNS boolean
LANGUAGE sql
STABLE
SET search_path TO 'public'
AS $$
  SELECT upper(coalesce(_role, '')) = ANY (
    ARRAY[
      'SUPER_ADMIN', 'ADMIN', 'FINANCE_HEAD', 'FINANCE_EXEC',
      'OPERATIONS_MANAGER', 'PRODUCTION_MANAGER', 'ASSEMBLY_MANAGER', 'PACKING_SUPERVISOR',
      'PROD_MANAGER', 'PROD_ARABIC', 'PROD_CHOCOLATE', 'PROD_FUSION',
      'PROD_NUTS', 'PROD_DATES', 'PROD_BAKERY',
      'HOD_ARABIC', 'HOD_FUSION', 'HOD_CHOCOLATE', 'HOD_DRAGEES',
      'HOD_BAKERY', 'HOD_NUTS', 'HOD_ASSEMBLY',
      'STORE_INCHARGE', 'STORE_READY_GOODS', 'STORE_3RD_PARTY', 'RGS_ADMIN',
      'INVENTORY_MANAGER',
      'DISPATCH_MANAGER', 'DISPATCH_INCHARGE', 'DISPATCH_HEAD',
      'SECURITY_CONTROL', 'GATE_SECURITY', 'SUPPORT_EXECUTIVE', 'SALES_EXECUTIVE'
    ]
  );
$$;

CREATE OR REPLACE FUNCTION public.is_internal_staff(_user_id uuid)
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
      AND public.is_staff_role(role)
  );
$$;

COMMENT ON FUNCTION public.is_staff_role(text) IS
  'Canonical internal-role predicate shared by application and inventory RLS.';

COMMENT ON FUNCTION public.is_internal_staff(uuid) IS
  'True when the user has a canonical internal role, including inventory authority roles.';

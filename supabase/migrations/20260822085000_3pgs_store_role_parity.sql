-- Central issue #368, Lane 2/3 closure programme. Owner-directed audit found
-- that STORE_3RD_PARTY -- the role Central actually assigns to 3PGS store
-- staff (see Oasis-Baklawa-Central auth-routing.ts) -- was never added to
-- can_manage_b2b_inventory / can_receive_b2b_inventory when those functions
-- were created (20260803194132_phase2_b2b_store_fulfilment_contract.sql).
-- As a result 3PGS's own staff role could not call any of the governed
-- 3PGS RPCs shipped in 20260820100000_3pgs_governed_fulfilment_authority.sql
-- (reserve/issue/acknowledge, procurement bridge). This is a governed-role
-- gap fix only: no new authority, no new table, no RPC redesign -- it adds
-- STORE_3RD_PARTY to the same coarse-grained role lists STORE_INCHARGE and
-- STORE_READY_GOODS already sit in, mirroring the existing pattern exactly.
--
-- Scope is deliberately unchanged from the existing model: this does not
-- grant STORE_3RD_PARTY procurement/vendor-assignment authority beyond what
-- STORE_INCHARGE/STORE_READY_GOODS already hold under can_manage_b2b_inventory
-- today -- narrowing that further is a separate, later decision, not a
-- defect in this fix.

CREATE OR REPLACE FUNCTION public.can_manage_b2b_inventory(_user_id uuid)
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
      AND upper(coalesce(role, '')) = ANY (
        ARRAY[
          'SUPER_ADMIN', 'ADMIN', 'OPERATIONS_MANAGER', 'PRODUCTION_MANAGER',
          'HOD_ASSEMBLY', 'STORE_INCHARGE', 'STORE_READY_GOODS', 'RGS_ADMIN',
          'INVENTORY_MANAGER', 'STORE_3RD_PARTY'
        ]
      )
  );
$$;

CREATE OR REPLACE FUNCTION public.can_receive_b2b_inventory(_user_id uuid)
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
      AND upper(coalesce(role, '')) = ANY (
        ARRAY[
          'SUPER_ADMIN', 'ADMIN', 'OPERATIONS_MANAGER', 'PRODUCTION_MANAGER',
          'STORE_INCHARGE', 'STORE_READY_GOODS', 'RGS_ADMIN', 'INVENTORY_MANAGER',
          'STORE_3RD_PARTY'
        ]
      )
  );
$$;

COMMENT ON FUNCTION public.can_manage_b2b_inventory(uuid) IS
  'Central issue #368: includes STORE_3RD_PARTY as of 2026-08-22 so 3PGS store staff can call governed 3PGS RPCs (reserve/issue/procurement). Grants are unchanged for all other roles.';
COMMENT ON FUNCTION public.can_receive_b2b_inventory(uuid) IS
  'Central issue #368: includes STORE_3RD_PARTY as of 2026-08-22 so 3PGS store staff can call governed 3PGS receipt/acknowledgement RPCs. Grants are unchanged for all other roles.';

-- REVOKE/GRANT are idempotent no-ops here (identical to the original
-- migration) -- restated for auditability alongside the function bodies.
REVOKE ALL ON FUNCTION public.can_manage_b2b_inventory(uuid) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.can_receive_b2b_inventory(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.can_manage_b2b_inventory(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.can_receive_b2b_inventory(uuid) TO authenticated;

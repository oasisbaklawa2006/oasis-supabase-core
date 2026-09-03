-- P0 Dispatch least-privilege companion for Central #456/#458 and Core #182.
--
-- The governed RGS authority already revoked direct authenticated writes to
-- inventory_reservations. This migration makes that invariant explicit at both
-- the privilege and RLS-policy layers, and narrows finance_review_evidence
-- INSERT authority to the same Finance roles used by assert_order_transition_role.
-- Read access remains available to internal staff. Governed SECURITY DEFINER
-- inventory/dispatch RPCs are intentionally unchanged.
--
-- Forward-fix only. No governed business rows are changed.

SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '60s';

ALTER TABLE public.finance_review_evidence ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.inventory_reservations ENABLE ROW LEVEL SECURITY;

-- Retire every direct-write policy on finance evidence so no historical ALL or
-- broad staff policy can OR with the canonical finance-only INSERT policy.
DO $$
DECLARE
  v_policy record;
BEGIN
  FOR v_policy IN
    SELECT policyname
    FROM pg_catalog.pg_policies
    WHERE schemaname = 'public'
      AND tablename = 'finance_review_evidence'
      AND cmd IN ('ALL', 'INSERT', 'UPDATE', 'DELETE')
  LOOP
    EXECUTE format(
      'DROP POLICY IF EXISTS %I ON public.finance_review_evidence',
      v_policy.policyname
    );
  END LOOP;
END;
$$;

DROP POLICY IF EXISTS finance_review_evidence_internal_read
  ON public.finance_review_evidence;
CREATE POLICY finance_review_evidence_internal_read
  ON public.finance_review_evidence
  FOR SELECT TO authenticated
  USING (public.is_internal_staff(auth.uid()));

DROP POLICY IF EXISTS finance_review_evidence_finance_insert
  ON public.finance_review_evidence;
CREATE POLICY finance_review_evidence_finance_insert
  ON public.finance_review_evidence
  FOR INSERT TO authenticated
  WITH CHECK (
    auth.uid() IS NOT NULL
    AND upper(coalesce(public.get_user_role(auth.uid()), '')) = ANY (
      ARRAY['FINANCE_HEAD','FINANCE_EXEC','ADMIN','SUPER_ADMIN','OWNER']::text[]
    )
  );

REVOKE ALL ON TABLE public.finance_review_evidence FROM anon;
REVOKE UPDATE, DELETE ON TABLE public.finance_review_evidence FROM authenticated;
GRANT SELECT, INSERT ON TABLE public.finance_review_evidence TO authenticated;

-- inventory_reservations is RPC-only mutation authority since
-- 20260817100000_rgs_production_governed_authority.sql. Remove any historical
-- write-capable RLS policy as defence in depth and re-assert the table grants.
DO $$
DECLARE
  v_policy record;
BEGIN
  FOR v_policy IN
    SELECT policyname
    FROM pg_catalog.pg_policies
    WHERE schemaname = 'public'
      AND tablename = 'inventory_reservations'
      AND cmd IN ('ALL', 'INSERT', 'UPDATE', 'DELETE')
  LOOP
    EXECUTE format(
      'DROP POLICY IF EXISTS %I ON public.inventory_reservations',
      v_policy.policyname
    );
  END LOOP;
END;
$$;

DROP POLICY IF EXISTS inventory_reservations_internal_read
  ON public.inventory_reservations;
CREATE POLICY inventory_reservations_internal_read
  ON public.inventory_reservations
  FOR SELECT TO authenticated
  USING (public.is_internal_staff(auth.uid()));

REVOKE ALL ON TABLE public.inventory_reservations FROM anon;
REVOKE INSERT, UPDATE, DELETE ON TABLE public.inventory_reservations FROM authenticated;
GRANT SELECT ON TABLE public.inventory_reservations TO authenticated;

COMMENT ON POLICY finance_review_evidence_finance_insert
  ON public.finance_review_evidence IS
  'Direct evidence append is restricted to Finance authority roles; Dispatch roles fail closed.';

COMMENT ON POLICY inventory_reservations_internal_read
  ON public.inventory_reservations IS
  'Reservations remain staff-readable but direct authenticated mutation is revoked; governed RPCs own writes.';

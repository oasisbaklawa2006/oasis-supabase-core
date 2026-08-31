-- Production semantic parity reconciliation after the protected 2026-08-31 release.
--
-- The protected deployment successfully applied every pending migration and reached
-- a zero-pending ledger, then the post-deploy semantic census exposed historical
-- production-only residue. This forward-only migration removes unmanaged residue
-- and makes the stricter production policy shape reproducible from zero-state.
-- It does not roll back or replay any applied migration.

SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '60s';

-- A Wave-1C smoke scratch relation was left in production outside canonical
-- migration authority. It contains no governed business truth and must not exist.
DROP TABLE IF EXISTS public._wave1c_smoke_scratch;

-- Three legacy Finance hold helpers exist only in production history and are not
-- present in canonical Core or Central callers. Current Finance authority is the
-- PF-6C clearance/event chain, so hidden duplicate hold authority is retired.
DROP FUNCTION IF EXISTS public.derive_order_finance_blockers_json(text,text,numeric,numeric,numeric,text);
DROP FUNCTION IF EXISTS public.order_dispatch_finance_hold(text,text,numeric,numeric,numeric);
DROP FUNCTION IF EXISTS public.order_operations_finance_hold(text,text,numeric,numeric);

-- Preserve the narrower production policy posture as canonical zero-state truth.
-- The old single ALL policy on legacy dispatch_cartons is replaced by explicit
-- read/insert/update policies. Delete remains unavailable through RLS.
DROP POLICY IF EXISTS "Staff full access dispatch_cartons" ON public.dispatch_cartons;
DROP POLICY IF EXISTS "Staff insert dispatch_cartons" ON public.dispatch_cartons;
DROP POLICY IF EXISTS "Staff read dispatch_cartons" ON public.dispatch_cartons;
DROP POLICY IF EXISTS "Staff update dispatch_carton_metadata" ON public.dispatch_cartons;
CREATE POLICY "Staff insert dispatch_cartons"
  ON public.dispatch_cartons FOR INSERT TO authenticated
  WITH CHECK (public.is_internal_staff(auth.uid()));
CREATE POLICY "Staff read dispatch_cartons"
  ON public.dispatch_cartons FOR SELECT TO authenticated
  USING (public.is_internal_staff(auth.uid()));
CREATE POLICY "Staff update dispatch_carton_metadata"
  ON public.dispatch_cartons FOR UPDATE TO authenticated
  USING (public.is_internal_staff(auth.uid()))
  WITH CHECK (public.is_internal_staff(auth.uid()));

-- Production already carries these narrower Finance read/manage policies. Make
-- them deterministic in clean replay instead of relying on historical state.
DROP POLICY IF EXISTS "Finance staff manage order payments" ON public.order_payments;
DROP POLICY IF EXISTS "Staff read order payments" ON public.order_payments;
CREATE POLICY "Finance staff manage order payments"
  ON public.order_payments FOR ALL TO authenticated
  USING (
    public.is_internal_staff(auth.uid())
    AND upper(public.get_user_role(auth.uid())) = ANY (
      ARRAY['FINANCE_HEAD','FINANCE_EXEC','ADMIN','SUPER_ADMIN','OWNER']::text[]
    )
  )
  WITH CHECK (
    public.is_internal_staff(auth.uid())
    AND upper(public.get_user_role(auth.uid())) = ANY (
      ARRAY['FINANCE_HEAD','FINANCE_EXEC','ADMIN','SUPER_ADMIN','OWNER']::text[]
    )
  );
CREATE POLICY "Staff read order payments"
  ON public.order_payments FOR SELECT TO authenticated
  USING (
    public.is_internal_staff(auth.uid())
    OR public.get_user_role(auth.uid()) = ANY (ARRAY['admin','super_admin']::text[])
  );

DROP POLICY IF EXISTS "Staff update non-governed order fields" ON public.orders;
CREATE POLICY "Staff update non-governed order fields"
  ON public.orders FOR UPDATE TO authenticated
  USING (
    public.is_internal_staff(auth.uid())
    AND upper(public.get_user_role(auth.uid())) <> 'SALES_EXECUTIVE'
  )
  WITH CHECK (
    public.is_internal_staff(auth.uid())
    AND upper(public.get_user_role(auth.uid())) <> 'SALES_EXECUTIVE'
  );

-- The broad authenticated audit insert policy exists only in clean local replay;
-- production correctly does not expose it. Keep audit writes behind governed RPCs.
DROP POLICY IF EXISTS "Authenticated can insert audit_logs" ON public.audit_logs;

-- Reproduce production's legacy gate supporting index and explicit FK delete
-- behavior so clean replay and the deployed schema have the same structure.
CREATE INDEX IF NOT EXISTS idx_dispatch_gate_decisions_carton
  ON public.dispatch_gate_decisions(carton_id, decided_at DESC);

ALTER TABLE public.dispatch_gate_decisions
  DROP CONSTRAINT IF EXISTS dispatch_gate_decisions_carton_id_fkey,
  DROP CONSTRAINT IF EXISTS dispatch_gate_decisions_order_id_fkey,
  DROP CONSTRAINT IF EXISTS dispatch_gate_decisions_scan_evidence_id_fkey;
ALTER TABLE public.dispatch_gate_decisions
  ADD CONSTRAINT dispatch_gate_decisions_carton_id_fkey
    FOREIGN KEY (carton_id) REFERENCES public.dispatch_cartons(id) ON DELETE RESTRICT,
  ADD CONSTRAINT dispatch_gate_decisions_order_id_fkey
    FOREIGN KEY (order_id) REFERENCES public.orders(id) ON DELETE RESTRICT,
  ADD CONSTRAINT dispatch_gate_decisions_scan_evidence_id_fkey
    FOREIGN KEY (scan_evidence_id) REFERENCES public.operational_scan_records(id) ON DELETE RESTRICT;

COMMENT ON INDEX public.idx_dispatch_gate_decisions_carton IS
  'Canonical legacy gate lookup index retained only for compatibility while governed B2B gate authority is primary.';

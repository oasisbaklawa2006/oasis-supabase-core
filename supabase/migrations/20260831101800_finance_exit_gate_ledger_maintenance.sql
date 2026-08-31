-- Finance Exit gate-ledger maintainability hardening.
SET LOCAL lock_timeout='5s';
SET LOCAL statement_timeout='60s';

CREATE INDEX IF NOT EXISTS idx_b2b_dispatch_gate_decisions_order_decision
  ON public.b2b_dispatch_gate_decisions(order_id, decision);
CREATE INDEX IF NOT EXISTS idx_b2b_dispatch_gate_decisions_carton_created
  ON public.b2b_dispatch_gate_decisions(carton_id, created_at DESC);

-- Refresh named ACL objects idempotently in the forward migration rather than
-- rewriting the already preview-applied authority migration.
DROP POLICY IF EXISTS b2b_dispatch_gate_decisions_internal_read
  ON public.b2b_dispatch_gate_decisions;
CREATE POLICY b2b_dispatch_gate_decisions_internal_read
  ON public.b2b_dispatch_gate_decisions
  FOR SELECT TO authenticated
  USING(public.is_internal_staff(auth.uid()));

DROP TRIGGER IF EXISTS trg_b2b_dispatch_gate_decisions_immutable
  ON public.b2b_dispatch_gate_decisions;
CREATE TRIGGER trg_b2b_dispatch_gate_decisions_immutable
  BEFORE UPDATE OR DELETE ON public.b2b_dispatch_gate_decisions
  FOR EACH ROW EXECUTE FUNCTION public.prevent_dispatch_gate_decision_mutation();

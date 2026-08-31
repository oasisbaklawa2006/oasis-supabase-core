-- Finance Exit schema compatibility for 20260830143700_gate_dispatch_proof_authority.sql.
-- Structured canonical Finance/DPL/E-way lineage is additive audit metadata only.

SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '60s';

ALTER TABLE public.dispatch_gate_decisions
  ADD COLUMN IF NOT EXISTS metadata jsonb NOT NULL DEFAULT '{}'::jsonb;

COMMENT ON COLUMN public.dispatch_gate_decisions.metadata IS
  'Structured immutable-at-event lineage for Finance Dispatch Clearance, final invoice, final DPL receipt, E-way evidence and related physical-gate facts.';

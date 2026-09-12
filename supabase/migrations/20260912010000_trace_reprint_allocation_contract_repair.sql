-- Trace #38 reprint approval single-use guard.
-- Intentionally non-transactional: concurrent index creation preserves writes
-- to the durable allocation ledger while the uniqueness guard is built.
CREATE UNIQUE INDEX CONCURRENTLY IF NOT EXISTS ols_trace_reprint_allocations_approval_request_uniq
  ON public.ols_trace_reprint_allocations(approval_request_id)
  WHERE approval_request_id IS NOT NULL;

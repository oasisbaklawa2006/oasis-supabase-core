-- Trace #38 / Core #291: non-transactional uniqueness guard for governed
-- reprint print-log execution. Kept as a single CONCURRENTLY statement for
-- Supabase zero-state replay compatibility.
CREATE UNIQUE INDEX CONCURRENTLY IF NOT EXISTS ols_print_logs_reprint_request_uniq
  ON public.ols_print_logs(reprint_request_id)
  WHERE reprint_request_id IS NOT NULL;

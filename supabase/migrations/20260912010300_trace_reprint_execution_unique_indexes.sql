-- Trace #38 / Core #291: non-transactional uniqueness guards for governed
-- reprint execution. Concurrent index creation preserves writes while the
-- durable request-id claims are added.
CREATE UNIQUE INDEX CONCURRENTLY IF NOT EXISTS ols_print_jobs_reprint_request_uniq
  ON public.ols_print_jobs(reprint_request_id)
  WHERE reprint_request_id IS NOT NULL;

CREATE UNIQUE INDEX CONCURRENTLY IF NOT EXISTS ols_print_logs_reprint_request_uniq
  ON public.ols_print_logs(reprint_request_id)
  WHERE reprint_request_id IS NOT NULL;

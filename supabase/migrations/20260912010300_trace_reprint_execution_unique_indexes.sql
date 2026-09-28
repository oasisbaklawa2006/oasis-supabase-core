-- Trace #38 / Core #291: non-transactional uniqueness guard for governed
-- reprint print-job execution. Keep this migration to exactly one concurrent
-- index statement so Supabase zero-state replay does not pipeline it with a
-- second CONCURRENTLY command.
CREATE UNIQUE INDEX CONCURRENTLY IF NOT EXISTS ols_print_jobs_reprint_request_uniq
  ON public.ols_print_jobs(reprint_request_id)
  WHERE reprint_request_id IS NOT NULL;

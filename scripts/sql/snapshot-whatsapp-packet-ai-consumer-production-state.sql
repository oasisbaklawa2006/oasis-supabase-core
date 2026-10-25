-- Read-only production state snapshot used to prove a consumer release changed no data.
-- Run with `psql -X -q -t -A -v ON_ERROR_STOP=1 -f`: emits exactly one JSON object. Counts and timestamps only: no message content, identity or secret.
BEGIN READ ONLY;
SELECT json_build_object(
  'capturedAt', clock_timestamp(),
  'dispatchJobStates', (
    SELECT coalesce(json_object_agg(state, n), '{}'::json)
    FROM (SELECT state, count(*) AS n FROM public.whatsapp_packet_ai_dispatch_jobs GROUP BY state) s
  ),
  'dispatchJobsMaxUpdatedAt', (SELECT max(updated_at) FROM public.whatsapp_packet_ai_dispatch_jobs),
  'dispatchJobsMaxAttemptCount', (SELECT max(attempt_count) FROM public.whatsapp_packet_ai_dispatch_jobs),
  'deadLetterEntries', (SELECT count(*) FROM public.dead_letter_entries),
  'caseOutboundAttempts', (SELECT count(*) FROM public.whatsapp_case_outbound_attempts),
  'caseEvents', (SELECT count(*) FROM public.whatsapp_case_events),
  'departmentTasks', (SELECT count(*) FROM public.whatsapp_case_department_tasks),
  'activeConsumerCronJobs', (
    SELECT count(*) FROM cron.job WHERE active AND command ILIKE '%consumer_tick%'
  )
);
ROLLBACK;

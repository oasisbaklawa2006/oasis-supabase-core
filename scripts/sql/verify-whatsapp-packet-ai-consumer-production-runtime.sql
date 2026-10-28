-- Read-only production runtime certification for whatsapp-packet-ai-consumer (Core #454).
-- Asserts the database prerequisites the scheduler-facing consumer depends on. It runs as the
-- least-privilege release role (oasis_drift_watch_ro): catalog and migration-ledger reads only. That role
-- cannot read the cron or vault schemas or any business table, and this file must not need to. Cron
-- liveness is proven by the tick observation, not here. No RPC with side effects is called.
BEGIN READ ONLY;
SELECT 1 / CASE WHEN
  to_regprocedure('public.claim_whatsapp_packet_ai_dispatch_job(integer)') IS NOT NULL
  AND has_function_privilege('service_role', 'public.claim_whatsapp_packet_ai_dispatch_job(integer)', 'EXECUTE')
  AND NOT has_function_privilege('anon', 'public.claim_whatsapp_packet_ai_dispatch_job(integer)', 'EXECUTE')
  AND NOT has_function_privilege('authenticated', 'public.claim_whatsapp_packet_ai_dispatch_job(integer)', 'EXECUTE')
  AND to_regprocedure('public.verify_whatsapp_packet_ai_consumer_secret(text)') IS NOT NULL
  AND has_function_privilege('service_role', 'public.verify_whatsapp_packet_ai_consumer_secret(text)', 'EXECUTE')
  AND NOT has_function_privilege('anon', 'public.verify_whatsapp_packet_ai_consumer_secret(text)', 'EXECUTE')
  AND NOT has_function_privilege('authenticated', 'public.verify_whatsapp_packet_ai_consumer_secret(text)', 'EXECUTE')
  AND to_regprocedure('public.whatsapp_run_packet_ai_consumer_tick()') IS NOT NULL
  AND to_regclass('public.whatsapp_packet_ai_dispatch_jobs') IS NOT NULL
THEN 1 ELSE 0 END AS whatsapp_packet_ai_consumer_prerequisites_pass;

-- Database releases the bundled worker depends on (bounded retry, materialization,
-- Phase 2 task dedupe and follow-up receipt).
SELECT 1 / CASE WHEN (
  SELECT count(*) FROM supabase_migrations.schema_migrations
  WHERE version IN ('20261022120000', '20261022121000', '20261024130000')
) = 3 THEN 1 ELSE 0 END AS whatsapp_packet_ai_consumer_migration_prerequisites_pass;
SELECT 'WHATSAPP_PACKET_AI_CONSUMER_PRODUCTION_RUNTIME_OK';
ROLLBACK;

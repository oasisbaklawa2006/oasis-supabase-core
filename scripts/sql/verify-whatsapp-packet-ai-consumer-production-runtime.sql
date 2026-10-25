-- Read-only production runtime certification for whatsapp-packet-ai-consumer (Core #454).
-- Asserts the database prerequisites the scheduler-facing consumer depends on. It reads
-- catalog, ledger and cron metadata only: no vault secret value, no business row and no
-- job is read or changed, and no RPC with side effects is called.
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

-- The scheduler invokes the consumer through this tick function; it must stay scheduled.
SELECT 1 / CASE WHEN EXISTS (
  SELECT 1 FROM cron.job
  WHERE jobname = 'whatsapp-packet-ai-consumer-minute'
    AND active
    AND schedule = '* * * * *'
    AND command = 'select public.whatsapp_run_packet_ai_consumer_tick();'
) THEN 1 ELSE 0 END AS whatsapp_packet_ai_consumer_cron_active;

-- Names only (never decrypted values): the tick fails closed without both secrets.
SELECT 1 / CASE WHEN (
  SELECT count(DISTINCT name) FROM vault.secrets
  WHERE name IN ('whatsapp_packet_ai_consumer_url_v1', 'whatsapp_packet_ai_consumer_v1')
) = 2 THEN 1 ELSE 0 END AS whatsapp_packet_ai_consumer_vault_names_present;

-- Database releases the bundled worker depends on (bounded retry, materialization,
-- Phase 2 task dedupe and follow-up receipt).
SELECT 1 / CASE WHEN (
  SELECT count(*) FROM supabase_migrations.schema_migrations
  WHERE version IN ('20261022120000', '20261022121000', '20261024130000')
) = 3 THEN 1 ELSE 0 END AS whatsapp_packet_ai_consumer_migration_prerequisites_pass;
SELECT 'WHATSAPP_PACKET_AI_CONSUMER_PRODUCTION_RUNTIME_OK';
ROLLBACK;

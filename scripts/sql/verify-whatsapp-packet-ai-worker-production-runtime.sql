-- Read-only production runtime certification for whatsapp-packet-ai-worker (#412).
-- Check prerequisites using ordinary PostgreSQL SQL so static analyzers can parse
-- the same assertions as the production runtime. No business state is modified.
BEGIN READ ONLY;
SELECT 1 / CASE WHEN
  to_regprocedure('public.whatsapp_continue_case_after_identity_confirmation()') IS NOT NULL
  AND to_regprocedure('public.whatsapp_search_case_parties(text,text,integer)') IS NOT NULL
  AND to_regclass('public.whatsapp_case_identity_confirmation_continuations') IS NOT NULL
  AND to_regclass('public.whatsapp_packet_ai_dispatch_jobs') IS NOT NULL
  AND to_regprocedure('public.claim_whatsapp_packet_ai_dispatch_job(integer)') IS NOT NULL
  AND to_regprocedure('public.complete_whatsapp_packet_ai_dispatch_job(uuid,uuid,bigint)') IS NOT NULL
  AND has_function_privilege('service_role', 'public.complete_whatsapp_packet_ai_dispatch_job(uuid,uuid,bigint)', 'EXECUTE')
THEN 1 ELSE 0 END AS whatsapp_packet_ai_worker_prerequisites_pass;
SELECT 'WHATSAPP_PACKET_AI_WORKER_PRODUCTION_RUNTIME_OK';
ROLLBACK;

-- Read-only production runtime certification for whatsapp-packet-ai-worker (#412).
-- Proves MC#629 database prerequisites and dispatch authority exist without
-- mutating production business state, sending WhatsApp messages, or creating orders.
BEGIN READ ONLY;
do $$
begin
  if to_regprocedure('public.whatsapp_continue_case_after_identity_confirmation()') is null then
    raise exception 'MC629_CONTINUATION_FUNCTION_MISSING';
  end if;
  if to_regprocedure('public.whatsapp_search_case_parties(text,text,integer)') is null then
    raise exception 'MC629_CASE_PARTY_SEARCH_MISSING';
  end if;
  if to_regclass('public.whatsapp_case_identity_confirmation_continuations') is null then
    raise exception 'MC629_CONTINUATION_TABLE_MISSING';
  end if;
  if to_regclass('public.whatsapp_packet_ai_dispatch_jobs') is null then
    raise exception 'PACKET_AI_DISPATCH_QUEUE_MISSING';
  end if;
  if to_regprocedure('public.claim_whatsapp_packet_ai_dispatch_job(integer)') is null then
    raise exception 'PACKET_AI_CLAIM_RPC_MISSING';
  end if;
  if to_regprocedure('public.complete_whatsapp_packet_ai_dispatch_job(uuid,uuid,bigint)') is null then
    raise exception 'PACKET_AI_COMPLETE_RPC_MISSING';
  end if;
end
$$;
select 'WHATSAPP_PACKET_AI_WORKER_PRODUCTION_RUNTIME_OK';
ROLLBACK;

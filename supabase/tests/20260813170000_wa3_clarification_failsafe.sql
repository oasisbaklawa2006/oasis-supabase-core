-- Contract for 20260813170000_wa3_clarification_failsafe.sql.
begin;
select plan(31);

select has_table('public','whatsapp_order_field_resolutions');
select has_table('public','whatsapp_order_field_evidence');
select has_table('public','whatsapp_order_clarification_tasks');
select has_column('public','sales_order_drafts','potential_order_id');
select col_hasnt_default('public','whatsapp_sales_order_drafts','quantity','legacy WhatsApp quantity has no executable default');
select has_function('public','record_whatsapp_order_field_evidence',array['uuid','text','uuid','text','jsonb','text','numeric','text','jsonb','boolean']);
select has_function('public','answer_whatsapp_order_clarification',array['uuid','uuid','text','jsonb','text','jsonb']);
select has_function('public','evaluate_whatsapp_order_readiness',array['uuid']);
select has_function('public','link_whatsapp_potential_order_draft',array['uuid','uuid']);
select has_view('public','whatsapp_order_readiness');

select ok((select relrowsecurity from pg_class where oid='public.whatsapp_order_field_resolutions'::regclass),'resolution ledger has RLS');
select ok((select relrowsecurity from pg_class where oid='public.whatsapp_order_field_evidence'::regclass),'evidence ledger has RLS');
select ok((select relrowsecurity from pg_class where oid='public.whatsapp_order_clarification_tasks'::regclass),'clarification ledger has RLS');
select ok(not has_table_privilege('anon','public.whatsapp_order_field_evidence','select'),'anon cannot read evidence');
select ok(not has_table_privilege('authenticated','public.whatsapp_order_field_evidence','insert'),'clients cannot forge evidence');
select ok(not has_table_privilege('authenticated','public.whatsapp_order_field_resolutions','update'),'clients cannot mutate resolution state');
select ok(not has_table_privilege('authenticated','public.whatsapp_order_clarification_tasks','update'),'clients cannot close clarification work directly');

select ok(exists(select 1 from pg_trigger where tgrelid='public.whatsapp_order_field_evidence'::regclass and tgname='wa3_evidence_immutable' and not tgisinternal),'source evidence is append-only');
select ok(exists(select 1 from pg_trigger where tgrelid='public.whatsapp_order_field_resolutions'::regclass and tgname='wa3_resolution_governed' and not tgisinternal),'resolution writes are governed');
select ok(exists(select 1 from pg_trigger where tgrelid='public.sales_order_drafts'::regclass and tgname='wa3_draft_promotion_readiness' and not tgisinternal),'promotion has Core readiness guard');

select isnt_empty($$select 1 from pg_constraint where conrelid='public.whatsapp_order_field_evidence'::regclass and contype='u' and pg_get_constraintdef(oid) like '%potential_order_id, field_key, evidence_key%'$$,'duplicate/replayed field evidence is idempotent');
select isnt_empty($$select 1 from pg_constraint where conrelid='public.whatsapp_order_clarification_tasks'::regclass and contype='u' and pg_get_constraintdef(oid) like '%potential_order_id, idempotency_key%'$$,'duplicate clarification work is idempotent');
select isnt_empty($$select 1 from pg_proc where oid='public.create_whatsapp_sales_order_draft_from_operator(uuid,text,text,uuid,text,text,numeric)'::regprocedure and pg_get_functiondef(oid) like '%QUANTITY_UNRESOLVED%' and pg_get_functiondef(oid) not like '%COALESCE(_quantity, 1)%'$$,'legacy draft creation fails closed on missing quantity');
select isnt_empty($$select 1 from pg_proc where oid='public.record_whatsapp_order_field_evidence(uuid,text,uuid,text,jsonb,text,numeric,text,jsonb,boolean)'::regprocedure and pg_get_functiondef(oid) like '%conflicting%' and pg_get_functiondef(oid) like '%operator_confirmed%' and pg_get_functiondef(oid) like '%ai_failure%'$$,'deterministic reconciliation covers conflict, correction, and AI failure');
select isnt_empty($$select 1 from pg_proc where oid='public.record_whatsapp_order_field_evidence(uuid,text,uuid,text,jsonb,text,numeric,text,jsonb,boolean)'::regprocedure and pg_get_functiondef(oid) like '%FIELD_CLARIFICATION_REQUIRED%' and pg_get_functiondef(oid) like '%AWAITING_CLARIFICATION%'$$,'failure remains visible in WA-1 lifecycle');
select isnt_empty($$select 1 from pg_proc where oid='public.evaluate_whatsapp_order_readiness(uuid)'::regprocedure and pg_get_functiondef(oid) like '%client_identity%' and pg_get_functiondef(oid) like '%unit_packaging%' and pg_get_functiondef(oid) like '%moq_carton%'$$,'readiness covers all mandatory commercial dimensions');
select isnt_empty($$select 1 from pg_proc where oid='public.wa3_assert_draft_ready_for_promotion()'::regprocedure and pg_get_functiondef(oid) like '%WA3_COMMERCIAL_DIMENSIONS_UNRESOLVED%'$$,'one unresolved mandatory dimension blocks promotion');
select isnt_empty($$select 1 from pg_proc where oid='public.record_whatsapp_order_field_evidence(uuid,text,uuid,text,jsonb,text,numeric,text,jsonb,boolean)'::regprocedure and pg_get_functiondef(oid) like '%historical_reference%' and pg_get_functiondef(oid) like '%awaiting_clarification%'$$,'same-as-last-time remains governed, not assumed');
select isnt_empty($$select 1 from pg_proc where oid='public.answer_whatsapp_order_clarification(uuid,uuid,text,jsonb,text,jsonb)'::regprocedure and pg_get_functiondef(oid) like '%status=''ANSWERED''%' and pg_get_functiondef(oid) like '%clarification:%'$$,'clarification response is idempotent and evidence linked');
select isnt_empty($$select 1 from pg_proc where oid='public.wa3_clarification_question(text)'::regprocedure and pg_get_functiondef(oid) like '%pieces, packs, boxes, or cartons%'$$,'questions request only the missing commercial fact');
select ok(not has_function_privilege('anon','public.record_whatsapp_order_field_evidence(uuid,text,uuid,text,jsonb,text,numeric,text,jsonb,boolean)','execute'),'anon cannot reconcile fields');

select * from finish();
rollback;

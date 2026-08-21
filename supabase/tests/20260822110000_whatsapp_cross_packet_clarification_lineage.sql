begin;
select plan(25);

select has_table('public','whatsapp_clarification_answer_evidence','immutable cross-packet clarification answer relation exists');
select has_table('public','whatsapp_potential_order_evidence_lineage','immutable governed continuation lineage exists');
select has_table('public','whatsapp_case_context_executions','case-context execution records exist');
select has_column('public','whatsapp_clarification_answer_evidence','answer_inbound_message_id','canonical WA1 inbound source identity is retained');
select has_column('public','whatsapp_clarification_answer_evidence','answer_packet_id','later packet provenance is retained');
select has_column('public','whatsapp_potential_order_evidence_lineage','source_inbound_message_id','WA3 lineage retains canonical inbound source identity');
select has_column('public','whatsapp_communication_cases','context_revision','case context revision is separate from packet revision');
select has_column('public','whatsapp_packet_ai_dispatch_jobs','execution_kind','shared durable outbox has typed execution identity');
select has_column('public','whatsapp_packet_ai_dispatch_jobs','context_revision','outbox pins case context revision');

select has_function('public','whatsapp_correlate_clarification_answer',array['uuid','text'],'trusted cross-packet clarification correlation exists');
select has_function('public','whatsapp_potential_order_source_message_is_authorized',array['uuid','uuid'],'WA3 source authorization helper exists');
select has_function('public','enqueue_whatsapp_case_context_ai_dispatch',array['uuid','uuid'],'cross-packet answer creates durable context execution');
select has_function('public','whatsapp_case_context_messages',array['uuid'],'worker has governed case-context evidence loader');

select ok((select relrowsecurity from pg_class where oid='public.whatsapp_clarification_answer_evidence'::regclass),'clarification answer relation is RLS protected');
select ok((select relrowsecurity from pg_class where oid='public.whatsapp_potential_order_evidence_lineage'::regclass),'continuation lineage is RLS protected');
select is_empty($$select 1 from information_schema.role_table_grants where table_schema='public' and table_name in ('whatsapp_clarification_answer_evidence','whatsapp_potential_order_evidence_lineage','whatsapp_case_context_executions') and grantee in ('PUBLIC','anon','authenticated')$$,'untrusted roles cannot write lineage tables');
select is_empty($$select 1 from information_schema.role_routine_grants where routine_schema='public' and routine_name in ('whatsapp_correlate_clarification_answer','enqueue_whatsapp_case_context_ai_dispatch','whatsapp_case_context_messages','whatsapp_potential_order_source_message_is_authorized') and grantee in ('PUBLIC','anon','authenticated')$$,'new continuation functions are service-only');

select isnt_empty($$select 1 from pg_trigger where tgrelid='public.whatsapp_clarification_answer_evidence'::regclass and tgname='whatsapp_clarification_answer_evidence_immutable'$$,'clarification relation is append-only');
select isnt_empty($$select 1 from pg_trigger where tgrelid='public.whatsapp_potential_order_evidence_lineage'::regclass and tgname='whatsapp_potential_order_evidence_lineage_immutable'$$,'continuation lineage is append-only');
select isnt_empty($$select 1 from pg_proc where oid='public.whatsapp_correlate_clarification_answer(uuid,text)'::regprocedure and pg_get_functiondef(oid) like '%count(*), min(id)%'$$,'provider id mapping requires aggregate uniqueness proof');
select isnt_empty($$select 1 from pg_proc where oid='public.whatsapp_correlate_clarification_answer(uuid,text)'::regprocedure and pg_get_functiondef(oid) like '%v_candidate_count<>1%'$$,'zero or multiple compatible clarifications fail closed');
select is_empty($$select 1 from pg_proc where oid='public.whatsapp_correlate_clarification_answer(uuid,text)'::regprocedure and pg_get_functiondef(oid) ~ 'LIMIT[[:space:]]+1'$$,'correlation never guesses with LIMIT 1');
select isnt_empty($$select 1 from pg_proc where oid='public.record_whatsapp_order_field_evidence(uuid,text,uuid,text,jsonb,text,numeric,text,jsonb,boolean)'::regprocedure and pg_get_functiondef(oid) like '%whatsapp_potential_order_source_message_is_authorized%'$$,'WA3 source guard delegates only to governed authorization helper');
select isnt_empty($$select 1 from pg_proc where oid='public.assert_whatsapp_packet_ai_dispatch_lease(uuid,uuid,bigint)'::regprocedure and pg_get_functiondef(oid) like '%context_revision=j.context_revision%'$$,'stale case-context execution fails lease assertion');
select isnt_empty($$select 1 from pg_proc where oid='public.whatsapp_case_context_messages(uuid)'::regprocedure and pg_get_functiondef(oid) like '%whatsapp_clarification_answer_evidence%'$$,'worker context uses approved cross-packet evidence only');

select * from finish();
rollback;

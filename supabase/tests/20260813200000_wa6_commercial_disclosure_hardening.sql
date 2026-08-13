-- Contract for migration 20260813200000_wa6_commercial_disclosure_hardening.sql.
begin;
select plan(24);
select has_table('public','whatsapp_sender_commercial_authorizations','sender disclosure authority exists');
select has_function('public','authorize_whatsapp_commercial_disclosure',array['uuid','uuid','text[]','jsonb','timestamp with time zone']);
select has_function('public','wa6_infer_commercial_disclosure',array['text']);
select ok(exists(select 1 from pg_trigger where tgname='wa6_operator_reply_disclosure' and not tgisinternal),'outbound disclosure trigger is active');
select is_empty($$select 1 from information_schema.role_table_grants where table_schema='public' and table_name='whatsapp_sender_commercial_authorizations' and grantee in('anon','authenticated') and privilege_type in('INSERT','UPDATE','DELETE')$$,'clients cannot mutate recipient authority');
select ok(not has_function_privilege('anon','public.authorize_whatsapp_commercial_disclosure(uuid,uuid,text[],jsonb,timestamptz)','execute'),'anonymous cannot authorize disclosure');
select is(public.wa6_infer_commercial_disclosure('Your account balance is Rs. 500'),array['customer_pricing','account_balance']::text[],'sensitive commercial facts are classified');
select is(public.wa6_infer_commercial_disclosure('Which product and quantity did you mean?'),'{}'::text[],'narrow clarification is not invented disclosure');

insert into auth.users(id,email) values('86000000-0000-0000-0000-000000000001','wa6-admin@example.test');
insert into public.users(id,email,name,role,is_active) values('86000000-0000-0000-0000-000000000001','wa6-admin@example.test','WA6 Admin','admin',true);
insert into public.user_role_map(user_id,role_id) select '86000000-0000-0000-0000-000000000001',id from public.roles where role_key='admin';
insert into public.companies(id,business_name,status) values('86000000-0000-0000-0000-000000000002','WA6 Company','approved');
insert into public.whatsapp_contacts(id,phone_number,customer_name) values('86000000-0000-0000-0000-000000000003','919333333333','WA6 Recipient');
insert into public.whatsapp_message_packets(id,contact_id,stitched_content,first_message_at,last_message_at) values('86000000-0000-0000-0000-000000000004','86000000-0000-0000-0000-000000000003','{}',now(),now());
insert into public.whatsapp_inbound_messages(id,provider_message_id,sender_phone,message_body,raw_payload,resolver_status) values('86000000-0000-0000-0000-000000000005','wa6-source','919333333333','order query','{}','resolved');
select set_config('request.jwt.claims',json_build_object('sub','86000000-0000-0000-0000-000000000001','role','service_role','aal','aal2')::text,true);
select public.capture_whatsapp_potential_order('86000000-0000-0000-0000-000000000005',true,true,'{}');
select throws_ok($$select public.enqueue_whatsapp_operator_reply('86000000-0000-0000-0000-000000000004','86000000-0000-0000-0000-000000000003','+919333333333','Your price is Rs. 500','wa6-leak')$$,'WA6_COMMERCIAL_DISCLOSURE_REQUIRES_GOVERNED_ORDER','commercial data cannot leave without governed order');
select lives_ok($$select public.enqueue_whatsapp_operator_reply('86000000-0000-0000-0000-000000000004','86000000-0000-0000-0000-000000000003','+919333333333','Which product and quantity did you mean?','wa6-safe')$$,'non-disclosing clarification remains available');
select is((select disclosure_scope from public.whatsapp_operator_reply_outbox where idempotency_key='wa6-safe'),'{}'::text[],'safe clarification invents no disclosure');

select throws_ok($$select public.authorize_whatsapp_commercial_disclosure('86000000-0000-0000-0000-000000000003','86000000-0000-0000-0000-000000000002',array['customer_pricing'],'{}',now()+interval '1 day')$$,'new row for relation "whatsapp_sender_commercial_authorizations" violates check constraint "whatsapp_sender_commercial_authorizations_identity_evidence_check"','identity evidence is mandatory');
select set_config('request.jwt.claims',json_build_object('sub','86000000-0000-0000-0000-000000000001','role','authenticated','aal','aal1')::text,true);
select throws_ok($$select public.authorize_whatsapp_commercial_disclosure('86000000-0000-0000-0000-000000000003','86000000-0000-0000-0000-000000000002',array['customer_pricing'],'{"method":"verified_account_contact"}',now()+interval '1 day')$$,'WA6_DISCLOSURE_AUTHORITY_REQUIRED','AAL1 cannot authorize commercial disclosure');
select set_config('request.jwt.claims',json_build_object('sub','86000000-0000-0000-0000-000000000001','role','service_role','aal','aal2')::text,true);
select lives_ok($$select public.authorize_whatsapp_commercial_disclosure('86000000-0000-0000-0000-000000000003','86000000-0000-0000-0000-000000000002',array['customer_pricing'],'{"method":"verified_account_contact"}',now()+interval '1 day')$$,'AAL2 admin grants scoped recipient authority');
select is((select count(*) from public.whatsapp_sender_commercial_authorizations where status='ACTIVE'),1::bigint,'one active authorization exists');

insert into public.whatsapp_order_field_resolutions(potential_order_id,field_key,resolution_state,resolved_value,resolved_at,resolved_by)
select id,'client_identity','operator_confirmed','{"company_id":"86000000-0000-0000-0000-000000000002"}',now(),'86000000-0000-0000-0000-000000000001' from public.whatsapp_potential_orders where source_message_id='86000000-0000-0000-0000-000000000005';
select lives_ok($$select public.enqueue_whatsapp_operator_reply('86000000-0000-0000-0000-000000000004','86000000-0000-0000-0000-000000000003','+919333333333','Your price is Rs. 500','wa6-authorized',(select id from public.whatsapp_potential_orders where source_message_id='86000000-0000-0000-0000-000000000005'))$$,'verified recipient receives authorized pricing scope');
select is((select disclosure_scope from public.whatsapp_operator_reply_outbox where idempotency_key='wa6-authorized'),array['customer_pricing']::text[],'inferred disclosure scope is persisted');
select throws_ok($$select public.enqueue_whatsapp_operator_reply('86000000-0000-0000-0000-000000000004','86000000-0000-0000-0000-000000000003','+919333333333','Your account balance is Rs. 500','wa6-overbroad',(select id from public.whatsapp_potential_orders where source_message_id='86000000-0000-0000-0000-000000000005'))$$,'WA6_DISCLOSURE_SCOPE_NOT_AUTHORIZED','scope exceeding authorization fails closed');
select is((select count(*) from public.whatsapp_operator_reply_outbox where idempotency_key='wa6-overbroad'),0::bigint,'failed disclosure creates no send work');
select throws_ok($$update public.whatsapp_sender_commercial_authorizations set disclosure_scope=array['account_balance']$$,'WA1_AUDIT_IMMUTABLE','recipient authority is immutable outside governed RPC');

select ok(position('for update' in lower(pg_get_functiondef('public.approve_sales_order_draft_for_so_atomic(uuid,text,uuid,text,text,jsonb)'::regprocedure)))>0,'promotion serializes concurrent operators');
select ok(exists(select 1 from pg_indexes where schemaname='public' and indexname='sales_order_drafts_potential_order_unique'),'one potential order has at most one draft');
select ok(exists(select 1 from pg_indexes where schemaname='public' and indexname='whatsapp_operator_reply_provider_unique'),'provider acceptance is globally idempotent');
select is((select unaccounted_potential_orders from public.whatsapp_potential_order_reconciliation),0::bigint,'WA-1 zero-loss reconciliation remains closed');
select * from finish();
rollback;

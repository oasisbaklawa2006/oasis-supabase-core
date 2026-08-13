-- Contract for migration 20260813190000_wa5_governed_operator_replies.sql.
begin;
select plan(27);
select has_table('public','whatsapp_operator_reply_outbox','whatsapp_operator_reply_outbox');
select has_table('public','whatsapp_operator_reply_events','whatsapp_operator_reply_events');
select has_function('public','enqueue_whatsapp_operator_reply',array['uuid','uuid','text','text','text','uuid','uuid','text','text','text','text','text[]']);
select has_function('public','claim_whatsapp_operator_reply',array['text','uuid','integer']);
select has_function('public','complete_whatsapp_operator_reply',array['uuid','uuid','text','text']);
select has_function('public','fail_whatsapp_operator_reply',array['uuid','uuid','text','text','boolean']);
select has_function('public','record_whatsapp_operator_reply_status',array['uuid','text','text','text','jsonb']);
select is_empty($$select 1 from information_schema.role_table_grants where table_schema='public' and table_name in('whatsapp_operator_reply_outbox','whatsapp_operator_reply_events') and grantee in('anon','authenticated') and privilege_type in('INSERT','UPDATE','DELETE')$$,'clients have no direct outbox mutation');
select is_empty($$select 1 from information_schema.role_routine_grants where routine_schema='public' and routine_name in('claim_whatsapp_operator_reply','complete_whatsapp_operator_reply','fail_whatsapp_operator_reply','record_whatsapp_operator_reply_status') and grantee in('PUBLIC','anon','authenticated')$$,'provider lifecycle is service-only');
select ok(exists(select 1 from pg_trigger where tgname='wa5_reply_events_immutable' and not tgisinternal),'outbound events are immutable');

insert into auth.users(id,email) values('85000000-0000-0000-0000-000000000001','wa5-admin@example.test');
insert into public.users(id,email,name,role,is_active) values('85000000-0000-0000-0000-000000000001','wa5-admin@example.test','WA5 Admin','admin',true);
insert into public.user_role_map(user_id,role_id) select '85000000-0000-0000-0000-000000000001',id from public.roles where role_key='admin';
insert into public.whatsapp_contacts(id,phone_number,customer_name) values
 ('85000000-0000-0000-0000-000000000010','919111111111','Recipient A'),
 ('85000000-0000-0000-0000-000000000011','919222222222','Recipient B');
insert into public.whatsapp_message_packets(id,contact_id,stitched_content,first_message_at,last_message_at) values
 ('85000000-0000-0000-0000-000000000020','85000000-0000-0000-0000-000000000010','{}',now(),now());

select set_config('request.jwt.claims',json_build_object('sub','85000000-0000-0000-0000-000000000001','role','authenticated','aal','aal1')::text,true);
select lives_ok($$select public.enqueue_whatsapp_operator_reply('85000000-0000-0000-0000-000000000020','85000000-0000-0000-0000-000000000010','+919111111111','Which carton size?','wa5-reply-1')$$,'authorized operator queues recipient-bound reply');
select lives_ok($$select public.enqueue_whatsapp_operator_reply('85000000-0000-0000-0000-000000000020','85000000-0000-0000-0000-000000000010','+919111111111','changed replay body','wa5-reply-1')$$,'duplicate UI submit is idempotent');
select is((select count(*) from public.whatsapp_operator_reply_outbox where idempotency_key='wa5-reply-1'),1::bigint,'one commercial reply work item survives replay');
select is((select message_body from public.whatsapp_operator_reply_outbox where idempotency_key='wa5-reply-1'),'Which carton size?','replay cannot overwrite released content');
select throws_ok($$select public.enqueue_whatsapp_operator_reply('85000000-0000-0000-0000-000000000020','85000000-0000-0000-0000-000000000011','+919222222222','leak','wrong-recipient')$$,'WA5_PACKET_CONTACT_MISMATCH','cross-customer disclosure fails closed');
select throws_ok($$select public.enqueue_whatsapp_operator_reply('85000000-0000-0000-0000-000000000020','85000000-0000-0000-0000-000000000010','+919222222222','leak','wrong-phone')$$,'WA5_RECIPIENT_MISMATCH','caller-supplied wrong phone fails closed');

select set_config('request.jwt.claims',json_build_object('role','service_role')::text,true);
select lives_ok($$select public.claim_whatsapp_operator_reply('worker-1',null,60)$$,'trusted worker claims once');
select is((select status from public.whatsapp_operator_reply_outbox where idempotency_key='wa5-reply-1'),'SENDING','claim obtains sending lease');
select lives_ok($$select public.fail_whatsapp_operator_reply(id,lease_token,'TIMEOUT','provider may have accepted',true) from public.whatsapp_operator_reply_outbox where idempotency_key='wa5-reply-1'$$,'network timeout becomes acceptance unknown');
select is((select status from public.whatsapp_operator_reply_outbox where idempotency_key='wa5-reply-1'),'ACCEPTANCE_UNKNOWN','unknown acceptance is not blindly retried');
select is((select public.claim_whatsapp_operator_reply('worker-2',null,60)),null::public.whatsapp_operator_reply_outbox,'uncertain provider acceptance cannot duplicate-send');
select lives_ok($$select public.record_whatsapp_operator_reply_status(id,'click2api','provider-wa5-1','DELIVERED','{"callback":true}') from public.whatsapp_operator_reply_outbox where idempotency_key='wa5-reply-1'$$,'provider callback reconciles unknown acceptance');
select is((select status from public.whatsapp_operator_reply_outbox where idempotency_key='wa5-reply-1'),'DELIVERED','delivery lifecycle is persisted');
select throws_ok($$select public.record_whatsapp_operator_reply_status(id,'click2api','provider-wa5-1','ACCEPTED','{}') from public.whatsapp_operator_reply_outbox where idempotency_key='wa5-reply-1'$$,'WA5_STATUS_BOUNDARY_OR_REGRESSION','provider status cannot regress');
select throws_ok($$delete from public.whatsapp_operator_reply_events$$,'WA1_AUDIT_IMMUTABLE','outbound audit cannot be deleted');

select set_config('request.jwt.claims',json_build_object('role','anon')::text,true);
select throws_ok($$select public.enqueue_whatsapp_operator_reply('85000000-0000-0000-0000-000000000020','85000000-0000-0000-0000-000000000010','+919111111111','unauthorized','wa5-unauthorized')$$,'WA5_REPLY_SEND_REQUIRED','unauthorized client cannot queue reply');
select is((select count(*) from public.whatsapp_operator_reply_outbox where idempotency_key='wa5-unauthorized'),0::bigint,'unauthorized attempt creates no work');

select * from finish();
rollback;

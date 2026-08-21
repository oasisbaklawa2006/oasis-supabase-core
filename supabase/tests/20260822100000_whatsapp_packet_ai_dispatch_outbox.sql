begin;
-- Contract coverage for 20260822100000_whatsapp_packet_ai_dispatch_outbox.sql.
select plan(30);

select has_table('public', 'whatsapp_packet_ai_dispatch_jobs', 'durable packet dispatch outbox exists');
select has_column('public', 'whatsapp_packet_ai_dispatch_jobs', 'packet_revision', 'outbox pins the packet revision');
select has_column('public', 'whatsapp_packet_ai_dispatch_jobs', 'logical_dispatch_key', 'outbox has stable logical idempotency key');
select has_column('public', 'whatsapp_packet_ai_dispatch_jobs', 'lease_token', 'outbox has lease token');
select has_column('public', 'whatsapp_packet_ai_dispatch_jobs', 'lease_expires_at', 'outbox has recoverable lease expiry');
select has_column('public', 'whatsapp_packet_ai_dispatch_jobs', 'last_error_detail', 'outbox records bounded retry diagnostics');
select trigger_is('public', 'whatsapp_messages', 'whatsapp_messages_enqueue_packet_ai_dispatch', 'public', 'enqueue_whatsapp_packet_ai_dispatch', 'packet assignment atomically enqueues dispatch');
select has_function('public', 'claim_whatsapp_packet_ai_dispatch_job', array['integer'], 'trusted workers claim one job under a lease');
select has_function('public', 'assert_whatsapp_packet_ai_dispatch_lease', array['uuid','uuid','bigint'], 'workers must prove their lease before effects');
select has_function('public', 'complete_whatsapp_packet_ai_dispatch_job', array['uuid','uuid','bigint'], 'completion is lease and revision bound');
select has_function('public', 'retry_whatsapp_packet_ai_dispatch_job', array['uuid','uuid','bigint','text','text','boolean'], 'retry is lease and revision bound');
select has_function('public', 'release_superseded_whatsapp_packet_ai_dispatch_job', array['uuid','uuid','bigint'], 'new evidence releases obsolete lease without outcome');
select ok((select relrowsecurity from pg_class where oid = 'public.whatsapp_packet_ai_dispatch_jobs'::regclass), 'outbox RLS remains enabled');
select isnt_empty(
  $$select 1 from pg_proc where oid='public.stitch_whatsapp_messages_atomic(uuid,uuid[],integer)'::regprocedure
      and pg_get_functiondef(oid) like '%m.direction=''inbound''%'$$,
  'only inbound messages can advance packet evidence/revisions'
);
select isnt_empty(
  $$select 1 from pg_proc where oid='public.stitch_whatsapp_messages_atomic(uuid,uuid[],integer)'::regprocedure
      and pg_get_functiondef(oid) like '%return v_existing_packet;%'$$,
  'exact stitched replay returns before a new packet assignment/revision'
);
select isnt_empty(
  $$select 1 from pg_proc where oid='public.assert_whatsapp_packet_ai_dispatch_lease(uuid,uuid,bigint)'::regprocedure
      and pg_get_functiondef(oid) like '%packet_revision=p_packet_revision%'$$,
  'stale revision cannot pass the authoritative lease assertion'
);
select isnt_empty(
  $$select 1 from pg_proc where oid='public.release_superseded_whatsapp_packet_ai_dispatch_job(uuid,uuid,bigint)'::regprocedure
      and pg_get_functiondef(oid) like '%packet_revision%<>%p_claimed_packet_revision%'$$,
  'new evidence releases obsolete worker lease for the current revision'
);
select isnt_empty(
  $$select 1 from pg_proc where oid='public.enqueue_whatsapp_packet_ai_dispatch()'::regprocedure
      and pg_get_functiondef(oid) like '%new.packet_id is not distinct from old.packet_id%'$$,
  'duplicate packet assignment does not create another revision'
);

insert into public.whatsapp_contacts(id,phone_number,customer_name) values
  ('86200000-0000-0000-0000-000000000001','919620000001','Dispatch regression contact');
insert into public.whatsapp_messages(id,contact_id,direction,message_type,content,provider,provider_message_id,status,message_timestamp,created_at) values
  ('86200000-0000-0000-0000-000000000011','86200000-0000-0000-0000-000000000001','inbound','text','10 boxes','click2api','dispatch-a','received','2026-08-22 10:00:00','2026-08-22 10:00:00'),
  ('86200000-0000-0000-0000-000000000012','86200000-0000-0000-0000-000000000001','inbound','text','not 10 boxes, make it 12 cartons','click2api','dispatch-b','received','2026-08-22 10:00:10','2026-08-22 10:00:10');
select lives_ok($$select public.stitch_whatsapp_messages_atomic('86200000-0000-0000-0000-000000000001',array['86200000-0000-0000-0000-000000000011'::uuid],300)$$,'message A creates an atomic packet/job');
select is((select packet_revision from public.whatsapp_packet_ai_dispatch_jobs where packet_id=(select packet_id from public.whatsapp_messages where id='86200000-0000-0000-0000-000000000011')),1::bigint,'message A creates revision 1');
create temporary table dispatch_claim_a as select * from public.claim_whatsapp_packet_ai_dispatch_job(120);
select is((select state from dispatch_claim_a),'LEASED','revision 1 is exclusively leased');
select lives_ok($$select public.stitch_whatsapp_messages_atomic('86200000-0000-0000-0000-000000000001',array['86200000-0000-0000-0000-000000000012'::uuid],300)$$,'correction evidence joins the same logical packet');
select is((select packet_revision from public.whatsapp_packet_ai_dispatch_jobs where packet_id=(select packet_id from public.whatsapp_messages where id='86200000-0000-0000-0000-000000000011')),2::bigint,'correction creates revision 2');
select is((select logical_dispatch_key from public.whatsapp_packet_ai_dispatch_jobs where packet_id=(select packet_id from public.whatsapp_messages where id='86200000-0000-0000-0000-000000000011')),'packet:'||(select packet_id::text from public.whatsapp_messages where id='86200000-0000-0000-0000-000000000011')||':revision:2','revision 2 receives a distinct logical dispatch key');
select ok(not public.assert_whatsapp_packet_ai_dispatch_lease((select id from dispatch_claim_a),(select lease_token from dispatch_claim_a),(select packet_revision from dispatch_claim_a)),'revision 1 lease fails closed after revision 2 exists');
select ok(public.release_superseded_whatsapp_packet_ai_dispatch_job((select id from dispatch_claim_a),(select lease_token from dispatch_claim_a),(select packet_revision from dispatch_claim_a)),'obsolete worker releases the current revision for retry');
select is((select state from public.whatsapp_packet_ai_dispatch_jobs where id=(select id from dispatch_claim_a)),'QUEUED','revision 2 remains runnable after stale worker release');
select lives_ok($$select public.stitch_whatsapp_messages_atomic('86200000-0000-0000-0000-000000000001',array['86200000-0000-0000-0000-000000000012'::uuid],300)$$,'replaying correction does not restitch it');
select is((select packet_revision from public.whatsapp_packet_ai_dispatch_jobs where packet_id=(select packet_id from public.whatsapp_messages where id='86200000-0000-0000-0000-000000000011')),2::bigint,'replaying same correction does not create another revision');
insert into public.whatsapp_messages(id,contact_id,direction,message_type,content,provider,provider_message_id,status,packet_id,message_timestamp,created_at) values
  ('86200000-0000-0000-0000-000000000013','86200000-0000-0000-0000-000000000001','outbound','text','clarification sent','click2api','dispatch-outbound','sent',(select packet_id from public.whatsapp_messages where id='86200000-0000-0000-0000-000000000011'),'2026-08-22 10:01:00','2026-08-22 10:01:00');
select is((select packet_revision from public.whatsapp_packet_ai_dispatch_jobs where packet_id=(select packet_id from public.whatsapp_messages where id='86200000-0000-0000-0000-000000000011')),2::bigint,'outbound messages cannot create commercial processing revisions');

select * from finish();
rollback;

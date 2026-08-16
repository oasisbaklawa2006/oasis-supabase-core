-- Contract for 20260816120000_wa_atomic_packet_authority.sql
begin;
select plan(23);

select has_function('public','stitch_whatsapp_messages_atomic',array['uuid','uuid[]','integer']);
select ok(exists(select 1 from pg_indexes where schemaname='public' and indexname='whatsapp_messages_provider_message_unique'),'provider message idempotency index exists');
select is_empty($$select 1 from information_schema.role_routine_grants where routine_schema='public' and routine_name='stitch_whatsapp_messages_atomic' and grantee in('PUBLIC','anon','authenticated')$$,'packet mutation is not client executable');

insert into public.whatsapp_contacts(id,phone_number,customer_name) values
 ('86100000-0000-0000-0000-000000000001','919610000001','Atomic A'),
 ('86100000-0000-0000-0000-000000000002','919610000002','Atomic B');

insert into public.whatsapp_messages(id,contact_id,direction,message_type,content,provider,provider_message_id,status,message_timestamp,created_at) values
 ('86100000-0000-0000-0000-000000000011','86100000-0000-0000-0000-000000000001','inbound','text','one','click2api','atomic-1','received','2026-08-16 10:00:00','2026-08-16 10:00:00'),
 ('86100000-0000-0000-0000-000000000012','86100000-0000-0000-0000-000000000001','inbound','text','two','click2api','atomic-2','received','2026-08-16 10:00:10','2026-08-16 10:00:10'),
 ('86100000-0000-0000-0000-000000000013','86100000-0000-0000-0000-000000000001','inbound','text','three','click2api','atomic-3','received','2026-08-16 10:01:00','2026-08-16 10:01:00'),
 ('86100000-0000-0000-0000-000000000014','86100000-0000-0000-0000-000000000002','inbound','text','other customer','click2api','atomic-4','received','2026-08-16 10:01:05','2026-08-16 10:01:05'),
 ('86100000-0000-0000-0000-000000000015','86100000-0000-0000-0000-000000000001','inbound','text','later conversation','click2api','atomic-5','received','2026-08-16 10:10:00','2026-08-16 10:10:00'),
 ('86100000-0000-0000-0000-000000000016','86100000-0000-0000-0000-000000000001','inbound','text','mixed near','click2api','atomic-6','received','2026-08-16 10:14:00','2026-08-16 10:14:00'),
 ('86100000-0000-0000-0000-000000000017','86100000-0000-0000-0000-000000000001','inbound','text','mixed far','click2api','atomic-7','received','2026-08-16 10:30:00','2026-08-16 10:30:00');

select throws_ok($$select public.stitch_whatsapp_messages_atomic('86100000-0000-0000-0000-000000000001',array['86100000-0000-0000-0000-000000000011'::uuid],null)$$,'WA_PACKET_WINDOW_INVALID','explicit null packet window fails closed');
select lives_ok($$select public.stitch_whatsapp_messages_atomic('86100000-0000-0000-0000-000000000001',array['86100000-0000-0000-0000-000000000011'::uuid,'86100000-0000-0000-0000-000000000012'::uuid],300)$$,'first batch stitches atomically');
select is((select count(distinct packet_id) from public.whatsapp_messages where id in('86100000-0000-0000-0000-000000000011','86100000-0000-0000-0000-000000000012')),1::bigint,'burst shares one packet');
select is((select fragment_count from public.whatsapp_message_packets where id=(select packet_id from public.whatsapp_messages where id='86100000-0000-0000-0000-000000000011')),2,'fragment count matches first batch');
select lives_ok($$select public.stitch_whatsapp_messages_atomic('86100000-0000-0000-0000-000000000001',array['86100000-0000-0000-0000-000000000013'::uuid],300)$$,'later fragment inside window appends');
select is((select fragment_count from public.whatsapp_message_packets where id=(select packet_id from public.whatsapp_messages where id='86100000-0000-0000-0000-000000000011')),3,'append increments exactly once');
select lives_ok($$select public.stitch_whatsapp_messages_atomic('86100000-0000-0000-0000-000000000001',array['86100000-0000-0000-0000-000000000013'::uuid],300)$$,'exact replay is idempotent');
select is((select fragment_count from public.whatsapp_message_packets where id=(select packet_id from public.whatsapp_messages where id='86100000-0000-0000-0000-000000000011')),3,'replay does not double count');
select throws_ok($$select public.stitch_whatsapp_messages_atomic('86100000-0000-0000-0000-000000000001',array['86100000-0000-0000-0000-000000000014'::uuid],300)$$,'WA_PACKET_MESSAGE_SCOPE_MISMATCH','cross-contact batch fails closed');
select is((select packet_id from public.whatsapp_messages where id='86100000-0000-0000-0000-000000000014'),null::uuid,'cross-contact failure leaves source untouched');
select lives_ok($$select public.stitch_whatsapp_messages_atomic('86100000-0000-0000-0000-000000000001',array['86100000-0000-0000-0000-000000000015'::uuid],300)$$,'message outside window starts a new packet');
select isnt((select packet_id from public.whatsapp_messages where id='86100000-0000-0000-0000-000000000015'),(select packet_id from public.whatsapp_messages where id='86100000-0000-0000-0000-000000000011'),'outside-window message is isolated');
select throws_ok($$select public.stitch_whatsapp_messages_atomic('86100000-0000-0000-0000-000000000001',array['86100000-0000-0000-0000-000000000016'::uuid,'86100000-0000-0000-0000-000000000017'::uuid],300)$$,'WA_PACKET_BATCH_WINDOW_EXCEEDED','mixed-distance batch exceeding the configured window fails closed');
select is((select count(*) from public.whatsapp_messages where id in('86100000-0000-0000-0000-000000000016','86100000-0000-0000-0000-000000000017') and packet_id is not null),0::bigint,'rejected mixed-distance batch leaves both fragments untouched');
select throws_ok($$insert into public.whatsapp_messages(contact_id,direction,message_type,content,provider,provider_message_id,status) values('86100000-0000-0000-0000-000000000001','inbound','text','duplicate','click2api','atomic-1','received')$$,'23505',null,'provider retry cannot create a duplicate raw row');
select ok((select packet_id is null from public.whatsapp_messages where id='86100000-0000-0000-0000-000000000016'),'near fragment remains retryable after mixed-distance rejection');
select ok((select packet_id is null from public.whatsapp_messages where id='86100000-0000-0000-0000-000000000017'),'far fragment remains retryable after mixed-distance rejection');
select ok((select fragment_count=3 from public.whatsapp_message_packets where id=(select packet_id from public.whatsapp_messages where id='86100000-0000-0000-0000-000000000011')),'rejected mixed-distance batch does not alter earlier packet');
select ok((select fragment_count=1 from public.whatsapp_message_packets where id=(select packet_id from public.whatsapp_messages where id='86100000-0000-0000-0000-000000000015')),'later isolated packet remains unchanged after rejection');
select is((select count(*) from public.whatsapp_message_packets where contact_id='86100000-0000-0000-0000-000000000001'),2::bigint,'failed mixed-distance batch creates no extra packet');

select * from finish();
rollback;

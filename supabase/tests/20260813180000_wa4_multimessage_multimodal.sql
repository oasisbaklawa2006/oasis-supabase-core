-- Contract for migration 20260813180000_wa4_multimessage_multimodal.sql.
begin;
select plan(27);

select has_table('public','whatsapp_commercial_packets','WA-4 packet authority exists');
select has_table('public','whatsapp_commercial_evidence','immutable fragment evidence exists');
select has_table('public','whatsapp_media_processing_events','append-only media outcomes exist');
select has_function('public','capture_whatsapp_commercial_fragment',array['uuid','uuid','text','uuid','integer','boolean','jsonb']);
select has_function('public','complete_whatsapp_media_processing',array['text','text','text','jsonb']);
select is_empty($$select 1 from information_schema.role_table_grants where table_schema='public' and table_name in ('whatsapp_commercial_packets','whatsapp_commercial_evidence','whatsapp_packet_audit_log','whatsapp_media_processing_events') and grantee in ('anon','authenticated') and privilege_type in ('INSERT','UPDATE','DELETE')$$,'clients cannot mutate packet authority');
select is_empty($$select 1 from information_schema.role_routine_grants where routine_schema='public' and routine_name in ('capture_whatsapp_commercial_fragment','complete_whatsapp_media_processing') and grantee in ('PUBLIC','anon','authenticated')$$,'only trusted processors can mutate evidence');

insert into public.whatsapp_inbound_messages(id,provider_message_id,sender_phone,message_body,message_type,received_at,raw_payload) values
 ('84000000-0000-0000-0000-000000000001','wa4-first','919111111111','send pistachio','text','2026-08-13 12:00:02+00','{"original":1}'),
 ('84000000-0000-0000-0000-000000000002','wa4-later','919111111111','5 cartons','text','2026-08-13 12:00:05+00','{"original":2}'),
 ('84000000-0000-0000-0000-000000000003','wa4-correct','919111111111','not 5, make it 6 cartons','text','2026-08-13 12:00:06+00','{"original":3}'),
 ('84000000-0000-0000-0000-000000000004','wa4-second-order','919111111111','send cashew 2 cartons','text','2026-08-13 12:00:07+00','{"original":4}'),
 ('84000000-0000-0000-0000-000000000005','wa4-image','919111111111','[unreadable image attachment]','image','2026-08-13 12:00:08+00','{"media_id":"safe-ref"}'),
 ('84000000-0000-0000-0000-000000000006','wa4-other-sender','919222222222','join wrong packet','text','2026-08-13 12:00:09+00','{}');

select lives_ok($$select public.capture_whatsapp_commercial_fragment('84000000-0000-0000-0000-000000000001',null,'wa4-first',null,0,false,'{"kind":"fragment"}')$$,'first fragment creates durable isolated packet');
select lives_ok($$select public.capture_whatsapp_commercial_fragment('84000000-0000-0000-0000-000000000002',null,'wa4-first',null,0,false,'{"kind":"later"}')$$,'explicit provider conversation stitches later fragment');
select is((select count(distinct packet_id) from public.whatsapp_commercial_evidence where provider_message_id in('wa4-first','wa4-later')),1::bigint,'fragmented messages share exactly one packet');
select is((select array_agg(provider_message_id order by deterministic_sequence) from public.whatsapp_commercial_evidence where provider_message_id in('wa4-first','wa4-later')),array['wa4-first','wa4-later']::text[],'sequence is deterministic and preserves arrival lineage');
select lives_ok($$select public.capture_whatsapp_commercial_fragment('84000000-0000-0000-0000-000000000003',null,'wa4-later','84000000-0000-0000-0000-000000000002',0,false,'{"kind":"correction"}')$$,'reply to a later fragment resolves the packet and records correction');
select is((select correction_of_source_message_id from public.whatsapp_commercial_evidence where provider_message_id='wa4-correct'),'84000000-0000-0000-0000-000000000002'::uuid,'correction points to immutable prior evidence');
select lives_ok($$select public.capture_whatsapp_commercial_fragment('84000000-0000-0000-0000-000000000004',null,null,null,0,false,'{}')$$,'same sender can create a separate order without time-window stitching');
select is((select count(distinct potential_order_id) from public.whatsapp_commercial_evidence where provider_message_id in('wa4-first','wa4-second-order')),2::bigint,'same-customer distinct intents remain separate potential orders');
select lives_ok($$select public.capture_whatsapp_commercial_fragment('84000000-0000-0000-0000-000000000001',null,'different',null,9,true,'{"replay":true}')$$,'provider replay is idempotent despite changed replay payload');
select is((select count(*) from public.whatsapp_commercial_evidence where provider_message_id='wa4-first'),1::bigint,'replay creates no duplicate evidence or work');
select lives_ok($$select public.capture_whatsapp_commercial_fragment('84000000-0000-0000-0000-000000000005',null,'wa4-image',null,1,true,'{"failure":"unreadable"}')$$,'image-only failure still creates governed evidence');
select lives_ok($$select public.complete_whatsapp_media_processing('wa4-image','UNREADABLE','attempt-1','{"ocr":"failed"}')$$,'unreadable media outcome persists');
select lives_ok($$select public.complete_whatsapp_media_processing('wa4-image','UNREADABLE','attempt-1','{"replay":true}')$$,'media outcome replay is idempotent');
select is((select count(*) from public.whatsapp_media_processing_events e join public.whatsapp_commercial_evidence w on w.id=e.evidence_id where w.provider_message_id='wa4-image'),1::bigint,'processing replay creates one append-only event');
select is((select state from public.whatsapp_potential_orders p join public.whatsapp_commercial_evidence e on e.potential_order_id=p.id where e.provider_message_id='wa4-image'),'FAILED_INTERPRETATION','media failure remains human-visible');
select is((select queue from public.whatsapp_potential_orders p join public.whatsapp_commercial_evidence e on e.potential_order_id=p.id where e.provider_message_id='wa4-image'),'WA_FAILED_INTERPRETATION','failed media is actionable in correct queue');
select throws_ok(format($$select public.capture_whatsapp_commercial_fragment('84000000-0000-0000-0000-000000000006','%s',null,null,0,false,'{}')$$,(select packet_id from public.whatsapp_commercial_evidence where provider_message_id='wa4-first')),'WA4_PACKET_BOUNDARY_MISMATCH','cross-customer explicit stitching fails closed');
select throws_ok($$update public.whatsapp_commercial_evidence set original_body='invented' where provider_message_id='wa4-first'$$,'WA1_AUDIT_IMMUTABLE','original evidence cannot be overwritten');
select throws_ok($$delete from public.whatsapp_media_processing_events$$,'WA1_AUDIT_IMMUTABLE','media history cannot be deleted');
select is((select unaccounted_potential_orders from public.whatsapp_potential_order_reconciliation),0::bigint,'WA-1 reconciliation remains zero after fragmented and failed-media intake');

select * from finish();
rollback;

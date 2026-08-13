-- Behavioral hostile acceptance for 20260813170000_wa3_clarification_failsafe.sql.
begin;
select plan(24);

insert into public.whatsapp_inbound_messages(id,provider_message_id,sender_phone,message_body,resolver_status) values
 ('83000000-0000-0000-0000-000000000001','wa3-1','919999999999','send 5 baklawa','resolved'),
 ('83000000-0000-0000-0000-000000000002','wa3-2','919999999999','send pistachio','resolved'),
 ('83000000-0000-0000-0000-000000000003','wa3-3','919999999999','send 10 boxes','resolved'),
 ('83000000-0000-0000-0000-000000000004','wa3-4','919999999999','same as last time','resolved'),
 ('83000000-0000-0000-0000-000000000005','wa3-5','919999999999','not 10 boxes, make it 12','resolved'),
 ('83000000-0000-0000-0000-000000000006','wa3-6','919999999999','I meant 5 cartons','resolved'),
 ('83000000-0000-0000-0000-000000000007','wa3-7','919999999999','unreadable attachment','failed');

insert into public.whatsapp_potential_orders(id,source_message_id,provider_message_id,sender_key,source_fingerprint,source_evidence,state,first_received_at,last_evidence_at)
values('83000000-0000-0000-0000-000000000100','83000000-0000-0000-0000-000000000001','wa3-1','919999999999','wa3-hostile',
 (select jsonb_agg(jsonb_build_object('message_id',id)) from public.whatsapp_inbound_messages where id::text like '83000000-0000-0000-0000-00000000000%'),'NEW',now(),now());

select set_config('request.jwt.claims',json_build_object('role','service_role')::text,true);

select lives_ok($$select public.record_whatsapp_order_field_evidence('83000000-0000-0000-0000-000000000100','unit_packaging','83000000-0000-0000-0000-000000000001','wa3-unit-ambiguous',null,'ambiguous',0.4,'5 baklawa')$$,'send 5 baklawa records ambiguous unit without inventing one');
select is((select resolution_state from public.whatsapp_order_field_resolutions where potential_order_id='83000000-0000-0000-0000-000000000100' and field_key='unit_packaging'),'ambiguous','unit remains ambiguous');
select lives_ok($$select public.record_whatsapp_order_field_evidence('83000000-0000-0000-0000-000000000100','quantity','83000000-0000-0000-0000-000000000002','wa3-qty-missing',null,'unresolved',null,'send pistachio')$$,'send pistachio records missing quantity');
select is((select resolved_value from public.whatsapp_order_field_resolutions where potential_order_id='83000000-0000-0000-0000-000000000100' and field_key='quantity'),null::jsonb,'missing quantity never becomes one');
select lives_ok($$select public.record_whatsapp_order_field_evidence('83000000-0000-0000-0000-000000000100','product','83000000-0000-0000-0000-000000000003','wa3-product-missing',null,'unresolved',null,'send 10 boxes')$$,'send 10 boxes records missing product');
select lives_ok($$select public.record_whatsapp_order_field_evidence('83000000-0000-0000-0000-000000000100','product','83000000-0000-0000-0000-000000000004','wa3-repeat-reference',jsonb_build_object('phrase','same as last time'),'historical_reference',0.5,'same as last time')$$,'historical shorthand becomes governed clarification');
select is((select resolution_state from public.whatsapp_order_field_resolutions where potential_order_id='83000000-0000-0000-0000-000000000100' and field_key='product'),'awaiting_clarification','same as last time is not assumed');
select lives_ok($$select public.record_whatsapp_order_field_evidence('83000000-0000-0000-0000-000000000100','product','83000000-0000-0000-0000-000000000002','wa3-product-nickname',jsonb_build_array('PISTACHIO-250','PISTACHIO-500'),'ambiguous',0.55,'pistachio')$$,'nickname matching multiple SKUs remains ambiguous');
select lives_ok($$select public.record_whatsapp_order_field_evidence('83000000-0000-0000-0000-000000000100','quantity','83000000-0000-0000-0000-000000000003','wa3-qty-10','10','resolved',0.98,'10 boxes')$$,'first explicit quantity is retained as evidence');
select lives_ok($$select public.record_whatsapp_order_field_evidence('83000000-0000-0000-0000-000000000100','quantity','83000000-0000-0000-0000-000000000005','wa3-qty-12','12','correction',0.99,'make it 12')$$,'later contradictory quantity is appended');
select is((select resolution_state from public.whatsapp_order_field_resolutions where potential_order_id='83000000-0000-0000-0000-000000000100' and field_key='quantity'),'conflicting','10 to 12 correction requires governed confirmation');
select is((select count(*) from public.whatsapp_order_field_evidence where potential_order_id='83000000-0000-0000-0000-000000000100' and field_key='quantity'),3::bigint,'all missing, original, and corrected quantity evidence survives');
select lives_ok($$select public.record_whatsapp_order_field_evidence('83000000-0000-0000-0000-000000000100','unit_packaging','83000000-0000-0000-0000-000000000006','wa3-carton-correction',jsonb_build_object('unit','carton'),'correction',0.99,'I meant 5 cartons')$$,'box-to-carton correction is evidence, not overwrite');
select lives_ok($$select public.record_whatsapp_order_field_evidence('83000000-0000-0000-0000-000000000100','delivery_address','83000000-0000-0000-0000-000000000007','wa3-ai-failure',null,'ai_failure',null,'unreadable attachment')$$,'AI/media failure fails open into visible work');
select is((select state from public.whatsapp_potential_orders where id='83000000-0000-0000-0000-000000000100'),'AWAITING_CLARIFICATION','fragmented hostile intake remains active and visible');
select ok((select count(*)>0 from public.whatsapp_order_clarification_tasks where potential_order_id='83000000-0000-0000-0000-000000000100' and status='OPEN'),'focused clarification work remains queued');
select ok(not (public.evaluate_whatsapp_order_readiness('83000000-0000-0000-0000-000000000100')->>'ready')::boolean,'one unresolved dimension blocks readiness');
select is((select count(*) from public.whatsapp_order_field_evidence where potential_order_id='83000000-0000-0000-0000-000000000100' and evidence_key='wa3-carton-correction'),1::bigint,'first correction response persisted exactly once');
select lives_ok($$select public.record_whatsapp_order_field_evidence('83000000-0000-0000-0000-000000000100','unit_packaging','83000000-0000-0000-0000-000000000006','wa3-carton-correction',jsonb_build_object('unit','box'),'correction',0.2,'duplicate forward')$$,'duplicate forward is idempotent even when replay payload differs');
select is((select count(*) from public.whatsapp_order_field_evidence where potential_order_id='83000000-0000-0000-0000-000000000100' and evidence_key='wa3-carton-correction'),1::bigint,'duplicate clarification evidence cannot create duplicate commercial work');
select throws_ok($$update public.whatsapp_order_field_evidence set source_excerpt='tampered' where evidence_key='wa3-carton-correction'$$,'WA3_APPEND_ONLY','evidence update is rejected');
select throws_ok($$delete from public.whatsapp_order_field_evidence where evidence_key='wa3-carton-correction'$$,'WA3_APPEND_ONLY','evidence delete is rejected');
insert into public.whatsapp_inbound_messages(id,provider_message_id,sender_phone,message_body) values('83000000-0000-0000-0000-000000000099','wa3-unlinked','918888888888','unlinked');
select throws_ok($$select public.record_whatsapp_order_field_evidence('83000000-0000-0000-0000-000000000100','quantity','83000000-0000-0000-0000-000000000099','wa3-unlinked','9','resolved',1,'unlinked')$$,'WA3_SOURCE_NOT_LINKED','unlinked source evidence is rejected');
select set_config('request.jwt.claims',json_build_object('role','anon')::text,true);
select throws_ok($$select public.record_whatsapp_order_field_evidence('83000000-0000-0000-0000-000000000100','quantity','83000000-0000-0000-0000-000000000005','wa3-unauthorized','12','operator_confirmation',1,'unauthorized')$$,'WA3_TRIAGE_REQUIRED','unauthorized operator cannot correct commercial facts');

select * from finish();
rollback;

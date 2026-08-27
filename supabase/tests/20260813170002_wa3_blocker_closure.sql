-- Runtime closure for generic-draft compatibility and WA-1 durable reconciliation.
begin;
select plan(12);

insert into auth.users(id,email)
values('84000000-0000-0000-0000-000000000001','wa3-blocker@test.invalid');
insert into public.users(id,role,name,is_active)
values('84000000-0000-0000-0000-000000000001','SUPER_ADMIN','WA-3 blocker test',true);
insert into public.user_role_map(user_id,role_id)
select '84000000-0000-0000-0000-000000000001',id from public.roles where role_key='super_admin'
on conflict(user_id,role_id) do nothing;
insert into public.companies(id,business_name,status)
values('84000000-0000-0000-0000-000000000002','WA-3 Test Company','approved');
insert into public.products(id,name,product_name,category,sku,hsn_code,is_active,visible_in_catalog,is_catalogue_ready,moq_value,increment_value,base_price,price_b2b)
values('84000000-0000-0000-0000-000000000003','WA-3 Test Product','WA-3 Test Product','test','WA3-TEST','1905',true,true,true,1,1,650,650);
insert into public.product_pricing_rules(product_id,price_channel,approval_status,base_price,calculated_price,currency,uom,gst_rate,tax_inclusive)
values('84000000-0000-0000-0000-000000000003','b2b','approved',650,650,'INR','box',0,true);
insert into public.product_moq_rules(product_id,channel,moq_applicable,moq_value,increment_value,min_carton_qty)
values('84000000-0000-0000-0000-000000000003','b2b',true,1,1,1);
insert into public.whatsapp_contacts(id,phone_number,customer_name)
values('84000000-0000-0000-0000-000000000004','919111111111','WA-3 Test');
insert into public.whatsapp_message_packets(id,contact_id,stitched_content,first_message_at,last_message_at,status)
values
 ('84000000-0000-0000-0000-000000000005','84000000-0000-0000-0000-000000000004','{}',now(),now(),'closed'),
 ('84000000-0000-0000-0000-000000000006','84000000-0000-0000-0000-000000000004','{}',now(),now(),'closed');

insert into public.whatsapp_inbound_messages(id,provider_message_id,sender_phone,message_body,raw_payload,resolver_status)
values('84000000-0000-0000-0000-000000000007','wa3-blocker-source','919111111111','send pistachio','{"commercial_eligible":true}','failed');

select set_config('request.jwt.claims',json_build_object('sub','84000000-0000-0000-0000-000000000001','role','service_role','aal','aal2')::text,true);
select lives_ok(
 $$select public.capture_whatsapp_potential_order('84000000-0000-0000-0000-000000000007',true,true,'{"test":"wa3-blocker"}')$$,
 'commercial-risk ingress is durably captured even when interpretation fails'
);

insert into public.sales_order_drafts(
 id,packet_id,extraction_request_key,status,company_id,company_name,readiness_overall_score,
 readiness_dimensions,original_whatsapp_text,created_by,updated_by,potential_order_id
) values
 ('84000000-0000-0000-0000-000000000008','84000000-0000-0000-0000-000000000005','generic-ready-v1','UNDER_REVIEW','84000000-0000-0000-0000-000000000002','WA-3 Test Company',100,
  '[{"dimension":"client","status":"ready","score":100},{"dimension":"product","status":"ready","score":100},{"dimension":"quantity","status":"ready","score":100},{"dimension":"address","status":"ready","score":100},{"dimension":"payment_terms","status":"ready","score":100}]','generic source','84000000-0000-0000-0000-000000000001','84000000-0000-0000-0000-000000000001',null),
 ('84000000-0000-0000-0000-000000000009','84000000-0000-0000-0000-000000000006','wa-unresolved-v1','UNDER_REVIEW','84000000-0000-0000-0000-000000000002','WA-3 Test Company',100,
  '[{"dimension":"client","status":"ready","score":100},{"dimension":"product","status":"ready","score":100},{"dimension":"quantity","status":"ready","score":100},{"dimension":"address","status":"ready","score":100},{"dimension":"payment_terms","status":"ready","score":100}]','send pistachio','84000000-0000-0000-0000-000000000001','84000000-0000-0000-0000-000000000001',
  (select id from public.whatsapp_potential_orders where source_message_id='84000000-0000-0000-0000-000000000007'));

insert into public.sales_order_draft_lines(draft_id,line_index,product_id,product_name,sku,raw_quantity,raw_unit,normalized_quantity,normalized_unit)
values
 ('84000000-0000-0000-0000-000000000008',0,'84000000-0000-0000-0000-000000000003','WA-3 Test Product','WA3-TEST',2,'box',2,'box'),
 ('84000000-0000-0000-0000-000000000009',0,'84000000-0000-0000-0000-000000000003','WA-3 Test Product','WA3-TEST',2,'box',2,'box');

select lives_ok(
 $$select * from public.approve_sales_order_draft_for_so_atomic('84000000-0000-0000-0000-000000000008','generic-ready-v1','84000000-0000-0000-0000-000000000001','WA-3 blocker test')$$,
 'valid generic draft follows the canonical approval RPC without a potential-order link'
);
select is((select status from public.sales_order_drafts where id='84000000-0000-0000-0000-000000000008'),'APPROVED_FOR_SO','generic draft reaches APPROVED_FOR_SO');
select ok((select promoted_order_id is not null from public.sales_order_drafts where id='84000000-0000-0000-0000-000000000008'),'generic canonical RPC creates its Sales Order');
select is(
 (select o.order_origin from public.orders o join public.sales_order_drafts d on d.promoted_order_id=o.id where d.id='84000000-0000-0000-0000-000000000008'),
 'WHATSAPP','promoted order preserves truthful WhatsApp provenance'
);
select ok(
 (select o.advance_required=public.calculate_sales_order_advance_v1(o.sales_order_value)
    from public.orders o join public.sales_order_drafts d on d.promoted_order_id=o.id where d.id='84000000-0000-0000-0000-000000000008'),
 'WhatsApp-promoted SO uses the source-independent 30 percent rounded advance'
);

create temporary table wa3_blocked_error(sqlstate text,message text) on commit drop;
do $$begin
 perform * from public.approve_sales_order_draft_for_so_atomic('84000000-0000-0000-0000-000000000009','wa-unresolved-v1','84000000-0000-0000-0000-000000000001','WA-3 blocker test');
exception when others then insert into wa3_blocked_error values(sqlstate,sqlerrm); end$$;
select is((select sqlstate from wa3_blocked_error),'P0001','WhatsApp-governed promotion fails closed');
select ok((select message like 'WA3_COMMERCIAL_DIMENSIONS_UNRESOLVED:%' from wa3_blocked_error),'failure identifies unresolved WA-3 dimensions');
select is((select status from public.sales_order_drafts where id='84000000-0000-0000-0000-000000000009'),'UNDER_REVIEW','blocked WhatsApp draft remains reviewable');

select is(
 (select potential_received),(select converted+active_pending+explicitly_closed)
 ,'reconciliation equation accounts for every commercial potential order'
) from public.whatsapp_potential_order_reconciliation;
select is((select unaccounted_potential_orders from public.whatsapp_potential_order_reconciliation),0::bigint,'unaccounted_potential_orders remains zero');
select is((select count(*) from public.whatsapp_potential_orders where source_message_id='84000000-0000-0000-0000-000000000007'),1::bigint,'durable capture is exactly once');

select * from finish();
rollback;

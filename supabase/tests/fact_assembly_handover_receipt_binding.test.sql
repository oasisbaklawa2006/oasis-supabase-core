begin;
-- Core #176: acknowledged Assembly handover -> canonical return_from_assembly
-- receipt -> physical record -> receiver acceptance -> stock credit.
select plan(33);

select has_function(
  'public',
  'create_b2b_inventory_receipt_from_assembly_handover',
  ARRAY['uuid','text','numeric','text','text'],
  'Assembly-handover receipt binding RPC exists'
);

select is(
  has_function_privilege(
    'authenticated',
    'public.create_b2b_inventory_receipt_from_assembly_handover(uuid,text,numeric,text,text)',
    'EXECUTE'
  ),
  true,
  'authenticated callers may execute the governed Assembly-handover binding RPC'
);

select is(
  has_table_privilege('authenticated', 'public.b2b_inventory_receipts', 'INSERT'),
  false,
  'authenticated cannot directly insert inventory receipts'
);
select is(
  has_table_privilege('authenticated', 'public.b2b_inventory_receipt_lines', 'UPDATE'),
  false,
  'authenticated cannot directly update inventory receipt lines'
);

insert into public.users (id, role) values
  ('17600000-0000-0000-0000-000000000001', 'INVENTORY_MANAGER'),
  ('17600000-0000-0000-0000-000000000002', 'STORE_INCHARGE'),
  ('17600000-0000-0000-0000-000000000003', 'SALES');

insert into public.products (id, name, category, sku, hsn_code, production_department) values
  ('27600000-0000-0000-0000-000000000001', 'FACT Assembly Output', 'hampers', 'FACT-ASM-OUT-176', '1905', null),
  ('27600000-0000-0000-0000-000000000002', 'Caller Substitute Product', 'hampers', 'FACT-ASM-FAKE-176', '1905', null);

insert into public.orders (id, order_number, tracking_token, order_origin) values
  ('37600000-0000-0000-0000-000000000001', 'FACT-ASM-ORDER-176', 'fact-asm-token-176', 'MANUAL');

insert into public.b2b_assembly_jobs (
  id, assembly_job_number, order_id, output_product_id, output_sku,
  planned_qty, completed_qty, accepted_qty, rejected_qty, status, correlation_id
) values (
  '47600000-0000-0000-0000-000000000001', 'FACT-ASM-JOB-176',
  '37600000-0000-0000-0000-000000000001',
  '27600000-0000-0000-0000-000000000001', 'FACT-ASM-OUT-176',
  10, 10, 10, 0, 'accepted', 'fact-asm-job-176'
);

insert into public.b2b_assembly_handovers (
  id, assembly_job_id, destination_type, destination_reference, dispatched_qty,
  dispatched_by, receiver_id, received_qty, acknowledged_at, status, correlation_id
) values (
  '57600000-0000-0000-0000-000000000001',
  '47600000-0000-0000-0000-000000000001',
  'RGS', 'FINISHED_GOODS', 10,
  '17600000-0000-0000-0000-000000000002',
  '17600000-0000-0000-0000-000000000001',
  10, now(), 'acknowledged', 'fact-asm-handover-176'
);

set local request.jwt.claim.sub = '17600000-0000-0000-0000-000000000001';
set local request.jwt.claim.role = 'authenticated';

select throws_like(
  $$ select public.create_b2b_inventory_receipt(
       'FACT-RAW-RETURN-176', 'return_from_assembly', 'FINISHED_GOODS',
       'manual', 'caller-supplied-fake-handover',
       jsonb_build_array(jsonb_build_object(
         'product_id','27600000-0000-0000-0000-000000000002',
         'sku','FACT-ASM-FAKE-176','expected_qty',10
       )),
       'fact-raw-return-176'
     ) $$,
  '%must be created from an acknowledged Assembly handover%',
  'generic receipt opener cannot fabricate return_from_assembly lineage/product truth'
);

select lives_ok(
  $$ select public.create_b2b_inventory_receipt_from_assembly_handover(
       '57600000-0000-0000-0000-000000000001',
       'FACT-ASM-RCPT-176-1', 6, 'fact-asm-bind-176-1', 'first partial bound receipt'
     ) $$,
  'acknowledged Assembly handover opens a canonical partial return receipt'
);

select is(
  (select receipt_source || '|' || destination_store_code || '|' || source_document_type || '|' || source_document_reference
   from public.b2b_inventory_receipts where correlation_id='fact-asm-bind-176-1'),
  'return_from_assembly|FINISHED_GOODS|b2b_assembly_handover|57600000-0000-0000-0000-000000000001',
  'receipt source, destination and handover lineage are server-bound'
);

select is(
  (select product_id::text || '|' || sku || '|' || expected_qty::text
   from public.b2b_inventory_receipt_lines l
   join public.b2b_inventory_receipts r on r.id=l.receipt_id
   where r.correlation_id='fact-asm-bind-176-1'),
  '27600000-0000-0000-0000-000000000001|FACT-ASM-OUT-176|6',
  'receipt line product/SKU come from Assembly output and expected quantity is bounded input'
);

select is(
  coalesce((select available_qty from public.inventory_stock_balances
    where product_id='27600000-0000-0000-0000-000000000001'
      and sku='FACT-ASM-OUT-176' and location_code='FINISHED_GOODS'),0::numeric),
  0::numeric,
  'opening the bound receipt does not credit stock'
);

select lives_ok(
  $$ select public.create_b2b_inventory_receipt_from_assembly_handover(
       '57600000-0000-0000-0000-000000000001',
       'FACT-ASM-RCPT-176-1', 6, 'fact-asm-bind-176-1', 'replay notes may differ without changing authority'
     ) $$,
  'exact correlation replay returns the same bound receipt'
);
select is(
  (select count(*)::int from public.b2b_inventory_receipts where correlation_id='fact-asm-bind-176-1'),
  1,
  'exact replay does not duplicate the receipt'
);

select throws_like(
  $$ select public.create_b2b_inventory_receipt_from_assembly_handover(
       '57600000-0000-0000-0000-000000000001',
       'FACT-ASM-RCPT-176-1', 5, 'fact-asm-bind-176-1', null
     ) $$,
  '%conflicts with existing line identity or quantity%',
  'same correlation id with changed quantity fails closed'
);

select lives_ok(
  $$ select public.create_b2b_inventory_receipt_from_assembly_handover(
       '57600000-0000-0000-0000-000000000001',
       'FACT-ASM-RCPT-176-2', 4, 'fact-asm-bind-176-2', null
     ) $$,
  'second cumulative bound receipt may reserve the acknowledged remainder'
);

select throws_like(
  $$ select public.create_b2b_inventory_receipt_from_assembly_handover(
       '57600000-0000-0000-0000-000000000001',
       'FACT-ASM-RCPT-176-OVER', 1, 'fact-asm-bind-176-over', null
     ) $$,
  '%exceeds remaining acknowledged handover quantity 0%',
  'pending bound receipts cannot cumulatively oversubscribe one acknowledged handover'
);

select throws_like(
  $$ select public.record_b2b_inventory_receipt(
       (select id from public.b2b_inventory_receipts where correlation_id='fact-asm-bind-176-1'),
       jsonb_build_array(jsonb_build_object(
         'line_id',(select l.id from public.b2b_inventory_receipt_lines l join public.b2b_inventory_receipts r on r.id=l.receipt_id where r.correlation_id='fact-asm-bind-176-1'),
         'received_qty',7
       )),
       'fact-asm-bind-176-1'
     ) $$,
  '%exceeds bound expected quantity 6%',
  'physical Assembly-return recording cannot exceed the handover-bound receipt quantity'
);

select is(
  (select count(*)::int from public.inventory_movements
   where movement_type='returned_from_assembly'
     and source_document_type='b2b_assembly_handover'
     and source_document_reference='57600000-0000-0000-0000-000000000001'),
  0,
  'rejected physical over-receipt creates no stock movement evidence'
);

select lives_ok(
  $$ select public.record_b2b_inventory_receipt(
       (select id from public.b2b_inventory_receipts where correlation_id='fact-asm-bind-176-1'),
       jsonb_build_array(jsonb_build_object(
         'line_id',(select l.id from public.b2b_inventory_receipt_lines l join public.b2b_inventory_receipts r on r.id=l.receipt_id where r.correlation_id='fact-asm-bind-176-1'),
         'received_qty',6
       )),
       'fact-asm-bind-176-1'
     ) $$,
  'physical receipt is recorded through the existing governed receipt RPC'
);

select is(
  coalesce((select available_qty from public.inventory_stock_balances
    where product_id='27600000-0000-0000-0000-000000000001'
      and sku='FACT-ASM-OUT-176' and location_code='FINISHED_GOODS'),0::numeric),
  0::numeric,
  'physical record still does not credit stock before receiver acceptance'
);

select lives_ok(
  $$ select public.accept_b2b_inventory_receipt(
       (select id from public.b2b_inventory_receipts where correlation_id='fact-asm-bind-176-1'),
       jsonb_build_array(jsonb_build_object(
         'line_id',(select l.id from public.b2b_inventory_receipt_lines l join public.b2b_inventory_receipts r on r.id=l.receipt_id where r.correlation_id='fact-asm-bind-176-1'),
         'accepted_qty',6,'damaged_qty',0,'rejected_qty',0,'expected_balance_version',0
       )),
       'fact-asm-bind-176-1'
     ) $$,
  'receiver acceptance remains the sole stock-credit step'
);

select is(
  (select available_qty from public.inventory_stock_balances
    where product_id='27600000-0000-0000-0000-000000000001'
      and sku='FACT-ASM-OUT-176' and location_code='FINISHED_GOODS'),
  0::numeric,
  'accepted Assembly return remains unavailable until governed put-away and GRN finalisation'
);

select is(
  (select count(*)::int from public.inventory_movements
   where movement_type='returned_from_assembly'
     and product_id='27600000-0000-0000-0000-000000000001'
     and sku='FACT-ASM-OUT-176'
     and quantity=6
     and destination_location='FINISHED_GOODS'
     and source_document_type='b2b_assembly_handover'
     and source_document_reference='57600000-0000-0000-0000-000000000001'),
  1,
  'returned_from_assembly movement preserves exact Assembly handover lineage'
);

-- Receipt 2 was expected as 4 but physically only 2 arrived. After terminal
-- acceptance, the unreceived shortfall must become receivable again rather
-- than permanently consuming the handover.
select lives_ok(
  $$ select public.record_b2b_inventory_receipt(
       (select id from public.b2b_inventory_receipts where correlation_id='fact-asm-bind-176-2'),
       jsonb_build_array(jsonb_build_object(
         'line_id',(select l.id from public.b2b_inventory_receipt_lines l join public.b2b_inventory_receipts r on r.id=l.receipt_id where r.correlation_id='fact-asm-bind-176-2'),
         'received_qty',2
       )),
       'fact-asm-bind-176-2'
     ) $$,
  'a later cumulative receipt may physically arrive short'
);

select lives_ok(
  $$ select public.accept_b2b_inventory_receipt(
       (select id from public.b2b_inventory_receipts where correlation_id='fact-asm-bind-176-2'),
       jsonb_build_array(jsonb_build_object(
         'line_id',(select l.id from public.b2b_inventory_receipt_lines l join public.b2b_inventory_receipts r on r.id=l.receipt_id where r.correlation_id='fact-asm-bind-176-2'),
         'accepted_qty',2,'damaged_qty',0,'rejected_qty',0,
         'expected_balance_version',(select version from public.inventory_stock_balances where product_id='27600000-0000-0000-0000-000000000001' and sku='FACT-ASM-OUT-176' and location_code='FINISHED_GOODS')
       )),
       'fact-asm-bind-176-2'
     ) $$,
  'short physical arrival can be accepted without bypassing canonical stock authority'
);

select is(
  (select available_qty from public.inventory_stock_balances
    where product_id='27600000-0000-0000-0000-000000000001'
      and sku='FACT-ASM-OUT-176' and location_code='FINISHED_GOODS'),
  0::numeric,
  'cumulative accepted Assembly-return stock remains unavailable pending governed put-away and GRN'
);

select lives_ok(
  $$ select public.create_b2b_inventory_receipt_from_assembly_handover(
       '57600000-0000-0000-0000-000000000001',
       'FACT-ASM-RCPT-176-3', 2, 'fact-asm-bind-176-3', null
     ) $$,
  'terminal short receipt releases only its unreceived remainder for a later bound receipt'
);

select throws_like(
  $$ select public.create_b2b_inventory_receipt_from_assembly_handover(
       '57600000-0000-0000-0000-000000000001',
       'FACT-ASM-RCPT-176-4', 1, 'fact-asm-bind-176-4', null
     ) $$,
  '%exceeds remaining acknowledged handover quantity 0%',
  'accepted plus outstanding bound receipt quantity can never exceed acknowledged custody'
);

-- Negative handover states.
insert into public.b2b_assembly_handovers (
  id, assembly_job_id, destination_type, destination_reference, dispatched_qty,
  dispatched_by, status, correlation_id
) values
  ('57600000-0000-0000-0000-000000000002','47600000-0000-0000-0000-000000000001','RGS','FINISHED_GOODS',1,'17600000-0000-0000-0000-000000000002','pending_acknowledgement','fact-asm-hand-pending'),
  ('57600000-0000-0000-0000-000000000003','47600000-0000-0000-0000-000000000001','RGS','FINISHED_GOODS',1,'17600000-0000-0000-0000-000000000002','disputed','fact-asm-hand-disputed'),
  ('57600000-0000-0000-0000-000000000004','47600000-0000-0000-0000-000000000001','RGS','FINISHED_GOODS',1,'17600000-0000-0000-0000-000000000002','cancelled','fact-asm-hand-cancelled');

select throws_like(
  $$ select public.create_b2b_inventory_receipt_from_assembly_handover('57600000-0000-0000-0000-000000000002','FACT-PENDING',1,'fact-pending-bind',null) $$,
  '%not fully acknowledged%',
  'unacknowledged Assembly handover fails closed'
);
select throws_like(
  $$ select public.create_b2b_inventory_receipt_from_assembly_handover('57600000-0000-0000-0000-000000000003','FACT-DISPUTED',1,'fact-disputed-bind',null) $$,
  '%not fully acknowledged%',
  'disputed Assembly handover fails closed'
);
select throws_like(
  $$ select public.create_b2b_inventory_receipt_from_assembly_handover('57600000-0000-0000-0000-000000000004','FACT-CANCELLED',1,'fact-cancelled-bind',null) $$,
  '%not fully acknowledged%',
  'cancelled Assembly handover fails closed'
);

insert into public.b2b_assembly_handovers (
  id, assembly_job_id, destination_type, destination_reference, dispatched_qty,
  dispatched_by, receiver_id, received_qty, acknowledged_at, status, correlation_id
) values (
  '57600000-0000-0000-0000-000000000005','47600000-0000-0000-0000-000000000001',
  'OUTLET','OUTLET-NOT-A-B2B-STORE',1,
  '17600000-0000-0000-0000-000000000002','17600000-0000-0000-0000-000000000001',
  1,now(),'acknowledged','fact-asm-hand-nonstore'
);
select throws_like(
  $$ select public.create_b2b_inventory_receipt_from_assembly_handover('57600000-0000-0000-0000-000000000005','FACT-NONSTORE',1,'fact-nonstore-bind',null) $$,
  '%not an active canonical inventory store%',
  'acknowledged handover to a non-store destination cannot be converted into stock'
);

set local request.jwt.claim.sub = '17600000-0000-0000-0000-000000000003';
select throws_like(
  $$ select public.create_b2b_inventory_receipt_from_assembly_handover('57600000-0000-0000-0000-000000000001','FACT-UNAUTH',1,'fact-unauth-bind',null) $$,
  '%Not authorised%',
  'unauthorised actor cannot bind Assembly custody into inventory receipt authority'
);

set local request.jwt.claim.sub = '17600000-0000-0000-0000-000000000001';
select throws_like(
  $$ insert into public.b2b_inventory_receipts(
       receipt_number,receipt_source,destination_store_code,source_document_type,source_document_reference,status,correlation_id
     ) values (
       'FACT-BAD-SHAPE','return_from_assembly','FINISHED_GOODS','manual','fake','expected','fact-bad-shape'
     ) $$,
  '%violates check constraint%',
  'database constraint rejects new unbound return_from_assembly source-document shape even outside the RPC'
);

select lives_ok(
  $$ select public.create_b2b_inventory_receipt(
       'FACT-OPENING-176','opening_balance','FINISHED_GOODS','manual_count','FACT-OPENING-176',
       jsonb_build_array(jsonb_build_object(
         'product_id','27600000-0000-0000-0000-000000000001',
         'sku','FACT-ASM-OUT-176','expected_qty',1
       )),
       'fact-opening-176'
     ) $$,
  'generic opening-balance receipt path remains unchanged'
);

select * from finish();
rollback;
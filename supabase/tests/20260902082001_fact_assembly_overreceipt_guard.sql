begin;
select plan(2);

insert into public.users (id, role) values
  ('17610000-0000-0000-0000-000000000001', 'INVENTORY_MANAGER'),
  ('17610000-0000-0000-0000-000000000002', 'STORE_INCHARGE');

insert into public.products (id, name, category, sku, hsn_code, production_department) values
  ('27610000-0000-0000-0000-000000000001', 'FACT Overreceipt Output', 'hampers', 'FACT-ASM-OVER-176', '1905', null);

insert into public.orders (id, order_number, tracking_token, order_origin) values
  ('37610000-0000-0000-0000-000000000001', 'FACT-ASM-OVER-176', 'fact-asm-over-token-176', 'MANUAL');

insert into public.b2b_assembly_jobs (
  id, assembly_job_number, order_id, output_product_id, output_sku,
  planned_qty, completed_qty, accepted_qty, rejected_qty, status, correlation_id
) values (
  '47610000-0000-0000-0000-000000000001', 'FACT-ASM-OVER-JOB-176',
  '37610000-0000-0000-0000-000000000001',
  '27610000-0000-0000-0000-000000000001', 'FACT-ASM-OVER-176',
  6, 6, 6, 0, 'accepted', 'fact-asm-over-job-176'
);

insert into public.b2b_assembly_handovers (
  id, assembly_job_id, destination_type, destination_reference, dispatched_qty,
  dispatched_by, receiver_id, received_qty, acknowledged_at, status, correlation_id
) values (
  '57610000-0000-0000-0000-000000000001',
  '47610000-0000-0000-0000-000000000001',
  'RGS', 'FINISHED_GOODS', 6,
  '17610000-0000-0000-0000-000000000002',
  '17610000-0000-0000-0000-000000000001',
  6, now(), 'acknowledged', 'fact-asm-over-handover-176'
);

set local request.jwt.claim.sub = '17610000-0000-0000-0000-000000000001';
set local request.jwt.claim.role = 'authenticated';

select lives_ok(
  $$ select public.create_b2b_inventory_receipt_from_assembly_handover(
       '57610000-0000-0000-0000-000000000001',
       'FACT-ASM-OVER-RCPT-176', 6, 'fact-asm-over-bind-176', null
     ) $$,
  'acknowledged handover may reserve its exact physical quantity'
);

select throws_like(
  $$ select public.record_b2b_inventory_receipt(
       (select id from public.b2b_inventory_receipts where correlation_id='fact-asm-over-bind-176'),
       jsonb_build_array(jsonb_build_object(
         'line_id',(select l.id from public.b2b_inventory_receipt_lines l
                    join public.b2b_inventory_receipts r on r.id=l.receipt_id
                    where r.correlation_id='fact-asm-over-bind-176'),
         'received_qty',7
       )),
       'fact-asm-over-bind-176'
     ) $$,
  '%exceeds bound expected quantity%',
  'physical recording cannot over-receive beyond the Assembly quantity reserved from acknowledged custody'
);

select * from finish();
rollback;

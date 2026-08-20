begin;
-- Contract coverage for 20260819120000_pna_assembly_job_governed_authority.sql:
-- governed assembly job lifecycle RPCs on b2b_assembly_jobs/b2b_assembly_components.
select plan(33);

select has_function('public', 'create_assembly_job', 'create_assembly_job exists');
select has_function('public', 'reserve_assembly_components', 'reserve_assembly_components exists');
select has_function('public', 'issue_assembly_components', 'issue_assembly_components exists');
select has_function('public', 'record_assembly_consumption', 'record_assembly_consumption exists');
select has_function('public', 'complete_assembly_job', 'complete_assembly_job exists');
select has_function('public', 'accept_assembly_output', 'accept_assembly_output exists');
select has_function('public', 'mark_assembly_handed_over', 'mark_assembly_handed_over exists');
select has_function('public', 'close_assembly_job', 'close_assembly_job exists');

-- Direct table writes are revoked now that the RPC layer exists.
select is(
  (select has_table_privilege('authenticated', 'public.b2b_assembly_jobs', 'INSERT')),
  false, 'authenticated cannot directly insert b2b_assembly_jobs'
);
select is(
  (select has_table_privilege('authenticated', 'public.b2b_assembly_components', 'UPDATE')),
  false, 'authenticated cannot directly update b2b_assembly_components'
);

insert into public.users (id, role) values
  ('17000000-0000-0000-0000-000000000001', 'HOD_ASSEMBLY');
insert into public.products (id, name, category, sku, hsn_code, production_department) values
  ('27000000-0000-0000-0000-000000000001', 'Hamper Box Output', 'hampers', 'HAMPER-OUT-1', '1905', null),
  ('27000000-0000-0000-0000-000000000002', 'Kunafa Roll Component', 'sweets', 'KUNAFA-COMP-1', '1905', 'arabic_sweets'),
  ('27000000-0000-0000-0000-000000000003', 'Ribbon Packaging Component', 'packaging', 'RIBBON-COMP-1', '4823', null);
insert into public.orders (id, order_number, tracking_token) values
  ('37000000-0000-0000-0000-000000000001', 'PGTAP-ORD-ASSEMBLY-1', 'pgtap-fixture-token-assembly-1');

-- Food component has only partial stock (shortfall must route to RGS/Production).
insert into public.inventory_stock_balances (product_id, sku, location_code, available_qty) values
  ('27000000-0000-0000-0000-000000000002', 'KUNAFA-COMP-1', 'FINISHED_GOODS', 4);
-- Packaging component is fully short (must NOT route to Production).
insert into public.inventory_stock_balances (product_id, sku, location_code, available_qty) values
  ('27000000-0000-0000-0000-000000000003', 'RIBBON-COMP-1', '3PGS', 0);

set local request.jwt.claim.sub = '17000000-0000-0000-0000-000000000001';
set local request.jwt.claim.role = 'authenticated';

select lives_ok(
  $$ select public.create_assembly_job(
       'ASM-JOB-1', '37000000-0000-0000-0000-000000000001',
       '27000000-0000-0000-0000-000000000001', 'HAMPER-OUT-1', 20,
       jsonb_build_array(
         jsonb_build_object('product_id', '27000000-0000-0000-0000-000000000002', 'sku', 'KUNAFA-COMP-1', 'source_store_code', 'FINISHED_GOODS', 'required_qty', 10),
         jsonb_build_object('product_id', '27000000-0000-0000-0000-000000000003', 'sku', 'RIBBON-COMP-1', 'source_store_code', '3PGS', 'required_qty', 20)
       ),
       'corr-asm-create-1'
     ) $$,
  'create_assembly_job opens a job with its components'
);
select is(
  (select status from public.b2b_assembly_jobs where assembly_job_number = 'ASM-JOB-1'),
  'planned', 'new job starts in planned status'
);
select is(
  (select count(*)::int from public.b2b_assembly_components c
     join public.b2b_assembly_jobs j on j.id = c.assembly_job_id
     where j.assembly_job_number = 'ASM-JOB-1'),
  2, 'both components were snapshotted'
);
select lives_ok(
  $$ select public.create_assembly_job(
       'ASM-JOB-1-REPLAY', '37000000-0000-0000-0000-000000000001',
       '27000000-0000-0000-0000-000000000001', 'HAMPER-OUT-1', 20,
       jsonb_build_array(jsonb_build_object('product_id', '27000000-0000-0000-0000-000000000002', 'sku', 'KUNAFA-COMP-1', 'source_store_code', 'FINISHED_GOODS', 'required_qty', 10)),
       'corr-asm-create-1'
     ) $$,
  'repeat create_assembly_job with same correlation_id is idempotent'
);
select is(
  (select count(*)::int from public.b2b_assembly_jobs where correlation_id = 'corr-asm-create-1'),
  1, 'idempotent replay created no duplicate job'
);

select lives_ok(
  $$ select public.reserve_assembly_components(
       (select id from public.b2b_assembly_jobs where assembly_job_number = 'ASM-JOB-1'),
       'normal', 'corr-asm-reserve-1'
     ) $$,
  'reserve_assembly_components succeeds'
);
select is(
  (select status from public.b2b_assembly_jobs where assembly_job_number = 'ASM-JOB-1'),
  'materials_reserved', 'job moves to materials_reserved after reservation'
);
select is(
  (select c.reserved_qty from public.b2b_assembly_components c
     join public.b2b_assembly_jobs j on j.id = c.assembly_job_id
     where j.assembly_job_number = 'ASM-JOB-1' and c.sku = 'KUNAFA-COMP-1'),
  4::numeric, 'food component reserves only the available quantity'
);

-- Food shortfall (10 required, 4 available) must route to RGS then Production
-- via the existing governed RPCs, never a direct P&A -> Production write.
select is(
  (select count(*)::int from public.inventory_reservations
     where demand_source_type = 'pna' and demand_reference = 'ASM-JOB-1'
       and product_id = '27000000-0000-0000-0000-000000000002'),
  1, 'a food shortfall opens an RGS demand-source reservation'
);
select is(
  (select count(*)::int from public.production_jobs pj
     join public.inventory_reservations ir on ir.id = pj.reservation_id
     where ir.demand_source_type = 'pna' and ir.demand_reference = 'ASM-JOB-1'),
  1, 'the unmet food shortfall is routed to a Production shortage job'
);

-- Packaging shortfall (20 required, 0 available at 3PGS) must NOT create any
-- production_jobs row -- packaging/outsourced/giftware never goes to Production.
select is(
  (select count(*)::int from public.production_jobs pj
     join public.b2b_assembly_components c on c.product_id = pj.product_id
     where c.sku = 'RIBBON-COMP-1'),
  0, 'a packaging shortfall never creates a production shortage job'
);
select is(
  (select c.reserved_qty from public.b2b_assembly_components c
     join public.b2b_assembly_jobs j on j.id = c.assembly_job_id
     where j.assembly_job_number = 'ASM-JOB-1' and c.sku = 'RIBBON-COMP-1'),
  0::numeric, 'the packaging component is left under-reserved for 3PGS to action'
);

select lives_ok(
  $$ select public.issue_assembly_components(
       (select id from public.b2b_assembly_jobs where assembly_job_number = 'ASM-JOB-1'), 'corr-asm-issue-1'
     ) $$,
  'issue_assembly_components succeeds'
);
select is(
  (select status from public.b2b_assembly_jobs where assembly_job_number = 'ASM-JOB-1'),
  'issued', 'job moves to issued after issuance'
);

select lives_ok(
  $$ select public.record_assembly_consumption(
       (select c.id from public.b2b_assembly_components c
          join public.b2b_assembly_jobs j on j.id = c.assembly_job_id
          where j.assembly_job_number = 'ASM-JOB-1' and c.sku = 'KUNAFA-COMP-1'),
       4, 0, 0, 'corr-asm-consume-1'
     ) $$,
  'record_assembly_consumption succeeds'
);
select is(
  (select status from public.b2b_assembly_jobs where assembly_job_number = 'ASM-JOB-1'),
  'in_progress', 'job moves to in_progress on first consumption'
);

select lives_ok(
  $$ select public.complete_assembly_job(
       (select id from public.b2b_assembly_jobs where assembly_job_number = 'ASM-JOB-1'), 18, 'corr-asm-complete-1'
     ) $$,
  'complete_assembly_job succeeds'
);
select lives_ok(
  $$ select public.accept_assembly_output(
       (select id from public.b2b_assembly_jobs where assembly_job_number = 'ASM-JOB-1'), 18, 0, 'corr-asm-accept-1'
     ) $$,
  'accept_assembly_output succeeds'
);
select is(
  (select status from public.b2b_assembly_jobs where assembly_job_number = 'ASM-JOB-1'),
  'accepted', 'job is fully accepted (Ready)'
);

-- Accepting output must never itself credit any RGS/3PGS-owned stock balance.
select is(
  (select available_qty from public.inventory_stock_balances where sku = 'KUNAFA-COMP-1' and location_code = 'FINISHED_GOODS'),
  0::numeric, 'accept_assembly_output does not credit the RGS-owned FINISHED_GOODS balance'
);

select lives_ok(
  $$ select public.mark_assembly_handed_over(
       (select id from public.b2b_assembly_jobs where assembly_job_number = 'ASM-JOB-1'), 'corr-asm-handover-1'
     ) $$,
  'mark_assembly_handed_over succeeds after acceptance'
);
select lives_ok(
  $$ select public.close_assembly_job(
       (select id from public.b2b_assembly_jobs where assembly_job_number = 'ASM-JOB-1'), 'corr-asm-close-1'
     ) $$,
  'close_assembly_job succeeds after handover'
);
select is(
  (select (handed_over_at is not null)::text || '|' || (job_closed_at is not null)::text
     from public.b2b_assembly_jobs where assembly_job_number = 'ASM-JOB-1'),
  'true|true', 'Ready, Handed Over and Job Closed are distinct, all separately timestamped'
);

select finish();
rollback;

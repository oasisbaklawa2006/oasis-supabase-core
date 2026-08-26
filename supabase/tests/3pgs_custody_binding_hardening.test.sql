begin;

-- Contract coverage for 20260825101000_3pgs_custody_binding_hardening.sql.
-- Proves that P&A credit can only be reached through the dedicated 3PGS
-- acknowledgement wrapper, and that the wrapper rejects wrong-material or
-- wrong-reservation-lineage issue events even when their destination reference
-- is forged to the target requirement number.
select plan(17);

select has_function(
  'public',
  'acknowledge_3pgs_requirement_receipt',
  'authoritative 3PGS acknowledgement wrapper exists'
);

select is(
  has_function_privilege(
    'authenticated',
    'public.fulfil_assembly_3pgs_requirement(uuid,numeric,text)',
    'EXECUTE'
  ),
  false,
  'authenticated sessions cannot execute the internal fulfil helper directly'
);

insert into public.users (id, role) values
  ('59000000-0000-0000-0000-000000000001', 'INVENTORY_MANAGER'),
  ('59000000-0000-0000-0000-000000000002', 'STORE_READY_GOODS');

insert into public.products (id, name, category, sku, hsn_code, production_department) values
  ('69000000-0000-0000-0000-000000000001', 'Target Packing Material', 'packaging', 'BIND-TARGET-1', '4823', null),
  ('69000000-0000-0000-0000-000000000002', 'Wrong Packing Material', 'packaging', 'BIND-WRONG-1', '4823', null);

insert into public.orders (id, order_number, tracking_token) values
  ('79000000-0000-0000-0000-000000000001', 'PGTAP-ORD-3PGS-BIND-1', 'pgtap-3pgs-bind-token');

insert into public.inventory_stock_balances (product_id, sku, location_code, available_qty) values
  ('69000000-0000-0000-0000-000000000001', 'BIND-TARGET-1', '3PGS', 0),
  ('69000000-0000-0000-0000-000000000002', 'BIND-WRONG-1', '3PGS', 10);

set local request.jwt.claim.sub = '59000000-0000-0000-0000-000000000001';
set local request.jwt.claim.role = 'authenticated';

select lives_ok(
  $$ select public.create_assembly_job(
       'ASM-3PGS-BIND-1',
       '79000000-0000-0000-0000-000000000001',
       '69000000-0000-0000-0000-000000000001',
       'BIND-TARGET-1',
       1,
       jsonb_build_array(jsonb_build_object(
         'product_id', '69000000-0000-0000-0000-000000000001',
         'sku', 'BIND-TARGET-1',
         'source_store_code', '3PGS',
         'required_qty', 5
       )),
       'corr-bind-job-1'
     ) $$,
  'assembly job for the target 3PGS material is created'
);

select lives_ok(
  $$ select public.reserve_assembly_components(
       (select id from public.b2b_assembly_jobs where assembly_job_number = 'ASM-3PGS-BIND-1'),
       'normal',
       'corr-bind-assembly-reserve-1'
     ) $$,
  'zero stock raises the real governed 3PGS requirement'
);

select is(
  (select status from public.b2b_assembly_jobs where assembly_job_number = 'ASM-3PGS-BIND-1'),
  'partially_reserved',
  'target assembly job is blocked while the 3PGS requirement is unresolved'
);

-- Attack A: wrong product, forged destination reference. The generic RGS
-- primitives can create legitimate custody for another material; that custody
-- must not be usable as evidence for the target P&A requirement.
select lives_ok(
  $$ select public.reserve_rgs_stock(
       'EVIL-WRONG-MATERIAL-RES',
       null,
       '69000000-0000-0000-0000-000000000002',
       'BIND-WRONG-1',
       5,
       '3PGS',
       'corr-bind-wrong-reserve',
       'normal',
       '3PGS',
       null,
       null,
       'internal',
       'evil-unrelated-demand'
     ) $$,
  'unrelated wrong-material stock can be reserved normally'
);

select lives_ok(
  $$ select public.issue_rgs_stock(
       (select id from public.inventory_reservations where correlation_id = 'corr-bind-wrong-reserve'),
       5,
       'pna',
       (select requirement_number from public.b2b_assembly_3pgs_requirements
          where assembly_job_id = (select id from public.b2b_assembly_jobs where assembly_job_number = 'ASM-3PGS-BIND-1')),
       'corr-bind-wrong-issue'
     ) $$,
  'wrong-material issue can carry a forged target destination reference'
);

set local request.jwt.claim.sub = '59000000-0000-0000-0000-000000000002';
select throws_like(
  $$ select public.acknowledge_3pgs_requirement_receipt(
       (select id from public.rgs_issue_events where correlation_id = 'corr-bind-wrong-issue'),
       5,
       'corr-bind-wrong-ack'
     ) $$,
  '%material does not match%',
  'wrong-product/wrong-SKU custody cannot satisfy the target 3PGS requirement'
);

select is(
  (select fulfilled_qty from public.b2b_assembly_3pgs_requirements
     where assembly_job_id = (select id from public.b2b_assembly_jobs where assembly_job_number = 'ASM-3PGS-BIND-1')),
  0::numeric,
  'rejected wrong-material evidence leaves requirement fulfilment at zero'
);

-- Attack B: exact product/SKU but reservation lineage is unrelated. Seed real
-- target stock, create a generic reservation under a different demand reference,
-- and forge only the issue destination reference.
set local request.jwt.claim.sub = '59000000-0000-0000-0000-000000000001';
update public.inventory_stock_balances
set available_qty = 10
where product_id = '69000000-0000-0000-0000-000000000001'
  and sku = 'BIND-TARGET-1'
  and location_code = '3PGS';

select lives_ok(
  $$ select public.reserve_rgs_stock(
       'EVIL-WRONG-LINEAGE-RES',
       null,
       '69000000-0000-0000-0000-000000000001',
       'BIND-TARGET-1',
       2,
       '3PGS',
       'corr-bind-lineage-reserve',
       'normal',
       '3PGS',
       null,
       null,
       'internal',
       'evil-unrelated-demand-2'
     ) $$,
  'same-material but unrelated reservation can be created normally'
);

select lives_ok(
  $$ select public.issue_rgs_stock(
       (select id from public.inventory_reservations where correlation_id = 'corr-bind-lineage-reserve'),
       2,
       'pna',
       (select requirement_number from public.b2b_assembly_3pgs_requirements
          where assembly_job_id = (select id from public.b2b_assembly_jobs where assembly_job_number = 'ASM-3PGS-BIND-1')),
       'corr-bind-lineage-issue'
     ) $$,
  'same-material unrelated issue can carry a forged target destination reference'
);

set local request.jwt.claim.sub = '59000000-0000-0000-0000-000000000002';
select throws_like(
  $$ select public.acknowledge_3pgs_requirement_receipt(
       (select id from public.rgs_issue_events where correlation_id = 'corr-bind-lineage-issue'),
       2,
       'corr-bind-lineage-ack'
     ) $$,
  '%reservation does not belong%',
  'same-material custody with wrong reservation lineage cannot satisfy the requirement'
);

-- Positive control: the real requirement-specific reserve -> issue -> distinct
-- receiver acknowledgement path still succeeds after hardening.
set local request.jwt.claim.sub = '59000000-0000-0000-0000-000000000001';
select lives_ok(
  $$ select public.reserve_3pgs_requirement_stock(
       (select id from public.b2b_assembly_3pgs_requirements
          where assembly_job_id = (select id from public.b2b_assembly_jobs where assembly_job_number = 'ASM-3PGS-BIND-1')),
       'normal',
       'corr-bind-valid-reserve'
     ) $$,
  'real requirement-specific reservation succeeds'
);

select lives_ok(
  $$ select public.issue_3pgs_requirement_stock(
       (select id from public.b2b_assembly_3pgs_requirements
          where assembly_job_id = (select id from public.b2b_assembly_jobs where assembly_job_number = 'ASM-3PGS-BIND-1')),
       (select id from public.inventory_reservations where correlation_id = 'corr-bind-valid-reserve'),
       5,
       'corr-bind-valid-issue'
     ) $$,
  'real requirement-specific issue succeeds'
);

set local request.jwt.claim.sub = '59000000-0000-0000-0000-000000000002';
select lives_ok(
  $$ select public.acknowledge_3pgs_requirement_receipt(
       (select id from public.rgs_issue_events where correlation_id = 'corr-bind-valid-issue'),
       5,
       'corr-bind-valid-ack'
     ) $$,
  'distinct receiver can acknowledge the exact requirement-specific custody'
);

select is(
  (select status || '|' || fulfilled_qty::text from public.b2b_assembly_3pgs_requirements
     where assembly_job_id = (select id from public.b2b_assembly_jobs where assembly_job_number = 'ASM-3PGS-BIND-1')),
  'fulfilled|5',
  'valid exact custody fulfils the target requirement exactly once'
);

select is(
  (select reserved_qty::text || '|' || issued_qty::text
     from public.b2b_assembly_components
     where assembly_job_id = (select id from public.b2b_assembly_jobs where assembly_job_number = 'ASM-3PGS-BIND-1')),
  '5|5',
  'valid exact custody credits the linked P&A component in lockstep'
);

select finish();
rollback;

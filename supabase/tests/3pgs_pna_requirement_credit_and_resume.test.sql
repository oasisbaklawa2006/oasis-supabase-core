begin;
-- Contract coverage for 20260825100000_3pgs_pna_requirement_credit_and_resume.sql.
-- Proves the actual missing capability and the two safety invariants added
-- after adversarial review: only acknowledged custody can credit P&A, and
-- issued-but-unacknowledged stock cannot be reserved a second time.
select plan(28);

select has_function('public', 'fulfil_assembly_3pgs_requirement', 'fulfil_assembly_3pgs_requirement still exists (same signature)');
select has_function('public', 'reserve_3pgs_requirement_stock', 'reserve_3pgs_requirement_stock still exists (same signature)');

-- =================================================================================
-- Fixtures
-- =================================================================================
insert into public.users (id, role) values
  ('58000000-0000-0000-0000-000000000001', 'INVENTORY_MANAGER'),
  ('58000000-0000-0000-0000-000000000002', 'STORE_READY_GOODS');
insert into public.products (id, name, category, sku, hsn_code, production_department) values
  ('68000000-0000-0000-0000-000000000001', 'Credit-Resume 3PGS Item', 'packaging', 'CREDIT-3PGS-1', '4823', null),
  ('68000000-0000-0000-0000-000000000002', 'Partial-Credit 3PGS Item', 'packaging', 'PARTIAL-3PGS-1', '4823', null);
insert into public.orders (id, order_number, tracking_token, order_origin) values
  ('78000000-0000-0000-0000-000000000001', 'PGTAP-ORD-3PGSCREDIT-1', 'pgtap-fixture-token-3pgscredit-1', 'SALES');

set local request.jwt.claim.sub = '58000000-0000-0000-0000-000000000001';
set local request.jwt.claim.role = 'authenticated';

-- =================================================================================
-- Scenario A: full governed fulfilment closes the loop.
-- =================================================================================
select lives_ok(
  $$ select public.create_assembly_job(
       'ASM-3PGSCREDIT-A', '78000000-0000-0000-0000-000000000001',
       '68000000-0000-0000-0000-000000000001', 'CREDIT-3PGS-1', 5,
       jsonb_build_array(jsonb_build_object('product_id', '68000000-0000-0000-0000-000000000001', 'sku', 'CREDIT-3PGS-1', 'source_store_code', '3PGS', 'required_qty', 10)),
       'corr-3pgscredit-job-a'
     ) $$,
  'Scenario A: a P&A assembly job with a genuinely out-of-stock 3PGS component is created'
);

insert into public.inventory_stock_balances (product_id, sku, location_code, available_qty) values
  ('68000000-0000-0000-0000-000000000001', 'CREDIT-3PGS-1', '3PGS', 0)
  on conflict (product_id, sku, location_code) do update set available_qty = excluded.available_qty;
select lives_ok(
  $$ select public.reserve_assembly_components(
       (select id from public.b2b_assembly_jobs where assembly_job_number = 'ASM-3PGSCREDIT-A'),
       'high', 'corr-3pgscredit-reservepass-a'
     ) $$,
  'Scenario A: the reservation pass finds zero 3PGS stock and auto-raises the governed requirement'
);
select is(
  (select status from public.b2b_assembly_jobs where assembly_job_number = 'ASM-3PGSCREDIT-A'),
  'partially_reserved', 'Scenario A: the job is parked at partially_reserved'
);
select is(
  (select requested_qty from public.b2b_assembly_3pgs_requirements
     where assembly_component_id = (select id from public.b2b_assembly_components where assembly_job_id = (select id from public.b2b_assembly_jobs where assembly_job_number = 'ASM-3PGSCREDIT-A'))),
  10::numeric, 'Scenario A: the auto-raised requirement is sized to the full 10-unit shortfall'
);

insert into public.inventory_stock_balances (product_id, sku, location_code, available_qty) values
  ('68000000-0000-0000-0000-000000000001', 'CREDIT-3PGS-1', '3PGS', 10)
  on conflict (product_id, sku, location_code) do update set available_qty = excluded.available_qty;
select lives_ok(
  $$ select public.reserve_3pgs_requirement_stock(
       (select id from public.b2b_assembly_3pgs_requirements where assembly_component_id = (select id from public.b2b_assembly_components where assembly_job_id = (select id from public.b2b_assembly_jobs where assembly_job_number = 'ASM-3PGSCREDIT-A'))),
       'high', 'corr-3pgscredit-reserve-a'
     ) $$,
  'Scenario A: the full requirement reserves against the now-available stock'
);
select lives_ok(
  $$ select public.issue_3pgs_requirement_stock(
       (select id from public.b2b_assembly_3pgs_requirements where assembly_component_id = (select id from public.b2b_assembly_components where assembly_job_id = (select id from public.b2b_assembly_jobs where assembly_job_number = 'ASM-3PGSCREDIT-A'))),
       (select id from public.inventory_reservations where correlation_id = 'corr-3pgscredit-reserve-a'),
       10, 'corr-3pgscredit-issue-a'
     ) $$,
  'Scenario A: the full 10 units are issued'
);

-- Issued stock is now in transit. It has left the source balance but is not
-- yet receiver-acknowledged. Two fail-closed properties must hold here.
set local request.jwt.claim.sub = '58000000-0000-0000-0000-000000000002';
select throws_like(
  $$ select public.fulfil_assembly_3pgs_requirement(
       (select id from public.b2b_assembly_3pgs_requirements where assembly_component_id = (select id from public.b2b_assembly_components where assembly_job_id = (select id from public.b2b_assembly_jobs where assembly_job_number = 'ASM-3PGSCREDIT-A'))),
       10, 'corr-3pgscredit-direct-before-ack-a'
     ) $$,
  '%requires acknowledged 3PGS custody evidence%',
  'Scenario A: direct fulfilment before receiver acknowledgement fails closed and cannot credit P&A'
);
set local request.jwt.claim.sub = '58000000-0000-0000-0000-000000000001';
select throws_like(
  $$ select public.reserve_3pgs_requirement_stock(
       (select id from public.b2b_assembly_3pgs_requirements where assembly_component_id = (select id from public.b2b_assembly_components where assembly_job_id = (select id from public.b2b_assembly_jobs where assembly_job_number = 'ASM-3PGSCREDIT-A'))),
       'high', 'corr-3pgscredit-second-reserve-before-ack-a'
     ) $$,
  '%already committed%',
  'Scenario A: issued-but-unacknowledged quantity remains committed and cannot be reserved again'
);

set local request.jwt.claim.sub = '58000000-0000-0000-0000-000000000002';
select lives_ok(
  $$ select public.acknowledge_3pgs_requirement_receipt(
       (select id from public.rgs_issue_events where correlation_id = 'corr-3pgscredit-issue-a'),
       10, 'corr-3pgscredit-ack-a'
     ) $$,
  'Scenario A: a genuinely distinct receiver acknowledges the full receipt'
);
set local request.jwt.claim.sub = '58000000-0000-0000-0000-000000000001';

select is(
  (select reserved_qty::text || '|' || issued_qty::text from public.b2b_assembly_components
     where assembly_job_id = (select id from public.b2b_assembly_jobs where assembly_job_number = 'ASM-3PGSCREDIT-A')),
  '10|10', 'Scenario A: the linked component is credited only after acknowledged custody'
);
select is(
  (select status from public.b2b_assembly_jobs where assembly_job_number = 'ASM-3PGSCREDIT-A'),
  'materials_reserved', 'Scenario A: the job resumes once the acknowledged fulfilment fully covers the component'
);
select isnt(
  (select reserved_at from public.b2b_assembly_jobs where assembly_job_number = 'ASM-3PGSCREDIT-A'),
  null, 'Scenario A: reserved_at is set on resume'
);
select is(
  (select reserved_qty from public.inventory_stock_balances where product_id = '68000000-0000-0000-0000-000000000001' and sku = 'CREDIT-3PGS-1' and location_code = '3PGS'),
  0::numeric, 'Scenario A (pre-check): source reserved_qty is zero after 3PGS issue'
);
select lives_ok(
  $$ select public.issue_assembly_components(
       (select id from public.b2b_assembly_jobs where assembly_job_number = 'ASM-3PGSCREDIT-A'),
       'corr-3pgscredit-issueasm-a'
     ) $$,
  'Scenario A: issue_assembly_components succeeds without re-issuing bridge stock'
);
select is(
  (select status from public.b2b_assembly_jobs where assembly_job_number = 'ASM-3PGSCREDIT-A'),
  'issued', 'Scenario A: the job is now issued'
);
select is(
  (select reserved_qty from public.inventory_stock_balances where product_id = '68000000-0000-0000-0000-000000000001' and sku = 'CREDIT-3PGS-1' and location_code = '3PGS'),
  0::numeric, 'Scenario A: issue_assembly_components does not double-decrement 3PGS stock'
);

select lives_ok(
  $$ select public.fulfil_assembly_3pgs_requirement(
       (select id from public.b2b_assembly_3pgs_requirements where assembly_component_id = (select id from public.b2b_assembly_components where assembly_job_id = (select id from public.b2b_assembly_jobs where assembly_job_number = 'ASM-3PGSCREDIT-A'))),
       10, 'corr-3pgscredit-ack-a:fulfil'
     ) $$,
  'Scenario A: replay of the fulfil correlation emitted by acknowledgement is idempotent'
);
select is(
  (select reserved_qty::text || '|' || issued_qty::text from public.b2b_assembly_components
     where assembly_job_id = (select id from public.b2b_assembly_jobs where assembly_job_number = 'ASM-3PGSCREDIT-A')),
  '10|10', 'Scenario A: replay does not double-credit the component'
);

-- =================================================================================
-- Scenario B: partial acknowledged fulfilment credits only the amount actually
-- received and leaves the P&A job blocked on the genuine remainder.
-- =================================================================================
select lives_ok(
  $$ select public.create_assembly_job(
       'ASM-3PGSCREDIT-B', '78000000-0000-0000-0000-000000000001',
       '68000000-0000-0000-0000-000000000002', 'PARTIAL-3PGS-1', 3,
       jsonb_build_array(jsonb_build_object('product_id', '68000000-0000-0000-0000-000000000002', 'sku', 'PARTIAL-3PGS-1', 'source_store_code', '3PGS', 'required_qty', 12)),
       'corr-3pgscredit-job-b'
     ) $$,
  'Scenario B: a second job is created, requiring 12 units'
);
insert into public.inventory_stock_balances (product_id, sku, location_code, available_qty) values
  ('68000000-0000-0000-0000-000000000002', 'PARTIAL-3PGS-1', '3PGS', 0)
  on conflict (product_id, sku, location_code) do update set available_qty = excluded.available_qty;
select lives_ok(
  $$ select public.reserve_assembly_components(
       (select id from public.b2b_assembly_jobs where assembly_job_number = 'ASM-3PGSCREDIT-B'),
       'normal', 'corr-3pgscredit-reservepass-b'
     ) $$,
  'Scenario B: the reservation pass auto-raises a requirement for the 12-unit shortfall'
);

insert into public.inventory_stock_balances (product_id, sku, location_code, available_qty) values
  ('68000000-0000-0000-0000-000000000002', 'PARTIAL-3PGS-1', '3PGS', 10)
  on conflict (product_id, sku, location_code) do update set available_qty = excluded.available_qty;
select lives_ok(
  $$ select public.reserve_3pgs_requirement_stock(
       (select id from public.b2b_assembly_3pgs_requirements where assembly_component_id = (select id from public.b2b_assembly_components where assembly_job_id = (select id from public.b2b_assembly_jobs where assembly_job_number = 'ASM-3PGSCREDIT-B'))),
       'normal', 'corr-3pgscredit-reserve-b'
     ) $$,
  'Scenario B: only the 10 units genuinely available are reserved'
);
select lives_ok(
  $$ select public.issue_3pgs_requirement_stock(
       (select id from public.b2b_assembly_3pgs_requirements where assembly_component_id = (select id from public.b2b_assembly_components where assembly_job_id = (select id from public.b2b_assembly_jobs where assembly_job_number = 'ASM-3PGSCREDIT-B'))),
       (select id from public.inventory_reservations where correlation_id = 'corr-3pgscredit-reserve-b'),
       10, 'corr-3pgscredit-issue-b'
     ) $$,
  'Scenario B: the 10 reserved units are issued'
);
set local request.jwt.claim.sub = '58000000-0000-0000-0000-000000000002';
select lives_ok(
  $$ select public.acknowledge_3pgs_requirement_receipt(
       (select id from public.rgs_issue_events where correlation_id = 'corr-3pgscredit-issue-b'),
       10, 'corr-3pgscredit-ack-b'
     ) $$,
  'Scenario B: a distinct receiver acknowledges exactly the 10 units received'
);
set local request.jwt.claim.sub = '58000000-0000-0000-0000-000000000001';

select is(
  (select reserved_qty::text || '|' || issued_qty::text from public.b2b_assembly_components
     where assembly_job_id = (select id from public.b2b_assembly_jobs where assembly_job_number = 'ASM-3PGSCREDIT-B')),
  '10|10', 'Scenario B: component credit equals acknowledged custody, not the full 12 required'
);
select is(
  (select status from public.b2b_assembly_jobs where assembly_job_number = 'ASM-3PGSCREDIT-B'),
  'partially_reserved', 'Scenario B: the job stays blocked while 2 units remain genuinely short'
);
select throws_like(
  $$ select public.authorize_partial_assembly_issue(
       (select id from public.b2b_assembly_jobs where assembly_job_number = 'ASM-3PGSCREDIT-B'),
       'attempting to bypass the remaining genuine 2-unit shortfall', 'corr-3pgscredit-authorize-b'
     ) $$,
  '%unresolved 3PGS/packaging shortfall%',
  'Scenario B: partial 3PGS fulfilment does not create a bypass'
);

select * from finish();
rollback;

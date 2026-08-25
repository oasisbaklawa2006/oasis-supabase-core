begin;
-- Contract coverage for 20260825100000_3pgs_pna_requirement_credit_and_resume.sql.
-- Proves the actual missing capability: fulfil_assembly_3pgs_requirement now
-- credits the linked b2b_assembly_components.reserved_qty/issued_qty and
-- resumes the job from partially_reserved to materials_reserved once every
-- component is covered -- without this, a fully, genuinely fulfilled 3PGS
-- requirement left the P&A job permanently stuck, because
-- authorize_partial_assembly_issue's unresolved-shortfall check reads the
-- component's reserved_qty, not the requirement's own status.
--
-- Both scenarios drive the requirement into existence through the REAL
-- production path (reserve_assembly_components), not the standalone
-- create_assembly_3pgs_requirement entry point, because only the real path
-- puts the job into partially_reserved -- the precondition the resume fix
-- actually resumes from.
select plan(26);

select has_function('public', 'fulfil_assembly_3pgs_requirement', 'fulfil_assembly_3pgs_requirement still exists (same signature)');
select has_function('public', 'reserve_3pgs_requirement_stock', 'reserve_3pgs_requirement_stock still exists (same signature)');

-- =================================================================================
-- Fixtures
-- =================================================================================
insert into public.users (id, role) values
  ('58000000-0000-0000-0000-000000000001', 'INVENTORY_MANAGER'),   -- 3PGS operator: manage + receive + store-assignment-exempt
  ('58000000-0000-0000-0000-000000000002', 'STORE_READY_GOODS');   -- distinct receiver: manage + receive authority
insert into public.products (id, name, category, sku, hsn_code, production_department) values
  ('68000000-0000-0000-0000-000000000001', 'Credit-Resume 3PGS Item', 'packaging', 'CREDIT-3PGS-1', '4823', null),
  ('68000000-0000-0000-0000-000000000002', 'Partial-Credit 3PGS Item', 'packaging', 'PARTIAL-3PGS-1', '4823', null);
insert into public.orders (id, order_number, tracking_token) values
  ('78000000-0000-0000-0000-000000000001', 'PGTAP-ORD-3PGSCREDIT-1', 'pgtap-fixture-token-3pgscredit-1');

set local request.jwt.claim.sub = '58000000-0000-0000-0000-000000000001';
set local request.jwt.claim.role = 'authenticated';

-- =================================================================================
-- Scenario A: full fulfilment closes the loop -- component reserved_qty/
-- issued_qty are credited, and the job resumes to materials_reserved.
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

-- The 3PGS store's balance row exists (as it always does once a SKU is
-- catalogued there) but is genuinely empty, so the real reservation pass
-- cannot cover the component: it auto-raises the governed 3PGS requirement
-- itself (the same path reserve_assembly_components already took before
-- this fix) and parks the job at partially_reserved -- the actual "stuck"
-- precondition.
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
  'partially_reserved', 'Scenario A: the job is parked at partially_reserved -- the real precondition the fix must resume from'
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
  '10|10', 'Scenario A: the linked assembly component''s reserved_qty AND issued_qty are both credited by the fulfilled amount'
);
select is(
  (select status from public.b2b_assembly_jobs where assembly_job_number = 'ASM-3PGSCREDIT-A'),
  'materials_reserved', 'Scenario A: the job RESUMES from partially_reserved to materials_reserved once the 3PGS requirement is fully covered -- this is the fix; without it the job stayed stuck forever'
);
select isnt(
  (select reserved_at from public.b2b_assembly_jobs where assembly_job_number = 'ASM-3PGSCREDIT-A'),
  null, 'Scenario A: reserved_at is set on resume'
);

-- issue_assembly_components must now succeed on this job WITHOUT
-- authorize_partial_assembly_issue -- the job is no longer partially_reserved.
-- The bridge-fulfilled component's reserved_qty already equals issued_qty,
-- so issue_assembly_components' own per-component loop (reserved_qty >
-- issued_qty) must skip it and NOT attempt a second stock-balance
-- decrement against 3PGS for stock that already left it.
select is(
  (select reserved_qty from public.inventory_stock_balances where product_id = '68000000-0000-0000-0000-000000000001' and sku = 'CREDIT-3PGS-1' and location_code = '3PGS'),
  0::numeric, 'Scenario A (pre-check): the 3PGS store''s own reserved_qty is already back to zero after issue_3pgs_requirement_stock -- nothing left there for issue_assembly_components to touch'
);
select lives_ok(
  $$ select public.issue_assembly_components(
       (select id from public.b2b_assembly_jobs where assembly_job_number = 'ASM-3PGSCREDIT-A'),
       'corr-3pgscredit-issueasm-a'
     ) $$,
  'Scenario A: issue_assembly_components succeeds directly (materials_reserved), no partial-issue authorisation needed'
);
select is(
  (select status from public.b2b_assembly_jobs where assembly_job_number = 'ASM-3PGSCREDIT-A'),
  'issued', 'Scenario A: the job is now issued'
);
select is(
  (select reserved_qty from public.inventory_stock_balances where product_id = '68000000-0000-0000-0000-000000000001' and sku = 'CREDIT-3PGS-1' and location_code = '3PGS'),
  0::numeric, 'Scenario A: the 3PGS store''s reserved_qty is UNCHANGED by issue_assembly_components (still zero, not negative) -- confirms no double-decrement of stock already moved by the bridge'
);

-- Idempotent replay: a direct re-call of fulfil_assembly_3pgs_requirement
-- with the SAME correlation_id used by the acknowledge call above must not
-- double-credit the component (its own idempotency guard, unchanged).
select lives_ok(
  $$ select public.fulfil_assembly_3pgs_requirement(
       (select id from public.b2b_assembly_3pgs_requirements where assembly_component_id = (select id from public.b2b_assembly_components where assembly_job_id = (select id from public.b2b_assembly_jobs where assembly_job_number = 'ASM-3PGSCREDIT-A'))),
       10, 'corr-3pgscredit-ack-a:fulfil'
     ) $$,
  'Scenario A: a replayed fulfil call with the same correlation id does not error'
);
select is(
  (select reserved_qty::text || '|' || issued_qty::text from public.b2b_assembly_components
     where assembly_job_id = (select id from public.b2b_assembly_jobs where assembly_job_number = 'ASM-3PGSCREDIT-A')),
  '10|10', 'Scenario A: the replay did NOT double-credit reserved_qty/issued_qty -- still 10, not 20'
);

-- =================================================================================
-- Scenario B: PARTIAL fulfilment (only 10 of a genuine 12-unit shortfall is
-- actually in stock when 3PGS reserves against it) credits exactly the
-- fulfilled amount and correctly leaves the job blocked (still short) --
-- authorize_partial_assembly_issue must still refuse.
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
  'Scenario B: the reservation pass finds zero 3PGS stock and auto-raises a requirement for the full 12-unit shortfall'
);

-- Deliberately short the stock: only 10 of the 12 requested units are
-- actually available when 3PGS reserves against the requirement.
insert into public.inventory_stock_balances (product_id, sku, location_code, available_qty) values
  ('68000000-0000-0000-0000-000000000002', 'PARTIAL-3PGS-1', '3PGS', 10)
  on conflict (product_id, sku, location_code) do update set available_qty = excluded.available_qty;
select lives_ok(
  $$ select public.reserve_3pgs_requirement_stock(
       (select id from public.b2b_assembly_3pgs_requirements where assembly_component_id = (select id from public.b2b_assembly_components where assembly_job_id = (select id from public.b2b_assembly_jobs where assembly_job_number = 'ASM-3PGSCREDIT-B'))),
       'normal', 'corr-3pgscredit-reserve-b'
     ) $$,
  'Scenario B: the requirement reserves only the 10 units genuinely available, not the full 12 requested'
);
select lives_ok(
  $$ select public.issue_3pgs_requirement_stock(
       (select id from public.b2b_assembly_3pgs_requirements where assembly_component_id = (select id from public.b2b_assembly_components where assembly_job_id = (select id from public.b2b_assembly_jobs where assembly_job_number = 'ASM-3PGSCREDIT-B'))),
       (select id from public.inventory_reservations where correlation_id = 'corr-3pgscredit-reserve-b'),
       10, 'corr-3pgscredit-issue-b'
     ) $$,
  'Scenario B: the 10 actually-reserved units are issued'
);
set local request.jwt.claim.sub = '58000000-0000-0000-0000-000000000002';
select lives_ok(
  $$ select public.acknowledge_3pgs_requirement_receipt(
       (select id from public.rgs_issue_events where correlation_id = 'corr-3pgscredit-issue-b'),
       10, 'corr-3pgscredit-ack-b'
     ) $$,
  'Scenario B: a distinct receiver acknowledges the 10 units'
);
set local request.jwt.claim.sub = '58000000-0000-0000-0000-000000000001';

select is(
  (select reserved_qty::text || '|' || issued_qty::text from public.b2b_assembly_components
     where assembly_job_id = (select id from public.b2b_assembly_jobs where assembly_job_number = 'ASM-3PGSCREDIT-B')),
  '10|10', 'Scenario B: the component is credited exactly the 10 units fulfilled, not the full 12 required'
);
select is(
  (select status from public.b2b_assembly_jobs where assembly_job_number = 'ASM-3PGSCREDIT-B'),
  'partially_reserved', 'Scenario B: the job correctly stays blocked -- 10 of 12 required is still a genuine shortfall, so it must NOT resume'
);
select throws_like(
  $$ select public.authorize_partial_assembly_issue(
       (select id from public.b2b_assembly_jobs where assembly_job_number = 'ASM-3PGSCREDIT-B'),
       'attempting to bypass the remaining genuine 2-unit shortfall', 'corr-3pgscredit-authorize-b'
     ) $$,
  '%unresolved 3PGS/packaging shortfall%',
  'Scenario B: authorize_partial_assembly_issue still refuses unconditionally -- partial 3PGS credit does not create a bypass'
);

select * from finish();
rollback;

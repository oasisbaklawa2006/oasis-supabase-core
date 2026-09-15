begin;
-- Contract coverage for 20260915190000_dispatch_execution_view_select_grant.sql
-- Core #299 / Physical UAT #462: restore authenticated SELECT on the governed
-- Dispatch execution view without weakening underlying RLS or anon/PUBLIC denial.
select plan(25);

-- TEST 1 — authenticated has SELECT on the governed execution view
select ok(
  has_table_privilege('authenticated', 'public.b2b_dispatch_shipment_execution_view', 'SELECT'),
  'TEST 1: authenticated has SELECT on b2b_dispatch_shipment_execution_view'
);

-- TEST 2 — anon does NOT have SELECT
select ok(
  not has_table_privilege('anon', 'public.b2b_dispatch_shipment_execution_view', 'SELECT'),
  'TEST 2: anon does not have SELECT on b2b_dispatch_shipment_execution_view'
);

-- TEST 3 — PUBLIC does not receive unintended SELECT authority
select ok(
  not has_table_privilege('public', 'public.b2b_dispatch_shipment_execution_view', 'SELECT'),
  'TEST 3: PUBLIC does not have unintended SELECT on b2b_dispatch_shipment_execution_view'
);

-- TEST 4 — view remains security_invoker=true
select is(
  (select 'security_invoker=true' = any(coalesce(reloptions, '{}'))
     from pg_class
    where oid = 'public.b2b_dispatch_shipment_execution_view'::regclass),
  true,
  'TEST 4: b2b_dispatch_shipment_execution_view uses security_invoker=true'
);

-- Synthetic fixtures: one consignment on company A, buyer on company B.
insert into public.users (id, role, company_id, is_active) values
  ('99d00000-0000-0000-0000-000000000001', 'DISPATCH_INCHARGE', null, true),
  ('99d00000-0000-0000-0000-000000000002', 'SALES_EXECUTIVE', null, true),
  ('99d00000-0000-0000-0000-000000000003', 'FINANCE_HEAD', null, true),
  ('99d00000-0000-0000-0000-000000000004', 'GATE_SECURITY', null, true),
  ('99d00000-0000-0000-0000-000000000005', 'BUYER', '99e00000-0000-0000-0000-000000000002', true),
  ('99d00000-0000-0000-0000-000000000006', 'BUYER', '99e00000-0000-0000-0000-000000000001', true),
  ('99d00000-0000-0000-0000-000000000007', 'BUYER', null, false);

insert into public.companies (id, business_name, phone)
values
  ('99e00000-0000-0000-0000-000000000001', 'Dispatch Grant Test Co A', '+91-9000000001'),
  ('99e00000-0000-0000-0000-000000000002', 'Dispatch Grant Test Co B', '+91-9000000002');

insert into public.orders (id, order_number, tracking_token, company_id, sales_order_value, payment_status, order_origin)
values (
  '99f00000-0000-0000-0000-000000000001',
  'PGTAP-299-ORD-1',
  'pgtap-299-fixture-token-1',
  '99e00000-0000-0000-0000-000000000001',
  125000,
  'partial',
  'SALES'
);

insert into public.b2b_dispatch_consignments (
  id, consignment_number, order_id, sequence_number, status, dispatch_mode, destination_snapshot, correlation_id
) values (
  '99100000-0000-0000-0000-000000000001',
  'PGTAP-299-CONS-1',
  '99f00000-0000-0000-0000-000000000001',
  1,
  'ready_to_load',
  'road_transporter',
  jsonb_build_object(
    'consignee_name', 'Dispatch Grant Test Co A',
    'address_line1', '12 Test Industrial Estate',
    'city', 'Chennai',
    'state', 'Tamil Nadu',
    'pincode', '600001'
  ),
  'pgtap-299-cons-1'
);

-- TEST 5 — authorized Dispatch actor can execute the view
set local request.jwt.claim.sub = '99d00000-0000-0000-0000-000000000001';
set local request.jwt.claim.role = 'authenticated';
set local role authenticated;

select is(
  (select consignee_name
     from public.b2b_dispatch_shipment_execution_view
    where consignment_id = '99100000-0000-0000-0000-000000000001'),
  'Dispatch Grant Test Co A',
  'TEST 5: authorized Dispatch actor can query the execution view'
);

-- TEST 6 — unauthorized authenticated actors cannot obtain rows outside canonical RLS
set local request.jwt.claim.sub = '99d00000-0000-0000-0000-000000000007';
set local request.jwt.claim.role = 'authenticated';
set local role authenticated;

select is(
  (select count(*)::int from public.b2b_dispatch_shipment_execution_view),
  0,
  'TEST 6: inactive buyer without staff authority sees zero rows through the view'
);

set local request.jwt.claim.sub = '99d00000-0000-0000-0000-000000000005';
set local request.jwt.claim.role = 'authenticated';
set local role authenticated;

select is(
  (select count(*)::int
     from public.b2b_dispatch_consignments
    where id = '99100000-0000-0000-0000-000000000001'),
  0,
  'TEST 6: buyer direct underlying-table read remains RLS-blocked even when view SELECT exists'
);

-- TEST 7 — cross-company buyer cannot read another company''s consignment through the view
set local request.jwt.claim.sub = '99d00000-0000-0000-0000-000000000005';
set local request.jwt.claim.role = 'authenticated';
set local role authenticated;

select is(
  (select count(*)::int
     from public.b2b_dispatch_shipment_execution_view
    where consignment_id = '99100000-0000-0000-0000-000000000001'),
  0,
  'TEST 7: buyer from company B cannot read company A consignment rows through the view'
);

-- Adversarial: JWT/client metadata role assertion cannot bypass relation RLS
set local request.jwt.claim.sub = '99d00000-0000-0000-0000-000000000005';
set local request.jwt.claim.role = 'service_role';
set local role authenticated;

select is(
  (select count(*)::int
     from public.b2b_dispatch_shipment_execution_view
    where consignment_id = '99100000-0000-0000-0000-000000000001'),
  0,
  'adversarial: spoofed JWT role metadata does not bypass buyer RLS on the execution view'
);

reset role;

-- TEST 8 — forbidden commercial/CRM/Finance fields remain structurally absent
select hasnt_column('public', 'b2b_dispatch_shipment_execution_view', 'account_manager_id', 'TEST 8: no salesperson/account-manager column');
select hasnt_column('public', 'b2b_dispatch_shipment_execution_view', 'sales_order_value', 'TEST 8: no raw commercial order value column');
select hasnt_column('public', 'b2b_dispatch_shipment_execution_view', 'payment_status', 'TEST 8: no raw payment status column');
select hasnt_column('public', 'b2b_dispatch_shipment_execution_view', 'release_state', 'TEST 8: no raw uncollapsed release_state column');
select is(
  (select count(*)::int
     from information_schema.view_column_usage
    where view_schema = 'public'
      and view_name = 'b2b_dispatch_shipment_execution_view'
      and table_name in ('companies', 'crm_tasks')),
  0,
  'TEST 8: execution view never joins companies or crm_tasks'
);

-- TEST 9 — existing Dispatch execution semantics remain unchanged
select has_function('public', 'can_manage_b2b_dispatch', 'TEST 9: canonical dispatch predicate still exists');
select has_view('public', 'b2b_dispatch_command_queue', 'TEST 9: dispatch command queue view still exists');
select ok(
  has_table_privilege('authenticated', 'public.b2b_dispatch_command_queue', 'SELECT'),
  'TEST 9: sibling dispatch command queue authenticated SELECT grant remains intact'
);

-- TEST 10 — Security Gate independence remains unchanged
select ok(
  not public.can_manage_b2b_dispatch('99d00000-0000-0000-0000-000000000004'),
  'TEST 10: Security Gate role is not promoted into can_manage_b2b_dispatch'
);
select ok(
  has_table_privilege('authenticated', 'public.b2b_gate_store_reconciliation', 'SELECT'),
  'TEST 10: Security Gate reconciliation view authenticated SELECT remains available'
);

-- Adversarial role matrix under canonical RLS (view privilege alone must not broaden authority)
set local request.jwt.claim.sub = '99d00000-0000-0000-0000-000000000002';
set local request.jwt.claim.role = 'authenticated';
set local role authenticated;

select ok(
  (select count(*) >= 1
     from public.b2b_dispatch_shipment_execution_view
    where consignment_id = '99100000-0000-0000-0000-000000000001'),
  'adversarial: internal Sales staff visibility follows existing internal-staff RLS, not a new bypass'
);

set local request.jwt.claim.sub = '99d00000-0000-0000-0000-000000000003';
set local request.jwt.claim.role = 'authenticated';
set local role authenticated;

select ok(
  (select finance_status
     from public.b2b_dispatch_shipment_execution_view
    where consignment_id = '99100000-0000-0000-0000-000000000001') in ('CLEARED', 'HOLD'),
  'adversarial: Finance staff only receives collapsed finance_status through the governed view'
);
select hasnt_column('public', 'b2b_dispatch_shipment_execution_view', 'advance_paid', 'adversarial: Finance staff cannot read raw advance_paid through the view');

set local request.jwt.claim.sub = '99d00000-0000-0000-0000-000000000004';
set local request.jwt.claim.role = 'authenticated';
set local role authenticated;

select ok(
  (select count(*) >= 1
     from public.b2b_dispatch_shipment_execution_view
    where consignment_id = '99100000-0000-0000-0000-000000000001'),
  'adversarial: Security Gate internal staff read path remains independent and unchanged'
);

set local request.jwt.claim.sub = '99d00000-0000-0000-0000-000000000006';
set local request.jwt.claim.role = 'authenticated';
set local role authenticated;

select is(
  (select count(*)::int
     from public.b2b_dispatch_shipment_execution_view
    where consignment_id = '99100000-0000-0000-0000-000000000001'),
  0,
  'adversarial: buyer on the owning company still cannot read dispatch consignments without staff authority'
);

reset role;

select ok(
  not has_table_privilege('anon', 'public.b2b_dispatch_command_queue', 'SELECT'),
  'regression guard: anon still cannot read sibling dispatch command queue view'
);

select * from finish();
rollback;

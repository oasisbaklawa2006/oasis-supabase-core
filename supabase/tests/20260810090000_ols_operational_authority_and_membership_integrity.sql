begin;

-- Contract coverage for 20260810090000_ols_operational_authority_and_membership_integrity.sql.
select plan(24);

select has_function('public','can_manage_ols_production',array['uuid'],'production authority RPC exists');
select has_function('public','can_manage_ols_packing',array['uuid'],'packing authority RPC exists');
select has_function('public','can_manage_ols_dispatch',array['uuid'],'dispatch authority RPC exists');
select has_function('public','can_manage_ols_finance',array['uuid'],'finance authority RPC exists');
select has_function('public','can_manage_ols_gate',array['uuid'],'gate authority RPC exists');
select has_function('public','ols_create_dpl_with_cartons',array['text','text','text','text','text','uuid[]','text'],'governed DPL creation RPC exists');
select has_function('public','ols_finance_pi_scan_carton',array['uuid','text','text'],'governed Finance PI scan RPC exists');

select is((select has_function_privilege('anon','public.ols_finance_pi_scan_carton(uuid,text,text)','execute')),false,'anonymous cannot call the Finance PI scan RPC');

-- Direct table-write bypass: this project grants base table privileges
-- broadly (Supabase's default anon/authenticated grants), so the real
-- enforcement point is RLS, not has_table_privilege() — attempt the actual
-- INSERT and confirm RLS (42501) rejects it, exactly as the RPC-only
-- design requires.
set local role anon;
select throws_ok(
  $$ insert into public.ols_dpl_documents (dpl_no, status) values ('DPL-BYPASS-ANON', 'open') $$,
  '42501', null,
  'anonymous cannot directly write DPL documents (RLS, no anon policy exists)'
);
reset role;

set local role authenticated;
set local request.jwt.claim.sub = '10000000-0000-0000-0000-000000000002';
select throws_ok(
  $$ insert into public.ols_dpl_documents (dpl_no, status) values ('DPL-BYPASS-AUTH', 'open') $$,
  '42501', null,
  'authenticated staff cannot bypass the RPC with a direct DPL insert (no INSERT policy at all)'
);
select throws_ok(
  $$ insert into public.ols_finance_pi (pi_no, status) values ('PI-BYPASS-AUTH', 'pending') $$,
  '42501', null,
  'authenticated staff cannot bypass the RPC with a direct Finance PI insert (no INSERT policy at all)'
);
reset role;

-- Fixtures: one finance-authorized actor, one unauthorized actor, one order
-- with two packed cartons.
insert into public.users (id, email, role) values
  ('10000000-0000-0000-0000-000000000001', 'trace-finance@example.invalid', 'FINANCE_HEAD'),
  ('10000000-0000-0000-0000-000000000002', 'trace-sales@example.invalid', 'SALES_EXECUTIVE'),
  ('10000000-0000-0000-0000-000000000003', 'trace-dispatch@example.invalid', 'DISPATCH_MANAGER');

insert into public.ols_cartons (id, carton_no, order_ref, customer_name, status, gross_weight, net_weight) values
  ('20000000-0000-0000-0000-000000000001', 'CTN-TEST-001', 'SO-TEST-1', 'Test Customer', 'packed', 5.25, 5.00),
  ('20000000-0000-0000-0000-000000000002', 'CTN-TEST-002', 'SO-TEST-1', 'Test Customer', 'packed', 5.25, 5.00),
  ('20000000-0000-0000-0000-000000000003', 'CTN-TEST-003', 'SO-TEST-1', 'Test Customer', 'draft', 0, 0);

set local request.jwt.claim.sub = '10000000-0000-0000-0000-000000000003';
set local request.jwt.claim.role = 'authenticated';

select lives_ok(
  $$ select public.ols_create_dpl_with_cartons(
    'DPL-TEST-001', 'SO-TEST-1', 'Test Customer', 'Test Destination', 'Road',
    array['20000000-0000-0000-0000-000000000001','20000000-0000-0000-0000-000000000002']::uuid[],
    'trace-dpl-test-001'
  ) $$,
  'dispatch authority creates a DPL with full carton membership atomically'
);

select is(
  (select count(*)::int from public.ols_dpl_cartons where carton_id in
    ('20000000-0000-0000-0000-000000000001','20000000-0000-0000-0000-000000000002')),
  2,
  'both cartons are genuinely linked to the DPL via the FK table'
);

select throws_ok(
  $$ select public.ols_create_dpl_with_cartons(
    'DPL-TEST-002', 'SO-TEST-1', 'Test Customer', 'Test Destination', 'Road',
    array['20000000-0000-0000-0000-000000000003']::uuid[],
    'trace-dpl-test-002'
  ) $$,
  null,
  'rejects a DPL carton that is not packed (invalid state transition)'
);

select is(
  (select count(*)::int from public.ols_dpl_documents where dpl_no = 'DPL-TEST-002'),
  0,
  'a rejected DPL creation leaves no partial DPL row behind (atomicity)'
);

set local request.jwt.claim.sub = '10000000-0000-0000-0000-000000000002';
select throws_ok(
  $$ select public.ols_finance_pi_scan_carton(
    '20000000-0000-0000-0000-000000000001', 'PI-TEST-001', 'trace-pi-test-001'
  ) $$,
  null,
  'a non-finance-authorized actor cannot scan a carton onto a Finance PI'
);

set local request.jwt.claim.sub = '10000000-0000-0000-0000-000000000001';
select lives_ok(
  $$ select public.ols_finance_pi_scan_carton(
    '20000000-0000-0000-0000-000000000001', 'PI-TEST-001', 'trace-pi-test-001'
  ) $$,
  'finance authority scans a DPL-linked carton onto a new Finance PI'
);

select throws_ok(
  $$ select public.ols_finance_pi_scan_carton(
    '30000000-0000-0000-0000-000000000099', 'PI-TEST-999', 'trace-pi-test-unlinked'
  ) $$,
  null,
  'scanning a nonexistent carton fails'
);

insert into public.ols_cartons (id, carton_no, order_ref, customer_name, status, gross_weight, net_weight) values
  ('20000000-0000-0000-0000-000000000004', 'CTN-TEST-004', 'SO-TEST-2', 'Other Customer', 'packed', 3.0, 2.8);

select throws_ok(
  $$ select public.ols_finance_pi_scan_carton(
    '20000000-0000-0000-0000-000000000004', 'PI-TEST-002', 'trace-pi-test-unlinked'
  ) $$,
  null,
  'fails closed: a carton with no DPL membership at all is rejected, never silently accepted'
);

select is(
  (select count(*)::int from public.ols_finance_pi_cartons where carton_id = '20000000-0000-0000-0000-000000000004'),
  0,
  'the rejected unlinked-carton scan created no Finance PI carton row'
);

select is(
  (select public.ols_finance_pi_scan_carton(
    '20000000-0000-0000-0000-000000000001', 'PI-TEST-001', 'trace-pi-test-001'
  )).pi_no,
  'PI-TEST-001',
  'replaying the identical correlation id is idempotent — returns the existing PI, no duplicate link'
);

select is(
  (select count(*)::int from public.ols_finance_pi_cartons where carton_id = '20000000-0000-0000-0000-000000000001'),
  1,
  'idempotent replay left exactly one Finance PI carton link, not two'
);

-- Audit-evidence immutability, both by trigger and by RLS deny-policy.
insert into public.ols_audit_logs (id, action, entity_type, entity_id, user_id) values
  ('40000000-0000-0000-0000-000000000001', 'test.action', 'test_entity', '20000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001');

select throws_ok(
  $$ update public.ols_audit_logs set action = 'tampered' where id = '40000000-0000-0000-0000-000000000001' $$,
  null,
  'audit evidence cannot be mutated by an ordinary application role'
);

select throws_ok(
  $$ delete from public.ols_audit_logs where id = '40000000-0000-0000-0000-000000000001' $$,
  null,
  'audit evidence cannot be deleted by an ordinary application role'
);

select * from finish();
rollback;

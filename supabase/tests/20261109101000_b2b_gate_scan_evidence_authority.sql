-- Contract for migration 20261109101000_b2b_gate_scan_evidence_authority.sql
-- (b2b_gate_scan_evidence_authority). Behavioural: authorization, provenance, wrong carton/order/barcode, replay,
-- duplicate, direct-insert rejection, append-only preservation and release gating on authoritative evidence.
begin;
select plan(40);

select has_function('public','record_b2b_dispatch_gate_scan_v1',array['uuid','text','text'],'governed Gate scan writer exists');
select is(has_function_privilege('anon','public.record_b2b_dispatch_gate_scan_v1(uuid,text,text)','execute'), false, 'anon cannot execute the Gate scan writer');
select is(has_function_privilege('authenticated','public.record_b2b_dispatch_gate_scan_v1(uuid,text,text)','execute'), true, 'authenticated may call the Gate scan writer (authority enforced inside)');
select ok(exists(select 1 from pg_trigger where tgrelid='public.operational_scan_records'::regclass and tgname='trg_operational_scan_records_gate_authority' and not tgisinternal), 'direct dispatch_gate insert guard exists');
select ok(pg_get_functiondef('public.record_b2b_dispatch_gate_scan_v1(uuid,text,text)'::regprocedure) like '%assert_order_transition_role(''gate_release'')%', 'writer is bound to the independent Gate authority');

select ok(exists(select 1 from pg_catalog.pg_roles
  where rolname='ob_b2b_gate_scan_writer_v1' and not rolcanlogin),
  'governed insert owner is a NOLOGIN database role');
select is((select pg_get_userbyid(proowner) from pg_catalog.pg_proc
  where oid='public._insert_b2b_gate_scan_evidence_v1(uuid,uuid,text,text,uuid,text,text,text,uuid)'::regprocedure),
  'ob_b2b_gate_scan_writer_v1', 'only the dedicated database role owns the scan insert helper');
select is(has_function_privilege('authenticated',
  'public._insert_b2b_gate_scan_evidence_v1(uuid,uuid,text,text,uuid,text,text,text,uuid)', 'EXECUTE'), false,
  'authenticated cannot call the private insert helper');
select is(has_function_privilege('service_role',
  'public._insert_b2b_gate_scan_evidence_v1(uuid,uuid,text,text,uuid,text,text,text,uuid)', 'EXECUTE'), false,
  'service_role cannot call the private insert helper');
select is(has_function_privilege('postgres',
  'public._insert_b2b_gate_scan_evidence_v1(uuid,uuid,text,text,uuid,text,text,text,uuid)', 'EXECUTE'), true,
  'trusted postgres outer writer retains explicit execute privilege after helper ownership transfer');

-- Fixtures (inserted as the migration owner) -----------------------------------------------------------
insert into auth.users (id, email) values
  ('a1000000-0000-4000-8000-000000000001', 'gate-scan-1@test.invalid'),
  ('a1000000-0000-4000-8000-000000000002', 'gate-scan-2@test.invalid'),
  ('a1000000-0000-4000-8000-000000000003', 'gate-scan-3@test.invalid'),
  ('a1000000-0000-4000-8000-000000000004', 'gate-scan-4@test.invalid')
on conflict (id) do nothing;

insert into public.users (id, role) values
  ('a1000000-0000-4000-8000-000000000001', 'GATE_SECURITY'),
  ('a1000000-0000-4000-8000-000000000002', 'DISPATCH_MANAGER'),
  ('a1000000-0000-4000-8000-000000000003', 'SALES_EXECUTIVE'),
  ('a1000000-0000-4000-8000-000000000004', 'SECURITY_CONTROL');

insert into public.orders (id, order_number, tracking_token, order_origin, status) values
  ('a2000000-0000-4000-8000-000000000001', 'PGTAP-GATE-ORD-1', 'pgtap-gate-token-1', 'SALES', 'cleared_for_dispatch'),
  ('a2000000-0000-4000-8000-000000000002', 'PGTAP-GATE-ORD-2', 'pgtap-gate-token-2', 'SALES', 'confirmed');

-- The real legacy dispatch_cartons pathway must retain its own Gate evidence.
-- It is a different model from b2b_dispatch_cartons, and never counts as B2B authority.
insert into public.dispatch_cartons(id,order_id,barcode_string,box_number,total_boxes,status)
values ('a6000000-0000-4000-8000-000000000001', 'a2000000-0000-4000-8000-000000000001',
        'PGTAP-LEGACY-DISPATCH-C1', 1, 1, 'labeled');

insert into public.b2b_dispatch_consignments (id, consignment_number, order_id, sequence_number, status, dispatch_mode, correlation_id) values
  ('a3000000-0000-4000-8000-000000000001', 'PGTAP-GATE-CONS-1', 'a2000000-0000-4000-8000-000000000001', 1, 'ready_to_load', 'road_transporter', 'pgtap-gate-cons-1'),
  ('a3000000-0000-4000-8000-000000000002', 'PGTAP-GATE-CONS-2', 'a2000000-0000-4000-8000-000000000002', 1, 'ready_to_load', 'road_transporter', 'pgtap-gate-cons-2');

insert into public.b2b_dispatch_cartons (id, carton_code, consignment_id, carton_sequence, status, physical_location, net_weight, gross_weight, open_photo_ref, locked_by, locked_at) values
  ('a4000000-0000-4000-8000-000000000001', 'PGTAP-GATE-C1', 'a3000000-0000-4000-8000-000000000001', 1, 'ready_to_load', 'READY_TO_LOAD_BAY', 5, 6, 'photo://c1', 'a1000000-0000-4000-8000-000000000002', now()),
  ('a4000000-0000-4000-8000-000000000002', 'PGTAP-GATE-C2', 'a3000000-0000-4000-8000-000000000001', 2, 'ready_to_load', 'READY_TO_LOAD_BAY', 5, 6, 'photo://c2', 'a1000000-0000-4000-8000-000000000002', now()),
  ('a4000000-0000-4000-8000-000000000003', 'PGTAP-GATE-C3', 'a3000000-0000-4000-8000-000000000001', 3, 'open', 'CONSOLIDATION_ZONE', null, null, null, null, null),
  ('a4000000-0000-4000-8000-000000000004', 'PGTAP-GATE-C4', 'a3000000-0000-4000-8000-000000000002', 1, 'ready_to_load', 'READY_TO_LOAD_BAY', 5, 6, 'photo://c4', 'a1000000-0000-4000-8000-000000000002', now());

-- Unauthorized roles are rejected -------------------------------------------------------------------------
set local role authenticated;
set local request.jwt.claim.role = 'authenticated';
set local request.jwt.claim.sub = 'a1000000-0000-4000-8000-000000000003';
select throws_like($$ select public.record_b2b_dispatch_gate_scan_v1('a4000000-0000-4000-8000-000000000001','PGTAP-GATE-C1','k-sales') $$, '%independent security gate authority required%', 'non-Gate staff (sales) cannot record Gate evidence');
set local request.jwt.claim.sub = 'a1000000-0000-4000-8000-000000000002';
select throws_like($$ select public.record_b2b_dispatch_gate_scan_v1('a4000000-0000-4000-8000-000000000001','PGTAP-GATE-C1','k-dispatch') $$, '%independent security gate authority required%', 'Dispatch Manager cannot record Gate evidence');
select throws_like($$ insert into public.operational_scan_records(scan_type,verification_type,entity_type,entity_id,order_id,barcode_value,expected_barcode,verification_status,scan_source,correlation_id)
  values ('dispatch_gate','gate_check','b2b_dispatch_carton','a4000000-0000-4000-8000-000000000001','a2000000-0000-4000-8000-000000000001','PGTAP-GATE-C1','PGTAP-GATE-C1','scanned','forged','forged-1') $$, '%B2B_GATE_SCAN_DIRECT_INSERT_FORBIDDEN%', 'internal staff cannot insert dispatch_gate evidence directly');

select lives_ok($$ insert into public.operational_scan_records(scan_type,verification_type,entity_type,entity_id,order_id,barcode_value,expected_barcode,verification_status,scan_source,correlation_id)
  values ('dispatch_gate','gate_check','order','a2000000-0000-4000-8000-000000000001','a2000000-0000-4000-8000-000000000001','LEGACY-ORDER-GATE','LEGACY-ORDER-GATE','scanned','legacy_order_gate','legacy-order-gate-1') $$, 'legacy order-level gate scans (not B2B carton evidence) are not affected by the guard');

-- Real legacy dispatch_cartons scans remain possible for Gate staff; a B2B
-- carton using the old entity_type='dispatch_carton' alias must fail closed.
set local request.jwt.claim.sub = 'a1000000-0000-4000-8000-000000000001';
select lives_ok($$ insert into public.operational_scan_records(
  scan_type,verification_type,entity_type,entity_id,order_id,barcode_value,
  expected_barcode,verification_status,scan_source,correlation_id
) values (
  'dispatch_gate','gate_check','dispatch_carton',
  'a6000000-0000-4000-8000-000000000001','a2000000-0000-4000-8000-000000000001',
  'PGTAP-LEGACY-DISPATCH-C1','PGTAP-LEGACY-DISPATCH-C1','scanned',
  'legacy_dispatch_carton_gate','pgtap-legacy-carton-allowed'
) $$, 'real legacy dispatch_cartons Gate evidence remains insertable by Gate staff');
select throws_like($$ insert into public.operational_scan_records(
  scan_type,verification_type,entity_type,entity_id,order_id,barcode_value,
  expected_barcode,verification_status,scan_source,correlation_id
) values (
  'dispatch_gate','gate_check','dispatch_carton',
  'a4000000-0000-4000-8000-000000000001','a2000000-0000-4000-8000-000000000001',
  'PGTAP-GATE-C1','PGTAP-GATE-C1','scanned',
  'admin_b2b_security_gate','pgtap-b2b-alias-forbidden'
) $$, '%B2B_GATE_SCAN_DIRECT_INSERT_FORBIDDEN%',
  'B2B carton cannot forge authoritative evidence through legacy entity alias');

-- service_role bypasses RLS but MUST NOT forge authoritative B2B Gate scans.
reset role;
set local role service_role;
select throws_like($$ insert into public.operational_scan_records(
  scan_type,verification_type,entity_type,entity_id,order_id,barcode_value,
  expected_barcode,verification_status,scan_source,correlation_id,metadata
) values (
  'dispatch_gate','gate_check','b2b_dispatch_carton',
  'a4000000-0000-4000-8000-000000000002','a2000000-0000-4000-8000-000000000001',
  'PGTAP-GATE-C2','PGTAP-GATE-C2','scanned','B2B_GATE_SCAN_V1',
  'forged-service-gate','{"authority":"B2B_GATE_SCAN_V1"}'::jsonb
) $$,'%B2B_GATE_SCAN_DIRECT_INSERT_FORBIDDEN%', 
  'service_role cannot forge an authoritative B2B Gate scan despite BYPASSRLS');
select lives_ok($$ insert into public.operational_scan_records(
  scan_type,verification_type,entity_type,entity_id,order_id,barcode_value,
  expected_barcode,verification_status,scan_source,correlation_id
) values (
  'dispatch_gate','gate_check','order',
  'a2000000-0000-4000-8000-000000000001','a2000000-0000-4000-8000-000000000001',
  'LEGACY-SERVICE-GATE','LEGACY-SERVICE-GATE','scanned','legacy_order_gate',
  'legacy-service-gate-1'
) $$,'legacy order-level gate inserts remain available to service_role');
select lives_ok($$ insert into public.operational_scan_records(
  scan_type,verification_type,entity_type,entity_id,order_id,barcode_value,
  expected_barcode,verification_status,scan_source,correlation_id
) values (
  'dispatch_gate','gate_check','dispatch_carton',
  'a6000000-0000-4000-8000-000000000001','a2000000-0000-4000-8000-000000000001',
  'PGTAP-LEGACY-DISPATCH-C1','PGTAP-LEGACY-DISPATCH-C1','scanned',
  'legacy_dispatch_carton_gate','pgtap-legacy-carton-service-allowed'
) $$, 'real legacy carton Gate evidence survives service_role BYPASSRLS');
select throws_like($$ insert into public.operational_scan_records(
  scan_type,verification_type,entity_type,entity_id,order_id,barcode_value,
  expected_barcode,verification_status,scan_source,correlation_id,metadata
) values (
  'dispatch_gate','gate_check','dispatch_carton',
  'a6000000-0000-4000-8000-000000000001','a2000000-0000-4000-8000-000000000001',
  'PGTAP-LEGACY-DISPATCH-C1','PGTAP-LEGACY-DISPATCH-C1','scanned',
  'B2B_GATE_SCAN_V1','pgtap-legacy-carton-authority-forbidden',
  '{"authority":"B2B_GATE_SCAN_V1"}'::jsonb
) $$, '%B2B_GATE_SCAN_DIRECT_INSERT_FORBIDDEN%',
  'service_role cannot forge B2B authority marker even on a real legacy carton');
reset role;
set local role authenticated;


-- A revoked Gate actor retains a valid JWT and role, but must fail closed.
reset role;
update public.users set is_active=false where id='a1000000-0000-4000-8000-000000000001';
set local role authenticated;
set local request.jwt.claim.sub = 'a1000000-0000-4000-8000-000000000001';
select throws_like($$ select public.record_b2b_dispatch_gate_scan_v1('a4000000-0000-4000-8000-000000000001','PGTAP-GATE-C1','k-revoked') $$,
  '%B2B_GATE_SCAN_ACTOR_INACTIVE%', 'revoked Gate actor cannot record evidence with a valid JWT');
reset role;
update public.users set is_active=true where id='a1000000-0000-4000-8000-000000000001';
set local role authenticated;


-- Gate identity records authoritative evidence ----------------------------------------------------------------
set local request.jwt.claim.sub = 'a1000000-0000-4000-8000-000000000001';
select is((public.record_b2b_dispatch_gate_scan_v1('a4000000-0000-4000-8000-000000000001','pgtap-gate-c1','k-gate-1')->>'already_recorded')::boolean, false, 'Gate records the scan (barcode compared case-insensitively)');
select is((select actor_id::text || '|' || actor_role || '|' || scan_source || '|' || order_id::text from public.operational_scan_records where correlation_id='b2b-gate-scan:k-gate-1'),
  'a1000000-0000-4000-8000-000000000001|GATE_SECURITY|B2B_GATE_SCAN_V1|a2000000-0000-4000-8000-000000000001', 'actor, role, source and order are server-derived');
select is((public.record_b2b_dispatch_gate_scan_v1('a4000000-0000-4000-8000-000000000001','PGTAP-GATE-C1','k-gate-1')->>'already_recorded')::boolean, true, 'same idempotency key replays the same evidence');
select is((select count(*)::int from public.operational_scan_records where entity_id='a4000000-0000-4000-8000-000000000001'), 1, 'replay did not create a second row');
select throws_like($$ select public.record_b2b_dispatch_gate_scan_v1('a4000000-0000-4000-8000-000000000001','PGTAP-GATE-C1','k-gate-2') $$, '%B2B_GATE_SCAN_DUPLICATE%', 'a second scan for the same carton under a new key is rejected');
select throws_like($$ select public.record_b2b_dispatch_gate_scan_v1('a4000000-0000-4000-8000-000000000002','PGTAP-GATE-C1','k-gate-1') $$, '%B2B_GATE_SCAN_IDEMPOTENCY_CONFLICT%', 'the same key with a different carton is rejected');
select throws_like($$ select public.record_b2b_dispatch_gate_scan_v1('a4000000-0000-4000-8000-000000000002','PGTAP-GATE-C1','k-gate-3') $$, '%B2B_GATE_SCAN_BARCODE_MISMATCH%', 'wrong barcode for the carton is rejected');
select throws_like($$ select public.record_b2b_dispatch_gate_scan_v1('a4000000-0000-4000-8000-000000000003','PGTAP-GATE-C3','k-gate-4') $$, '%B2B_GATE_SCAN_CARTON_NOT_READY%', 'a carton that is not ready to load is rejected');
select throws_like($$ select public.record_b2b_dispatch_gate_scan_v1('a4000000-0000-4000-8000-000000000004','PGTAP-GATE-C4','k-gate-5') $$, '%B2B_GATE_SCAN_ORDER_NOT_CLEARED%', 'an order that is not cleared for dispatch is rejected');
select throws_like($$ select public.record_b2b_dispatch_gate_scan_v1('a4000000-0000-4000-8000-0000000000ff','PGTAP-GATE-C1','k-gate-6') $$, '%B2B_GATE_SCAN_CARTON_NOT_FOUND%', 'an unknown carton is rejected');

-- Evidence stays append-only for every role, including the owner --------------------------------------------------
reset role;
select throws_like($$ update public.operational_scan_records set verification_status='verified' where correlation_id='b2b-gate-scan:k-gate-1' $$, '%append-only%', 'evidence remains append-only') ;

-- Release requires authoritative evidence ----------------------------------------------------------------------
-- pgTAP's privileged test owner temporarily disables ONLY the new guarded
-- insert trigger to seed historically forged rows, then immediately restores it.
-- This happens inside BEGIN/ROLLBACK; no persistent trigger change is possible.
ALTER TABLE public.operational_scan_records
  DISABLE TRIGGER trg_operational_scan_records_gate_authority;
insert into public.operational_scan_records(id,scan_type,verification_type,entity_type,entity_id,order_id,barcode_value,expected_barcode,verification_status,scan_source,actor_id,actor_role,correlation_id)
values ('a5000000-0000-4000-8000-000000000001','dispatch_gate','gate_check','b2b_dispatch_carton','a4000000-0000-4000-8000-000000000002','a2000000-0000-4000-8000-000000000001','PGTAP-GATE-C2','PGTAP-GATE-C2','scanned','point100_disposable_synthetic_gate','a1000000-0000-4000-8000-000000000001','GATE_SECURITY','legacy-forged-row');

-- Independent single-field evidence-forgery fixtures; all unrelated attributes are valid.
insert into public.operational_scan_records(
  id,scan_type,verification_type,entity_type,entity_id,order_id,barcode_value,expected_barcode,
  verification_status,scan_source,actor_id,actor_role,correlation_id,metadata
) values
 ('a5000000-0000-4000-8000-000000000002','dispatch_gate','gate_check','b2b_dispatch_carton','a4000000-0000-4000-8000-000000000002','a2000000-0000-4000-8000-000000000001','PGTAP-GATE-C2','PGTAP-GATE-C2','scanned','unauthoritative_source','a1000000-0000-4000-8000-000000000001','GATE_SECURITY','gate-forged-source','{"authority":"B2B_GATE_SCAN_V1"}'::jsonb),
 ('a5000000-0000-4000-8000-000000000003','dispatch_gate','gate_check','b2b_dispatch_carton','a4000000-0000-4000-8000-000000000002','a2000000-0000-4000-8000-000000000001','PGTAP-GATE-C2','PGTAP-GATE-C2','scanned','B2B_GATE_SCAN_V1','a1000000-0000-4000-8000-000000000001','GATE_SECURITY','gate-forged-marker','{}'::jsonb),
 ('a5000000-0000-4000-8000-000000000004','dispatch_gate','gate_check','b2b_dispatch_carton','a4000000-0000-4000-8000-000000000002','a2000000-0000-4000-8000-000000000001','PGTAP-GATE-C2','PGTAP-GATE-C2','scanned','B2B_GATE_SCAN_V1','a1000000-0000-4000-8000-000000000002','DISPATCH_MANAGER','gate-forged-role','{"authority":"B2B_GATE_SCAN_V1"}'::jsonb),
 ('a5000000-0000-4000-8000-000000000005','dispatch_gate','gate_check','b2b_dispatch_carton','a4000000-0000-4000-8000-000000000002','a2000000-0000-4000-8000-000000000001','PGTAP-GATE-C2','PGTAP-GATE-C2','scanned','B2B_GATE_SCAN_V1',null,'GATE_SECURITY','gate-forged-actor','{"authority":"B2B_GATE_SCAN_V1"}'::jsonb);
ALTER TABLE public.operational_scan_records
  ENABLE TRIGGER trg_operational_scan_records_gate_authority;
select ok(exists(
  select 1 from pg_catalog.pg_trigger
  where tgrelid='public.operational_scan_records'::regclass
    and tgname='trg_operational_scan_records_gate_authority'
    and tgenabled='O'
), 'privileged test fixture has restored the production insert guard');


set local role authenticated;
set local request.jwt.claim.sub = 'a1000000-0000-4000-8000-000000000001';
select ok((public.release_b2b_dispatch_carton_at_gate_v1('a4000000-0000-4000-8000-000000000002','a5000000-0000-4000-8000-000000000001')->'blockers') @> '[{"code":"invalid_scan_evidence"}]'::jsonb, 'release rejects a non-authoritative scan row even when its content matches');
select ok(not ((public.release_b2b_dispatch_carton_at_gate_v1('a4000000-0000-4000-8000-000000000001',(select id from public.operational_scan_records where correlation_id='b2b-gate-scan:k-gate-1'))->'blockers') @> '[{"code":"invalid_scan_evidence"}]'::jsonb), 'release accepts the authoritative Gate evidence as scan evidence (other Finance blockers are covered by their own contracts)');


-- Each evidence-trust condition is isolated: no overlapping reason for denial.
select ok((public.release_b2b_dispatch_carton_at_gate_v1('a4000000-0000-4000-8000-000000000002','a5000000-0000-4000-8000-000000000002')->'blockers') @> '[{"code":"invalid_scan_evidence"}]'::jsonb,
  'a wrong scan_source alone cannot satisfy release');
select ok((public.release_b2b_dispatch_carton_at_gate_v1('a4000000-0000-4000-8000-000000000002','a5000000-0000-4000-8000-000000000003')->'blockers') @> '[{"code":"invalid_scan_evidence"}]'::jsonb,
  'a missing authority metadata marker alone cannot satisfy release');
select ok((public.release_b2b_dispatch_carton_at_gate_v1('a4000000-0000-4000-8000-000000000002','a5000000-0000-4000-8000-000000000004')->'blockers') @> '[{"code":"invalid_scan_evidence"}]'::jsonb,
  'a non-Gate actor role alone cannot satisfy release');
select ok((public.release_b2b_dispatch_carton_at_gate_v1('a4000000-0000-4000-8000-000000000002','a5000000-0000-4000-8000-000000000005')->'blockers') @> '[{"code":"invalid_scan_evidence"}]'::jsonb,
  'a missing actor identity alone cannot satisfy release');

-- A revoked Gate actor cannot finalize even an otherwise authoritative scan.
reset role;
update public.users set is_active=false where id='a1000000-0000-4000-8000-000000000001';
set local role authenticated;
set local request.jwt.claim.sub = 'a1000000-0000-4000-8000-000000000001';
select throws_like($$ select public.release_b2b_dispatch_carton_at_gate_v1('a4000000-0000-4000-8000-000000000001',
  (select id from public.operational_scan_records where correlation_id='b2b-gate-scan:k-gate-1')) $$,
  '%B2B_GATE_RELEASE_ACTOR_INACTIVE%', 'revoked Gate actor cannot release a carton using valid evidence');
reset role;
update public.users set is_active=true where id='a1000000-0000-4000-8000-000000000001';

select * from finish();
rollback;

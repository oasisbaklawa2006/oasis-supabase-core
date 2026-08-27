begin;
-- Contract coverage for 20260817150000_rgs_authority_hardening.sql, addressing
-- review of PR #83 (head 9a6ec92): stage-advance retry idempotency and
-- department-scoped authorisation on production mutation RPCs.
select plan(17);

insert into public.users (id, role) values
  ('15000000-0000-0000-0000-000000000001', 'PROD_ARABIC'),
  ('15000000-0000-0000-0000-000000000002', 'PROD_FUSION'),
  ('15000000-0000-0000-0000-000000000003', 'STORE_READY_GOODS');
insert into public.products (id, name, category, sku, hsn_code, production_department) values
  ('25000000-0000-0000-0000-000000000001', 'Kunafa Roll HD', 'sweets', 'KUNAFA-ROLL-HD', '1905', 'arabic_sweets');
insert into public.orders (id, order_number, tracking_token, order_origin) values
  ('35000000-0000-0000-0000-000000000001', 'PGTAP-ORD-HARDEN-1', 'pgtap-fixture-token-harden-1', 'MANUAL');

-- === Gap 1: advance_production_job_stage retry is a no-op, not a double-advance ===
set local request.jwt.claim.sub = '15000000-0000-0000-0000-000000000001';
set local request.jwt.claim.role = 'authenticated';

insert into public.production_jobs (id, order_id, product_id, department, assigned_qty, status, stage)
values ('45000000-0000-0000-0000-000000000001', '35000000-0000-0000-0000-000000000001', '25000000-0000-0000-0000-000000000001', 'ARABIC_SWEETS', 10, 'in_production', 'prep');

select lives_ok(
  $$ select public.advance_production_job_stage('45000000-0000-0000-0000-000000000001', 'corr-adv-1') $$,
  'first stage advance succeeds'
);
select is((select stage from public.production_jobs where id = '45000000-0000-0000-0000-000000000001'), 'processing', 'stage moved prep -> processing');

select lives_ok(
  $$ select public.advance_production_job_stage('45000000-0000-0000-0000-000000000001', 'corr-adv-1') $$,
  'retrying the exact same correlation id does not error'
);
select is(
  (select stage from public.production_jobs where id = '45000000-0000-0000-0000-000000000001'),
  'processing',
  'retry with the same correlation id left the stage unchanged -- it did NOT skip ahead to finishing'
);
select is(
  (select count(*)::int from public.production_job_stage_transitions where job_id = '45000000-0000-0000-0000-000000000001'),
  1,
  'exactly one transition was recorded despite two calls'
);

-- A genuinely new correlation id legitimately advances again.
select lives_ok(
  $$ select public.advance_production_job_stage('45000000-0000-0000-0000-000000000001', 'corr-adv-2') $$,
  'a new correlation id legitimately advances the stage again'
);
select is((select stage from public.production_jobs where id = '45000000-0000-0000-0000-000000000001'), 'finishing', 'stage moved processing -> finishing on the second distinct call');

-- === Gap 2: department-scoped authorisation, fail closed cross-department ===
insert into public.production_jobs (id, order_id, product_id, department, assigned_qty, status, stage)
values ('45000000-0000-0000-0000-000000000002', '35000000-0000-0000-0000-000000000001', '25000000-0000-0000-0000-000000000001', 'ARABIC_SWEETS', 10, 'pending', 'prep');

-- PROD_FUSION (wrong department) cannot act on an ARABIC_SWEETS job.
set local request.jwt.claim.sub = '15000000-0000-0000-0000-000000000002';

select throws_like(
  $$ select public.reject_production_job('45000000-0000-0000-0000-000000000002', 'wrong dept test', 'corr-cross-1') $$,
  '%not authorised for department%',
  'PROD_FUSION cannot reject an ARABIC_SWEETS job'
);

insert into public.production_jobs (id, order_id, product_id, department, assigned_qty, status, stage)
values ('45000000-0000-0000-0000-000000000003', '35000000-0000-0000-0000-000000000001', '25000000-0000-0000-0000-000000000001', 'ARABIC_SWEETS', 10, 'in_production', 'prep');

select throws_like(
  $$ select public.advance_production_job_stage('45000000-0000-0000-0000-000000000003', 'corr-cross-2') $$,
  '%not authorised for department%',
  'PROD_FUSION cannot advance the stage of an ARABIC_SWEETS job'
);
select throws_like(
  $$ select public.pause_production_job('45000000-0000-0000-0000-000000000003', 'other', 'x', 'corr-cross-3') $$,
  '%not authorised for department%',
  'PROD_FUSION cannot pause an ARABIC_SWEETS job'
);
select throws_like(
  $$ select public.record_production_output('45000000-0000-0000-0000-000000000003', 1, 0, 'B', 'corr-cross-4') $$,
  '%not authorised for department%',
  'PROD_FUSION cannot record output for an ARABIC_SWEETS job'
);
select throws_like(
  $$ select public.declare_production_ready('45000000-0000-0000-0000-000000000003', 'corr-cross-5') $$,
  '%not authorised for department%',
  'PROD_FUSION cannot declare an ARABIC_SWEETS job ready'
);
select throws_like(
  $$ select public.quick_log_production_to_rgs('25000000-0000-0000-0000-000000000001', 'arabic_sweets', 5, 0, 'corr-cross-6') $$,
  '%not authorised for department%',
  'PROD_FUSION cannot quick-log Arabic Sweets output'
);

-- Same-department actor is unaffected by the hardening.
set local request.jwt.claim.sub = '15000000-0000-0000-0000-000000000001';
select lives_ok(
  $$ select public.reject_production_job('45000000-0000-0000-0000-000000000002', 'legitimate reason', 'corr-same-dept-1') $$,
  'PROD_ARABIC (matching department) can still reject its own ARABIC_SWEETS job'
);

-- === Gap 3 (hardening note): record_rgs_receipt / acknowledge_rgs_issue idempotent replay ===
set local request.jwt.claim.sub = '15000000-0000-0000-0000-000000000001';
select public.record_production_output('45000000-0000-0000-0000-000000000003', 10, 0, 'B-H', 'corr-output-h');
select public.declare_production_ready('45000000-0000-0000-0000-000000000003', 'corr-ready-h');
set local request.jwt.claim.sub = '15000000-0000-0000-0000-000000000003';
select public.dispatch_production_to_rgs('45000000-0000-0000-0000-000000000003', 10, 'corr-dispatch-h');

select lives_ok(
  $$ select public.record_rgs_receipt((select id from public.production_rgs_transfers where correlation_id = 'corr-dispatch-h'), 10, 'corr-receipt-h') $$,
  'first receipt call succeeds'
);
select lives_ok(
  $$ select public.record_rgs_receipt((select id from public.production_rgs_transfers where correlation_id = 'corr-dispatch-h'), 10, 'corr-receipt-h') $$,
  'retrying the same receipt correlation id after a lost response does not raise'
);
select throws_like(
  $$ select public.record_rgs_receipt((select id from public.production_rgs_transfers where correlation_id = 'corr-dispatch-h'), 10, 'corr-receipt-h-different') $$,
  '%already been received%',
  'a genuinely different call against an already-received transfer is still refused'
);

select finish();
rollback;

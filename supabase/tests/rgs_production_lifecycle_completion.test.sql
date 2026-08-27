begin;
-- Contract coverage for 20260817110000_rgs_production_lifecycle_completion.sql.
select plan(14);

insert into public.users (id, role) values
  ('11000000-0000-0000-0000-000000000001', 'PROD_ARABIC'),
  ('11000000-0000-0000-0000-000000000002', 'STORE_READY_GOODS');

insert into public.products (id, name, category, sku, hsn_code, production_department) values
  ('21000000-0000-0000-0000-000000000001', 'Kunafa Tray', 'sweets', 'KUNAFA-TRAY', '1905', 'arabic_sweets');

insert into public.orders (id, order_number, tracking_token, order_origin) values ('31000000-0000-0000-0000-000000000001', 'PGTAP-ORD-LC-1', 'pgtap-fixture-token-lc-1', 'MANUAL');

select has_function('public','pause_production_job', 'pause_production_job exists');
select has_function('public','resume_production_job', 'resume_production_job exists');
select has_function('public','advance_production_job_stage', 'advance_production_job_stage exists');

set local request.jwt.claim.sub = '11000000-0000-0000-0000-000000000001';
set local request.jwt.claim.role = 'authenticated';

insert into public.production_jobs (id, order_id, product_id, department, assigned_qty, status, stage)
values ('41000000-0000-0000-0000-000000000001', '31000000-0000-0000-0000-000000000001', '21000000-0000-0000-0000-000000000001', 'ARABIC_SWEETS', 10, 'in_production', 'prep');

select lives_ok(
  $$ select public.advance_production_job_stage('41000000-0000-0000-0000-000000000001', 'corr-stage-1') $$,
  'stage advances from prep'
);
select is((select stage from public.production_jobs where id = '41000000-0000-0000-0000-000000000001'), 'processing', 'stage is now processing');

select lives_ok(
  $$ select public.pause_production_job('41000000-0000-0000-0000-000000000001', 'material_shortage', 'waiting on nuts', 'corr-pause-1') $$,
  'job pauses with a reason'
);
select is((select status from public.production_jobs where id = '41000000-0000-0000-0000-000000000001'), 'paused', 'job status is paused');
select is((select count(*)::int from public.production_pauses where job_id = '41000000-0000-0000-0000-000000000001' and resumed_at is null), 1, 'an open pause record exists');

select lives_ok(
  $$ select public.resume_production_job('41000000-0000-0000-0000-000000000001', 'corr-resume-1') $$,
  'job resumes'
);
select is((select status from public.production_jobs where id = '41000000-0000-0000-0000-000000000001'), 'in_production', 'job status is back to in_production');
select is((select count(*)::int from public.production_pauses where job_id = '41000000-0000-0000-0000-000000000001' and resumed_at is null), 0, 'the pause record was closed, not left dangling');

-- factory_inventory projection: only updated at RGS acceptance, with the accepted (not declared) quantity.
select lives_ok(
  $$ select public.record_production_output('41000000-0000-0000-0000-000000000001', 10.0, 0, 'BATCH-LC-1', 'corr-output-lc') $$,
  'output recorded'
);
select public.declare_production_ready('41000000-0000-0000-0000-000000000001', 'corr-ready-lc');
set local request.jwt.claim.sub = '11000000-0000-0000-0000-000000000002';
select public.dispatch_production_to_rgs('41000000-0000-0000-0000-000000000001', 10.0, 'corr-dispatch-lc');
select is((select count(*)::int from public.factory_inventory where product_id = '21000000-0000-0000-0000-000000000001'), 0, 'factory_inventory is untouched at dispatch time -- only acceptance posts stock');

select public.record_rgs_receipt((select id from public.production_rgs_transfers where correlation_id = 'corr-dispatch-lc'), 10.0, 'corr-receipt-lc');
select public.accept_rgs_production_receipt((select id from public.production_rgs_transfers where correlation_id = 'corr-dispatch-lc'), 9.0, 0, 1.0, 0, 'corr-accept-lc');
select is((select quantity from public.factory_inventory where product_id = '21000000-0000-0000-0000-000000000001'), 9.0::numeric, 'factory_inventory reflects the accepted 9.0kg, not the declared 10.0kg');

select finish();
rollback;

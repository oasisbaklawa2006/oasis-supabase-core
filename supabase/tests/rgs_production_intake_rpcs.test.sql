begin;
-- Contract coverage for 20260817120000_rgs_production_intake_rpcs.sql.
select plan(8);

insert into public.users (id, role) values ('12000000-0000-0000-0000-000000000001', 'PROD_ARABIC');
insert into public.products (id, name, category, sku, hsn_code, production_department) values
  ('22000000-0000-0000-0000-000000000001', 'Osh El Bulbul Tray', 'sweets', 'OEB-TRAY', '1905', 'arabic_sweets');
insert into public.orders (id, order_number, tracking_token, order_origin) values
  ('32000000-0000-0000-0000-000000000001', 'PGTAP-ORD-INTAKE-1', 'pgtap-fixture-token-intake-1', 'MANUAL');

select has_function('public','accept_production_job', 'accept_production_job exists');
select has_function('public','reject_production_job', 'reject_production_job exists');
select is((select has_function_privilege('anon','public.accept_production_job(uuid,text,text)','execute')), false, 'anonymous cannot accept production jobs');

set local request.jwt.claim.sub = '12000000-0000-0000-0000-000000000001';
set local request.jwt.claim.role = 'authenticated';

insert into public.production_jobs (id, order_id, product_id, department, assigned_qty, status)
values ('42000000-0000-0000-0000-000000000001', '32000000-0000-0000-0000-000000000001', '22000000-0000-0000-0000-000000000001', 'ARABIC_SWEETS', 5, 'pending');
insert into public.production_jobs (id, order_id, product_id, department, assigned_qty, status)
values ('42000000-0000-0000-0000-000000000002', '32000000-0000-0000-0000-000000000001', '22000000-0000-0000-0000-000000000001', 'ARABIC_SWEETS', 5, 'pending');

select lives_ok(
  $$ select public.accept_production_job('42000000-0000-0000-0000-000000000001', 'B-PGTAP-1', 'corr-accept-1') $$,
  'department-matched operator accepts a pending job'
);
select is((select status from public.production_jobs where id = '42000000-0000-0000-0000-000000000001'), 'accepted', 'job status is accepted');
select is((select batch_number from public.production_jobs where id = '42000000-0000-0000-0000-000000000001'), 'B-PGTAP-1', 'batch number recorded');

select lives_ok(
  $$ select public.reject_production_job('42000000-0000-0000-0000-000000000002', 'wrong department mapping', 'corr-reject-1') $$,
  'a pending job can be rejected with a reason'
);
select throws_like(
  $$ select public.reject_production_job('42000000-0000-0000-0000-000000000002', '', 'corr-reject-2') $$,
  '%rejection reason is required%',
  'rejecting without a reason is refused'
);

select finish();
rollback;

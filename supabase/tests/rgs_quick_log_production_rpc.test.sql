begin;
-- Contract coverage for 20260817130000_rgs_quick_log_production_rpc.sql.
select plan(9);

insert into public.users (id, role) values ('13000000-0000-0000-0000-000000000001', 'PROD_FUSION');
insert into public.products (id, name, category, sku, hsn_code, production_department) values
  ('23000000-0000-0000-0000-000000000001', 'Fusion Chikki Bar', 'sweets', 'FUSION-CHIKKI', '1905', 'fusion_sweets');

select has_function('public','quick_log_production_to_rgs', 'quick_log_production_to_rgs exists');
select is((select has_function_privilege('anon','public.quick_log_production_to_rgs(uuid,text,numeric,numeric,text,text)','execute')), false, 'anonymous cannot quick-log production');

set local request.jwt.claim.sub = '13000000-0000-0000-0000-000000000001';
set local request.jwt.claim.role = 'authenticated';

select lives_ok(
  $$ select public.quick_log_production_to_rgs('23000000-0000-0000-0000-000000000001', 'fusion_sweets', 20, 1, 'corr-qlog-1') $$,
  'ad-hoc quick log succeeds for a mapped department'
);

select is((select count(*)::int from public.production_jobs where correlation_id = 'corr-qlog-1:job'), 1, 'exactly one ad-hoc job was created, not a parallel write path');
select is((select status from public.production_jobs where correlation_id = 'corr-qlog-1:job'), 'transferred', 'the ad-hoc job reaches transferred status through the same lifecycle as routed demand');
select is((select count(*)::int from public.production_rgs_transfers where correlation_id = 'corr-qlog-1'), 1, 'a governed transfer record exists');
select is((select count(*)::int from public.factory_inventory where product_id = '23000000-0000-0000-0000-000000000001'), 0, 'factory_inventory is untouched -- only RGS acceptance posts stock, never quick-log');

-- Idempotent retry: same correlation id, called again.
select lives_ok(
  $$ select public.quick_log_production_to_rgs('23000000-0000-0000-0000-000000000001', 'fusion_sweets', 20, 1, 'corr-qlog-1') $$,
  'retrying the same correlation id succeeds (idempotent replay)'
);
select is(
  (select count(*)::int from public.production_jobs where correlation_id = 'corr-qlog-1:job'),
  1,
  'retrying the same correlation id did not create a second job'
);

select finish();
rollback;

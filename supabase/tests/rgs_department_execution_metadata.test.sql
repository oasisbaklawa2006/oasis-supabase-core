begin;
-- Contract coverage for 20260817140000_rgs_department_execution_metadata.sql.
select plan(6);

insert into public.users (id, role) values ('14000000-0000-0000-0000-000000000001', 'PROD_ARABIC');
insert into public.products (id, name, category, sku, hsn_code, production_department) values
  ('24000000-0000-0000-0000-000000000001', 'Baklawa Pyramid Tray', 'sweets', 'BAKLAWA-TRAY', '1905', 'arabic_sweets');
insert into public.orders (id, order_number, tracking_token, order_origin) values
  ('34000000-0000-0000-0000-000000000001', 'PGTAP-ORD-META-1', 'pgtap-fixture-token-meta-1', 'MANUAL');

select col_type_is('public','production_job_outputs','execution_metadata','jsonb','execution_metadata column exists and is jsonb');

set local request.jwt.claim.sub = '14000000-0000-0000-0000-000000000001';
set local request.jwt.claim.role = 'authenticated';

insert into public.production_jobs (id, order_id, product_id, department, assigned_qty, status)
values ('44000000-0000-0000-0000-000000000001', '34000000-0000-0000-0000-000000000001', '24000000-0000-0000-0000-000000000001', 'ARABIC_SWEETS', 10, 'in_production');

-- Backward compatibility: the 5-arg call shape (no metadata) still works.
select lives_ok(
  $$ select public.record_production_output('44000000-0000-0000-0000-000000000001', 5, 0, 'B-1', 'corr-meta-legacy') $$,
  'record_production_output still works with no execution_metadata argument'
);

select lives_ok(
  $$ select public.record_production_output(
       '44000000-0000-0000-0000-000000000001', 5, 0, 'B-1', 'corr-meta-1',
       null, '{"bake_stage":"second_bake","syrup_stage":"soaked","nut_variant":"pistachio"}'::jsonb
     ) $$,
  'record_production_output accepts department-specific execution metadata'
);

select is(
  (select execution_metadata->>'bake_stage' from public.production_job_outputs where correlation_id = 'corr-meta-1'),
  'second_bake',
  'Arabic Sweets bake_stage is preserved in execution_metadata'
);

select throws_like(
  $$ select public.record_production_output('44000000-0000-0000-0000-000000000001', 5, 0, 'B-1', 'corr-meta-bad', null, '["not","an","object"]'::jsonb) $$,
  '%must be a JSON object%',
  'a non-object execution_metadata payload is rejected'
);

select is(
  (select execution_metadata from public.production_job_outputs where correlation_id = 'corr-meta-legacy'),
  '{}'::jsonb,
  'omitted execution_metadata defaults to an empty object, not null'
);

select finish();
rollback;

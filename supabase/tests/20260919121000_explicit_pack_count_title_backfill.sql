-- Contract coverage for migration:
-- 20260919121000_explicit_pack_count_title_backfill.sql

begin;
select plan(12);

select has_function(
  'public',
  'reconcile_explicit_pack_count_from_title_v1',
  array[]::text[],
  'explicit title pack-count reconciliation RPC exists'
);

select ok(
  has_function_privilege(
    'service_role',
    'public.reconcile_explicit_pack_count_from_title_v1()',
    'EXECUTE'
  )
  and not has_function_privilege(
    'authenticated',
    'public.reconcile_explicit_pack_count_from_title_v1()',
    'EXECUTE'
  )
  and not has_function_privilege(
    'anon',
    'public.reconcile_explicit_pack_count_from_title_v1()',
    'EXECUTE'
  ),
  'reconciliation RPC is service-role only'
);

insert into public.products (
  id, name, product_name, category, sku, hsn_code, is_active,
  visible_in_catalog, product_type, primary_uom, retail_uom, b2b_uom,
  pcs_per_pack
) values
(
  '19121000-0000-4000-8000-000000000001',
  'Pack Count Six',
  'Baklawa Classic Collection - Pack of 6 Pcs',
  'Ready packs',
  'TEST-PACK-COUNT-006',
  '9999',
  true, true, 'retail_pack', 'pcs', 'pack', 'carton', null
),
(
  '19121000-0000-4000-8000-000000000002',
  'Pack Count Pieces',
  'Baklawa Collection - Pack of 12 Pieces',
  'Ready packs',
  'TEST-PACK-COUNT-012',
  '9999',
  true, true, 'retail_pack', 'pcs', 'pack', 'carton', 0
),
(
  '19121000-0000-4000-8000-000000000003',
  'Preserve Existing',
  'Baklawa Collection - Pack of 9 Pcs',
  'Ready packs',
  'TEST-PACK-KEEP-005',
  '9999',
  true, true, 'retail_pack', 'pcs', 'pack', 'carton', 5
),
(
  '19121000-0000-4000-8000-000000000004',
  'Not Ready Pack',
  'Bulk Sweet - Pack of 20 Pcs',
  'Bulk Sweets & Nuts',
  'TEST-PACK-BULK-020',
  '9999',
  true, true, 'bulk_sweets', 'kg', 'kg', 'kg', null
),
(
  '19121000-0000-4000-8000-000000000005',
  'No Explicit Count',
  'Baklawa Royal Collection 250g',
  'Ready packs',
  'TEST-PACK-NOCOUNT',
  '9999',
  true, true, 'retail_pack', 'pcs', 'pack', 'carton', null
);

insert into public.products (
  id, name, product_name, category, sku, hsn_code, is_active,
  visible_in_catalog, product_type, primary_uom, retail_uom, b2b_uom,
  pcs_per_pack, net_weight_grams, weight_per_pc_grams
) values
(
  '19121000-0000-4000-8000-000000000006',
  'Exact Weight Ratio Pack',
  'Latte Style Pack',
  'Bulk Sweets & Nuts',
  'TEST-PACK-WEIGHT-020',
  '9999',
  true, true, 'bulk_sweets', 'pcs', 'pack', 'carton',
  null, 700, 35
),
(
  '19121000-0000-4000-8000-000000000007',
  'Non Integer Weight Ratio Pack',
  'Non Integer Pack',
  'Bulk Sweets & Nuts',
  'TEST-PACK-WEIGHT-NONINT',
  '9999',
  true, true, 'bulk_sweets', 'pcs', 'pack', 'carton',
  null, 701, 35
);

select lives_ok(
  $$select public.reconcile_explicit_pack_count_from_title_v1()$$,
  'explicit pack-count reconciliation executes'
);

select is(
  (select pcs_per_pack from public.products where id='19121000-0000-4000-8000-000000000001'),
  6::numeric,
  'Pack of 6 Pcs is copied exactly'
);

select is(
  (select pcs_per_pack from public.products where id='19121000-0000-4000-8000-000000000002'),
  12::numeric,
  'Pack of 12 Pieces is copied exactly'
);

select is(
  (select pcs_per_pack from public.products where id='19121000-0000-4000-8000-000000000003'),
  5::numeric,
  'existing positive pack count is never overwritten'
);

select is(
  (select pcs_per_pack from public.products where id='19121000-0000-4000-8000-000000000004'),
  null::numeric,
  'non-ready-pack product is not updated from title text'
);

select is(
  (select pcs_per_pack from public.products where id='19121000-0000-4000-8000-000000000005'),
  null::numeric,
  'product without explicit Pack of N Pcs title remains unset'
);

select is(
  (select pcs_per_pack from public.products where id='19121000-0000-4000-8000-000000000006'),
  20::numeric,
  'exact 700g / 35g persisted pack-to-piece ratio reconciles to 20 pcs'
);

select is(
  (select pcs_per_pack from public.products where id='19121000-0000-4000-8000-000000000007'),
  null::numeric,
  'non-integer pack-to-piece ratio is never rounded into authority'
);

select lives_ok(
  $$select public.reconcile_explicit_pack_count_from_title_v1()$$,
  'reconciliation is safe to repeat'
);

select is(
  (select pcs_per_pack from public.products where id='19121000-0000-4000-8000-000000000001'),
  6::numeric,
  'repeat execution is idempotent'
);

select * from finish();
rollback;

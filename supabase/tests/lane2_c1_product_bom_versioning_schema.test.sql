begin;
-- Contract coverage for 20260824150000_lane2_c1_product_bom_versioning_schema.sql.
select plan(17);

select has_column('public', 'product_bom', 'bom_version', 'product_bom has a bom_version column');
select has_column('public', 'product_bom', 'effective_from', 'product_bom has an effective_from column');
select has_column('public', 'product_bom', 'effective_until', 'product_bom has an effective_until column');
select has_column('public', 'product_bom', 'uom_conversion_factor', 'product_bom has a uom_conversion_factor column');
select has_column('public', 'product_bom', 'yield_pct', 'product_bom has a yield_pct column');
select has_column('public', 'product_bom', 'waste_pct', 'product_bom has a waste_pct column');
select has_column('public', 'product_bom', 'substitution_group', 'product_bom has a substitution_group column');
select has_column('public', 'product_bom', 'source_store_code', 'product_bom has a source_store_code column');

insert into public.products (id, name, category, sku, hsn_code)
values ('99f40000-0000-0000-0000-000000000001', 'C1 Schema Test Tray', 'sweets', 'C1SCHEMA-TRAY-1', '1905');

-- 1: existing-shape inserts (pre-migration column set only) still succeed --
-- this is a purely additive migration and must not break the unmodified
-- the Central product-BOM admin screen insert shape.
select lives_ok(
  $$insert into public.product_bom (product_id, component_name, quantity_per_unit, source_department)
    values ('99f40000-0000-0000-0000-000000000001', 'Sugar', 2, 'ARABIC_SWEETS')$$,
  'a pre-existing-shape insert (no new columns referenced) still succeeds'
);

-- 2: new rows default to a valid, backward-compatible state.
select is(
  (select bom_version from public.product_bom where component_name = 'Sugar'), 1,
  'a new row defaults to bom_version 1'
);

select is(
  (select source_store_code from public.product_bom where component_name = 'Sugar'), NULL,
  'source_store_code is NULL by default -- no automatic backfill from source_department was attempted'
);

-- 3: an out-of-range yield_pct is rejected.
select throws_ok(
  $$insert into public.product_bom (product_id, component_name, quantity_per_unit, yield_pct)
    values ('99f40000-0000-0000-0000-000000000001', 'Bad Yield', 1, 0)$$,
  23514, NULL, 'a zero yield_pct is rejected'
);

-- 4: source_store_code must reference a real canonical store.
select throws_ok(
  $$insert into public.product_bom (product_id, component_name, quantity_per_unit, source_store_code)
    values ('99f40000-0000-0000-0000-000000000001', 'Bad Store', 1, 'NOT_A_REAL_STORE')$$,
  23503, NULL, 'an unknown source_store_code is rejected'
);

-- 5: effective_until must be after effective_from.
select throws_ok(
  $$insert into public.product_bom (product_id, component_name, quantity_per_unit, effective_from, effective_until)
    values ('99f40000-0000-0000-0000-000000000001', 'Bad Window', 1, now(), now() - interval '1 day')$$,
  23514, NULL, 'an effective_until at or before effective_from is rejected'
);

-- 6: uom_conversion_factor must be positive.
select throws_ok(
  $$insert into public.product_bom (product_id, component_name, quantity_per_unit, uom_conversion_factor)
    values ('99f40000-0000-0000-0000-000000000001', 'Bad Conversion', 1, 0)$$,
  23514, NULL, 'a zero uom_conversion_factor is rejected'
);

-- 7: waste_pct must be in [0, 100).
select throws_ok(
  $$insert into public.product_bom (product_id, component_name, quantity_per_unit, waste_pct)
    values ('99f40000-0000-0000-0000-000000000001', 'Bad Waste Negative', 1, -1)$$,
  23514, NULL, 'a negative waste_pct is rejected'
);

select throws_ok(
  $$insert into public.product_bom (product_id, component_name, quantity_per_unit, waste_pct)
    values ('99f40000-0000-0000-0000-000000000001', 'Bad Waste 100', 1, 100)$$,
  23514, NULL, 'a waste_pct of exactly 100 is rejected'
);

select * from finish();
rollback;

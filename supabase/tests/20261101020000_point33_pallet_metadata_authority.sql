-- POINT33 schema/permission regression: additive pallet metadata, no write-authority escalation.
BEGIN;
SELECT plan(13);

SELECT has_column('public', 'products', 'cartons_per_pallet', 'P01 carton pallet count stored on product');
SELECT has_column('public', 'products', 'master_cartons_per_pallet', 'P02 master-carton pallet count stored on product');
SELECT has_column('public', 'products', 'pallet_uom', 'P03 pallet UOM stored on product');

SELECT col_type_is('public', 'products', 'cartons_per_pallet', 'integer', 'P04 case carton count is integer');
SELECT col_type_is('public', 'products', 'master_cartons_per_pallet', 'integer', 'P05 master count is integer');
SELECT col_type_is('public', 'products', 'pallet_uom', 'text', 'P06 pallet UOM is text');

SELECT ok((SELECT NOT attnotnull FROM pg_attribute
  WHERE attrelid='public.products'::regclass AND attname='cartons_per_pallet'), 'P07 case count is optional');
SELECT ok((SELECT NOT attnotnull FROM pg_attribute
  WHERE attrelid='public.products'::regclass AND attname='master_cartons_per_pallet'), 'P08 master count is optional');
SELECT ok((SELECT NOT attnotnull FROM pg_attribute
  WHERE attrelid='public.products'::regclass AND attname='pallet_uom'), 'P09 pallet UOM is optional');

SELECT ok(NOT EXISTS (
  SELECT 1 FROM pg_attribute a JOIN pg_attrdef d
    ON d.adrelid=a.attrelid AND d.adnum=a.attnum
  WHERE a.attrelid='public.products'::regclass
    AND a.attname IN ('cartons_per_pallet','master_cartons_per_pallet','pallet_uom')
), 'P10 no fabricated pallet defaults');

SELECT ok(EXISTS (
  SELECT 1 FROM pg_constraint
  WHERE conrelid='public.products'::regclass
    AND conname='products_point33_pallet_metadata_valid'
    AND contype='c' AND convalidated
), 'P11 positive and complete pallet CHECK is installed');

SELECT ok((SELECT relrowsecurity FROM pg_class WHERE oid='public.products'::regclass),
  'P12 existing products RLS remains enabled');

SELECT is((SELECT count(*)::int FROM pg_policies
  WHERE schemaname='public'
    AND (tablename,policyname) IN (
      ('products','Admins insert products'),
      ('products','Admins update products'),
      ('products','Admins delete products')
    )
    AND ((qual='is_admin()') OR (with_check='is_admin()'))),
  3,'P13 original product insert/update/delete policy names and authority retained');

SELECT * FROM finish();
ROLLBACK;

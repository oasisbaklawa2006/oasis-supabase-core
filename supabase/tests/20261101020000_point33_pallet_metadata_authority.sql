-- Contract test for migration 20261101020000_point33_pallet_metadata_authority.sql:
-- additive pallet metadata, CHECK behaviour, no write-authority escalation.
BEGIN;
SELECT plan(35);

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
    AND (
      (cmd='DELETE' AND qual IN ('is_admin()','public.is_admin()'))
      OR (cmd IN ('INSERT','UPDATE') AND
        (qual IN ('is_admin()','public.is_admin()',
                  'can_write_product_master()','public.can_write_product_master()')
         OR with_check IN ('is_admin()','public.is_admin()',
                           'can_write_product_master()','public.can_write_product_master()')))
    )),
  3,'P13 existing product policies remain restrictive across Core #407 release order');

-- ---- behaviour of the CHECK constraint (rows seeded under replica: FKs/triggers off, CHECKs on)
SET LOCAL session_replication_role = replica;
CREATE TEMP TABLE p33_case (label text, ok boolean);
CREATE FUNCTION pg_temp.p33_try(p_label text, p_cases int, p_master int, p_uom text) RETURNS void LANGUAGE plpgsql AS $f$
BEGIN
  BEGIN
    INSERT INTO public.products (name, category, sku, hsn_code, cartons_per_pallet, master_cartons_per_pallet, pallet_uom)
    VALUES ('p33-' || p_label, 'p33', 'P33-' || p_label, '00000000', p_cases, p_master, p_uom);
    INSERT INTO p33_case VALUES (p_label, TRUE);
  EXCEPTION WHEN check_violation THEN
    INSERT INTO p33_case VALUES (p_label, FALSE);
  END;
END $f$;
SELECT pg_temp.p33_try('all_null', NULL, NULL, NULL);
SELECT pg_temp.p33_try('full', 40, 8, 'standard');
SELECT pg_temp.p33_try('case_only', 40, NULL, 'standard');
SELECT pg_temp.p33_try('master_only', NULL, 8, 'standard');
SELECT pg_temp.p33_try('uom_only', NULL, NULL, 'standard');
SELECT pg_temp.p33_try('max', 10000, 10000, 'x');
SELECT pg_temp.p33_try('qty_without_uom', 40, NULL, NULL);
SELECT pg_temp.p33_try('master_without_uom', NULL, 8, NULL);
SELECT pg_temp.p33_try('zero', 0, NULL, 'standard');
SELECT pg_temp.p33_try('negative', NULL, -3, 'standard');
SELECT pg_temp.p33_try('too_big', 10001, NULL, 'standard');
SELECT pg_temp.p33_try('blank_uom', 5, NULL, '');
SELECT pg_temp.p33_try('space_uom', 5, NULL, '   ');
SELECT pg_temp.p33_try('padded_uom', 5, NULL, ' std ');
SELECT pg_temp.p33_try('long_uom', 5, NULL, repeat('x', 65));
SELECT pg_temp.p33_try('uom_64', 5, NULL, repeat('x', 64));
SELECT is((SELECT ok FROM p33_case WHERE label = 'all_null'), TRUE, 'B01 a row with no pallet data is accepted (backward compatible)');
SELECT is((SELECT ok FROM p33_case WHERE label = 'full'), TRUE, 'B02 independent case and master counts with a type are accepted');
SELECT is((SELECT bool_and(ok) FROM p33_case WHERE label IN ('case_only', 'master_only', 'max', 'uom_64')), TRUE,
  'B03 complete declarations (one or both counts plus a type) and boundary values are accepted');
SELECT is((SELECT ok FROM p33_case WHERE label = 'uom_only'), FALSE,
  'B03b a pallet type without any quantity is rejected (same contract as Studio)');
SELECT is((SELECT bool_or(ok) FROM p33_case WHERE label IN ('qty_without_uom', 'master_without_uom')), FALSE,
  'B04 a quantity without a pallet type is rejected');
SELECT is((SELECT bool_or(ok) FROM p33_case WHERE label IN ('zero', 'negative', 'too_big')), FALSE,
  'B05 zero, negative and oversize quantities are rejected');
SELECT is((SELECT bool_or(ok) FROM p33_case WHERE label IN ('blank_uom', 'space_uom', 'padded_uom', 'long_uom')), FALSE,
  'B06 blank, whitespace-padded and over-long pallet types are rejected');
SELECT is((SELECT count(*)::int FROM public.products WHERE name = 'p33-full' AND cartons_per_pallet = 40 AND master_cartons_per_pallet = 8),
  1, 'B07 stored values round-trip exactly, with no derived or defaulted quantity');
SELECT throws_ok($$UPDATE public.products SET cartons_per_pallet = 0 WHERE name = 'p33-full'$$, '23514', NULL,
  'B08 UPDATE to an invalid pallet quantity is rejected');
SELECT throws_ok($$UPDATE public.products SET pallet_uom = NULL WHERE name = 'p33-full'$$, '23514', NULL,
  'B09 removing the type while quantities remain is rejected');
SELECT throws_ok($$UPDATE public.products SET cartons_per_pallet = NULL, master_cartons_per_pallet = NULL WHERE name = 'p33-full'$$, '23514', NULL,
  'B09b removing every quantity while keeping the type is rejected');
SELECT lives_ok($$UPDATE public.products SET cartons_per_pallet = NULL, master_cartons_per_pallet = NULL, pallet_uom = NULL WHERE name = 'p33-full'$$,
  'B10 clearing all pallet data together is allowed');
SELECT is((SELECT count(*)::int FROM public.products WHERE name = 'p33-all_null' AND cartons_per_pallet IS NULL
  AND master_cartons_per_pallet IS NULL AND pallet_uom IS NULL), 1, 'B11 untouched rows remain NULL (not supplied)');
SELECT ok(NOT EXISTS (SELECT 1 FROM pg_policies WHERE schemaname = 'public' AND tablename = 'products'
  AND (COALESCE(qual, '') || COALESCE(with_check, '')) ~* 'pallet'),
  'B12 no RLS policy refers to pallet columns (no authority change)');
SELECT is((SELECT count(*)::int FROM pg_trigger WHERE tgrelid = 'public.products'::regclass AND NOT tgisinternal
  AND pg_get_triggerdef(oid) ~* 'pallet'), 0, 'B13 no trigger was added for pallet columns');
SELECT is((SELECT count(*)::int FROM pg_constraint WHERE conrelid = 'public.products'::regclass AND conname LIKE 'products_point33%'),
  1, 'B14 exactly one Point33 constraint');
SELECT ok((SELECT NOT attisdropped FROM pg_attribute WHERE attrelid = 'public.products'::regclass AND attname = 'pallet_uom'),
  'B17 pallet columns are live');
SELECT is((SELECT count(*)::int FROM pg_attribute WHERE attrelid = 'public.products'::regclass AND NOT attisdropped
  AND attname IN ('cartons_per_pallet', 'master_cartons_per_pallet', 'pallet_uom')), 3, 'B18 exactly three pallet columns');
SELECT is((SELECT count(*)::int FROM pg_description d JOIN pg_attribute a ON a.attrelid = d.objoid AND a.attnum = d.objsubid
  WHERE d.objoid = 'public.products'::regclass AND a.attname IN ('cartons_per_pallet', 'master_cartons_per_pallet', 'pallet_uom')),
  3, 'B19 each pallet column documents that it is never inferred');

-- anon can never write pallet data (by table privilege or by RLS - both raise 42501 or affect 0 rows)
CREATE FUNCTION pg_temp.p33_anon_update() RETURNS integer LANGUAGE plpgsql AS $f$
DECLARE n integer;
BEGIN
  UPDATE public.products SET cartons_per_pallet = 7, pallet_uom = 'anon-write' WHERE name = 'p33-case_only';
  GET DIAGNOSTICS n = ROW_COUNT;
  RETURN n;
EXCEPTION WHEN insufficient_privilege THEN
  RETURN 0;
END $f$;
GRANT EXECUTE ON FUNCTION pg_temp.p33_anon_update() TO PUBLIC;
SET LOCAL ROLE anon;
SELECT throws_ok($$INSERT INTO public.products (name, category, sku, hsn_code, cartons_per_pallet, pallet_uom)
  VALUES ('p33-anon', 'p33', 'P33-ANON', '0', 5, 'std')$$, '42501', NULL, 'B15 anon cannot insert pallet metadata');
SELECT is(pg_temp.p33_anon_update(), 0, 'B16 anon cannot update pallet metadata');
RESET ROLE;
SELECT is((SELECT cartons_per_pallet FROM public.products WHERE name = 'p33-case_only'), 40, 'B20 the anon attempt left the stored count untouched');

SELECT * FROM finish();
ROLLBACK;

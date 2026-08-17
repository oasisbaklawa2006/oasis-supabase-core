begin;
-- Contract coverage for 20260817090000_rgs_department_taxonomy.sql.
select plan(18);

select has_table('public', 'production_departments', 'canonical department master exists');
select is((select count(*)::int from public.production_departments where active), 6, 'exactly six canonical departments are active');

select has_function('public', 'canonical_production_department', array['text'], 'canonical mapping function exists');
select has_function('public', 'role_canonical_department', array['text'], 'role mapping function exists');
select has_function('public', 'user_canonical_department', array['uuid'], 'user mapping function exists');

-- Every legacy products.production_department CHECK value must resolve.
select is(canonical_production_department('arabic_sweets'), 'ARABIC_SWEETS', 'arabic_sweets maps');
select is(canonical_production_department('dragees'), 'CHOCOLATES_CONFECTIONERY', 'legacy dragees maps under Chocolates & Confectionery, not a duplicate department');
select is(canonical_production_department('chocolates_confectionery'), 'CHOCOLATES_CONFECTIONERY', 'chocolates_confectionery maps');
select is(canonical_production_department('fusion_sweets'), 'FUSION_SWEETS', 'fusion_sweets maps');
select is(canonical_production_department('seasoned_nuts_mixes'), 'SEASONED_NUTS_MIXES', 'seasoned_nuts_mixes maps');
select is(canonical_production_department('bakery'), 'BAKERY_SEMI_PREPARED', 'bakery maps to Bakery & Semi-Prepared');
select is(canonical_production_department('dates'), 'DATES', 'new dates value maps, closing the PROD_DATES role gap');
select is(canonical_production_department('unknown_value'), NULL, 'unmapped input returns NULL rather than a guessed default');

-- Role -> department closes the PROD_DATES / HOD_DRAGEES inconsistency.
select is(role_canonical_department('PROD_DATES'), 'DATES', 'PROD_DATES now resolves to a real department');
select is(role_canonical_department('HOD_DRAGEES'), 'CHOCOLATES_CONFECTIONERY', 'HOD_DRAGEES resolves without inventing a duplicate department');
select is(role_canonical_department('HOD_DATES'), 'DATES', 'new HOD_DATES role resolves');
select is(role_canonical_department('RGS_ADMIN'), NULL, 'non-department-scoped roles resolve to NULL, not a guessed department');

-- Widened CHECK constraint accepts 'dates' without breaking existing values.
prepare insert_dates_product as
  insert into public.products (id, name, category, sku, hsn_code, production_department)
  values (gen_random_uuid(), 'pgtap dates product', 'dates', 'PGTAP-DATES-001', '0000', 'dates');
select lives_ok('insert_dates_product', 'products.production_department accepts the new dates value');

select * from finish();
rollback;

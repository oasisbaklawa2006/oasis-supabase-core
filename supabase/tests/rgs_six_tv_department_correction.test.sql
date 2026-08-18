begin;
-- Contract coverage for 20260818090000_rgs_six_tv_department_correction.sql
-- (Central issue #368 owner correction to the six-TV department model).
select plan(12);

-- Exactly five production departments remain (RGS is the sixth TV surface
-- but is not itself a production department row).
select is((select count(*)::int from public.production_departments where active), 5, 'five canonical production departments after the correction');
select isnt_empty($$select 1 from public.production_departments where code = 'BAKERY'$$, 'BAKERY exists (renamed from BAKERY_SEMI_PREPARED)');
select is_empty($$select 1 from public.production_departments where code = 'BAKERY_SEMI_PREPARED'$$, 'BAKERY_SEMI_PREPARED no longer exists');
select is_empty($$select 1 from public.production_departments where code = 'DATES'$$, 'standalone DATES department is retired');

-- semi_prepared moved from Bakery to Arabic Sweets.
select is(canonical_production_department('semi_prepared'), 'ARABIC_SWEETS', 'semi_prepared now resolves to Arabic Sweets');
select is(canonical_production_department('bakery'), 'BAKERY', 'bakery resolves to the renamed BAKERY department, bakery-only');

-- dates moved from a standalone department to Fusion Sweets.
select is(canonical_production_department('dates'), 'FUSION_SWEETS', 'dates now resolves to Fusion Sweets');

-- Dragees / Chocolates & Confectionery mapping is unaffected.
select is(canonical_production_department('dragees'), 'CHOCOLATES_CONFECTIONERY', 'dragees mapping unaffected by the correction');

-- Role -> department follows the same correction.
select is(role_canonical_department('PROD_DATES'), 'FUSION_SWEETS', 'PROD_DATES routes to Fusion Sweets');
select is(role_canonical_department('HOD_DATES'), 'FUSION_SWEETS', 'HOD_DATES routes to Fusion Sweets');
select is(role_canonical_department('PROD_BAKERY'), 'BAKERY', 'PROD_BAKERY routes to the renamed BAKERY department');
select is(role_canonical_department('HOD_BAKERY'), 'BAKERY', 'HOD_BAKERY routes to the renamed BAKERY department');

select finish();
rollback;

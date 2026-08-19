begin;
-- Behavioral coverage for 20260819101000_fwd_rgs_lifecycle_quantity_correctness.sql.
select plan(7);

insert into public.users (id, role) values
  ('51000000-0000-0000-0000-000000000001', 'PROD_ARABIC'),
  ('51000000-0000-0000-0000-000000000002', 'SALES_REP');

insert into public.products (id, name, category, sku, hsn_code, production_department) values
  ('61000000-0000-0000-0000-000000000001', 'Test Lifecycle Tray', 'sweets', 'LIFECYCLE-TRAY', '1905', 'arabic_sweets');

-- =================================================================================
-- 1. canonical_production_department resolves for a non-staff authenticated
--    caller now that it is SECURITY DEFINER, instead of silently returning
--    NULL because production_departments RLS blocked the row lookup.
-- =================================================================================

select is(
  (select public.canonical_production_department('arabic_sweets')),
  'ARABIC_SWEETS',
  'as a privileged session, the mapping resolves (sanity baseline)'
);

select set_config('request.jwt.claims', json_build_object('sub', '51000000-0000-0000-0000-000000000002', 'role', 'authenticated')::text, true);
set local role authenticated;

select is(
  (select public.canonical_production_department('arabic_sweets')),
  'ARABIC_SWEETS',
  'a non-staff authenticated caller (SALES_REP) still resolves the real department code, not NULL'
);

select is(
  (select count(*)::int from public.production_departments),
  0,
  'the same non-staff caller still cannot directly SELECT production_departments -- RLS on the base table is unchanged, only the SECURITY DEFINER function is widened'
);

reset role;

-- =================================================================================
-- 2. quick_log_production_to_rgs: wastage above 10% of produced quantity no
--    longer spuriously fails declare_production_ready's tolerance check,
--    because assigned_qty now reflects produced + wasted, not produced alone.
-- =================================================================================

select set_config('request.jwt.claims', json_build_object('sub', '51000000-0000-0000-0000-000000000001', 'role', 'authenticated')::text, true);
set local role authenticated;

select lives_ok(
  $$ select public.quick_log_production_to_rgs(
       '61000000-0000-0000-0000-000000000001', 'ARABIC_SWEETS', 10, 0, 'corr-qlog-zero-waste', 'B-QLOG-ZERO'
     ) $$,
  'quick-log with zero waste succeeds'
);

select lives_ok(
  $$ select public.quick_log_production_to_rgs(
       '61000000-0000-0000-0000-000000000001', 'ARABIC_SWEETS', 10, 1, 'corr-qlog-low-waste', 'B-QLOG-LOW'
     ) $$,
  'quick-log with 10%% waste (at the tolerance boundary) succeeds'
);

select lives_ok(
  $$ select public.quick_log_production_to_rgs(
       '61000000-0000-0000-0000-000000000001', 'ARABIC_SWEETS', 10, 3, 'corr-qlog-legit-high-waste', 'B-QLOG-HIGH'
     ) $$,
  'quick-log with legitimate 30%% waste no longer spuriously fails the assigned-quantity tolerance check'
);

select throws_like(
  $$ select public.quick_log_production_to_rgs(
       '61000000-0000-0000-0000-000000000001', 'ARABIC_SWEETS', 0, 0, 'corr-qlog-invalid-qty', 'B-QLOG-INVALID'
     ) $$,
  '%Produced quantity must be positive%',
  'an invalid (non-positive) produced quantity still fails'
);

select finish();
rollback;

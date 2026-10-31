-- Contract for 20261101090000_buyer_carton_packing_profile_projection_v1.sql (spec section 9 of CORE_PACKING_PROFILE_CONTRACT_SPEC.md).
begin;
select plan(37);

-- Fixtures (all synthetic) -------------------------------------------------------------------------------------------
insert into auth.users (id) values ('00000000-0000-0000-0000-00000000000a'), ('00000000-0000-0000-0000-00000000000b'), ('00000000-0000-0000-0000-00000000000c'),
  ('00000000-0000-0000-0000-00000000000d'), ('00000000-0000-0000-0000-00000000000e'), ('00000000-0000-0000-0000-00000000000f'), ('00000000-0000-0000-0000-0000000000ad');
insert into public.companies (id, status, is_frozen, discount_percentage) values
  ('00000000-0000-0000-0000-0000000000a1', 'active', false, 0), ('00000000-0000-0000-0000-0000000000b1', 'active', false, 10), ('00000000-0000-0000-0000-0000000000f1', 'active', true, 0);
insert into public.profiles (id, company_id, is_approved, status, role) values
  ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a1', true, 'approved', 'b2b_buyer'),
  ('00000000-0000-0000-0000-00000000000b', '00000000-0000-0000-0000-0000000000b1', true, 'approved', 'buyer'),
  ('00000000-0000-0000-0000-00000000000f', '00000000-0000-0000-0000-0000000000f1', true, 'approved', 'b2b_buyer'),
  ('00000000-0000-0000-0000-00000000000c', '00000000-0000-0000-0000-0000000000a1', false, 'pending', 'b2b_buyer'),
  ('00000000-0000-0000-0000-00000000000d', '00000000-0000-0000-0000-0000000000a1', true, 'approved', 'ADMIN');
insert into public.users (id, is_active, role) values ('00000000-0000-0000-0000-00000000000d', true, 'ADMIN');
insert into public.products (id, sku, product_name, is_active, visible_in_catalog, is_catalogue_ready, uom) select ('00000000-0000-0000-0000-00000000' || lpad(n::text, 4, '0'))::uuid, 'SKU' || n, 'Product ' || n, n <> 1004, true, true, 'tray' from generate_series(1001, 1009) n;
insert into public.product_pricing_rules (product_id, base_price, currency, uom, gst_rate, tax_inclusive, price_channel, approval_status)
  select ('00000000-0000-0000-0000-00000000' || lpad(n::text, 4, '0'))::uuid, 100, 'INR', case when n = 1002 then 'kg' else 'tray' end, 5, true, 'b2b', 'approved' from generate_series(1001, 1009) n where n <> 1003;
-- configurations: 888x4 v1 and v2 live; bulk-6 draft; bulk-10 v1 expired, v2 not yet effective
insert into public.carton_configurations (config_id, config_version, label, family, capacity_slots, inner_pack, eligible_packing_groups, mixable_group_sets, approval_status, approved_by, approved_at, evidence_ref, effective_from, effective_until) values
  ('888x4', 1, 'Type A v1', 'bulk_sweets', 4, 'tray', '{g1,g2}', '[["g1","g2"]]', 'approved', '00000000-0000-0000-0000-0000000000ad', now(), 'EV-1', null, null),
  ('888x4', 2, 'Type A v2', 'bulk_sweets', 4, 'tray', '{g1,g2}', '[["g1","g2"]]', 'approved', '00000000-0000-0000-0000-0000000000ad', now(), 'EV-2', null, null),
  ('bulk-6', 1, 'Type B', 'bulk_sweets', 6, 'box', '{g1}', '[]', 'draft', null, null, null, null, null),
  ('bulk-10', 1, 'Type C v1', 'bulk_sweets', 10, 'tray', '{g1}', '[]', 'approved', '00000000-0000-0000-0000-0000000000ad', now(), 'EV-3', null, now() - interval '1 day'),
  ('bulk-10', 2, 'Type C v2', 'bulk_sweets', 10, 'tray', '{g1}', '[]', 'approved', '00000000-0000-0000-0000-0000000000ad', now(), 'EV-4', now() + interval '1 day', null);
-- profiles
create temp table _p (n int, status text, cfgs text[], basis text, eff_from timestamptz, eff_until timestamptz, uom text) on commit drop;
insert into _p values (1001, 'approved', '{888x4,bulk-6}', 'slot_unit', null, null, 'tray'), (1002, 'approved', '{888x4}', 'slot_unit', null, null, 'tray'),
  (1003, 'approved', '{888x4}', 'slot_unit', null, null, 'tray'), (1004, 'approved', '{888x4}', 'slot_unit', null, null, 'tray'), (1005, 'draft', '{888x4}', 'slot_unit', null, null, 'tray'),
  (1006, 'approved', '{888x4}', 'slot_unit', now() + interval '1 day', null, 'tray'), (1007, 'approved', '{888x4}', 'slot_unit', null, now() - interval '1 day', 'tray'),
  (1008, 'approved', '{888x4}', 'fixed_ratio', null, null, 'tray'), (1009, 'approved', '{bulk-6}', 'slot_unit', null, null, 'tray');
insert into public.product_packing_profiles (product_id, packing_group, conversion_basis, slots_per_unit, ordered_units_per_slot, commercial_uom, carton_config_ids, profile_version, approval_status, approved_by, approved_at, evidence_ref, effective_from, effective_until)
  select ('00000000-0000-0000-0000-00000000' || lpad(n::text, 4, '0'))::uuid, 'g1', basis, case when basis = 'slot_unit' then 1 end, case when basis = 'fixed_ratio' then 2.5 end, uom, cfgs, 1, status,
         case when status = 'approved' then '00000000-0000-0000-0000-0000000000ad'::uuid end, case when status = 'approved' then now() end, case when status = 'approved' then 'EV-P' end, eff_from, eff_until from _p;

-- Access control -------------------------------------------------------------------------------------------------------
set local role anon;
select throws_ok($$select * from public.buyer_carton_configurations_v1()$$, 'permission denied', 'anonymous callers cannot execute the configuration projection');
select throws_ok($$select * from public.buyer_packing_profiles_v1()$$, 'permission denied', 'anonymous callers cannot execute the profile projection');
reset role;

set local role authenticated; select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000000a', true);
select throws_ok($$select * from public.carton_configurations$$, 'permission denied', 'buyers cannot read the configuration governance table');
select throws_ok($$select * from public.product_packing_profiles$$, 'permission denied', 'buyers cannot read the profile governance table');
select throws_ok($$insert into public.product_packing_profiles (product_id, packing_group, commercial_uom, carton_config_ids, profile_version, slots_per_unit) values (gen_random_uuid(), 'g', 'tray', '{x}', 9, 1)$$, 'permission denied', 'buyers cannot write governance tables');
select is((select count(*)::int from public.buyer_carton_configurations_v1()), 1, 'approved buyer sees exactly one live configuration (drafts, expired and future versions hidden)');
select is((select config_version from public.buyer_carton_configurations_v1() where config_id = '888x4'), 2, 'the highest live version wins');
select is((select count(*)::int from public.buyer_carton_configurations_v1() where config_id in ('bulk-6', 'bulk-10')), 0, 'draft, expired and not-yet-effective configurations are never returned');
select is((select array_agg(product_id::text order by product_id) from public.buyer_packing_profiles_v1()), array['00000000-0000-0000-0000-000000001001'], 'only the orderable product with an approved, effective, unit-matching profile is returned (unit mismatch, no price, unpublished, draft, future, expired, fixed_ratio and non-live-config profiles excluded)');
select is((select carton_config_ids from public.buyer_packing_profiles_v1()), array['888x4'], 'non-live configuration ids are dropped from the profile');
select is((select sku from public.buyer_packing_profiles_v1()), 'SKU1001', 'sku is returned for display');
select ok((select bool_and(approval_status = 'approved' and contract_version = 1) from public.buyer_packing_profiles_v1()), 'rows are approved and contract_version 1');
select ok((select bool_and(commercial_uom = lower(pr.uom)) from public.buyer_packing_profiles_v1() pp join public.buyer_product_prices_v1() pr using (product_id)), 'commercial_uom equals the price projection uom for every returned row');
select ok(pg_get_function_result('public.buyer_packing_profiles_v1()'::regprocedure) !~* '(dimension|weight|cost|approved_by|evidence|price|gst)', 'profile projection exposes no dimension, weight, cost, approver, evidence, price or tax column');
select ok(pg_get_function_result('public.buyer_carton_configurations_v1()'::regprocedure) !~* '(dimension|weight|cost|approved_by|evidence|price|gst)', 'configuration projection exposes no dimension, weight, cost, approver, evidence, price or tax column');
reset role;

-- Customer isolation and ineligible callers ----------------------------------------------------------------------------------
create temp table _a (h text) on commit drop; create temp table _b (h text) on commit drop; grant all on _a, _b to public;
set local role authenticated; select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000000a', true);
insert into _a select projection_hash from public.buyer_packing_profiles_v1();
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000000b', true);
insert into _b select projection_hash from public.buyer_packing_profiles_v1();
select is((select array_agg(h) from _a), (select array_agg(h) from _b), 'two different approved buyer companies receive identical packing facts (no company-specific data)');
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000000f', true);
select is((select count(*)::int from public.buyer_packing_profiles_v1()), 0, 'a frozen company receives no profiles');
select is((select count(*)::int from public.buyer_carton_configurations_v1()), 0, 'a frozen company receives no configurations');
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000000c', true);
select is((select count(*)::int from public.buyer_packing_profiles_v1()), 0, 'a pending (unapproved) buyer receives no profiles');
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000000d', true);
select is((select count(*)::int from public.buyer_packing_profiles_v1()) + (select count(*)::int from public.buyer_carton_configurations_v1()), 0, 'a staff account receives nothing');
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000000e', true);
select is((select count(*)::int from public.buyer_packing_profiles_v1()) + (select count(*)::int from public.buyer_carton_configurations_v1()), 0, 'an authenticated user with no buyer profile receives nothing');
reset role;
select ok(has_function_privilege('service_role', 'public.buyer_packing_profiles_v1()', 'execute'), 'service_role may execute the projection');

-- Price authority is untouched ---------------------------------------------------------------------------------------------
set local role authenticated; select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000000a', true);
select is((select count(*)::int from public.buyer_product_prices_v1()), 7, 'the price projection still serves the same approved prices (no packing table affects it)');
reset role;

-- Versioning, staleness and immutability -------------------------------------------------------------------------------------
create temp table _h1 (h text) on commit drop; grant all on _h1 to public;
set local role authenticated; select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000000a', true);
insert into _h1 select projection_hash from public.buyer_packing_profiles_v1(); reset role;
insert into public.product_packing_profiles (product_id, packing_group, slots_per_unit, commercial_uom, carton_config_ids, profile_version, approval_status, approved_by, approved_at, evidence_ref)
  values ('00000000-0000-0000-0000-000000001001', 'g1', 2, 'tray', '{888x4}', 2, 'approved', '00000000-0000-0000-0000-0000000000ad', now(), 'EV-P2');
set local role authenticated; select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000000a', true);
select is((select slots_per_unit from public.buyer_packing_profiles_v1()), 2, 'a newer approved version replaces the older one');
select isnt((select projection_hash from public.buyer_packing_profiles_v1()), (select h from _h1), 'the projection hash changes when a governed field changes');
reset role;
update public.product_packing_profiles set approval_status = 'retired' where product_id = '00000000-0000-0000-0000-000000001001' and profile_version = 2;
set local role authenticated; select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000000a', true);
select is((select slots_per_unit from public.buyer_packing_profiles_v1()), 1, 'retiring the newest version falls back to the previous approved version (stale profiles stop being served)');
reset role;
select throws_ok($$update public.product_packing_profiles set slots_per_unit = 9 where product_id = '00000000-0000-0000-0000-000000001001' and profile_version = 1$$, 'approved packing rows are immutable', 'approved profile rows cannot be edited in place');
select throws_ok($$delete from public.carton_configurations where config_id = '888x4' and config_version = 1$$, 'cannot be deleted', 'approved configurations cannot be deleted');
select lives_ok($$update public.carton_configurations set approval_status = 'retired' where config_id = '888x4' and config_version = 2$$, 'an approved configuration can be retired');
set local role authenticated; select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000000a', true);
select is((select config_version from public.buyer_carton_configurations_v1() where config_id = '888x4'), 1, 'retiring the newest configuration falls back to the previous approved version');
reset role;

-- Window semantics (half-open) -------------------------------------------------------------------------------------------------
insert into public.carton_configurations (config_id, config_version, label, family, capacity_slots, inner_pack, approval_status, approved_by, approved_at, evidence_ref, effective_until)
  values ('edge', 1, 'edge', 'bulk_sweets', 2, 'tray', 'approved', '00000000-0000-0000-0000-0000000000ad', now(), 'EV-E', now());
set local role authenticated; select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000000a', true);
select is((select count(*)::int from public.buyer_carton_configurations_v1() where config_id = 'edge'), 0, 'the instant equal to effective_until is already expired');
reset role;

-- Constraints ----------------------------------------------------------------------------------------------------------------------
select throws_ok($$insert into public.product_packing_profiles (product_id, packing_group, slots_per_unit, commercial_uom, carton_config_ids, profile_version, requires_separate_carton, mix_allowed) values ('00000000-0000-0000-0000-000000001003', 'g', 1, 'tray', '{x}', 7, true, true)$$, 'product_packing_profiles_separate_ck', 'requires_separate_carton forbids mix_allowed');
select throws_ok($$insert into public.carton_configurations (config_id, config_version, label, family, capacity_slots, inner_pack, slot_columns, slot_rows) values ('grid', 1, 'g', 'f', 6, 'tray', 2, 2)$$, 'carton_configurations_grid_ck', 'slot_columns x slot_rows must equal capacity_slots');
select throws_ok($$insert into public.carton_configurations (config_id, config_version, label, family, capacity_slots, inner_pack, approval_status) values ('noappr', 1, 'n', 'f', 4, 'tray', 'approved')$$, 'carton_configurations_approved_ck', 'an approved configuration requires approver, time and evidence');
select throws_ok($$insert into public.product_packing_profiles (product_id, packing_group, slots_per_unit, commercial_uom, carton_config_ids, profile_version, variant_id) values ('00000000-0000-0000-0000-000000001003', 'g', 1, 'tray', '{x}', 8, gen_random_uuid())$$, 'check', 'variants are reserved and rejected');
select throws_ok($$insert into public.product_packing_profiles (product_id, packing_group, conversion_basis, commercial_uom, carton_config_ids, profile_version) values ('00000000-0000-0000-0000-000000001003', 'g', 'fixed_ratio', 'tray', '{x}', 9)$$, 'product_packing_profiles_basis_ck', 'fixed_ratio requires a ratio');
select throws_ok($$insert into public.carton_configurations (config_id, config_version, label, family, capacity_slots, inner_pack, eligible_packing_groups, mixable_group_sets) values ('mix', 1, 'm', 'f', 4, 'tray', '{a}', '[["a","b"]]')$$, 'not an eligible packing group', 'every mixable group must be an eligible group');

select finish();
rollback;

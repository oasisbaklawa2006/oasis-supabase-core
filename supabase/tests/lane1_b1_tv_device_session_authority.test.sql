begin;
-- Contract coverage for 20260824130000_lane1_b1_tv_device_session_authority.sql.
-- Central issue #368, Lane 1 B1.
select plan(55);

-- ---------------------------------------------------------------------
-- Fixture: one admin, one ordinary (non-TV) staff account, two TV
-- devices (BAKERY, RGS). TV accounts carry role='tv_ready' in
-- public.users -- a real, independently-existing, non-admin/non-staff
-- role -- specifically so tests M/N can prove device authority neither
-- grants nor depends on internal-staff/admin authority.
-- ---------------------------------------------------------------------
insert into auth.users (id, email) values
  ('14000000-0000-0000-0000-000000000001', 'admin@pgtap.invalid'),
  ('14000000-0000-0000-0000-000000000002', 'employee@pgtap.invalid'),
  ('14000000-0000-0000-0000-000000000003', 'tv-bakery@pgtap.invalid'),
  ('14000000-0000-0000-0000-000000000004', 'tv-rgs@pgtap.invalid');

insert into public.users (id, email, role) values
  ('14000000-0000-0000-0000-000000000001', 'admin@pgtap.invalid', 'super_admin'),
  ('14000000-0000-0000-0000-000000000002', 'employee@pgtap.invalid', 'PROD_ARABIC'),
  ('14000000-0000-0000-0000-000000000003', 'tv-bakery@pgtap.invalid', 'tv_ready'),
  ('14000000-0000-0000-0000-000000000004', 'tv-rgs@pgtap.invalid', 'tv_ready');

-- A. table/helper existence -----------------------------------------------
select has_table('public', 'tv_devices', 'tv_devices table exists');
select has_function('public', 'is_tv_device', 'is_tv_device exists');
select has_function('public', 'current_tv_group', 'current_tv_group exists');
select has_function('public', 'is_tv_device_for_group', 'is_tv_device_for_group exists');
select has_function('public', 'tv_device_status', 'tv_device_status exists');
select has_function('public', 'register_tv_device', 'register_tv_device exists');
select has_function('public', 'revoke_tv_device', 'revoke_tv_device exists');

-- C. unauthenticated caller fails closed (no JWT claim set at all) --------
select is(public.is_tv_device(), false, 'is_tv_device is false with no authenticated session');
select is(public.current_tv_group(), null, 'current_tv_group is null with no authenticated session');
select is(public.tv_device_status(), 'NOT_REGISTERED', 'tv_device_status is NOT_REGISTERED with no authenticated session');
select throws_like(
  $$ select public.register_tv_device('14000000-0000-0000-0000-000000000003', 'TV Bakery 01', 'BAKERY') $$,
  '%Not authorised%',
  'register_tv_device rejects an unauthenticated caller'
);

-- Register as admin -------------------------------------------------------
set local request.jwt.claim.sub = '14000000-0000-0000-0000-000000000001';
set local request.jwt.claim.role = 'authenticated';

-- B. malformed/unknown group rejected --------------------------------------
select throws_like(
  $$ select public.register_tv_device('14000000-0000-0000-0000-000000000003', 'TV Bakery 01', 'MARS_COLONY') $$,
  '%Unknown tv_group%',
  'register_tv_device rejects an unrecognised tv_group'
);

select lives_ok(
  $$ select public.register_tv_device('14000000-0000-0000-0000-000000000003', 'TV Bakery 01', 'bakery') $$,
  'admin registers the bakery TV device (lower-case group is normalised)'
);
select lives_ok(
  $$ select public.register_tv_device('14000000-0000-0000-0000-000000000004', 'TV RGS 01', 'RGS') $$,
  'admin registers the RGS TV device'
);

-- D. ordinary employee is not automatically a TV ---------------------------
set local request.jwt.claim.sub = '14000000-0000-0000-0000-000000000002';
select is(public.is_tv_device(), false, 'an ordinary staff account is not a TV device');
select is(public.current_tv_group(), null, 'an ordinary staff account has no TV group');

-- E. TV identity resolves its canonical group ------------------------------
set local request.jwt.claim.sub = '14000000-0000-0000-0000-000000000003';
select is(public.is_tv_device(), true, 'the bakery TV device is recognised');
select is(public.current_tv_group(), 'BAKERY', 'the bakery TV device resolves to BAKERY');
select is(public.tv_device_status(), 'ACTIVE', 'the bakery TV device status is ACTIVE');

-- H. wrong-group request rejected ------------------------------------------
select is(public.is_tv_device_for_group('RGS'), false, 'the bakery TV device is not recognised for the RGS group');
select is(public.tv_device_status('RGS'), 'GROUP_MISMATCH', 'tv_device_status reports GROUP_MISMATCH for the wrong expected group');

-- Q. register_tv_device requires the target identity to already hold a
--    governed TV role -- an admin cannot bind an arbitrary/non-TV identity
--    (e.g. an ordinary staff account) to a device row.
set local request.jwt.claim.sub = '14000000-0000-0000-0000-000000000001';
select throws_ok(
  $$ select public.register_tv_device('14000000-0000-0000-0000-000000000002', 'Rogue TV', 'BAKERY') $$,
  42501, NULL,
  'register_tv_device rejects an identity that does not hold a governed TV role'
);
set local request.jwt.claim.sub = '14000000-0000-0000-0000-000000000003';

-- M/N. device authority is orthogonal to admin/internal-staff authority ---
select is(public.is_admin(), false, 'a TV device session is not is_admin()');
select is(public.is_internal_staff('14000000-0000-0000-0000-000000000003'), false, 'a dedicated TV account (role=tv_ready) is not is_internal_staff() merely for holding a device');

-- seed production jobs in two departments to prove group scoping ----------
insert into public.products (id, name, category, sku, hsn_code, production_department) values
  ('24000000-0000-0000-0000-000000000001', 'Bakery Item', 'sweets', 'BK-PGTAP-1', '1905', 'bakery'),
  ('24000000-0000-0000-0000-000000000002', 'Chocolate Item', 'sweets', 'CH-PGTAP-1', '1806', 'chocolates_confectionery');
-- This is a synthetic pgTAP order identity, not a runtime SO creation path.
set local session_replication_role = replica;
insert into public.orders (id, order_number, tracking_token, order_origin) values
  ('34000000-0000-0000-0000-000000000001', 'PGTAP-ORD-TVDEV-1', 'pgtap-fixture-token-tvdev-1', 'MANUAL');
set local session_replication_role = default;
insert into public.production_jobs (id, order_id, product_id, department, canonical_department, assigned_qty, status) values
  ('44000000-0000-0000-0000-000000000001', '34000000-0000-0000-0000-000000000001', '24000000-0000-0000-0000-000000000001', 'BAKERY', 'BAKERY', 5, 'pending'),
  ('44000000-0000-0000-0000-000000000002', '34000000-0000-0000-0000-000000000001', '24000000-0000-0000-0000-000000000002', 'CHOCOLATES_CONFECTIONERY', 'CHOCOLATES_CONFECTIONERY', 5, 'pending');

-- I. correct-group read succeeds -------------------------------------------
select is(
  (select count(*) from public.tv_department_production_queue() where id = '44000000-0000-0000-0000-000000000001'),
  1::bigint,
  'the bakery TV device reads its own department''s job'
);

-- O. cross-department leakage denied ----------------------------------------
select is(
  (select count(*) from public.tv_department_production_queue() where id = '44000000-0000-0000-0000-000000000002'),
  0::bigint,
  'the bakery TV device cannot read a different department''s job'
);

-- R. RGS stock snapshot: RGS device reads FINISHED_GOODS balances, scoped
--    away from any other location; a non-RGS device reads nothing at all.
insert into public.inventory_stock_balances (id, product_id, sku, location_code, available_qty) values
  ('64000000-0000-0000-0000-000000000001', '24000000-0000-0000-0000-000000000001', 'BK-PGTAP-1', 'FINISHED_GOODS', 10),
  ('64000000-0000-0000-0000-000000000002', '24000000-0000-0000-0000-000000000001', 'BK-PGTAP-1', 'B2B_RAW', 99);

select is(
  (select count(*) from public.tv_rgs_stock_snapshot()),
  0::bigint,
  'a non-RGS (bakery) TV device reads no rows from tv_rgs_stock_snapshot'
);

set local request.jwt.claim.sub = '14000000-0000-0000-0000-000000000004';
select is(
  (select count(*) from public.tv_rgs_stock_snapshot()),
  1::bigint,
  'the RGS TV device reads exactly the FINISHED_GOODS balance row'
);
select is(
  (select id from public.tv_rgs_stock_snapshot()),
  '64000000-0000-0000-0000-000000000001'::uuid,
  'the RGS TV device never sees the B2B_RAW balance row at a different location'
);
set local request.jwt.claim.sub = '14000000-0000-0000-0000-000000000003';

-- K. TV cannot invoke RGS mutation authority ---------------------------------
select throws_ok(
  $$ select public.reserve_rgs_stock('RES-TVDEV-1', null, '24000000-0000-0000-0000-000000000001', 'BK-PGTAP-1', 1, 'BAKERY', 'corr-tvdev-rgs-1') $$,
  42501, 'Not authorised to reserve RGS stock',
  'a TV device cannot call reserve_rgs_stock'
);
select throws_like(
  $$ select public.acknowledge_rgs_issue('54000000-0000-0000-0000-000000000001', 1, 'corr-tvdev-rgs-2') $$,
  '%Not authorised%',
  'a TV device cannot call acknowledge_rgs_issue'
);

-- L. TV cannot invoke production mutation authority --------------------------
select throws_like(
  $$ select public.accept_production_job('44000000-0000-0000-0000-000000000001', 'B-TVDEV-1', 'corr-tvdev-prod-1') $$,
  '%Not authorised%',
  'a TV device cannot call accept_production_job'
);
select throws_like(
  $$ select public.start_production_job('44000000-0000-0000-0000-000000000001', 'corr-tvdev-prod-2') $$,
  '%Not authorised%',
  'a TV device cannot call start_production_job'
);

-- J. TV cannot INSERT/UPDATE/DELETE device authority directly (privilege
--    boundary -- checked statically since a superuser pgTAP session
--    bypasses RLS/GRANTs regardless of JWT claims, matching this repo's
--    established has_function_privilege convention for anon checks).
select is(has_table_privilege('authenticated', 'public.tv_devices', 'INSERT'), false, 'authenticated has no INSERT privilege on tv_devices');
select is(has_table_privilege('authenticated', 'public.tv_devices', 'UPDATE'), false, 'authenticated has no UPDATE privilege on tv_devices');
select is(has_table_privilege('authenticated', 'public.tv_devices', 'DELETE'), false, 'authenticated has no DELETE privilege on tv_devices');
select is(has_table_privilege('anon', 'public.tv_devices', 'SELECT'), false, 'anon has no SELECT privilege on tv_devices');

-- S. set_tv_device_group: unknown group rejected, idempotent on replay,
--    real change is applied and reflected in the resolved group.
set local request.jwt.claim.sub = '14000000-0000-0000-0000-000000000001';
select throws_ok(
  $$ select public.set_tv_device_group((select id from public.tv_devices where auth_user_id = '14000000-0000-0000-0000-000000000003'), 'MARS_COLONY') $$,
  22023, NULL,
  'set_tv_device_group rejects an unrecognised tv_group'
);
select lives_ok(
  $$ select public.set_tv_device_group((select id from public.tv_devices where auth_user_id = '14000000-0000-0000-0000-000000000003'), 'BAKERY') $$,
  'set_tv_device_group is idempotent when the group is unchanged'
);
select lives_ok(
  $$ select public.set_tv_device_group((select id from public.tv_devices where auth_user_id = '14000000-0000-0000-0000-000000000003'), 'FUSION_SWEETS') $$,
  'admin changes the bakery device''s group to FUSION_SWEETS'
);
set local request.jwt.claim.sub = '14000000-0000-0000-0000-000000000003';
select is(public.current_tv_group(), 'FUSION_SWEETS', 'the device resolves to its newly-assigned group');
set local request.jwt.claim.sub = '14000000-0000-0000-0000-000000000001';
select lives_ok(
  $$ select public.set_tv_device_group((select id from public.tv_devices where auth_user_id = '14000000-0000-0000-0000-000000000003'), 'BAKERY') $$,
  'admin reverts the device to BAKERY for the remaining department-scoping tests'
);

-- disable_tv_device requires a non-blank reason, matching revoke_tv_device.
select throws_ok(
  $$ select public.disable_tv_device((select id from public.tv_devices where auth_user_id = '14000000-0000-0000-0000-000000000003'), null) $$,
  NULL, 'A reason is required to disable a TV device',
  'disable_tv_device rejects a null reason'
);
select throws_ok(
  $$ select public.disable_tv_device((select id from public.tv_devices where auth_user_id = '14000000-0000-0000-0000-000000000003'), '   ') $$,
  NULL, 'A reason is required to disable a TV device',
  'disable_tv_device rejects a blank reason'
);

-- F/G. disabled and revoked devices are rejected, admin-driven ---------------
select lives_ok(
  $$ select public.disable_tv_device((select id from public.tv_devices where auth_user_id = '14000000-0000-0000-0000-000000000003'), 'pgtap: planned maintenance') $$,
  'admin disables the bakery TV device'
);
set local request.jwt.claim.sub = '14000000-0000-0000-0000-000000000003';
select is(public.is_tv_device(), false, 'a disabled TV device is no longer recognised');
select is(public.tv_device_status(), 'DISABLED', 'tv_device_status reports DISABLED');

set local request.jwt.claim.sub = '14000000-0000-0000-0000-000000000001';
select lives_ok(
  $$ select public.enable_tv_device((select id from public.tv_devices where auth_user_id = '14000000-0000-0000-0000-000000000003')) $$,
  'admin re-enables the bakery TV device'
);
select lives_ok(
  $$ select public.revoke_tv_device((select id from public.tv_devices where auth_user_id = '14000000-0000-0000-0000-000000000003'), 'pgtap: device retired') $$,
  'admin revokes the bakery TV device'
);
select throws_ok(
  $$ select public.enable_tv_device((select id from public.tv_devices where auth_user_id = '14000000-0000-0000-0000-000000000003')) $$,
  42501, 'A revoked TV device cannot be re-enabled -- re-register it instead',
  'enable_tv_device refuses to re-enable a revoked device'
);
set local request.jwt.claim.sub = '14000000-0000-0000-0000-000000000003';
select is(public.tv_device_status(), 'REVOKED', 'tv_device_status reports REVOKED');
select is(public.is_tv_device(), false, 'a revoked TV device is no longer recognised');

-- P. audit lifecycle recorded once/idempotently ------------------------------
set local request.jwt.claim.sub = '14000000-0000-0000-0000-000000000001';
select is(
  (select count(*) from public.audit_logs where module_name = 'TvDeviceAdmin' and action_type = 'TV_DEVICE_REVOKED'
     and entity_id = (select id::text from public.tv_devices where auth_user_id = '14000000-0000-0000-0000-000000000003')),
  1::bigint,
  'exactly one REVOKED audit row exists after the single revoke call'
);
select lives_ok(
  $$ select public.revoke_tv_device((select id from public.tv_devices where auth_user_id = '14000000-0000-0000-0000-000000000003'), 'pgtap: repeat call') $$,
  'revoking an already-revoked device is idempotent (no error)'
);
select is(
  (select count(*) from public.audit_logs where module_name = 'TvDeviceAdmin' and action_type = 'TV_DEVICE_REVOKED'
     and entity_id = (select id::text from public.tv_devices where auth_user_id = '14000000-0000-0000-0000-000000000003')),
  1::bigint,
  'an idempotent replay of revoke_tv_device does not insert a second audit row'
);

select finish();
rollback;
begin;
-- Contract coverage for 20260819130000_rgs_tv_role_write_authority_hardening.sql.
-- Proves the TV kiosk write-authority gap (Central issue #368 Lane 1 B1):
-- a TV_READY-role account must be rejected by start_production_job and
-- accept_production_job even though is_staff_role() alone would accept it.
select plan(9);

insert into public.users (id, role) values
  ('13000000-0000-0000-0000-000000000001', 'PROD_ARABIC'),
  ('13000000-0000-0000-0000-000000000002', 'TV_READY');
insert into public.products (id, name, category, sku, hsn_code, production_department) values
  ('23000000-0000-0000-0000-000000000001', 'Osh El Bulbul Tray', 'sweets', 'OEB-TRAY-TV', '1905', 'arabic_sweets');
insert into public.orders (id, order_number, tracking_token) values
  ('33000000-0000-0000-0000-000000000001', 'PGTAP-ORD-TV-1', 'pgtap-fixture-token-tv-1');

-- is_tv_display_role: exact TV accounts true, real staff and unrelated
-- values false.
select is(public.is_tv_display_role('TV_READY'), true, 'TV_READY is a TV display role');
select is(public.is_tv_display_role('tv_assembly'), true, 'is_tv_display_role is case-insensitive');
select is(public.is_tv_display_role('TV_DISPLAY'), true, 'TV_DISPLAY is a TV display role');
select is(public.is_tv_display_role('TV_DRAGEES'), true, 'TV_DRAGEES is a TV display role');
select is(public.is_tv_display_role('PROD_ARABIC'), false, 'a real production role is not a TV display role');
select is(public.is_tv_display_role(null), false, 'null role is not a TV display role');

insert into public.production_jobs (id, order_id, product_id, department, assigned_qty, status)
values ('43000000-0000-0000-0000-000000000001', '33000000-0000-0000-0000-000000000001', '23000000-0000-0000-0000-000000000001', 'ARABIC_SWEETS', 5, 'pending');

-- The gap this migration closes: a TV_READY-authenticated session must not
-- be able to accept or start a real production job.
set local request.jwt.claim.sub = '13000000-0000-0000-0000-000000000002';
set local request.jwt.claim.role = 'authenticated';

select throws_like(
  $$ select public.accept_production_job('43000000-0000-0000-0000-000000000001', 'B-PGTAP-TV-1', 'corr-tv-accept-1') $$,
  '%Not authorised%',
  'a TV_READY account cannot accept a production job'
);
select throws_like(
  $$ select public.start_production_job('43000000-0000-0000-0000-000000000001', 'corr-tv-start-1') $$,
  '%Not authorised%',
  'a TV_READY account cannot start a production job'
);

-- Real staff in the matching department is unaffected by the hardening.
set local request.jwt.claim.sub = '13000000-0000-0000-0000-000000000001';
set local request.jwt.claim.role = 'authenticated';

select lives_ok(
  $$ select public.accept_production_job('43000000-0000-0000-0000-000000000001', 'B-PGTAP-TV-2', 'corr-tv-accept-2') $$,
  'a real production-role account can still accept a production job'
);

select finish();
rollback;

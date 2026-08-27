begin;
-- Behavioral coverage for 20260819100000_fwd_rgs_authorization_idempotency_hardening.sql.
select plan(15);

insert into public.users (id, role) values
  ('50000000-0000-0000-0000-000000000001', 'PROD_ARABIC'),
  ('50000000-0000-0000-0000-000000000002', 'PROD_CHOCOLATE'),
  ('50000000-0000-0000-0000-000000000003', 'RGS_ADMIN');

insert into public.products (id, name, category, sku, hsn_code, production_department) values
  ('60000000-0000-0000-0000-000000000001', 'Test Baklawa Tray', 'sweets', 'HARDEN-TRAY', '1905', 'arabic_sweets');

insert into public.orders (id, order_number, tracking_token, order_origin) values
  ('70000000-0000-0000-0000-000000000001', 'PGTAP-ORD-HARDEN-1', 'pgtap-fixture-token-harden-1', 'MANUAL');

-- =================================================================================
-- 1. inventory_reservations.correlation_id concurrent-uniqueness enforcement.
-- =================================================================================

set local request.jwt.claim.sub = '50000000-0000-0000-0000-000000000003';
set local request.jwt.claim.role = 'authenticated';

insert into public.inventory_stock_balances (product_id, sku, location_code, available_qty)
values ('60000000-0000-0000-0000-000000000001', 'HARDEN-TRAY', 'FINISHED_GOODS', 10);

select lives_ok(
  $$ select public.reserve_rgs_stock('RES-HARDEN-1', '70000000-0000-0000-0000-000000000001', '60000000-0000-0000-0000-000000000001',
       'HARDEN-TRAY', 5, 'ARABIC_SWEETS', 'corr-harden-reserve') $$,
  'first reservation with a fresh correlation id succeeds'
);

select throws_ok(
  $$ insert into public.inventory_reservations
       (reservation_number, order_id, product_id, sku, requested_qty, reserved_qty, reservation_status, source_department, location_code, correlation_id)
     values
       ('RES-HARDEN-DUP', '70000000-0000-0000-0000-000000000001', '60000000-0000-0000-0000-000000000001',
        'HARDEN-TRAY', 1, 1, 'reserved', 'ARABIC_SWEETS', 'FINISHED_GOODS', 'corr-harden-reserve') $$,
  23505, NULL,
  'a second row with the same non-null correlation_id violates the new unique index'
);

-- =================================================================================
-- 2. release_rgs_reservation / pick_rgs_reservation replay guards are scoped
--    to their own movement_type, not any movement sharing the correlation id.
-- =================================================================================

-- reserve_rgs_stock already wrote an inventory_movements row with
-- correlation_id = 'corr-harden-reserve' (movement_type = 'reservation_created').
-- Reusing that same correlation id for a release must NOT be treated as an
-- already-completed replay of the release itself.
select results_eq(
  $$ select reserved_qty, released_qty from public.release_rgs_reservation(
       (select id from public.inventory_reservations where correlation_id = 'corr-harden-reserve'),
       2, 'order_cancelled', 'corr-harden-reserve'
     ) $$,
  $$ values (3::numeric, 2::numeric) $$,
  'release with a correlation id already used by reservation_created actually releases stock, not a false no-op'
);

select is(
  (select available_qty from public.inventory_stock_balances where sku = 'HARDEN-TRAY'),
  7::numeric,
  'released quantity is credited back to available stock'
);

-- A genuine retry of the SAME release (same correlation id, now tagged
-- reservation_released) must still be idempotent and not double-release.
select results_eq(
  $$ select reserved_qty, released_qty from public.release_rgs_reservation(
       (select id from public.inventory_reservations where correlation_id = 'corr-harden-reserve'),
       2, 'order_cancelled', 'corr-harden-reserve'
     ) $$,
  $$ values (3::numeric, 2::numeric) $$,
  'retrying the same release correlation id is idempotent (no double release)'
);

select is((select available_qty from public.inventory_stock_balances where sku = 'HARDEN-TRAY'), 7::numeric, 'available stock unchanged by the idempotent retry');

-- pick_rgs_reservation: same class of bug plus the missing non-empty
-- correlation-id validation.
select throws_like(
  $$ select public.pick_rgs_reservation((select id from public.inventory_reservations where correlation_id = 'corr-harden-reserve'), 1, '') $$,
  '%correlation id is required%',
  'pick_rgs_reservation now rejects an empty correlation id like its siblings'
);

select results_eq(
  $$ select picked_qty from public.inventory_stock_balances where sku = 'HARDEN-TRAY' $$,
  $$ values (0::numeric) $$,
  'nothing was picked by the rejected empty-correlation call'
);

select lives_ok(
  $$ select public.pick_rgs_reservation((select id from public.inventory_reservations where correlation_id = 'corr-harden-reserve'), 1, 'corr-harden-reserve') $$,
  'picking with the reservation-created correlation id (reused, unrelated movement_type) actually picks stock'
);

select is((select picked_qty from public.inventory_stock_balances where sku = 'HARDEN-TRAY'), 1::numeric, 'picked quantity recorded once');

-- =================================================================================
-- 3. accept_production_job authorizes the actor before returning on the
--    idempotent-replay path.
-- =================================================================================

set local request.jwt.claim.sub = '50000000-0000-0000-0000-000000000001';
insert into public.production_jobs (id, order_id, product_id, department, assigned_qty, status)
values ('80000000-0000-0000-0000-000000000001', '70000000-0000-0000-0000-000000000001', '60000000-0000-0000-0000-000000000001', 'ARABIC_SWEETS', 5, 'pending');

select lives_ok(
  $$ select public.accept_production_job('80000000-0000-0000-0000-000000000001', 'B-HARDEN-1', 'corr-harden-accept') $$,
  'department-matched operator accepts the job'
);

set local request.jwt.claim.sub = '50000000-0000-0000-0000-000000000002';
select throws_like(
  $$ select public.accept_production_job('80000000-0000-0000-0000-000000000001', 'B-HARDEN-2', 'corr-harden-accept-2') $$,
  '%not authorised for department%',
  'a different department can no longer retrieve an already-accepted job via the idempotent-replay path'
);

-- =================================================================================
-- 4. pause_production_job rejects a NULL reason explicitly (previously
--    `p_reason NOT IN (...)` silently passed on NULL).
-- =================================================================================

set local request.jwt.claim.sub = '50000000-0000-0000-0000-000000000001';
insert into public.production_jobs (id, order_id, product_id, department, assigned_qty, status)
values ('80000000-0000-0000-0000-000000000002', '70000000-0000-0000-0000-000000000001', '60000000-0000-0000-0000-000000000001', 'ARABIC_SWEETS', 5, 'pending');

select lives_ok(
  $$ select public.start_production_job('80000000-0000-0000-0000-000000000002', 'corr-harden-start') $$,
  'job moves into in_production so it becomes pausable'
);

select throws_like(
  $$ select public.pause_production_job('80000000-0000-0000-0000-000000000002', null, 'no reason given', 'corr-harden-pause-null') $$,
  '%Unknown pause reason%',
  'a NULL pause reason is now explicitly rejected, not silently inserted'
);

select lives_ok(
  $$ select public.pause_production_job('80000000-0000-0000-0000-000000000002', 'machine_breakdown', 'genuine reason', 'corr-harden-pause-valid') $$,
  'a valid non-NULL pause reason still works'
);

select finish();
rollback;

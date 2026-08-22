begin;
-- Contract coverage for 20260822120000_3pgs_order_item_governed_completion.sql:
-- complete_3pgs_order_item must let internal staff complete a 3PCS order_items
-- row idempotently, record an audit_logs entry, refuse non-3PCS items and
-- items in a non-completable status, and refuse an unauthorised caller --
-- without requiring order_items' broader legacy grants to be touched.
select plan(12);

select has_function('public', 'complete_3pgs_order_item', 'complete_3pgs_order_item exists');

insert into public.users (id, role) values
  ('98000000-0000-0000-0000-000000000001', 'STORE_3RD_PARTY'),
  ('98000000-0000-0000-0000-000000000002', 'CUSTOMER');
insert into public.products (id, name, category, sku, hsn_code, production_department) values
  ('98100000-0000-0000-0000-000000000001', '3PCS Completion Item', 'packaging', 'CARTON-COMPLETE-1', '4823', null);
insert into public.order_items (id, product_id, quantity, department, production_status) values
  ('98200000-0000-0000-0000-000000000001', '98100000-0000-0000-0000-000000000001', 12, '3PCS', 'pending'),
  ('98200000-0000-0000-0000-000000000002', '98100000-0000-0000-0000-000000000001', 8, '3PCS', 'completed'),
  ('98200000-0000-0000-0000-000000000003', '98100000-0000-0000-0000-000000000001', 5, 'ASSEMBLY', 'pending'),
  ('98200000-0000-0000-0000-000000000004', '98100000-0000-0000-0000-000000000001', 3, '3PCS', 'awaiting_dispatch');

set local request.jwt.claim.sub = '98000000-0000-0000-0000-000000000001';
set local request.jwt.claim.role = 'authenticated';

select lives_ok(
  $$ select public.complete_3pgs_order_item('98200000-0000-0000-0000-000000000001', 10) $$,
  'authorised 3PGS staff can complete a pending 3PCS item'
);
select is(
  (select production_status from public.order_items where id = '98200000-0000-0000-0000-000000000001'),
  'completed', 'the item transitions to completed'
);
select is(
  (select actual_packed_qty from public.order_items where id = '98200000-0000-0000-0000-000000000001'),
  10, 'the supplied actual packed quantity is recorded'
);
select is(
  (select count(*)::int from public.audit_logs where entity_id = '98200000-0000-0000-0000-000000000001' and action_type = '3PCS_COMPLETE'),
  1, 'a single audit log entry is recorded for the completion'
);

select lives_ok(
  $$ select public.complete_3pgs_order_item('98200000-0000-0000-0000-000000000001', 999) $$,
  'a retried completion on an already-completed item is a safe no-op'
);
select is(
  (select actual_packed_qty from public.order_items where id = '98200000-0000-0000-0000-000000000001'),
  10, 'the retry does not overwrite the originally recorded packed quantity'
);
select is(
  (select count(*)::int from public.audit_logs where entity_id = '98200000-0000-0000-0000-000000000001' and action_type = '3PCS_COMPLETE'),
  1, 'the retry does not create a second audit log entry'
);

select lives_ok(
  $$ select public.complete_3pgs_order_item('98200000-0000-0000-0000-000000000002') $$,
  'completing an item that was already completed before this migration is also a safe no-op'
);

select throws_ok(
  $$ select public.complete_3pgs_order_item('98200000-0000-0000-0000-000000000003') $$,
  'Order item 98200000-0000-0000-0000-000000000003 is not a 3PCS department item',
  'a non-3PCS department item is refused'
);
select throws_ok(
  $$ select public.complete_3pgs_order_item('98200000-0000-0000-0000-000000000004') $$,
  'Order item 98200000-0000-0000-0000-000000000004 cannot be completed from status awaiting_dispatch',
  'an item in a non-completable status is refused'
);

set local request.jwt.claim.sub = '98000000-0000-0000-0000-000000000002';
select throws_ok(
  $$ select public.complete_3pgs_order_item('98200000-0000-0000-0000-000000000004') $$,
  'Not authorised to complete a 3PGS order item',
  'a non-staff role is refused'
);

select * from finish(); -- skipcq (pgTAP's finish() returns setof text; column count is not actually ambiguous)
rollback;

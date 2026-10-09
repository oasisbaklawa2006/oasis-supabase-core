-- Contract for 20261002181140_customer_checkout_snapshot_authority.sql
begin;
select plan(4);

select has_function('public','customer_checkout_snapshot_total_v1',array['uuid'],
  '20261002181140 installs authoritative checkout snapshot total');

select ok(
  pg_get_functiondef('public.recalculate_customer_app_order_financials(uuid)'::regprocedure)
    like '%customer_checkout_snapshot_total_v1%',
  'CUSTOMER_APP recalculation derives from checkout snapshot'
);

select ok(
  pg_get_functiondef('public.restore_order_financials(uuid)'::regprocedure)
    like '%v_origin=''CUSTOMER_APP''%recalculate_customer_app_order_financials%',
  'financial restore routes CUSTOMER_APP through snapshot authority'
);

select ok(
  exists(select 1 from pg_trigger
    where tgrelid='public.orders'::regclass
      and tgname='trg_customer_checkout_snapshot_immutable'
      and not tgisinternal),
  'checkout snapshot immutability trigger exists'
);

select * from finish();
rollback;

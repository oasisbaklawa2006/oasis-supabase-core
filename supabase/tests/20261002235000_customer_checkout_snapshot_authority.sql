-- Contract: 20261002235000_customer_checkout_snapshot_authority
begin;
select plan(4);
select has_function('public','customer_checkout_snapshot_total_v1',array['uuid'],'20261002235000 installs checkout snapshot financial authority');
select ok(exists(select 1 from pg_trigger where tgrelid='public.orders'::regclass and tgname='trg_customer_checkout_snapshot_immutable' and not tgisinternal),'20261002235000 installs checkout snapshot immutability trigger');
select ok(position('customer_checkout_snapshot_total_v1' in pg_get_functiondef('public.recalculate_customer_app_order_financials(uuid)'::regprocedure))>0,'CUSTOMER_APP recalculation is snapshot-bound');
select ok(position('jsonb_array_elements' in pg_get_functiondef('public.build_sales_order_commercial_snapshot_v1(uuid)'::regprocedure))>0,'CUSTOMER_APP commercial snapshot builder reads frozen checkout snapshot');
select * from finish();
rollback;

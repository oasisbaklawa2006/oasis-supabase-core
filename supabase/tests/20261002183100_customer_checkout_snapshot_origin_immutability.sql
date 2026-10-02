-- Contract for 20261002183100_customer_checkout_snapshot_origin_immutability.sql
begin;
select plan(4);

select ok(
  pg_get_triggerdef(oid) like '%UPDATE OF checkout_snapshot, order_origin%'
  from pg_trigger
  where tgrelid='public.orders'::regclass
    and tgname='trg_customer_checkout_snapshot_immutable'
    and not tgisinternal,
  'immutability trigger watches both checkout_snapshot and order_origin'
);

select ok(
  pg_get_functiondef('public.prevent_customer_checkout_snapshot_mutation_v1()'::regprocedure)
    like '%old.order_origin = ''CUSTOMER_APP'' or new.order_origin = ''CUSTOMER_APP''%'
  and pg_get_functiondef('public.prevent_customer_checkout_snapshot_mutation_v1()'::regprocedure)
    like '%new.order_origin is distinct from old.order_origin%',
  'immutability guard freezes CUSTOMER_APP provenance in both directions'
);

select ok(
  exists(
    select 1 from pg_constraint
    where conrelid='public.customer_order_draft_lines'::regclass
      and conname='uq_customer_order_draft_lines_one_product_per_draft'
      and contype='u'
  ),
  'draft schema already prevents duplicate product lines before checkout'
);

select ok(
  pg_get_functiondef('public.customer_checkout_snapshot_total_v1(uuid)'::regprocedure)
    like '%CHECKOUT_SNAPSHOT_ORDER_ITEM_MISMATCH%',
  'post-checkout line drift continues to fail closed'
);

select * from finish();
rollback;

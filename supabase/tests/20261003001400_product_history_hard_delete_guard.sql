-- Contract for migration 20261003001400_product_history_hard_delete_guard.sql.
begin;
select plan(8);

select has_function(
  'public','guard_referenced_product_hard_delete_v1',array[]::text[],
  'product hard-delete guard exists'
);

select ok(
  exists(
    select 1 from pg_trigger
    where tgrelid='public.products'::regclass
      and tgname='trg_guard_referenced_product_hard_delete_v1'
      and not tgisinternal
  ),
  'products has hard-delete guard trigger'
);

set local session_replication_role = replica;

insert into public.companies(id,business_name,status)
values ('92400000-0000-0000-0000-000000000001','Product History Co','active');

insert into public.products(
  id,sku,product_name,name,category,hsn_code,is_active,visible_in_catalog
) values
  ('92400000-0000-0000-0000-000000000002','HIST-PROD-1','Historical Product','Historical Product','Bakery','19059090',false,false),
  ('92400000-0000-0000-0000-000000000003','UNUSED-PROD-1','Unused Product','Unused Product','Bakery','19059090',false,false),
  ('92400000-0000-0000-0000-000000000004','ACTIVE-PROD-1','Active Product','Active Product','Bakery','19059090',true,false);

insert into public.orders(
  id,company_id,status,order_origin,order_number,tracking_token
) values (
  '92400000-0000-0000-0000-000000000005',
  '92400000-0000-0000-0000-000000000001',
  'submitted','LEGACY_ERP','SO-PRODUCT-HISTORY-1',md5(random()::text)
);

insert into public.order_items(order_id,product_id,quantity,pack_size)
values (
  '92400000-0000-0000-0000-000000000005',
  '92400000-0000-0000-0000-000000000002',
  1,'kg'
);

set local session_replication_role = default;

select throws_ok(
  $$delete from public.products where id='92400000-0000-0000-0000-000000000002'$$,
  '23503',
  'PRODUCT_HARD_DELETE_FORBIDDEN: referenced product must be archived/deactivated to preserve historical identity',
  'referenced inactive product cannot be hard-deleted'
);

select is(
  (select count(*)::int from public.order_items
   where order_id='92400000-0000-0000-0000-000000000005'),
  1,
  'blocked product deletion preserves historical order line'
);

select throws_ok(
  $$delete from public.products where id='92400000-0000-0000-0000-000000000004'$$,
  '23503',
  'PRODUCT_HARD_DELETE_FORBIDDEN: deactivate/archive active product first',
  'active product must be deactivated before hard-delete'
);

select lives_ok(
  $$delete from public.products where id='92400000-0000-0000-0000-000000000003'$$,
  'unused inactive draft product remains deletable'
);

select is(
  (select count(*)::int from public.products
   where id='92400000-0000-0000-0000-000000000003'),
  0,
  'unused inactive product was deleted'
);

select ok(
  not has_function_privilege('authenticated',
    'public.guard_referenced_product_hard_delete_v1()','execute'),
  'guard helper is not directly executable by application users'
);

select * from finish();
rollback;

BEGIN;

SELECT plan(6);

SELECT ok(
  has_table_privilege('authenticated', 'public.b2b_order_availability', 'SELECT'),
  'authenticated can select the RGS availability view'
);

SELECT ok(
  has_table_privilege('authenticated', 'public.b2b_inventory_stores', 'SELECT'),
  'authenticated can reach the store relation required by the security-invoker view'
);

SELECT ok(
  has_table_privilege('authenticated', 'public.b2b_inventory_item_profiles', 'SELECT'),
  'authenticated can reach the item-profile relation required by the security-invoker view'
);

SELECT ok(
  NOT has_table_privilege('anon', 'public.b2b_order_availability', 'SELECT'),
  'anonymous callers cannot select the RGS availability view'
);

SELECT ok(
  NOT has_table_privilege('anon', 'public.b2b_inventory_stores', 'SELECT'),
  'anonymous callers cannot select B2B inventory stores'
);

SELECT ok(
  NOT has_table_privilege('anon', 'public.b2b_inventory_item_profiles', 'SELECT'),
  'anonymous callers cannot select B2B item profiles'
);

SELECT * FROM finish();
ROLLBACK;

-- Contract test for 20261113121200_buyer_shared_default_echo_safe_v1.sql.
-- Full behavioral regression is also in 20261113121000 ... authority_v1.sql (70 assertions).
BEGIN;
SELECT plan(3);
SELECT ok(pg_get_functiondef('public.customer_upsert_delivery_address_v1(uuid,text,text,text,text,text,text,text,boolean)'::regprocedure) ILIKE '%public.delivery_addresses.is_default IS TRUE%',
  'shared default is preserved when the viewer has a private default');
SELECT ok(pg_get_functiondef('public.customer_upsert_delivery_address_v1(uuid,text,text,text,text,text,text,text,boolean)'::regprocedure) ILIKE '%THEN TRUE%ELSE excluded.is_default%',
  'false effective-default echo does not silently demote shared default');
SELECT ok(NOT has_function_privilege('anon','public.customer_upsert_delivery_address_v1(uuid,text,text,text,text,text,text,text,boolean)','EXECUTE')
          AND has_function_privilege('authenticated','public.customer_upsert_delivery_address_v1(uuid,text,text,text,text,text,text,text,boolean)','EXECUTE'),
  'anon denied and authenticated Buyer RPC execute grant retained');
SELECT * FROM finish();
ROLLBACK;

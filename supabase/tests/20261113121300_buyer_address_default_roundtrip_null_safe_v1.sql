-- Contract test for 20261113121300_buyer_address_default_roundtrip_null_safe_v1.sql.
-- Behavioral round-trip, repeated-save and NULL regressions are exercised by
-- 20261113121000_buyer_delivery_address_and_saved_transporter_authority_v1.sql
-- inside its rollback-only 75-assertion fixture suite.
BEGIN;
SELECT plan(4);

SELECT has_function('public','customer_upsert_delivery_address_v1',
  ARRAY['uuid','text','text','text','text','text','text','text','boolean'],
  'buyer address write function preserved after forward-only correction');

SELECT ok(
  pg_get_functiondef('public.customer_upsert_delivery_address_v1(uuid,text,text,text,text,text,text,text,boolean)'::regprocedure)
    ILIKE '%AND coalesce(p_is_default,false) IS FALSE%',
  'NULL input is coalesced before shared-default preservation');

SELECT ok(
  pg_get_functiondef('public.customer_upsert_delivery_address_v1(uuid,text,text,text,text,text,text,text,boolean)'::regprocedure)
    ILIKE '%FROM public.customer_delivery_addresses_v1() AS projected%',
  'save response derives viewer-effective default from canonical read projection');

SELECT ok(
  NOT has_function_privilege('anon',
    'public.customer_upsert_delivery_address_v1(uuid,text,text,text,text,text,text,text,boolean)','EXECUTE')
  AND has_function_privilege('authenticated',
    'public.customer_upsert_delivery_address_v1(uuid,text,text,text,text,text,text,text,boolean)','EXECUTE'),
  'anonymous invocation denied and authenticated buyer grant retained');

SELECT * FROM finish();
ROLLBACK;

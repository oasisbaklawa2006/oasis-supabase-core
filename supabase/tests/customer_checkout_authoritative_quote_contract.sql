-- Contract for migration 20261013130000_customer_checkout_authoritative_quote.sql
BEGIN;
SELECT plan(10);
SELECT has_function('public','customer_checkout_quote_v1',ARRAY[]::text[],'authoritative quote RPC exists');
SELECT has_function('public','submit_customer_order_quoted_v1',ARRAY['text','text','date'],'quote-validated submit RPC exists');
SELECT function_lang_is('public','customer_checkout_quote_v1',ARRAY[]::text[],'plpgsql','quote uses plpgsql');
SELECT function_lang_is('public','submit_customer_order_quoted_v1',ARRAY['text','text','date'],'plpgsql','submit uses plpgsql');
SELECT function_privs_are('public','customer_checkout_quote_v1',ARRAY[]::text[],'anon',ARRAY[]::text[],'anon cannot execute quote');
SELECT function_privs_are('public','submit_customer_order_quoted_v1',ARRAY['text','text','date'],'anon',ARRAY[]::text[],'anon cannot execute quoted submit');
SELECT function_privs_are('public','customer_checkout_quote_v1',ARRAY[]::text[],'authenticated',ARRAY['EXECUTE'],'authenticated may quote');
SELECT function_privs_are('public','submit_customer_order_quoted_v1',ARRAY['text','text','date'],'authenticated',ARRAY['EXECUTE'],'authenticated may submit quoted order');
SELECT throws_ok($$SELECT public.customer_checkout_quote_v1()$$,'28000',NULL,'unauthenticated quote fails closed');
SELECT throws_ok($$SELECT * FROM public.submit_customer_order_quoted_v1('test','bad-fingerprint',NULL)$$,'28000',NULL,'unauthenticated quoted submit fails closed');
SELECT * FROM finish();
ROLLBACK;

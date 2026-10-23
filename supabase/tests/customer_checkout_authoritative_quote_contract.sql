-- Contract for migration 20261022150000_customer_checkout_authoritative_quote.sql
BEGIN;
SELECT plan(15);
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
SELECT is(
 (SELECT count(*)::integer FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
  WHERE n.nspname='public' AND p.prokind='f'
    AND p.prosrc ~* 'insert[[:space:]]+into[[:space:]]+(public[[:space:]]*\.)?[[:space:]]*orders([[:space:]]*\(|;)'),
 2,'exactly two canonical order writers remain');
SELECT ok(
 pg_get_functiondef('public.submit_customer_order_quoted_v1(text,text,date)'::regprocedure) LIKE '%QUOTE_CHANGED_REFRESH_REQUIRED%'
 AND pg_get_functiondef('public.submit_customer_order_quoted_v1(text,text,date)'::regprocedure) LIKE '%QUOTE_APPROVAL_REQUIRED%'
 AND pg_get_functiondef('public.submit_customer_order_quoted_v1(text,text,date)'::regprocedure) LIKE '%FOR UPDATE%',
 'quoted wrapper checks fingerprint and locks draft before canonical checkout');
SELECT ok(
 pg_get_functiondef('public.submit_customer_order_quoted_v1(text,text,date)'::regprocedure) LIKE '%pg_advisory_xact_lock(hashtextextended(''customer_checkout:''%'
 AND position('pg_advisory_xact_lock' in pg_get_functiondef('public.submit_customer_order_quoted_v1(text,text,date)'::regprocedure))
   < position('FOR UPDATE' in pg_get_functiondef('public.submit_customer_order_quoted_v1(text,text,date)'::regprocedure))
 AND pg_get_functiondef('public.submit_customer_order_quoted_v1(text,text,date)'::regprocedure) LIKE '%checkout_idempotency_key%',
 'quoted wrapper takes the canonical advisory lock before the draft lock and replays existing orders');

SELECT ok(
 pg_get_functiondef('public.submit_customer_order_quoted_v1(text,text,date)'::regprocedure) LIKE '%v_result.sales_order_value IS DISTINCT FROM%'
 AND pg_get_functiondef('public.submit_customer_order_quoted_v1(text,text,date)'::regprocedure) LIKE '%v_result.advance_required IS DISTINCT FROM%',
 'quoted wrapper rejects delegated totals that differ from the approved quote');

-- Static guard only: transactional matching/mismatched replay tests are still mandatory.
SELECT ok(
 pg_get_functiondef('public.submit_customer_order_quoted_v1(text,text,date)'::regprocedure) LIKE '%md5(v_quote::text) IS DISTINCT FROM p_quote_fingerprint%'
 AND pg_get_functiondef('public.submit_customer_order_quoted_v1(text,text,date)'::regprocedure) LIKE '%o.checkout_snapshot%'
 AND pg_get_functiondef('public.submit_customer_order_quoted_v1(text,text,date)'::regprocedure) LIKE '%d.promoted_order_id=o.id%',
 'idempotent replay verifies the original immutable quote fingerprint');

SELECT * FROM finish();
ROLLBACK;

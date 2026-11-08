-- Buyer #64 / Core #495: P0 financial-helper ACL regression.
-- Tests run against disposable, fully replayed local Supabase only.
-- Existing gateway integration tests separately cover authorised intent
-- creation, server-side amount derivation, and settlement/idempotency.
BEGIN;

SELECT plan(11);

SELECT has_function(
  'public', 'derive_payment_gateway_canonical_amount_v1',
  ARRAY['uuid', 'uuid', 'uuid', 'text'],
  'canonical amount derivation helper remains installed'
);

SELECT function_privs_are(
  'public', 'derive_payment_gateway_canonical_amount_v1',
  ARRAY['uuid', 'uuid', 'uuid', 'text']::text[],
  'anon', ARRAY[]::text[],
  'anonymous callers have no direct gateway amount helper privileges'
);

SELECT function_privs_are(
  'public', 'derive_payment_gateway_canonical_amount_v1',
  ARRAY['uuid', 'uuid', 'uuid', 'text']::text[],
  'authenticated', ARRAY[]::text[],
  'authenticated buyers cannot directly execute privileged amount derivation'
);

SELECT function_privs_are(
  'public', 'derive_payment_gateway_canonical_amount_v1',
  ARRAY['uuid', 'uuid', 'uuid', 'text']::text[],
  'service_role', ARRAY[]::text[],
  'service_role cannot bypass governed payable-intent creation directly'
);

SELECT ok(
  NOT EXISTS (
    SELECT 1
      FROM pg_proc p
      CROSS JOIN LATERAL aclexplode(
        coalesce(p.proacl, acldefault('f', p.proowner))
      ) a
     WHERE p.oid = 'public.derive_payment_gateway_canonical_amount_v1(uuid,uuid,uuid,text)'::regprocedure
       AND a.grantee = 0
       AND a.privilege_type = 'EXECUTE'
  ),
  'helper EXECUTE is not inherited from PUBLIC'
);

SELECT ok(
  has_function_privilege(
    'postgres',
    'public.derive_payment_gateway_canonical_amount_v1(uuid,uuid,uuid,text)',
    'EXECUTE'
  ),
  'function owner retains internal helper execution for governed wrappers'
);

SELECT ok(
  has_function_privilege(
    'authenticated',
    'public.create_payment_gateway_payable_intent_v1(uuid,uuid,uuid,text,text,text,text,uuid)',
    'EXECUTE'
  ),
  'authenticated buyer retains governed payable-intent entry point'
);

SELECT ok(
  NOT has_function_privilege(
    'service_role',
    'public.create_payment_gateway_payable_intent_v1(uuid,uuid,uuid,text,text,text,text,uuid)',
    'EXECUTE'
  ),
  'service role still cannot impersonate a buyer payable-intent creation'
);

SELECT ok(
  has_function_privilege(
    'authenticated', 'public.customer_checkout_quote_v1()', 'EXECUTE'
  )
  AND has_function_privilege(
    'authenticated', 'public.submit_customer_order_quoted_v1(text,text,date)', 'EXECUTE'
  ),
  'customer quote and fingerprint-bound quoted submission remain available'
);

SELECT ok(
  NOT has_function_privilege(
    'authenticated', 'public.submit_customer_order_v1(text,date)', 'EXECUTE'
  ),
  'direct legacy order submission remains blocked for authenticated buyers'
);

SET LOCAL ROLE authenticated;

SELECT throws_ok(
  $$ SELECT * FROM public.derive_payment_gateway_canonical_amount_v1(
       NULL::uuid, NULL::uuid, NULL::uuid, 'advance'::text
     ) $$,
  'permission denied for function derive_payment_gateway_canonical_amount_v1',
  'authenticated role is denied before any order or payment facts are read'
);

RESET ROLE;

SELECT * FROM finish();
ROLLBACK;

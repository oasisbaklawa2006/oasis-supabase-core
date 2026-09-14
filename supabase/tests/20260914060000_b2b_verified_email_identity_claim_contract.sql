begin;

select plan(6);

select has_function(
  'public', 'claim_approved_b2b_access_request_v2', array[]::text[],
  '20260914060000 preserves canonical B2B claim RPC signature'
);

select ok(
  has_function_privilege('authenticated', 'public.claim_approved_b2b_access_request_v2()', 'EXECUTE'),
  'authenticated retains claim execution privilege'
);

select ok(
  not has_function_privilege('anon', 'public.claim_approved_b2b_access_request_v2()', 'EXECUTE'),
  'anon remains excluded from claim execution'
);

select like(
  pg_get_functiondef('public.claim_approved_b2b_access_request_v2()'::regprocedure),
  '%email_confirmed_at%',
  'claim requires confirmed Auth email authority'
);

select like(
  pg_get_functiondef('public.claim_approved_b2b_access_request_v2()'::regprocedure),
  '%contact_email%',
  'claim can match approved B2B contact email'
);

select like(
  pg_get_functiondef('public.claim_approved_b2b_access_request_v2()'::regprocedure),
  '%normalize_b2b_access_mobile_v2%',
  'existing provider-confirmed mobile matching remains intact'
);

select * from finish();
rollback;

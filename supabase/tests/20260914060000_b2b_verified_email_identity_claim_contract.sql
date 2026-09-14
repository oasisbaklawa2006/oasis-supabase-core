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

select ok(
  position('email_confirmed_at' in pg_get_functiondef('public.claim_approved_b2b_access_request_v2()'::regprocedure)) > 0,
  'claim requires confirmed Auth email authority'
);

select ok(
  position('contact_email' in pg_get_functiondef('public.claim_approved_b2b_access_request_v2()'::regprocedure)) > 0,
  'claim can match approved B2B contact email'
);

select ok(
  position('normalize_b2b_access_mobile_v2' in pg_get_functiondef('public.claim_approved_b2b_access_request_v2()'::regprocedure)) > 0,
  'existing provider-confirmed mobile matching remains intact'
);

select * from finish();
rollback;

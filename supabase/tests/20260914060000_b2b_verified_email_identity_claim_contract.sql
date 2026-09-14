begin;

select plan(11);

select has_function(
  'public', 'claim_approved_b2b_access_request_v2', array[]::text[],
  '20260914060000 preserves canonical B2B claim RPC signature'
);

select has_function(
  'public', 'approve_b2b_access_request_v2', array['uuid','text','text'],
  '20260914060000 preserves governed B2B approval RPC signature'
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
  position('v_auth_email := NULL' in upper(pg_get_functiondef('public.claim_approved_b2b_access_request_v2()'::regprocedure))) > 0
  and position('v_auth_phone := NULL' in upper(pg_get_functiondef('public.claim_approved_b2b_access_request_v2()'::regprocedure))) > 0,
  'unconfirmed Auth identifiers are cleared before Buyer activation'
);

select ok(
  position('contact_email' in pg_get_functiondef('public.claim_approved_b2b_access_request_v2()'::regprocedure)) > 0,
  'claim can match approved B2B contact email'
);

select ok(
  position('normalize_b2b_access_mobile_v2' in pg_get_functiondef('public.claim_approved_b2b_access_request_v2()'::regprocedure)) > 0,
  'existing provider-confirmed mobile matching remains intact'
);

select ok(
  position('b2b_identity_email:' in pg_get_functiondef('public.claim_approved_b2b_access_request_v2()'::regprocedure)) > 0
  and position('b2b_identity_mobile:' in pg_get_functiondef('public.claim_approved_b2b_access_request_v2()'::regprocedure)) > 0,
  'claim serializes canonical email and mobile identity before candidate resolution'
);

select ok(
  position('b2b_identity_email:' in pg_get_functiondef('public.approve_b2b_access_request_v2(uuid,text,text)'::regprocedure)) > 0
  and position('b2b_identity_mobile:' in pg_get_functiondef('public.approve_b2b_access_request_v2(uuid,text,text)'::regprocedure)) > 0,
  'approval uses the same canonical identity advisory locks as claim'
);

select ok(
  position('APPLICATION_IDENTITY_CHANGED' in pg_get_functiondef('public.approve_b2b_access_request_v2(uuid,text,text)'::regprocedure)) > 0
  and position('APPLICATION_IDENTITY_CHANGED' in pg_get_functiondef('public.claim_approved_b2b_access_request_v2()'::regprocedure)) > 0,
  'approval and claim fail closed if identity changes across lock acquisition'
);

select * from finish();
rollback;

-- Contract test for migration 20260910040000_b2b_prelogin_access_lifecycle.sql
begin;

select plan(4);

select has_function(
  'public',
  'submit_b2b_access_request_v2',
  array['text','text','text','text','text','text','text','text','boolean','boolean'],
  '20260910040000_b2b_prelogin_access_lifecycle.sql exposes governed pre-login intake'
);

select has_function(
  'public',
  'approve_b2b_access_request_v2',
  array['uuid','text','text'],
  '20260910040000_b2b_prelogin_access_lifecycle.sql exposes governed staff approval'
);

select has_function(
  'public',
  'claim_approved_b2b_access_request_v2',
  array[]::text[],
  '20260910040000_b2b_prelogin_access_lifecycle.sql exposes verified identity claim'
);

select ok(
  has_function_privilege(
    'anon',
    'public.submit_b2b_access_request_v2(text,text,text,text,text,text,text,text,boolean,boolean)',
    'EXECUTE'
  )
  and not has_table_privilege('anon', 'public.b2b_applications', 'INSERT'),
  '20260910040000_b2b_prelogin_access_lifecycle.sql keeps anonymous intake behind the governed RPC'
);

select * from finish();
rollback;

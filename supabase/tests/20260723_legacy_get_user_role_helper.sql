-- Contract for migration 20260723160500_legacy_get_user_role_helper.sql
begin;

select plan(8);

select has_function(
  'public',
  'get_user_role',
  array['uuid'],
  'legacy get_user_role(uuid) compatibility helper exists'
);

select function_lang_is(
  'public',
  'get_user_role',
  array['uuid'],
  'sql',
  'get_user_role is implemented in SQL'
);

select ok(
  exists (
    select 1
    from pg_proc p
    where p.oid = 'public.get_user_role(uuid)'::regprocedure
      and p.prosecdef
      and p.proconfig @> array['search_path=public']
  ),
  'get_user_role(uuid) is security definer with fixed public search_path'
);

select ok(
  has_function_privilege('authenticated', 'public.get_user_role(uuid)', 'EXECUTE'),
  'authenticated can execute get_user_role(uuid)'
);

select ok(
  has_function_privilege('service_role', 'public.get_user_role(uuid)', 'EXECUTE'),
  'service_role can execute get_user_role(uuid)'
);

select ok(
  not has_function_privilege('anon', 'public.get_user_role(uuid)', 'EXECUTE'),
  'anon cannot execute get_user_role(uuid)'
);

select ok(
  not has_function_privilege('public', 'public.get_user_role(uuid)', 'EXECUTE'),
  'public cannot execute get_user_role(uuid)'
);

select is(
  pg_get_function_identity_arguments('public.get_user_role(uuid)'::regprocedure),
  '_user_id uuid',
  'security assertions are bound to the uuid overload'
);

select * from finish();
rollback;

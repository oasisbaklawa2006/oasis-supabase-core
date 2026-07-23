-- Contract coverage for 20260723160000_legacy_internal_staff_helper.sql
begin;

select plan(8);

select has_function(
  'public',
  'is_internal_staff',
  array['uuid'],
  'is_internal_staff(uuid) compatibility helper exists'
);

select function_returns(
  'public',
  'is_internal_staff',
  array['uuid'],
  'boolean',
  'is_internal_staff(uuid) returns boolean'
);

select ok(
  exists (
    select 1
    from pg_proc p
    where p.oid = 'public.is_internal_staff(uuid)'::regprocedure
      and p.prosecdef
      and p.proconfig @> array['search_path=public, pg_temp']
  ),
  'is_internal_staff(uuid) is security definer with fixed public and pg_temp search_path'
);

select ok(
  has_function_privilege('authenticated', 'public.is_internal_staff(uuid)', 'EXECUTE'),
  'authenticated can execute is_internal_staff(uuid)'
);

select ok(
  has_function_privilege('service_role', 'public.is_internal_staff(uuid)', 'EXECUTE'),
  'service_role can execute is_internal_staff(uuid)'
);

select ok(
  not has_function_privilege('anon', 'public.is_internal_staff(uuid)', 'EXECUTE'),
  'anon cannot execute is_internal_staff(uuid)'
);

select ok(
  not has_function_privilege('public', 'public.is_internal_staff(uuid)', 'EXECUTE'),
  'public cannot execute is_internal_staff(uuid)'
);

select is(
  pg_get_function_identity_arguments('public.is_internal_staff(uuid)'::regprocedure),
  '_user_id uuid',
  'security assertions are bound to the uuid overload'
);

select * from finish();
rollback;

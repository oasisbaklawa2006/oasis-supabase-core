begin;

select plan(3);

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
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
      and p.proname = 'get_user_role'
      and p.prosecdef
      and p.proconfig @> array['search_path=public']
  ),
  'get_user_role is security definer with fixed public search_path'
);

select * from finish();
rollback;

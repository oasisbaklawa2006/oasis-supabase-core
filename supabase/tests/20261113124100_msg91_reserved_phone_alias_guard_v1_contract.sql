begin;

-- Contract for 20261113124100_msg91_reserved_phone_alias_guard_v1.sql.
select plan(5);

select ok(exists (
  select 1
  from pg_trigger
  where tgrelid = 'auth.users'::regclass
    and tgname = 'msg91_reserved_phone_alias_guard_v1'
    and tgenabled = 'O'
    and tgdeferrable
    and tginitdeferred
), 'Auth alias guard is enabled and checks the completed transaction');

select ok(not (
  has_function_privilege('anon', 'public.msg91_guard_reserved_phone_alias_v1()', 'execute')
  or has_function_privilege('authenticated', 'public.msg91_guard_reserved_phone_alias_v1()', 'execute')
  or has_function_privilege('service_role', 'public.msg91_guard_reserved_phone_alias_v1()', 'execute')
), 'application roles cannot invoke the trigger function');

set constraints auth.msg91_reserved_phone_alias_guard_v1 immediate;

select throws_ok(
  $$insert into auth.users (id, email) values (gen_random_uuid(), '916000000107@phone.oasis.local')$$,
  '23514', 'Reserved phone alias requires verified provisioning',
  'unverified reserved email is rejected on the actual Auth table'
);

select lives_ok(
  $$insert into auth.users (id, email) values (gen_random_uuid(), 'msg91-alias-contract@example.test')$$,
  'ordinary email is allowed'
);

select throws_ok(
  $$update auth.users set email = '916000000108@phone.oasis.local'
    where email = 'msg91-alias-contract@example.test'$$,
  '23514', 'Reserved phone alias requires verified provisioning',
  'email changes cannot claim a reserved alias'
);

select * from finish();
rollback;

begin;

-- Verifies both least-privilege grants and trigger defence in depth.
-- No real identity, phone field or Auth row is modified.
select plan(12);

select ok(
  not has_column_privilege('authenticated', 'public.users', 'phone', 'UPDATE'),
  'authenticated clients cannot update primary phone');
select ok(
  not has_column_privilege('authenticated', 'public.users', 'mobile_number', 'UPDATE'),
  'authenticated clients cannot update mobile number');
select ok(
  not has_column_privilege('authenticated', 'public.users', 'secondary_phones', 'UPDATE'),
  'authenticated clients cannot update secondary phone numbers');

select ok(
  not has_column_privilege('anon', 'public.users', 'phone', 'UPDATE'),
  'anonymous clients cannot update primary phone');
select ok(
  not has_column_privilege('anon', 'public.users', 'mobile_number', 'UPDATE'),
  'anonymous clients cannot update mobile number');
select ok(
  not has_column_privilege('anon', 'public.users', 'secondary_phones', 'UPDATE'),
  'anonymous clients cannot update secondary phone numbers');

select ok(
  has_column_privilege('authenticated', 'public.users', 'name', 'UPDATE'),
  'existing authenticated non-identity profile edit permission is retained');
select ok(
  has_column_privilege('authenticated', 'public.users', 'full_name', 'UPDATE'),
  'existing authenticated full-name edit permission is retained');
select ok(
  has_column_privilege('service_role', 'public.users', 'phone', 'UPDATE'),
  'trusted service role retains verified identity maintenance capability');

select ok(exists (
  select 1 from pg_trigger
  where tgrelid = 'public.users'::regclass
    and tgname = 'trg_msg91_protect_profile_phone_v1'
    and tgenabled in ('O','A')
), 'client phone update defence-in-depth trigger exists and is enabled');

select ok(exists (
  select 1 from pg_proc
  where oid = 'public.msg91_deny_untrusted_profile_phone_write_v1()'::regprocedure
    and not prosecdef
), 'phone guard uses SECURITY INVOKER to distinguish direct client from governed write');

select ok(
  not has_function_privilege('authenticated',
    'public.msg91_deny_untrusted_profile_phone_write_v1()', 'execute'),
  'trigger function cannot be called directly by authenticated users');

select * from finish();
rollback;

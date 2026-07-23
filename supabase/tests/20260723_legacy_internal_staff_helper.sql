-- Contract coverage for 20260723160000_legacy_internal_staff_helper.sql
begin;

select plan(3);

select has_function('public', 'is_internal_staff', array['uuid'],
  'is_internal_staff(uuid) compatibility helper exists');

select function_returns('public', 'is_internal_staff', array['uuid'], 'boolean',
  'is_internal_staff(uuid) returns boolean');

select function_privs_are(
  'public',
  'is_internal_staff',
  array['uuid'],
  'authenticated',
  array['EXECUTE'],
  'authenticated can execute is_internal_staff(uuid)'
);

select * from finish();
rollback;

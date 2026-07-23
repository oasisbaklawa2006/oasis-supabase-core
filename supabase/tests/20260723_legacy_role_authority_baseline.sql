-- Contract test for 20260723142900_legacy_role_authority_baseline
begin;

select plan(8);

select has_table('public', 'roles', 'roles table exists');
select has_table('public', 'user_role_map', 'user_role_map table exists');
select has_column('public', 'roles', 'role_key', 'roles.role_key exists');
select has_column('public', 'roles', 'is_active', 'roles.is_active exists');
select has_column('public', 'user_role_map', 'user_id', 'user_role_map.user_id exists');
select has_column('public', 'user_role_map', 'role_id', 'user_role_map.role_id exists');
select col_is_pk('public', 'roles', 'id', 'roles.id is primary key');
select col_is_pk('public', 'user_role_map', 'id', 'user_role_map.id is primary key');

select * from finish();
rollback;

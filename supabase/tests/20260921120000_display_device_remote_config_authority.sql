begin;
-- Contract coverage for migration
-- 20260921120000_display_device_remote_config_authority.sql.

select plan(12);

select has_table('public','display_device_registry_v1','display device registry exists');
select ok((select relrowsecurity from pg_class where oid='public.display_device_registry_v1'::regclass),'display registry has RLS');
select is(has_table_privilege('authenticated','public.display_device_registry_v1','SELECT'),false,'browser cannot read display registry directly');

select has_function('public','admin_assign_display_device_v1',array['text','text','text','text','text'],'assign RPC exists');
select has_function('public','admin_list_display_devices_v1',array[]::text[],'list RPC exists');
select has_function('public','admin_revoke_display_device_v1',array['text'],'revoke RPC exists');

select is(has_function_privilege('anon','public.admin_assign_display_device_v1(text,text,text,text,text)','EXECUTE'),false,'anon cannot assign');
select is(has_function_privilege('authenticated','public.admin_assign_display_device_v1(text,text,text,text,text)','EXECUTE'),true,'authenticated can invoke subject to admin check');
select is(has_function_privilege('anon','public.admin_list_display_devices_v1()','EXECUTE'),false,'anon cannot list');
select is(has_function_privilege('anon','public.admin_revoke_display_device_v1(text)','EXECUTE'),false,'anon cannot revoke');

set local request.jwt.claim.role='authenticated';
set local request.jwt.claim.sub='';
select throws_like(
  $$select public.admin_list_display_devices_v1()$$,
  '%DISPLAY_ADMIN_REQUIRED%',
  'list fails closed without admin actor'
);
select throws_like(
  $$select public.admin_revoke_display_device_v1('tv-00000000-0000-0000-0000-000000000000')$$,
  '%DISPLAY_ADMIN_REQUIRED%',
  'revoke fails closed without admin actor'
);

select * from finish();
rollback;

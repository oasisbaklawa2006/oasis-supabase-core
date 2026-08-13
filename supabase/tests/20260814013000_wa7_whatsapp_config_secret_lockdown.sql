begin;
select plan(5);
select is_empty($$select 1 from information_schema.role_table_grants where table_schema='public' and table_name='whatsapp_config' and grantee in('PUBLIC','anon','authenticated')$$,'browser roles have no whatsapp_config grants');
select is_empty($$select 1 from pg_policies where schemaname='public' and tablename='whatsapp_config' and roles && array['authenticated']::name[]$$,'no authenticated policy exposes provider secrets');
select ok((select relrowsecurity from pg_class where oid='public.whatsapp_config'::regclass),'RLS remains enabled');
select isnt_empty($$select 1 from information_schema.role_table_grants where table_schema='public' and table_name='whatsapp_config' and grantee='service_role' and privilege_type='SELECT'$$,'trusted service role retains compatibility read');
select has_table('public','whatsapp_config','legacy configuration storage remains available to trusted server code');
select * from finish();
rollback;

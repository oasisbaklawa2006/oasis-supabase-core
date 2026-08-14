-- Contract for migration: 20260814121000_reconcile_pricing_moq_write_boundary.sql
begin;

select plan(10);

select table_privs_are('public','product_pricing_rules','anon',array['SELECT'],'anon can only select product_pricing_rules');
select table_privs_are('public','product_pricing_rules','authenticated',array['SELECT'],'authenticated can only select product_pricing_rules');
select table_privs_are('public','product_pricing_rules','service_role',array['SELECT','INSERT','UPDATE','DELETE','TRUNCATE','REFERENCES','TRIGGER'],'service_role retains full product_pricing_rules access');
select table_privs_are('public','product_moq_rules','anon',array['SELECT'],'anon can only select product_moq_rules');
select table_privs_are('public','product_moq_rules','authenticated',array['SELECT'],'authenticated can only select product_moq_rules');
select table_privs_are('public','product_moq_rules','service_role',array['SELECT','INSERT','UPDATE','DELETE','TRUNCATE','REFERENCES','TRIGGER'],'service_role retains full product_moq_rules access');
select has_function('public','approve_catalogue_pricing_draft',array['uuid'],'pricing approval authority remains');
select has_function('public','approve_catalogue_moq_draft',array['uuid'],'MOQ approval authority remains');
select ok((select prosecdef from pg_proc where oid='public.approve_catalogue_pricing_draft(uuid)'::regprocedure),'pricing approval remains security definer');
select ok((select prosecdef from pg_proc where oid='public.approve_catalogue_moq_draft(uuid)'::regprocedure),'MOQ approval remains security definer');

select * from finish();
rollback;

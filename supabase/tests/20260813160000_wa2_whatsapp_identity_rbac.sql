-- Contract for migration 20260813160000_wa2_whatsapp_identity_rbac.sql.
begin;
select plan(21);

select is((select count(*) from public.access_permissions where permission_key like 'wa.%' and is_active),7::bigint,'WA capabilities including governed outbound reply are authoritative');
select is((select count(*) from public.access_permissions where permission_key in('wa.intake.close','wa.draft.promote') and risk_level='high_risk' and requires_step_up),2::bigint,'terminal capabilities require AAL2 step-up');
select is((select count(*) from public.role_permission_grants where role_key='support_executive' and permission_key in('wa.intake.close','wa.draft.promote') and effect='allow'),0::bigint,'support cannot close or promote');
select is((select count(*) from public.role_permission_grants where role_key='support_executive' and permission_key in('wa.intake.read','wa.intake.triage','wa.intake.assign','wa.draft.manage') and effect='allow'),4::bigint,'support has non-terminal operational capabilities');
select has_function('public','has_whatsapp_permission',array['text']);
select has_function('public','get_my_whatsapp_permissions',array[]::text[]);
select ok(not has_function_privilege('anon','public.has_whatsapp_permission(text)','execute'),'anon cannot evaluate WA authority');
select ok(has_function_privilege('authenticated','public.has_whatsapp_permission(text)','execute'),'authenticated callers can evaluate their own authority');
select isnt_empty($$select 1 from pg_policies where schemaname='public' and tablename='whatsapp_potential_orders' and policyname='whatsapp_potential_orders_reader' and qual like '%has_whatsapp_permission%wa.intake.read%'$$,'intake read policy uses Core capability');
select isnt_empty($$select 1 from pg_policies where schemaname='public' and tablename='sales_order_drafts' and policyname='sales_order_drafts_inbox_reader_update' and qual like '%wa.draft.manage%' and with_check like '%wa.draft.manage%'$$,'draft update RLS requires manage capability');
select ok(exists(select 1 from pg_trigger where tgrelid='public.sales_order_drafts'::regclass and tgname='wa2_sales_order_drafts_write_guard' and not tgisinternal),'draft security-definer writes retain permission guard');
select ok(exists(select 1 from pg_trigger where tgrelid='public.sales_order_draft_audit_log'::regclass and tgname='wa2_sales_order_draft_audit_immutable' and not tgisinternal),'draft audit is append-only');
select isnt_empty($$select 1 from pg_proc where oid='public.transition_whatsapp_potential_order(uuid,text,uuid,text,text,timestamptz,uuid,uuid,text,timestamptz,jsonb)'::regprocedure and pg_get_functiondef(oid) like '%wa.intake.triage%' and pg_get_functiondef(oid) like '%wa.intake.assign%' and pg_get_functiondef(oid) like '%wa.intake.close%' and pg_get_functiondef(oid) like '%wa.draft.promote%'$$,'lifecycle transition enforces action-specific capabilities');
select isnt_empty($$select 1 from pg_proc where oid='public.transition_whatsapp_potential_order(uuid,text,uuid,text,text,timestamptz,uuid,uuid,text,timestamptz,jsonb)'::regprocedure and pg_get_functiondef(oid) like '%p_queue%' and pg_get_functiondef(oid) like '%WA2_ASSIGN_REQUIRED%'$$,'queue reassignment requires assign capability');
select isnt_empty($$select 1 from pg_proc where oid='public.has_whatsapp_permission(text)'::regprocedure and pg_get_functiondef(oid) like '%is_active%' and pg_get_functiondef(oid) like '%deleted_at%'$$,'inactive and deleted identities fail closed');

insert into public.roles(id,role_key,role_name,is_active) values
 ('82000000-0000-0000-0000-000000000001','wa2_test_support','WA2 test support',true),
 ('82000000-0000-0000-0000-000000000002','wa2_test_admin','WA2 test admin',true)
on conflict(role_key) do update set is_active=true;
insert into public.role_permission_grants(role_key,permission_key,effect) values
 ('wa2_test_support','wa.intake.read','allow'),('wa2_test_support','wa.draft.manage','allow'),
 ('wa2_test_admin','wa.intake.read','allow'),('wa2_test_admin','wa.intake.close','allow')
on conflict(role_key,permission_key) do update set effect=excluded.effect;
insert into public.users(id,email,role,is_active) values
 ('82000000-0000-0000-0000-000000000011','wa2-support@test.invalid','WA2_TEST_SUPPORT',true),
 ('82000000-0000-0000-0000-000000000012','wa2-admin@test.invalid','WA2_TEST_ADMIN',true)
on conflict(id) do update set is_active=true,deleted_at=null;
insert into public.user_role_map(user_id,role_id)
select '82000000-0000-0000-0000-000000000011',id from public.roles where role_key='wa2_test_support'
on conflict(user_id,role_id) do nothing;
insert into public.user_role_map(user_id,role_id)
select '82000000-0000-0000-0000-000000000012',id from public.roles where role_key='wa2_test_admin'
on conflict(user_id,role_id) do nothing;

select set_config('request.jwt.claims',json_build_object('sub','82000000-0000-0000-0000-000000000011','role','authenticated','aal','aal1')::text,true);
set local role authenticated;
select ok(public.has_whatsapp_permission('wa.intake.read'),'active support identity can read');
select ok(public.has_whatsapp_permission('wa.draft.manage'),'active support identity can manage drafts');
select ok(not public.has_whatsapp_permission('wa.intake.close'),'support identity cannot close');
reset role;

select set_config('request.jwt.claims',json_build_object('role','service_role')::text,true);
update public.users set is_active=false where id='82000000-0000-0000-0000-000000000011';
select set_config('request.jwt.claims',json_build_object('sub','82000000-0000-0000-0000-000000000011','role','authenticated','aal','aal1')::text,true);
set local role authenticated;
select ok(not public.has_whatsapp_permission('wa.intake.read'),'deactivated identity immediately loses authority');
reset role;

select set_config('request.jwt.claims',json_build_object('sub','82000000-0000-0000-0000-000000000012','role','authenticated','aal','aal1')::text,true);
set local role authenticated;
select ok(not public.has_whatsapp_permission('wa.intake.close'),'high-risk close fails without AAL2');
select set_config('request.jwt.claims',json_build_object('sub','82000000-0000-0000-0000-000000000012','role','authenticated','aal','aal2')::text,true);
select ok(public.has_whatsapp_permission('wa.intake.close'),'high-risk close succeeds with AAL2');
reset role;

select * from finish();
rollback;

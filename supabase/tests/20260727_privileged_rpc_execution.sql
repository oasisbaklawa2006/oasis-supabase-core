-- Contract test for 20260727173000_harden_privileged_rpc_execution.sql
begin;
select plan(8);

create temporary table protected_rpc(signature text primary key, service_only boolean not null);
insert into protected_rpc(signature, service_only) values
  ('public.approve_catalogue_alias_draft(uuid)', false),
  ('public.approve_catalogue_bom_draft(uuid)', false),
  ('public.approve_catalogue_draft_internal(text,uuid)', false),
  ('public.approve_catalogue_media_submission(uuid)', false),
  ('public.approve_catalogue_moq_draft(uuid)', false),
  ('public.approve_catalogue_pricing_draft(uuid)', false),
  ('public.approve_catalogue_product_draft(uuid)', false),
  ('public.approve_catalogue_tag_draft(uuid)', false),
  ('public.approve_sales_order_draft_for_so_atomic(uuid,text,uuid,text,text,jsonb)', false),
  ('public.create_sales_order_draft_atomic(jsonb,jsonb,uuid,text,jsonb)', false),
  ('public.create_whatsapp_sales_order_draft_from_operator(uuid,text,text,uuid,text,text,numeric)', false),
  ('public.generate_oasis_sku(text,text,text,text)', false),
  ('public.get_current_user_roles()', false),
  ('public.get_my_role_keys()', false),
  ('public.log_cart_failure(uuid,text,text,jsonb)', false),
  ('public.record_whatsapp_operator_decision(uuid,text,text,text,text)', false),
  ('public.reject_catalogue_alias_draft(uuid,text)', false),
  ('public.reject_catalogue_bom_draft(uuid,text)', false),
  ('public.reject_catalogue_draft_internal(text,uuid,text)', false),
  ('public.reject_catalogue_media_submission(uuid,text)', false),
  ('public.reject_catalogue_moq_draft(uuid,text)', false),
  ('public.reject_catalogue_pricing_draft(uuid,text)', false),
  ('public.reject_catalogue_product_draft(uuid,text)', false),
  ('public.reject_catalogue_tag_draft(uuid,text)', false),
  ('public.reject_sales_order_draft_atomic(uuid,uuid,text,text,text,jsonb)', false),
  ('public.run_customer_import_validation(uuid)', false),
  ('public.storage_object_path_matches_buyer_owned_order(text)', false),
  ('public.submit_sales_order_draft_for_review_atomic(uuid,text,jsonb,integer,jsonb,jsonb,uuid,text,jsonb)', false),
  ('public.transition_sales_order_draft_status(uuid,text,text,text,uuid,text,text,text,uuid,text,jsonb)', false),
  ('public.update_sales_order_draft_operator_final(uuid,text,jsonb,integer,jsonb,jsonb,uuid,text,jsonb)', false),
  ('public.ingest_whatsapp_inbound_message(text,text,text,text,text,timestamptz,jsonb,text,jsonb)', true),
  ('public.restore_order_financials(uuid)', true),
  ('public.run_month_end_credit_lock()', true);

create function public.pgtap_default_acl_probe()
returns integer
language sql
as 'select 1';

select is((select count(*)::integer from protected_rpc), 33, 'all protected RPC contracts are enumerated');
select is((select count(*)::integer from protected_rpc r where to_regprocedure(r.signature) is not null), 33, 'every protected RPC exists');
select is((select count(*)::integer from protected_rpc r where not has_function_privilege('anon', to_regprocedure(r.signature), 'EXECUTE')), 33, 'anon cannot execute any protected RPC');
select is((select count(*)::integer from protected_rpc r where r.service_only and not has_function_privilege('authenticated', to_regprocedure(r.signature), 'EXECUTE')), 3, 'authenticated cannot execute service-only RPCs');
select is((select count(*)::integer from protected_rpc r where not r.service_only and has_function_privilege('authenticated', to_regprocedure(r.signature), 'EXECUTE')), 30, 'authenticated retains every guarded RPC');
select is((select count(*)::integer from protected_rpc r where has_function_privilege('service_role', to_regprocedure(r.signature), 'EXECUTE')), 33, 'service_role retains every protected RPC contract');
select ok(not has_function_privilege('anon', 'public.pgtap_default_acl_probe()', 'EXECUTE'), 'new postgres functions do not default to anon execution');
select ok(not has_function_privilege('authenticated', 'public.pgtap_default_acl_probe()', 'EXECUTE'), 'new postgres functions do not default to authenticated execution');

select * from finish();
rollback;

-- Contract for migration 20260830143400_finance_dpl_receipt_authority.sql.

select plan(18);

select has_table('public','finance_dpl_receipts','Finance DPL receipt ledger exists');
select has_table('public','finance_dpl_receipt_idempotency','DPL receipt idempotency ledger exists');
select has_function('public','receive_finance_dpl_v1',array['uuid','uuid','text','integer','jsonb','text','timestamp with time zone','text','text','text','text','text','uuid'],'DPL receipt RPC exists');
select ok((select relrowsecurity from pg_class where oid='public.finance_dpl_receipts'::regclass),'DPL receipts have RLS');
select ok(not has_table_privilege('authenticated','public.finance_dpl_receipts','INSERT'),'Central cannot directly insert Finance DPL receipts');
select ok(not has_table_privilege('authenticated','public.finance_dpl_receipts','UPDATE'),'DPL evidence cannot be directly updated');
select ok(not has_table_privilege('authenticated','public.finance_dpl_receipts','DELETE'),'DPL evidence cannot be directly deleted');
select ok(not has_function_privilege('service_role','public.receive_finance_dpl_v1(uuid,uuid,text,integer,jsonb,text,timestamp with time zone,text,text,text,text,text,uuid)','EXECUTE'),'service role cannot impersonate DPL handoff actor');
select ok(pg_get_functiondef('public.receive_finance_dpl_v1(uuid,uuid,text,integer,jsonb,text,timestamp with time zone,text,text,text,text,text,uuid)'::regprocedure) like '%assert_order_transition_role(''mark_packed_ready'')%','DPL handoff requires packing/dispatch authority');
select ok(pg_get_functiondef('public.receive_finance_dpl_v1(uuid,uuid,text,integer,jsonb,text,timestamp with time zone,text,text,text,text,text,uuid)'::regprocedure) like '%assert_active_operations_clearance_v1%','DPL receipt requires the order to have entered operations through Finance clearance');
select ok(pg_get_functiondef('public.receive_finance_dpl_v1(uuid,uuid,text,integer,jsonb,text,timestamp with time zone,text,text,text,text,text,uuid)'::regprocedure) like '%FINANCE_DPL_FINGERPRINT_MISMATCH%','DPL packet fingerprint is verified');
select ok(pg_get_functiondef('public.receive_finance_dpl_v1(uuid,uuid,text,integer,jsonb,text,timestamp with time zone,text,text,text,text,text,uuid)'::regprocedure) like '%FINANCE_DPL_LINE_TRUTH_INVALID%','DPL line quantities and identities are validated');
select ok(pg_get_functiondef('public.receive_finance_dpl_v1(uuid,uuid,text,integer,jsonb,text,timestamp with time zone,text,text,text,text,text,uuid)'::regprocedure) like '%x.actual_dispatch_qty > oi.quantity%','unapproved over-dispatch fails closed');
select ok(pg_get_functiondef('public.receive_finance_dpl_v1(uuid,uuid,text,integer,jsonb,text,timestamp with time zone,text,text,text,text,text,uuid)'::regprocedure) like '%FINANCE_DPL_CARTON_IDENTITY_INVALID%','carton identity must be non-empty and unique');
select ok(pg_get_functiondef('public.receive_finance_dpl_v1(uuid,uuid,text,integer,jsonb,text,timestamp with time zone,text,text,text,text,text,uuid)'::regprocedure) like '%FINANCE_DPL_IDEMPOTENCY_CONFLICT%','DPL retries are actor/request bound');
select ok(pg_get_functiondef('public.receive_finance_dpl_v1(uuid,uuid,text,integer,jsonb,text,timestamp with time zone,text,text,text,text,text,uuid)'::regprocedure) not like '%INSERT INTO public.dispatch_cartons%','Finance never creates physical cartons');
select ok(pg_get_functiondef('public.receive_finance_dpl_v1(uuid,uuid,text,integer,jsonb,text,timestamp with time zone,text,text,text,text,text,uuid)'::regprocedure) not like '%UPDATE public.order_items%','Finance never rewrites packing/order line truth');
select ok(pg_get_functiondef('public.prevent_finance_dpl_receipt_mutation()'::regprocedure) like '%FINANCE_DPL_RECEIPT_IMMUTABLE%','received DPL packet is immutable');

select * from finish();

-- Contract for migration 20260902083000_final_payment_pi_revision_authority.sql.

begin;
select plan(35);

select has_table('public','sales_order_pi_final_payment_requests','Final-payment PI revision ledger exists');
select has_table('public','sales_order_pi_final_payment_request_idempotency','Final-payment PI idempotency ledger exists');
select has_table('public','sales_order_pi_final_payment_request_audit','Final-payment PI audit ledger exists');
select has_table('public','sales_order_pi_final_payment_request_deliveries','Final-payment PI delivery ledger exists');

select has_function('public','calculate_finance_dpl_commercial_totals_v1',array['uuid','uuid','uuid','uuid'],'DPL/commercial totals calculator exists');
select has_function('public','get_sales_order_final_payment_coverage_v1',array['uuid','uuid','uuid','numeric'],'Final-payment coverage facts RPC exists');
select has_function('public','issue_sales_order_pi_final_payment_request_v1',array['uuid','uuid','uuid','uuid','text','text','text','text','text','text','text','text','text','uuid'],'Final-payment PI revision issuer exists');
select has_function('public','get_sales_order_pi_final_payment_request_v1',array['uuid'],'Final-payment PI projection exists');
select has_function('public','record_sales_order_pi_final_payment_delivery_v1',array['uuid','text','text','text','text','text','timestamptz','text','text','uuid'],'Final-payment PI delivery recorder exists');
select has_function('public','enforce_final_invoice_latest_final_payment_request_v1',array[]::text[],'Final-invoice payment-request gate exists');

select ok((select relrowsecurity from pg_class where oid='public.sales_order_pi_final_payment_requests'::regclass),'Final-payment PI revision RLS enabled');
select ok(not has_table_privilege('authenticated','public.sales_order_pi_final_payment_requests','INSERT'),'No direct authenticated final-payment PI insert');
select ok(not has_table_privilege('authenticated','public.sales_order_pi_final_payment_requests','UPDATE'),'No direct authenticated final-payment PI update');
select ok(not has_table_privilege('authenticated','public.sales_order_pi_final_payment_request_deliveries','INSERT'),'No direct authenticated delivery insert');
select ok(not has_function_privilege('service_role','public.issue_sales_order_pi_final_payment_request_v1(uuid,uuid,uuid,uuid,text,text,text,text,text,text,text,text,text,uuid)','EXECUTE'),'Service role cannot impersonate final-payment PI issuer');
select ok(not has_function_privilege('service_role','public.record_sales_order_pi_final_payment_delivery_v1(uuid,text,text,text,text,text,timestamptz,text,text,uuid)','EXECUTE'),'Service role cannot impersonate M4 delivery recorder');

select ok(pg_get_functiondef('public.calculate_finance_dpl_commercial_totals_v1(uuid,uuid,uuid,uuid)'::regprocedure) like '%finance_dpl_receipts%','Final payable uses immutable Finance DPL receipt');
select ok(pg_get_functiondef('public.calculate_finance_dpl_commercial_totals_v1(uuid,uuid,uuid,uuid)'::regprocedure) like '%sales_order_commercial_versions%','Final payable uses frozen commercial version');
select ok(pg_get_functiondef('public.calculate_finance_dpl_commercial_totals_v1(uuid,uuid,uuid,uuid)'::regprocedure) like '%v_pi.status <> ''ISSUED''%','Final-payment revision requires issued PI lineage');
select ok(pg_get_functiondef('public.issue_sales_order_pi_final_payment_request_v1(uuid,uuid,uuid,uuid,text,text,text,text,text,text,text,text,text,uuid)'::regprocedure) like '%assert_finance_clearance_actor_v1%','Final-payment PI issuance requires Finance+AAL2 authority');
select ok(pg_get_functiondef('public.issue_sales_order_pi_final_payment_request_v1(uuid,uuid,uuid,uuid,text,text,text,text,text,text,text,text,text,uuid)'::regprocedure) like '%FINAL_PAYMENT_PI_REQUIRES_LATEST_FINANCE_DPL%','Final-payment PI revision requires latest Finance DPL');
select ok(pg_get_functiondef('public.issue_sales_order_pi_final_payment_request_v1(uuid,uuid,uuid,uuid,text,text,text,text,text,text,text,text,text,uuid)'::regprocedure) like '%revision_number%','Final-payment PI preserves governed revision lineage');
select ok(pg_get_functiondef('public.issue_sales_order_pi_final_payment_request_v1(uuid,uuid,uuid,uuid,text,text,text,text,text,text,text,text,text,uuid)'::regprocedure) like '%supersedes_request_id%','Reissued final-payment PI links to prior revision');
select ok(pg_get_functiondef('public.issue_sales_order_pi_final_payment_request_v1(uuid,uuid,uuid,uuid,text,text,text,text,text,text,text,text,text,uuid)'::regprocedure) not like '%allocate_commercial_document_number_v1%','Final-payment revision does not allocate a second PI number');

select ok(pg_get_functiondef('public.get_sales_order_final_payment_coverage_v1(uuid,uuid,uuid,numeric)'::regprocedure) like '%get_order_payment_facts_v1%','Coverage uses canonical verified payments');
select ok(pg_get_functiondef('public.get_sales_order_final_payment_coverage_v1(uuid,uuid,uuid,numeric)'::regprocedure) like '%wallet_transactions%','Coverage includes exact bound wallet debits');
select ok(pg_get_functiondef('public.get_sales_order_final_payment_coverage_v1(uuid,uuid,uuid,numeric)'::regprocedure) like '%credit_requests%','Coverage includes active approved bound credit');
select ok(pg_get_functiondef('public.get_sales_order_pi_final_payment_request_v1(uuid)'::regprocedure) like '%balance_due%','Projection exposes exact current balance due');
select ok(pg_get_functiondef('public.get_sales_order_pi_final_payment_request_v1(uuid)'::regprocedure) like '%payment_action%' and pg_get_functiondef('public.get_sales_order_pi_final_payment_request_v1(uuid)'::regprocedure) like '%payment_instructions%','Projection exposes payment action and instructions');
select ok(pg_get_functiondef('public.get_sales_order_pi_final_payment_request_v1(uuid)'::regprocedure) like '%auth_buyer_company_id%','Buyer projection is scoped to own company');
select ok(pg_get_functiondef('public.record_sales_order_pi_final_payment_delivery_v1(uuid,text,text,text,text,text,timestamptz,text,text,uuid)'::regprocedure) like '%sales_order_pi_final_payment_request_deliveries%','M4 communication writes append-only delivery evidence');
select ok(pg_get_functiondef('public.record_sales_order_pi_final_payment_delivery_v1(uuid,text,text,text,text,text,timestamptz,text,text,uuid)'::regprocedure) like '%FINAL_PAYMENT_PI_DELIVERY_IDEMPOTENCY_CONFLICT%','M4 delivery evidence is idempotent');

select has_trigger('public','final_invoices','trg_final_invoice_requires_final_payment_request','Final invoice has pre-issuance final-payment gate');
select ok(pg_get_functiondef('public.enforce_final_invoice_latest_final_payment_request_v1()'::regprocedure) like '%FINAL_INVOICE_FINAL_PAYMENT_REQUEST_STALE%' and pg_get_functiondef('public.enforce_final_invoice_latest_final_payment_request_v1()'::regprocedure) like '%finance_dpl_receipt_id%','Final invoice requires latest exact PI/commercial/DPL revision binding');
select ok(pg_get_functiondef('public.enforce_final_invoice_latest_final_payment_request_v1()'::regprocedure) like '%FINAL_INVOICE_FINAL_PAYMENT_NOT_SETTLED%' and pg_get_functiondef('public.enforce_final_invoice_latest_final_payment_request_v1()'::regprocedure) like '%FINAL_INVOICE_DATE_PRECEDES_FINAL_PAYMENT_REQUEST%' and pg_get_functiondef('public.get_sales_order_pi_final_payment_request_v1(uuid)'::regprocedure) like '%final_invoice_must_not_request_payment%','Final invoice only follows settlement and never becomes the payment request');

select * from finish();
rollback;

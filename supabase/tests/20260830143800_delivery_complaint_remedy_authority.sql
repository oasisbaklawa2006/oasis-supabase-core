-- Contract for the delivery/complaint authority after the invoice-date clock correction.

select plan(30);

select has_table('public','delivery_proofs','Delivery proof ledger exists');
select has_table('public','commercial_complaints','Commercial complaint ledger exists');
select has_table('public','commercial_complaint_events','Complaint event ledger exists');
select has_table('public','commercial_adjustments','Commercial adjustment ledger exists');
select has_function('public','record_delivery_proof_v1',array['uuid','timestamp with time zone','text','jsonb','text','text','uuid'],'Delivery proof RPC exists');
select has_function('public','file_commercial_complaint_v1',array['uuid','text','text','jsonb','text','text','text','uuid'],'Complaint filing RPC exists');
select has_function('public','resolve_commercial_complaint_v1',array['uuid','text','numeric','text','text','text','text','text','text','uuid'],'Complaint resolution RPC exists');
select has_view('public','commercial_complaint_window_v1','Complaint-window view exists');
select ok((select relrowsecurity from pg_class where oid='public.delivery_proofs'::regclass),'delivery proof RLS enabled');
select ok((select relrowsecurity from pg_class where oid='public.commercial_complaints'::regclass),'complaint RLS enabled');
select ok(not has_table_privilege('authenticated','public.delivery_proofs','INSERT'),'no direct delivery proof write');
select ok(not has_table_privilege('authenticated','public.commercial_complaints','INSERT'),'no direct complaint write');
select ok(not has_table_privilege('authenticated','public.commercial_adjustments','INSERT'),'no direct financial remedy write');
select ok(pg_get_functiondef('public.record_delivery_proof_v1(uuid,timestamp with time zone,text,jsonb,text,text,uuid)'::regprocedure) like '%dispatch_proof_packets%','delivery proof binds dispatch proof');
select ok(pg_get_functiondef('public.record_delivery_proof_v1(uuid,timestamp with time zone,text,jsonb,text,text,uuid)'::regprocedure) like '%complaint_deadline_from_invoice_v1%','delivery proof returns invoice-derived complaint deadline');
select ok(pg_get_functiondef('public.prevent_delivery_proof_mutation()'::regprocedure) like '%DELIVERY_PROOF_IMMUTABLE%','delivery proof immutable');
select ok(pg_get_functiondef('public.file_commercial_complaint_v1(uuid,text,text,jsonb,text,text,text,uuid)'::regprocedure) like '%auth_buyer_company_id%','buyer complaint is company scoped');
select ok(pg_get_functiondef('public.file_commercial_complaint_v1(uuid,text,text,jsonb,text,text,text,uuid)'::regprocedure) like '%complaint_deadline_from_invoice_v1%','complaint eligibility consumes canonical invoice clock');
select ok(pg_get_functiondef('public.file_commercial_complaint_v1(uuid,text,text,jsonb,text,text,text,uuid)'::regprocedure) like '%statement_timestamp()>=v_deadline%','deadline is exclusive start of day 11');
select ok(pg_get_functiondef('public.file_commercial_complaint_v1(uuid,text,text,jsonb,text,text,text,uuid)'::regprocedure) like '%COMPLAINT_WINDOW_EXPIRED%','buyer complaint fails closed after deadline');
select ok(pg_get_functiondef('public.file_commercial_complaint_v1(uuid,text,text,jsonb,text,text,text,uuid)'::regprocedure) like '%COMPLAINT_LATE_EXCEPTION_AAL2_REQUIRED%','late internal exception requires evidence and AAL2');
select ok(pg_get_functiondef('public.resolve_commercial_complaint_v1(uuid,text,numeric,text,text,text,text,text,text,uuid)'::regprocedure) like '%assert_finance_clearance_actor_v1%','financial remedy requires Finance+AAL2');
select ok(pg_get_functiondef('public.resolve_commercial_complaint_v1(uuid,text,numeric,text,text,text,text,text,text,uuid)'::regprocedure) like '%TAX_ADJUSTMENT_DOCUMENT_REQUIRED%','credit/debit notes require document identity');
select ok(pg_get_functiondef('public.resolve_commercial_complaint_v1(uuid,text,numeric,text,text,text,text,text,text,uuid)'::regprocedure) like '%BANK_REFUND_REFERENCE_REQUIRED%','bank refund requires payment reference');
select ok(pg_get_functiondef('public.resolve_commercial_complaint_v1(uuid,text,numeric,text,text,text,text,text,text,uuid)'::regprocedure) like '%record_wallet_entry_v1%','wallet refund uses canonical PF-6B wallet authority');
select ok(pg_get_functiondef('public.resolve_commercial_complaint_v1(uuid,text,numeric,text,text,text,text,text,text,uuid)'::regprocedure) like '%COMPLAINT_ALREADY_RESOLVED%','complaint cannot be financially resolved twice');
select ok(pg_get_functiondef('public.prevent_commercial_adjustment_mutation()'::regprocedure) like '%COMMERCIAL_ADJUSTMENT_APPEND_ONLY%','financial remedy is append-only');
select ok(
  pg_get_functiondef('public.get_commercial_complaint_window_rows_v1()'::regprocedure) like '%complaint_deadline_from_invoice_v1%'
  and pg_get_functiondef('public.get_commercial_complaint_window_rows_v1()'::regprocedure) not like '%delivered_at +%',
  'window authority consumes canonical invoice deadline rather than delivery-derived time'
);
select ok(
  pg_get_functiondef('public.get_commercial_complaint_window_rows_v1()'::regprocedure) like '%RESOLUTION_PENDING%',
  'window authority exposes unresolved complaint state'
);
select ok(pg_get_functiondef('public.resolve_commercial_complaint_v1(uuid,text,numeric,text,text,text,text,text,text,uuid)'::regprocedure) not like '%UPDATE public.final_invoices%','remedies do not destructively edit invoice');

select * from finish();
-- Contract for migration 20260831101600_finance_exit_facts_projection.sql.
select plan(11);
select has_function('public','get_finance_exit_facts_v1',array['uuid'],'Finance Exit facts RPC exists');
select ok(pg_get_functiondef('public.get_finance_exit_facts_v1(uuid)'::regprocedure) like '%finance_dpl_receipts%','facts include Finance DPL receipt');
select ok(pg_get_functiondef('public.get_finance_exit_facts_v1(uuid)'::regprocedure) like '%final_invoices%','facts include final invoice');
select ok(pg_get_functiondef('public.get_finance_exit_facts_v1(uuid)'::regprocedure) like '%get_final_settlement_facts_v1%','facts include canonical settlement');
select ok(pg_get_functiondef('public.get_finance_exit_facts_v1(uuid)'::regprocedure) like '%finance_dispatch_clearance_authority_v1%','facts include explicit Dispatch Clearance');
select ok(pg_get_functiondef('public.get_finance_exit_facts_v1(uuid)'::regprocedure) like '%dispatch_proof_packets%','facts include dispatch proof');
select ok(pg_get_functiondef('public.get_finance_exit_facts_v1(uuid)'::regprocedure) like '%delivery_proofs%','facts include delivery proof');
select ok(pg_get_functiondef('public.get_finance_exit_facts_v1(uuid)'::regprocedure) like '%commercial_complaints%','facts include complaint state');
select ok(pg_get_functiondef('public.get_finance_exit_facts_v1(uuid)'::regprocedure) like '%commercial_adjustments%','facts include governed complaint financial consequences');
select ok(pg_get_functiondef('public.get_finance_exit_facts_v1(uuid)'::regprocedure) like '%commercial_closures%','facts include commercial closure');
select ok(pg_get_functiondef('public.get_finance_exit_facts_v1(uuid)'::regprocedure) not like '%final_invoice_url%','facts do not trust legacy invoice URL');
select * from finish();
-- Contract for migration 20260831101500_finance_exit_b2b_lineage_correction.sql.
-- Finance Exit must consume FACT-C1/FACT-C2 B2B authority, never legacy
-- dispatch_cartons or browser-composed DPL truth.
select plan(24);

select has_function('public','receive_submitted_b2b_dispatch_dpls_v1',array['uuid','text','text','text','uuid'],'server-composed B2B DPL receipt RPC exists');
select has_table('public','b2b_dispatch_gate_decisions','governed B2B gate decision ledger exists');
select has_function('public','release_b2b_dispatch_carton_at_gate_v1',array['uuid','uuid'],'B2B physical gate RPC exists');
select ok((select relrowsecurity from pg_class where oid='public.b2b_dispatch_gate_decisions'::regclass),'B2B gate decisions use RLS');
select ok(not has_table_privilege('authenticated','public.b2b_dispatch_gate_decisions','INSERT'),'browser cannot insert B2B gate decisions');

select ok(pg_get_functiondef('public.receive_submitted_b2b_dispatch_dpls_v1(uuid,text,text,text,uuid)'::regprocedure) like '%b2b_dispatch_packing_list_versions%','Finance DPL receipt derives FACT-C2 versions server-side');
select ok(pg_get_functiondef('public.receive_submitted_b2b_dispatch_dpls_v1(uuid,text,text,text,uuid)'::regprocedure) like '%b2b_dispatch_consignment_lines%','Finance DPL receipt derives line quantities server-side');
select ok(pg_get_functiondef('public.receive_submitted_b2b_dispatch_dpls_v1(uuid,text,text,text,uuid)'::regprocedure) like '%b2b_dispatch_cartons%','Finance DPL receipt derives cartons server-side');
select ok(pg_get_functiondef('public.receive_submitted_b2b_dispatch_dpls_v1(uuid,text,text,text,uuid)'::regprocedure) like '%B2B_FINANCE_DPL_SUBMISSION_INCOMPLETE%','Finance receipt fails closed until every active consignment has a submitted current DPL');
select ok(pg_get_functiondef('public.receive_submitted_b2b_dispatch_dpls_v1(uuid,text,text,text,uuid)'::regprocedure) like '%sum(cl.packed_qty)%','fragmented consignment quantities aggregate server-side');
select ok(pg_get_functiondef('public.receive_submitted_b2b_dispatch_dpls_v1(uuid,text,text,text,uuid)'::regprocedure) like '%source_authority%','receipt snapshot records source authority');
select ok(pg_get_functiondef('public.receive_submitted_b2b_dispatch_dpls_v1(uuid,text,text,text,uuid)'::regprocedure) not like '%dispatch_cartons%','Finance DPL receipt does not consume legacy cartons');

select ok(pg_get_functiondef('public.release_b2b_dispatch_carton_at_gate_v1(uuid,uuid)'::regprocedure) like '%b2b_dispatch_cartons%','gate consumes governed B2B carton truth');
select ok(pg_get_functiondef('public.release_b2b_dispatch_carton_at_gate_v1(uuid,uuid)'::regprocedure) like '%assert_active_dispatch_clearance_v1%','gate requires Finance Dispatch Clearance');
select ok(pg_get_functiondef('public.release_b2b_dispatch_carton_at_gate_v1(uuid,uuid)'::regprocedure) like '%carton_not_in_final_dpl%','gate binds exact Finance-frozen DPL carton membership');
select ok(pg_get_functiondef('public.release_b2b_dispatch_carton_at_gate_v1(uuid,uuid)'::regprocedure) like '%eway_evidence_invalid_or_expired%','gate revalidates E-way evidence');
select ok(pg_get_functiondef('public.release_b2b_dispatch_carton_at_gate_v1(uuid,uuid)'::regprocedure) not like '%payment_cleared%','gate does not trust legacy payment boolean');
select ok(pg_get_functiondef('public.release_b2b_dispatch_carton_at_gate_v1(uuid,uuid)'::regprocedure) not like '%final_invoice_url%','gate does not trust invoice URL');

select ok(pg_get_functiondef('public.record_dispatch_proof_packet_v1(uuid,jsonb,jsonb,timestamp with time zone,text,text,uuid)'::regprocedure) like '%b2b_dispatch_gate_decisions%','dispatch proof consumes B2B gate decisions');
select ok(pg_get_functiondef('public.record_dispatch_proof_packet_v1(uuid,jsonb,jsonb,timestamp with time zone,text,text,uuid)'::regprocedure) like '%b2b_dispatch_cartons%','dispatch proof consumes B2B carton status');
select ok(pg_get_functiondef('public.record_dispatch_proof_packet_v1(uuid,jsonb,jsonb,timestamp with time zone,text,text,uuid)'::regprocedure) like '%source_authority%','dispatch proof requires B2B-sourced Finance DPL');
select ok(pg_get_functiondef('public.record_dispatch_proof_packet_v1(uuid,jsonb,jsonb,timestamp with time zone,text,text,uuid)'::regprocedure) not like '%public.dispatch_cartons%','dispatch proof no longer consumes legacy cartons');
select ok(pg_get_functiondef('public.record_dispatch_proof_packet_v1(uuid,jsonb,jsonb,timestamp with time zone,text,text,uuid)'::regprocedure) not like '%public.dispatch_gate_decisions%','dispatch proof no longer consumes legacy gate decisions');
select ok(pg_get_functiondef('public.record_dispatch_proof_packet_v1(uuid,jsonb,jsonb,timestamp with time zone,text,text,uuid)'::regprocedure) like '%DISPATCH_PROOF_GATE_LINEAGE_INCOMPLETE%','dispatch proof fails closed on incomplete physical lineage');

select * from finish();
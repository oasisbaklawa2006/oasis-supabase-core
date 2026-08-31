-- Contract for migration 20260830143700_gate_dispatch_proof_authority.sql.

select plan(22);

select has_table('public','dispatch_proof_packets','Dispatch proof packet ledger exists');
select has_function('public','record_dispatch_proof_packet_v1',array['uuid','jsonb','jsonb','timestamp with time zone','text','text','uuid'],'Dispatch proof RPC exists');
select ok((select relrowsecurity from pg_class where oid='public.dispatch_proof_packets'::regclass),'dispatch proof RLS enabled');
select ok(not has_table_privilege('authenticated','public.dispatch_proof_packets','INSERT'),'no direct dispatch proof insertion');
select ok(not has_function_privilege('service_role','public.record_dispatch_proof_packet_v1(uuid,jsonb,jsonb,timestamp with time zone,text,text,uuid)','EXECUTE'),'service role cannot impersonate dispatch proof actor');
select ok(pg_get_functiondef('public.release_carton_at_dispatch_gate_v1(uuid,uuid)'::regprocedure) like '%assert_active_dispatch_clearance_v1%','gate requires explicit Finance Dispatch Clearance');
select ok(pg_get_functiondef('public.release_carton_at_dispatch_gate_v1(uuid,uuid)'::regprocedure) like '%carton_not_in_final_dpl%','gate requires exact final-DPL carton membership');
select ok(pg_get_functiondef('public.release_carton_at_dispatch_gate_v1(uuid,uuid)'::regprocedure) like '%eway_evidence_invalid_or_expired%','gate revalidates E-way evidence at physical exit');
select ok(pg_get_functiondef('public.release_carton_at_dispatch_gate_v1(uuid,uuid)'::regprocedure) not like '%payment_cleared%','gate no longer trusts legacy payment boolean');
select ok(pg_get_functiondef('public.release_carton_at_dispatch_gate_v1(uuid,uuid)'::regprocedure) not like '%final_invoice_url%','gate no longer trusts uploaded invoice URL');
select ok(pg_get_functiondef('public.release_carton_at_dispatch_gate_v1(uuid,uuid)'::regprocedure) not like '%sales_order_value%50000%','gate no longer invents E-way threshold authority');
select ok(pg_get_functiondef('public.release_carton_at_dispatch_gate_v1(uuid,uuid)'::regprocedure) like '%finance_dispatch_clearance_event_id%','gate decision stores Finance-clearance lineage');
select ok(pg_get_functiondef('public.release_carton_at_dispatch_gate_v1(uuid,uuid)'::regprocedure) like '%finance_dpl_receipt_id%','gate decision stores DPL lineage');
select ok(pg_get_functiondef('public.release_carton_at_dispatch_gate_v1(uuid,uuid)'::regprocedure) like '%eway_evidence_id%','gate decision stores E-way lineage');
select ok(pg_get_functiondef('public.record_dispatch_proof_packet_v1(uuid,jsonb,jsonb,timestamp with time zone,text,text,uuid)'::regprocedure) like '%assert_order_transition_role(''gate_release'')%','dispatch proof requires gate/dispatch authority');
select ok(pg_get_functiondef('public.record_dispatch_proof_packet_v1(uuid,jsonb,jsonb,timestamp with time zone,text,text,uuid)'::regprocedure) like '%assert_active_dispatch_clearance_v1%','dispatch proof binds active Finance Dispatch Clearance');
select ok(pg_get_functiondef('public.record_dispatch_proof_packet_v1(uuid,jsonb,jsonb,timestamp with time zone,text,text,uuid)'::regprocedure) like '%DISPATCH_PROOF_GATE_RELEASE_INCOMPLETE%','proof cannot freeze before every DPL carton exits');
select ok(pg_get_functiondef('public.record_dispatch_proof_packet_v1(uuid,jsonb,jsonb,timestamp with time zone,text,text,uuid)'::regprocedure) like '%DISPATCH_PROOF_GATE_LINEAGE_INCOMPLETE%','proof requires one released gate decision per DPL carton');
select ok(pg_get_functiondef('public.record_dispatch_proof_packet_v1(uuid,jsonb,jsonb,timestamp with time zone,text,text,uuid)'::regprocedure) like '%lr_awb_bilty%','transport document identity required');
select ok(pg_get_functiondef('public.record_dispatch_proof_packet_v1(uuid,jsonb,jsonb,timestamp with time zone,text,text,uuid)'::regprocedure) like '%transporter%','transporter identity required');
select ok(pg_get_functiondef('public.prevent_dispatch_proof_packet_mutation()'::regprocedure) like '%DISPATCH_PROOF_PACKET_IMMUTABLE%','dispatch proof is immutable');
select ok(pg_get_functiondef('public.record_dispatch_proof_packet_v1(uuid,jsonb,jsonb,timestamp with time zone,text,text,uuid)'::regprocedure) not like '%UPDATE public.orders%','dispatch proof does not fabricate order lifecycle state');

select * from finish();

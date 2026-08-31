-- Contract for migration 20260901001000_production_semantic_parity_reconciliation.sql.
select plan(14);

select ok(to_regclass('public._wave1c_smoke_scratch') is null,'production smoke scratch table is absent');
select ok(to_regprocedure('public.derive_order_finance_blockers_json(text,text,numeric,numeric,numeric,text)') is null,'unmanaged finance blocker helper is absent');
select ok(to_regprocedure('public.order_dispatch_finance_hold(text,text,numeric,numeric,numeric)') is null,'unmanaged dispatch finance hold helper is absent');
select ok(to_regprocedure('public.order_operations_finance_hold(text,text,numeric,numeric)') is null,'unmanaged operations finance hold helper is absent');

select ok((select count(*)=0 from pg_policies where schemaname='public' and tablename='dispatch_cartons' and policyname='Staff full access dispatch_cartons'),'legacy broad dispatch_cartons ALL policy is absent');
select ok((select count(*)=1 from pg_policies where schemaname='public' and tablename='dispatch_cartons' and policyname='Staff insert dispatch_cartons' and cmd='INSERT'),'dispatch_cartons insert policy is canonical');
select ok((select count(*)=1 from pg_policies where schemaname='public' and tablename='dispatch_cartons' and policyname='Staff read dispatch_cartons' and cmd='SELECT'),'dispatch_cartons read policy is canonical');
select ok((select count(*)=1 from pg_policies where schemaname='public' and tablename='dispatch_cartons' and policyname='Staff update dispatch_carton_metadata' and cmd='UPDATE'),'dispatch_cartons update policy is canonical');
select ok((select count(*)=1 from pg_policies where schemaname='public' and tablename='order_payments' and policyname='Finance staff manage order payments'),'Finance order payment management policy is canonical');
select ok((select count(*)=1 from pg_policies where schemaname='public' and tablename='order_payments' and policyname='Staff read order payments'),'staff order payment read policy is canonical');
select ok((select count(*)=1 from pg_policies where schemaname='public' and tablename='orders' and policyname='Staff update non-governed order fields'),'non-governed order update policy is canonical');
select ok((select count(*)=0 from pg_policies where schemaname='public' and tablename='audit_logs' and policyname='Authenticated can insert audit_logs'),'broad authenticated audit insert policy is absent');
select has_index('public','dispatch_gate_decisions','idx_dispatch_gate_decisions_carton','legacy gate compatibility index exists deterministically');
select ok((select count(*)=3 from pg_constraint where conrelid='public.dispatch_gate_decisions'::regclass and conname in ('dispatch_gate_decisions_carton_id_fkey','dispatch_gate_decisions_order_id_fkey','dispatch_gate_decisions_scan_evidence_id_fkey') and confdeltype='r'),'legacy gate foreign keys use explicit RESTRICT delete semantics');

select * from finish();

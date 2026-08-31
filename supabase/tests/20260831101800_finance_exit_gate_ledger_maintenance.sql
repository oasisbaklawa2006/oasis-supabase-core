-- Contract for migration 20260831101800_finance_exit_gate_ledger_maintenance.sql.
select plan(6);

select has_index('public','b2b_dispatch_gate_decisions','idx_b2b_dispatch_gate_decisions_order_decision','order/decision lookup index exists');
select has_index('public','b2b_dispatch_gate_decisions','idx_b2b_dispatch_gate_decisions_carton_created','carton chronology lookup index exists');
select ok((select count(*)=1 from pg_policies where schemaname='public' and tablename='b2b_dispatch_gate_decisions' and policyname='b2b_dispatch_gate_decisions_internal_read'),'gate read policy exists exactly once');
select ok((select count(*)=1 from pg_trigger where tgrelid='public.b2b_dispatch_gate_decisions'::regclass and tgname='trg_b2b_dispatch_gate_decisions_immutable' and not tgisinternal),'immutable gate trigger exists exactly once');
select ok((select relrowsecurity from pg_class where oid='public.b2b_dispatch_gate_decisions'::regclass),'gate decision ledger keeps RLS enabled');
select ok(not has_table_privilege('authenticated','public.b2b_dispatch_gate_decisions','INSERT'),'browser still cannot insert gate decisions directly');

select * from finish();

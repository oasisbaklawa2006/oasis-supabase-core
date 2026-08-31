-- Contract for migration 20260830143200_pf6c_frozen_advance_binding.sql.

select plan(7);

select ok(pg_get_functiondef('public.get_finance_operations_clearance_facts_v1(uuid,uuid,uuid)'::regprocedure) like '%v_version.advance_required%','PF-6C consumes frozen commercial advance requirement');
select ok(pg_get_functiondef('public.get_finance_operations_clearance_facts_v1(uuid,uuid,uuid)'::regprocedure) like '%v_version.advance_rule_version%','PF-6C exposes the frozen advance rule version');
select ok(pg_get_functiondef('public.get_finance_operations_clearance_facts_v1(uuid,uuid,uuid)'::regprocedure) like '%v_pi.frozen_commercial_snapshot IS DISTINCT FROM v_version.commercial_snapshot%','PI snapshot must equal exact commercial version');
select ok(pg_get_functiondef('public.get_finance_operations_clearance_facts_v1(uuid,uuid,uuid)'::regprocedure) like '%advance_requirement_is_frozen_commercial_truth%','response declares frozen advance truth');
select ok(pg_get_functiondef('public.get_finance_operations_clearance_facts_v1(uuid,uuid,uuid)'::regprocedure) not like '%v_value * 0.30%','Finance clearance does not recompute advance policy');
select ok(pg_get_functiondef('public.get_finance_operations_clearance_facts_v1(uuid,uuid,uuid)'::regprocedure) not like '%ceil(%','Finance clearance does not round advance independently');
select ok(pg_get_functiondef('public.get_finance_operations_clearance_facts_v1(uuid,uuid,uuid)'::regprocedure) not like '%round((v_value%','Finance clearance does not introduce another rounding rule');

select * from finish();

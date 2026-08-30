-- Contract for migration 20260830143250_pf6c_clearance_idempotency_hardening.sql.

select plan(13);

select has_function('public','decide_finance_operations_clearance_v1',array['uuid','uuid','uuid','text','text','text','text','text','text','text','uuid'],'PF-6C decision RPC exists');
select ok(pg_get_functiondef('public.decide_finance_operations_clearance_v1(uuid,uuid,uuid,text,text,text,text,text,text,text,uuid)'::regprocedure) like '%finance_clearance_idempotency%FOR UPDATE%','decision checks durable idempotency receipt');
select ok(strpos(pg_get_functiondef('public.decide_finance_operations_clearance_v1(uuid,uuid,uuid,text,text,text,text,text,text,text,uuid)'::regprocedure),'finance_clearance_idempotency') < strpos(pg_get_functiondef('public.decide_finance_operations_clearance_v1(uuid,uuid,uuid,text,text,text,text,text,text,text,uuid)'::regprocedure),'get_finance_operations_clearance_facts_v1'),'idempotency replay precedes mutable funding facts');
select ok(strpos(pg_get_functiondef('public.decide_finance_operations_clearance_v1(uuid,uuid,uuid,text,text,text,text,text,text,text,uuid)'::regprocedure),'finance_clearance_idempotency') < strpos(pg_get_functiondef('public.decide_finance_operations_clearance_v1(uuid,uuid,uuid,text,text,text,text,text,text,text,uuid)'::regprocedure),'FINANCE_OPERATIONS_CLEARANCE_NOT_FUNDED'),'idempotency replay precedes funding validation');
select ok(strpos(pg_get_functiondef('public.decide_finance_operations_clearance_v1(uuid,uuid,uuid,text,text,text,text,text,text,text,uuid)'::regprocedure),'finance_clearance_idempotency') < strpos(pg_get_functiondef('public.decide_finance_operations_clearance_v1(uuid,uuid,uuid,text,text,text,text,text,text,text,uuid)'::regprocedure),'FINANCE_OPERATIONS_CLEARANCE_NOT_ACTIVE'),'idempotency replay precedes revoke-state validation');
select ok(pg_get_functiondef('public.decide_finance_operations_clearance_v1(uuid,uuid,uuid,text,text,text,text,text,text,text,uuid)'::regprocedure) not like '%''facts'',v_facts%','request fingerprint excludes volatile facts');
select ok(pg_get_functiondef('public.decide_finance_operations_clearance_v1(uuid,uuid,uuid,text,text,text,text,text,text,text,uuid)'::regprocedure) like '%''correlation_id'',btrim(p_correlation_id)%','request fingerprint binds caller correlation identity');
select ok(pg_get_functiondef('public.decide_finance_operations_clearance_v1(uuid,uuid,uuid,text,text,text,text,text,text,text,uuid)'::regprocedure) like '%v_existing.actor_id IS DISTINCT FROM v_actor%','idempotency replay remains actor-bound');
select ok(pg_get_functiondef('public.decide_finance_operations_clearance_v1(uuid,uuid,uuid,text,text,text,text,text,text,text,uuid)'::regprocedure) like '%facts_snapshot%','original decision retains immutable facts snapshot');
select ok(pg_get_functiondef('public.get_finance_operations_clearance_facts_v1(uuid,uuid,uuid)'::regprocedure) like '%reversal_of_id = w.id%','wallet coverage excludes reversed debits');
select ok(pg_get_functiondef('public.get_finance_operations_clearance_facts_v1(uuid,uuid,uuid)'::regprocedure) like '%v_value > 0 AND v_required <= 0%','positive governed SO cannot clear with zero frozen advance');
select ok(pg_get_functiondef('public.decide_finance_operations_clearance_v1(uuid,uuid,uuid,text,text,text,text,text,text,text,uuid)'::regprocedure) like '%v_latest.proforma_invoice_id IS DISTINCT FROM p_pi_id%','revocation requires exact PI lineage');
select ok(pg_get_functiondef('public.decide_finance_operations_clearance_v1(uuid,uuid,uuid,text,text,text,text,text,text,text,uuid)'::regprocedure) like '%v_latest.commercial_version_id IS DISTINCT FROM p_commercial_version_id%','revocation requires exact commercial-version lineage');

select * from finish();

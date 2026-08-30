-- PF-6C enforcement coverage: no lifecycle release may infer Finance clearance
-- from legacy payment/order fields.

select plan(11);

select has_function('public','assert_active_operations_clearance_v1',array['uuid'],'active operations clearance guard exists');
select ok(pg_get_functiondef('public.assert_active_operations_clearance_v1(uuid)'::regprocedure) like '%finance_operations_clearance_authority_v1%','release guard consumes canonical clearance projection');
select ok(pg_get_functiondef('public.assert_active_operations_clearance_v1(uuid)'::regprocedure) like '%FINANCE_OPERATIONS_CLEARANCE_REQUIRED%','release guard fails closed without granted clearance');
select ok(pg_get_functiondef('public.assert_active_operations_clearance_v1(uuid)'::regprocedure) like '%FINANCE_OPERATIONS_CLEARANCE_STALE_VERSION%','release guard rejects stale commercial version');
select ok(pg_get_functiondef('public.assert_active_operations_clearance_v1(uuid)'::regprocedure) like '%FINANCE_OPERATIONS_CLEARANCE_PI_STALE%','release guard rejects stale PI');
select ok(pg_get_functiondef('public.release_order_to_manufacturing_v1(uuid,text)'::regprocedure) like '%assert_active_operations_clearance_v1%','manufacturing release requires canonical Finance clearance');
select ok(pg_get_functiondef('public.release_order_to_in_production_v1(uuid,text)'::regprocedure) like '%assert_active_operations_clearance_v1%','production release requires canonical Finance clearance');
select ok(pg_get_functiondef('public.release_order_to_manufacturing_v1(uuid,text)'::regprocedure) not like '%is_advance_verification_path_cleared%','manufacturing release no longer infers authority from payment status');
select ok(pg_get_functiondef('public.release_order_to_in_production_v1(uuid,text)'::regprocedure) not like '%advance_paid%advance_required%','production release no longer derives clearance from legacy advance fields');
select ok(pg_get_functiondef('public.release_order_to_manufacturing_v1(uuid,text)'::regprocedure) like '%finance_clearance_event_id%','manufacturing audit records clearance lineage');
select ok(pg_get_functiondef('public.release_order_to_in_production_v1(uuid,text)'::regprocedure) like '%finance_clearance_event_id%','production audit records clearance lineage');

select * from finish();

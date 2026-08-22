begin;
-- Contract coverage for 20260822130000_dispatch_role_tiers.sql:
-- is_dispatch_operator_role / is_dispatch_manager_role must implement the
-- owner-approved two-tier Dispatch visibility model -- DISPATCH_INCHARGE is
-- operator-tier only; DISPATCH_MANAGER and DISPATCH_HEAD are manager/label-
-- authority tier AND pass the operator check (a manager can do everything
-- an operator can); non-dispatch staff and unauthenticated roles pass
-- neither.
select plan(11);

select has_function('public', 'is_dispatch_operator_role', 'is_dispatch_operator_role exists');
select has_function('public', 'is_dispatch_manager_role', 'is_dispatch_manager_role exists');

select ok(public.is_dispatch_operator_role('DISPATCH_INCHARGE'), 'DISPATCH_INCHARGE passes the operator tier');
select ok(NOT public.is_dispatch_manager_role('DISPATCH_INCHARGE'), 'DISPATCH_INCHARGE does NOT pass the manager/label-authority tier');

select ok(public.is_dispatch_manager_role('DISPATCH_MANAGER'), 'DISPATCH_MANAGER passes the manager/label-authority tier');
select ok(public.is_dispatch_operator_role('DISPATCH_MANAGER'), 'DISPATCH_MANAGER also passes the operator tier (manager is a superset)');

select ok(public.is_dispatch_manager_role('DISPATCH_HEAD'), 'DISPATCH_HEAD passes the manager/label-authority tier');
select ok(public.is_dispatch_operator_role('DISPATCH_HEAD'), 'DISPATCH_HEAD also passes the operator tier');

select ok(NOT public.is_dispatch_operator_role('SALES_EXECUTIVE'), 'a non-dispatch staff role passes neither tier (operator)');
select ok(NOT public.is_dispatch_manager_role('SALES_EXECUTIVE'), 'a non-dispatch staff role passes neither tier (manager)');

select ok(public.is_dispatch_manager_role('ADMIN'), 'ADMIN retains override access to the manager/label-authority tier');

select * from finish(); -- skipcq (pgTAP's finish() returns setof text; column count is not actually ambiguous)
rollback;

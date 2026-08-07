begin;
-- Contract coverage for 20260806101000_b2b_unannounced_return_arrival.sql.
select plan(6);

select has_table('public','b2b_return_arrival_cases','B2B unannounced return arrival case table exists');
select has_table('public','b2b_return_arrival_items','B2B return arrival item table exists');
select has_table('public','b2b_return_arrival_decisions','B2B return arrival decision table exists');
select col_default_is('public','b2b_return_arrival_cases','arrival_state','awaiting_gate_decision','new return arrivals start awaiting a gate decision');
select is((select has_table_privilege('anon','public.b2b_return_arrival_cases','select')),false,'anonymous cannot read return arrival cases');
select is((select has_table_privilege('authenticated','public.b2b_return_arrival_cases','select')),true,'authenticated staff can enter the RLS-governed return arrival cases table');

select * from finish();
rollback;

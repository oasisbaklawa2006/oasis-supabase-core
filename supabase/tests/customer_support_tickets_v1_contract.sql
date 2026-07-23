-- Contract for migration 20260722223000_support_ticket_security_boundary.sql

begin;

select plan(23);

-- Browser privilege boundary.
select ok(not has_table_privilege('anon', 'public.support_tickets', 'SELECT'), 'anon cannot select support_tickets');
select ok(not has_table_privilege('anon', 'public.support_tickets', 'INSERT'), 'anon cannot insert support_tickets');
select ok(not has_table_privilege('anon', 'public.support_tickets', 'UPDATE'), 'anon cannot update support_tickets');
select ok(not has_table_privilege('anon', 'public.support_tickets', 'DELETE'), 'anon cannot delete support_tickets');
select ok(not has_table_privilege('authenticated', 'public.support_tickets', 'TRUNCATE'), 'authenticated cannot truncate support_tickets');
select ok(not has_table_privilege('authenticated', 'public.support_tickets', 'TRIGGER'), 'authenticated cannot manage support_tickets triggers');
select ok(not has_table_privilege('authenticated', 'public.support_tickets', 'REFERENCES'), 'authenticated cannot create references on support_tickets');

-- Duplicate table is frozen for browser roles.
select ok(not has_table_privilege('anon', 'public.tickets', 'SELECT'), 'anon cannot select deprecated tickets');
select ok(not has_table_privilege('authenticated', 'public.tickets', 'SELECT'), 'authenticated cannot select deprecated tickets');
select ok(not has_table_privilege('authenticated', 'public.tickets', 'INSERT'), 'authenticated cannot insert deprecated tickets');
select ok(not has_table_privilege('authenticated', 'public.tickets', 'UPDATE'), 'authenticated cannot update deprecated tickets');
select ok(not has_table_privilege('authenticated', 'public.tickets', 'DELETE'), 'authenticated cannot delete deprecated tickets');

-- RPC privilege boundary.
select ok(not has_function_privilege('anon', 'public.customer_support_tickets_v1()', 'EXECUTE'), 'anon cannot execute customer_support_tickets_v1');
select ok(has_function_privilege('authenticated', 'public.customer_support_tickets_v1()', 'EXECUTE'), 'authenticated can execute customer_support_tickets_v1');
select ok(not has_function_privilege('anon', 'public.submit_customer_support_ticket_v1(uuid,text,text,text,integer)', 'EXECUTE'), 'anon cannot submit support tickets');
select ok(has_function_privilege('authenticated', 'public.submit_customer_support_ticket_v1(uuid,text,text,text,integer)', 'EXECUTE'), 'authenticated can submit support tickets');

-- Function hardening.
select ok((select prosecdef from pg_proc where oid = 'public.customer_support_tickets_v1()'::regprocedure), 'customer_support_tickets_v1 is SECURITY DEFINER');
select ok((select prosecdef from pg_proc where oid = 'public.submit_customer_support_ticket_v1(uuid,text,text,text,integer)'::regprocedure), 'submit_customer_support_ticket_v1 is SECURITY DEFINER');
select ok((select proconfig @> array['search_path=pg_catalog, public, auth'] from pg_proc where oid = 'public.customer_support_tickets_v1()'::regprocedure), 'customer_support_tickets_v1 has fixed search_path');
select ok((select proconfig @> array['search_path=pg_catalog, public, auth'] from pg_proc where oid = 'public.submit_customer_support_ticket_v1(uuid,text,text,text,integer)'::regprocedure), 'submit_customer_support_ticket_v1 has fixed search_path');

-- Canonical ownership and compact policy contract.
select is((select count(*)::integer from public.support_tickets where company_id is null), 0, 'all support tickets have canonical company ownership');
select is((select count(*)::integer from pg_policies where schemaname = 'public' and tablename = 'support_tickets'), 3, 'support_tickets has exactly three intended RLS policies');

-- Anonymous/no JWT identity receives no customer rows.
select is((select count(*)::integer from public.customer_support_tickets_v1()), 0, 'anonymous context receives no customer support tickets');

select * from finish();
rollback;

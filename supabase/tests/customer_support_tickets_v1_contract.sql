-- Contract checks for support-ticket security and customer RPCs.

begin;

-- Browser privilege boundary.
select has_table_privilege('anon', 'public.support_tickets', 'SELECT') is false;
select has_table_privilege('anon', 'public.support_tickets', 'INSERT') is false;
select has_table_privilege('anon', 'public.support_tickets', 'UPDATE') is false;
select has_table_privilege('anon', 'public.support_tickets', 'DELETE') is false;
select has_table_privilege('authenticated', 'public.support_tickets', 'TRUNCATE') is false;
select has_table_privilege('authenticated', 'public.support_tickets', 'TRIGGER') is false;
select has_table_privilege('authenticated', 'public.support_tickets', 'REFERENCES') is false;

-- Duplicate table is frozen for browser roles.
select has_table_privilege('anon', 'public.tickets', 'SELECT') is false;
select has_table_privilege('authenticated', 'public.tickets', 'SELECT') is false;
select has_table_privilege('authenticated', 'public.tickets', 'INSERT') is false;
select has_table_privilege('authenticated', 'public.tickets', 'UPDATE') is false;
select has_table_privilege('authenticated', 'public.tickets', 'DELETE') is false;

-- RPC privilege boundary.
select has_function_privilege('anon', 'public.customer_support_tickets_v1()', 'EXECUTE') is false;
select has_function_privilege('authenticated', 'public.customer_support_tickets_v1()', 'EXECUTE') is true;
select has_function_privilege('anon', 'public.submit_customer_support_ticket_v1(uuid,text,text,text,integer)', 'EXECUTE') is false;
select has_function_privilege('authenticated', 'public.submit_customer_support_ticket_v1(uuid,text,text,text,integer)', 'EXECUTE') is true;

-- Function hardening.
select prosecdef is true
from pg_proc
where oid = 'public.customer_support_tickets_v1()'::regprocedure;

select prosecdef is true
from pg_proc
where oid = 'public.submit_customer_support_ticket_v1(uuid,text,text,text,integer)'::regprocedure;

-- Canonical ownership must be populated.
select count(*) = 0
from public.support_tickets
where company_id is null;

-- Only the intended compact RLS policy set may remain.
select count(*) = 3
from pg_policies
where schemaname = 'public'
  and tablename = 'support_tickets';

-- Anonymous/no JWT identity receives no customer rows.
select count(*) = 0 from public.customer_support_tickets_v1();

rollback;

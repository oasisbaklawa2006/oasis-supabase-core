-- Contract for migration 20260722222900_legacy_support_ticket_baseline.sql

begin;

select plan(6);

select has_table('public', 'support_tickets', 'legacy support_tickets table exists for clean replay');
select has_table('public', 'tickets', 'legacy tickets table exists for clean replay');
select has_column('public', 'support_tickets', 'order_id', 'support_tickets exposes order_id');
select has_column('public', 'support_tickets', 'created_by', 'support_tickets exposes created_by');
select has_column('public', 'support_tickets', 'sla_resolution_due', 'support_tickets exposes SLA resolution deadline');
select has_column('public', 'support_tickets', 'customer_rating', 'support_tickets exposes customer rating');

select * from finish();
rollback;

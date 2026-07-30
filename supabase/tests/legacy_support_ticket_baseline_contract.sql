-- Contract for migration 20260722222900_legacy_support_ticket_baseline.sql

begin;

select plan(6);

select has_table('public', 'support_tickets', 'support_tickets baseline exists');
select has_table('public', 'tickets', 'legacy tickets baseline exists');
select has_column('public', 'support_tickets', 'id', 'support_tickets exposes id');
select has_column('public', 'support_tickets', 'order_id', 'support_tickets exposes order_id');
select has_column('public', 'support_tickets', 'created_by', 'support_tickets exposes created_by');
select has_column('public', 'support_tickets', 'created_at', 'support_tickets exposes created_at');

select * from finish();
rollback;
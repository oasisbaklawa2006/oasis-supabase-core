begin;
-- Contract coverage for recovered historical migration 20260817211610.
select plan(1);
select has_function('public', 'whatsapp_run_scheduled_reconciliation', array[]::text[], 'whatsapp_run_scheduled_reconciliation exists');
select * from finish();
rollback;

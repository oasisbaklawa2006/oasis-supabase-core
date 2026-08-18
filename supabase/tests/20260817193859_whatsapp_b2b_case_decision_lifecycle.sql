begin;
-- Contract coverage for recovered historical migration 20260817193859.
select plan(2);
select has_function('public', 'whatsapp_case_potential_order_id', array['uuid'], 'whatsapp_case_potential_order_id exists');
select has_function('public', 'whatsapp_signoff_reconciliation', array['uuid'], 'whatsapp_signoff_reconciliation exists');
select * from finish();
rollback;

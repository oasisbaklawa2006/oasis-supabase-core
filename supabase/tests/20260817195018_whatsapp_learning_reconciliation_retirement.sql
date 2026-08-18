begin;
-- Contract coverage for recovered historical migration 20260817195018.
select plan(3);
select has_function('public', 'whatsapp_get_reconciliation_run', array['uuid'], 'whatsapp_get_reconciliation_run exists');
select has_function('public', 'whatsapp_get_case_learning_candidates', array['uuid'], 'whatsapp_get_case_learning_candidates exists');
select has_function('public', 'whatsapp_get_legacy_retirements', array[]::text[], 'whatsapp_get_legacy_retirements exists');
select * from finish();
rollback;

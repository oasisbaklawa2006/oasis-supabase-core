begin;
-- Contract coverage for recovered historical migration 20260817194100.
select plan(1);
select has_function('public', 'bridge_whatsapp_case_identity_to_wa3', array[]::text[], 'bridge_whatsapp_case_identity_to_wa3 trigger function exists');
select * from finish();
rollback;

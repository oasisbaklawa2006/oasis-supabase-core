begin;
-- Contract coverage for recovered historical migration 20260817205006.
select plan(2);
select has_function('public', 'materialize_whatsapp_case_ai_layers_from_event', array[]::text[], 'materialize_whatsapp_case_ai_layers_from_event trigger function exists');
select has_function('public', 'whatsapp_get_case_commercial_layers', array['uuid'], 'whatsapp_get_case_commercial_layers exists');
select * from finish();
rollback;

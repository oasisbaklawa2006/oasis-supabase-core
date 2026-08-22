begin;
-- Contract coverage for recovered historical migration 20260817181608.
select plan(3);
select has_function('public', 'whatsapp_materialize_packet_ai_case', array['uuid','uuid','uuid','uuid','bigint'], 'whatsapp_materialize_packet_ai_case exists');
select has_function('public', 'whatsapp_get_case_decision_snapshot', array['uuid'], 'whatsapp_get_case_decision_snapshot exists');
select has_function('public', 'whatsapp_accept_ai_case_routing', array['uuid','text','text','timestamptz','text[]','text'], 'whatsapp_accept_ai_case_routing exists');
select * from finish();
rollback;

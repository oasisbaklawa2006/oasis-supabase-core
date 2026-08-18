begin;
-- Contract coverage for recovered historical migration 20260817123608.
select plan(2);
select ok(has_table_privilege('service_role', 'public.whatsapp_packet_ai_interpretations', 'insert'), 'service_role can insert into whatsapp_packet_ai_interpretations');
select ok(has_table_privilege('service_role', 'public.whatsapp_commercial_evidence', 'select'), 'service_role can select whatsapp_commercial_evidence');
select * from finish();
rollback;

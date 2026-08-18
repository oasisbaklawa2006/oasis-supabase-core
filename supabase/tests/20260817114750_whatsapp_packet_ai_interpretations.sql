begin;
-- Contract coverage for recovered historical migration 20260817114750.
select plan(2);
select has_table('public', 'whatsapp_packet_ai_interpretations', 'whatsapp_packet_ai_interpretations table exists');
select trigger_is('public', 'whatsapp_packet_ai_interpretations', 'whatsapp_packet_ai_interpretations_append_only', 'public', 'prevent_audit_log_mutation', 'append-only trigger wired to prevent_audit_log_mutation');
select * from finish();
rollback;

begin;
-- Contract coverage for 20260822090000_whatsapp_intelligence_knowledge_snapshots.sql.
select plan(11);
select has_table('public', 'whatsapp_intelligence_knowledge_snapshots', 'governed intelligence knowledge snapshots exist');
select has_column('public', 'whatsapp_intelligence_knowledge_snapshots', 'knowledge', 'snapshot stores governed knowledge bundle');
select has_column('public', 'whatsapp_intelligence_knowledge_snapshots', 'content_checksum', 'snapshot stores immutable content checksum');
select has_index('public', 'whatsapp_intelligence_knowledge_snapshots', 'whatsapp_intelligence_snapshot_one_active', 'only one active intelligence snapshot is allowed');
select ok((select relrowsecurity from pg_class where oid = 'public.whatsapp_intelligence_knowledge_snapshots'::regclass), 'RLS is enabled');
select is_empty($$select 1 from information_schema.role_table_grants where table_schema='public' and table_name='whatsapp_intelligence_knowledge_snapshots' and grantee in ('PUBLIC','anon','authenticated')$$, 'untrusted roles have no table grants');
select has_function('public', 'whatsapp_active_intelligence_knowledge_snapshot', array[]::text[], 'runtime selector exists');
select has_function('public', 'whatsapp_activate_intelligence_knowledge_snapshot', array['uuid'], 'governed activation RPC exists');
select trigger_is('public', 'whatsapp_intelligence_knowledge_snapshots', 'whatsapp_intelligence_snapshot_content_immutable', 'public', 'whatsapp_guard_intelligence_snapshot_mutation');
select has_column('public', 'whatsapp_packet_ai_interpretations', 'knowledge_snapshot_schema_version', 'interpretations pin knowledge snapshot schema version');
select is_empty($$select 1 from information_schema.role_routine_grants where routine_schema='public' and routine_name='whatsapp_active_intelligence_knowledge_snapshot' and grantee in ('PUBLIC','anon','authenticated')$$, 'runtime selector is service role only');
select * from finish();
rollback;

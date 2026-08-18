begin;
-- Contract coverage for recovered historical migration 20260817205955.
select plan(3);
select has_function('public', 'whatsapp_rule_validate_case_reply', array['uuid','uuid','text','text','text[]'], 'whatsapp_rule_validate_case_reply exists');
select has_function('public', 'whatsapp_release_case_reply', array['uuid','uuid','text','text','text[]','uuid','text'], 'whatsapp_release_case_reply exists');
select has_function('public', 'whatsapp_release_reviewed_case_reply', array['uuid','jsonb','text'], 'whatsapp_release_reviewed_case_reply exists');
select * from finish();
rollback;

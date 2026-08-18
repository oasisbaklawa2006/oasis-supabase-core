begin;
-- Contract coverage for recovered historical migration 20260817194648.
select plan(1);
select has_function('public', 'whatsapp_get_case_draft_candidates', array['uuid'], 'whatsapp_get_case_draft_candidates exists');
select * from finish();
rollback;

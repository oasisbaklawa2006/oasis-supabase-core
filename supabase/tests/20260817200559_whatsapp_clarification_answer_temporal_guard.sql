begin;
-- Contract coverage for recovered historical migration 20260817200559.
select plan(1);
select has_function('public', 'whatsapp_confirm_clarification_answer', array['uuid','uuid','text','jsonb','text'], 'whatsapp_confirm_clarification_answer exists');
select * from finish();
rollback;

begin;
-- Contract coverage for recovered historical migration 20260817182658.
select plan(1);
select has_function('public', 'whatsapp_b2b_response_team_allowed', array['text'], 'whatsapp_b2b_response_team_allowed exists');
select * from finish();
rollback;

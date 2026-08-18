begin;
-- Contract coverage for recovered historical migration 20260817211036.
select plan(1);
select has_function('public', 'materialize_whatsapp_payment_advice_from_ai_event', array[]::text[], 'materialize_whatsapp_payment_advice_from_ai_event trigger function exists');
select * from finish();
rollback;

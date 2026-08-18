begin;
-- Contract coverage for recovered historical migration 20260817115224.
select plan(1);
select has_function('public', 'complete_whatsapp_media_processing', array['text','text','text','jsonb'], 'complete_whatsapp_media_processing exists after historical recovery migration');
select * from finish();
rollback;

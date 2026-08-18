begin;
-- Contract coverage for 20260817213000_fwd_wa_packet_ai_release_hardening_delta.sql.
-- Genuine-gap delta recovered from open PR #82's release-hardening migration
-- (already-live grant/revoke portion intentionally not re-applied here).
select plan(2);
select has_function('public', 'complete_whatsapp_media_processing', array['text','text','text','jsonb'], 'idempotent-replay-guarded media completion function exists');
select col_hasnt_default('public', 'whatsapp_packet_ai_interpretations', 'provider_message_ids', 'provider_message_ids no longer carries a default');
select * from finish();
rollback;

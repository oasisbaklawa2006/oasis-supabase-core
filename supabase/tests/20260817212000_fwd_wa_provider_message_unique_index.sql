begin;
-- Contract coverage for 20260817212000_fwd_wa_provider_message_unique_index.sql.
-- Forward-only replacement of 20260816120100_wa_provider_message_unique_index.sql
-- (below production max at reconciliation time, see docs/reconciliation).
select plan(1);
select has_index('public', 'whatsapp_messages', 'whatsapp_messages_provider_message_unique', 'provider-message idempotency guard index exists');
select * from finish();
rollback;

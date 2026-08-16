-- WA provider-message idempotency guard.
-- Intentionally non-transactional: concurrent index creation keeps inbound WhatsApp writes available.
create unique index concurrently if not exists whatsapp_messages_provider_message_unique
  on public.whatsapp_messages (provider, btrim(provider_message_id))
  where provider_message_id is not null and btrim(provider_message_id) <> '';

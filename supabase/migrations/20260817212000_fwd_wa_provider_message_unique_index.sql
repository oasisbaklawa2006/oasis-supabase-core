-- Forward-only replacement of supabase/migrations/20260816120100_wa_provider_message_unique_index.sql.
-- The original was merged to Core main but never applied to production
-- (tcxvcatsqqertcnycuop): its historical timestamp sits below the current
-- production ledger max (20260817211610). Confirmed genuinely absent by direct
-- catalog check (no matching index on public.whatsapp_messages). Content
-- preserved verbatim below, forward-timestamped only.

-- WA provider-message idempotency guard.
-- Intentionally non-transactional: concurrent index creation keeps inbound WhatsApp writes available.
create unique index concurrently if not exists whatsapp_messages_provider_message_unique
  on public.whatsapp_messages (provider, btrim(provider_message_id))
  where provider_message_id is not null and btrim(provider_message_id) <> '';

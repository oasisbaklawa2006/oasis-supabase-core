# Runbook — WhatsApp Webhook Health

## Purpose

Diagnose whether incoming WhatsApp messages are reaching the legacy ERP webhook and `public.whatsapp_messages`.

## Hard Rule

Do not redeploy `whatsapp-webhook` from AI Studio.

## Health Path

```txt
WhatsApp phone -> Meta/service provider -> whatsapp-webhook -> public.whatsapp_messages -> Studio bridge
```

## SQL: Latest ERP Messages

```sql
select
  id,
  direction,
  message_type,
  content,
  provider,
  provider_message_id,
  status,
  failure_reason,
  message_timestamp,
  created_at
from public.whatsapp_messages
order by message_timestamp desc nulls last
limit 20;
```

## SQL: Recent Messages

```sql
select
  id,
  direction,
  message_type,
  content,
  provider,
  provider_message_id,
  status,
  failure_reason,
  message_timestamp,
  created_at
from public.whatsapp_messages
where message_timestamp >= now() - interval '30 minutes'
order by message_timestamp desc;
```

## Interpretation

| Result | Meaning | Next Action |
|---|---|---|
| New row appears | Legacy webhook/provider is working | Test Studio bridge |
| No new row and no edge logs | Provider/Meta not hitting webhook | Check provider callback URL/subscription |
| Edge logs exist but no DB row | Legacy webhook internal failure | Inspect `whatsapp-webhook` logs |
| DB row exists but bridge sees 0 | Bridge cursor/filter issue | Check bridge cursor and row filters |

## Provider Checks

- Callback URL still points to legacy `whatsapp-webhook`.
- Verify token is accepted.
- Webhook subscription is active.
- Phone number is connected.
- Provider billing/plan/session is active.
- Message direction and message type are expected.

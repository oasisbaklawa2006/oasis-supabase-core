# Runbook — Operator Inbox Test

## Purpose

Validate the live WhatsApp Operator Inbox path.

## Preconditions

- User is logged in as `purecocoa@live.in` or another user where `is_team_member=true`.
- Bridge cursor is near current time.
- `BRIDGE_ENABLED=false` before starting.
- Fresh WhatsApp message exists in `public.whatsapp_messages`.

## Test Message

```txt
10 kg cashew pyramid
```

## SQL: Confirm Studio Inbound Row

```sql
select
  provider_message_id,
  sender_phone,
  message_body,
  resolver_status,
  resolver_result_json,
  created_at
from public.whatsapp_inbound_messages
order by created_at desc
limit 10;
```

## UI

Open:

```txt
/admin/operator-inbox
```

Expected:

- Message appears.
- Resolver card appears.
- If low confidence, alternatives appear.
- Operator can select alternative.
- Confirm creates draft.
- Draft is reviewable only.
- No live Sales Order is created.

## SQL: Confirm Operator Decision

```sql
select
  id,
  source_message_id,
  action,
  sku,
  product_name,
  confidence_band,
  whatsapp_sales_order_draft_id,
  decided_by,
  decided_at
from public.whatsapp_operator_decisions
order by decided_at desc
limit 10;
```

## SQL: Confirm Draft

```sql
select
  id,
  source,
  source_message_id,
  sender_phone,
  message_body,
  resolved_sku,
  resolved_product_name,
  confidence_band,
  operator_decision,
  status,
  quantity,
  created_by,
  created_at
from public.whatsapp_sales_order_drafts
order by created_at desc
limit 10;
```

## Expected Draft Status

```txt
UNDER_REVIEW
```

or for auto-confirmed tests:

```txt
AI_DRAFT
```

depending on operator action.

## Do Not

- Do not promote to live Sales Order.
- Do not create stock/finance/invoice/outbound WhatsApp actions from this test.

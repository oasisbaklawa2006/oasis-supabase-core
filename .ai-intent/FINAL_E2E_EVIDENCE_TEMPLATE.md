# Final E2E Evidence Template

## Purpose

Capture one fresh proof after WhatsApp webhook recovery.

## Test Metadata

| Field | Value |
|---|---|
| Test date/time | TODO |
| Tester | TODO |
| Supabase project | `tcxvcatsqqertcnycuop` |
| Bridge function | `whatsapp-studio-inbox-bridge` |
| Legacy webhook | `whatsapp-webhook` |
| Bridge mode | Manual / Scheduled |
| BRIDGE_ENABLED | false before test / true during live pull / false after test |

## Test Message

```txt
TODO: exact WhatsApp test message
```

Recommended:

```txt
10 kg cashew pyramid
```

## Evidence Step 1 — Legacy ERP Webhook Received

SQL:

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
order by message_timestamp desc
limit 20;
```

Result:

```txt
TODO
```

## Evidence Step 2 — Bridge Dry-Run Sees Row

Command:

```bash
BRIDGE_SECRET="$(cat ~/.oasis_bridge_cron_secret.txt)"

curl -X POST "https://tcxvcatsqqertcnycuop.supabase.co/functions/v1/whatsapp-studio-inbox-bridge" \
-H "Authorization: Bearer $BRIDGE_SECRET" \
-H "Content-Type: application/json" \
-d '{"dry_run":true,"limit":5}'
```

Result:

```txt
TODO
```

## Evidence Step 3 — Controlled Live Ingest

Enable temporarily:

```bash
npx supabase secrets set BRIDGE_ENABLED=true --project-ref tcxvcatsqqertcnycuop
```

Ingest:

```bash
curl -X POST "https://tcxvcatsqqertcnycuop.supabase.co/functions/v1/whatsapp-studio-inbox-bridge" \
-H "Authorization: Bearer $BRIDGE_SECRET" \
-H "Content-Type: application/json" \
-d '{"dry_run":false,"limit":5}'
```

Disable:

```bash
npx supabase secrets set BRIDGE_ENABLED=false --project-ref tcxvcatsqqertcnycuop
```

Result:

```txt
TODO
```

## Evidence Step 4 — Studio Inbound Row

SQL:

```sql
select
  provider_message_id,
  message_body,
  resolver_status,
  resolver_result_json,
  created_at
from public.whatsapp_inbound_messages
order by created_at desc
limit 5;
```

Result:

```txt
TODO
```

## Evidence Step 5 — Operator Inbox

Screenshot/notes:

```txt
TODO: message visible in /admin/operator-inbox
```

## Evidence Step 6 — Operator Decision and Draft

SQL:

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

Result:

```txt
TODO
```

## Final E2E Verdict

```txt
PASS / FAIL
```

## Notes

- No live Sales Order promotion should occur.
- No final order, stock, finance, invoice, or outbound WhatsApp reply should be created by this flow.

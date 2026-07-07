# Runbook — Bridge Cursor and Backfill

## State Table

```txt
public.whatsapp_studio_inbox_bridge_state
```

## Cursor Field

```txt
last_erp_cursor
```

## Current Policy

The cursor was intentionally moved near current time to avoid importing May/June historical backlog into the live Operator Inbox.

## Inspect Cursor

```sql
select *
from public.whatsapp_studio_inbox_bridge_state;
```

## Jump Cursor Near Current Time

```sql
update public.whatsapp_studio_inbox_bridge_state
set last_erp_cursor = now() - interval '10 minutes'
returning *;
```

## Full Backfill Strategy

Only use after explicit approval.

Steps:

1. Ensure Operator Inbox can filter resolved/failed/clarification rows.
2. Ensure test users understand old messages will appear.
3. Run bridge in controlled batches.
4. Monitor duplicates and failed rows.
5. Stop if rows_failed increases.

Example:

```bash
curl -X POST "https://tcxvcatsqqertcnycuop.supabase.co/functions/v1/whatsapp-studio-inbox-bridge" \
-H "Authorization: Bearer $BRIDGE_SECRET" \
-H "Content-Type: application/json" \
-d '{"dry_run":false,"limit":50}'
```

## Manual Current-Only Strategy

Recommended for clean live operations:

1. Keep cursor near current time.
2. Process only new WhatsApp messages.
3. Import historical rows separately later if needed.

## Warning

Do not reset cursor to 1970 unless intentionally backfilling.

# Database Ledger

## Purpose

This ledger records known production tables, their purpose, ownership, and status.

## Confirmed Tables

| Table | Owner | Purpose | Status |
|---|---|---|---|
| `public.whatsapp_messages` | Legacy ERP / Central | Raw/stored WhatsApp messages from legacy webhook | Working when provider/webhook is healthy |
| `public.whatsapp_inbound_messages` | AI Studio | Normalized bridge-ingested messages for Operator Inbox | Working |
| `public.whatsapp_operator_decisions` | AI Studio / Central boundary | Operator audit for confirm/reject/alternative | Working |
| `public.whatsapp_sales_order_drafts` | AI Studio / Central boundary | Reviewable WhatsApp draft; no live SO promotion | Working |
| `public.whatsapp_studio_inbox_bridge_state` | AI Studio | Bridge cursor state | Working |
| `public.user_role_map` | Shared auth | Maps auth users to roles | Working |
| `public.roles` | Shared auth | Role definitions | Working |
| `public.products` | AI Studio | Product master / resolver product source | Working/partly verified |
| `public.product_aliases` | AI Studio | Product alias mapping | Working after schema-compatible loader patch |
| `public.sales_order_drafts` | Central | New governance draft table from Sprint 9 | Implemented in code/staging context |
| `public.sales_order_draft_lines` | Central | Draft line items | Implemented in code/staging context |
| `public.sales_order_draft_audit_log` | Central | Append-only draft audit | Implemented in code/staging context |

## Key Confirmed Schemas

### `public.whatsapp_messages`

Important columns:

```txt
id
contact_id
direction
message_type
content
provider
provider_message_id
status
failure_reason
message_timestamp
created_at
```

Bridge reads this table with:

```txt
message_timestamp > last_erp_cursor
```

### `public.whatsapp_inbound_messages`

Important columns:

```txt
id
provider_message_id
sender_phone
sender_name
message_body
message_type
received_at
raw_payload
resolver_status
resolver_result_json
created_at
```

### `public.whatsapp_operator_decisions`

Important columns:

```txt
id
source_message_id
action
sku
product_name
confidence_band
whatsapp_sales_order_draft_id
decided_by
decided_at
```

### `public.whatsapp_sales_order_drafts`

Important columns:

```txt
id
source
source_message_id
sender_phone
customer_name
message_body
resolved_product_id
resolved_sku
resolved_product_name
confidence_band
operator_decision
status
quantity
created_by
created_at
```

### `public.product_aliases`

Production-compatible confirmed fields used by edge catalog loader:

```txt
product_id
alias_text
canonical_name
created_at
```

Do not assume these fields unless migrations add them:

```txt
alias
alias_type
is_active
```

## RLS Notes

`whatsapp_inbound_messages` SELECT policy:

```sql
is_team_member(auth.uid())
```

Access failure appears as empty inbox in UI, not necessarily SQL error.

## Current Known DB Gaps

- Resolver error columns are not present.
- Optional future columns if resolver debugging remains opaque:
  - `resolver_error_code`
  - `resolver_error_message`
  - `resolver_attempted_at`
  - `resolver_runtime_version`
- Full 62-screen table/RPC registry is not yet production-verified.
- Labelling tables are mostly backlog/not confirmed.

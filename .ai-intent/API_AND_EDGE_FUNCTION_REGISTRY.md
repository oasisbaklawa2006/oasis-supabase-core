# API and Edge Function Registry

## Purpose

This registry identifies the current and planned backend API, Edge Function, RPC, and runtime boundaries.

## Confirmed Edge Functions

| Function | Owner Repo | Purpose | Auth | Status | Critical Warning |
|---|---|---|---|---|---|
| `whatsapp-webhook` | Legacy ERP / Central | Meta WhatsApp callback receiver; writes to `public.whatsapp_messages` | Provider verify token / Meta callback | Reported restored and working | Do not deploy from AI Studio. Do not repoint Meta without approved migration. |
| `whatsapp-studio-inbox-bridge` | AI Studio | Reads ERP WhatsApp messages and writes normalized Studio rows | `BRIDGE_CRON_SECRET`; `BRIDGE_ENABLED` gate | Deployed and validated | Do not rebuild. Keep cron off until approved. |

## Confirmed Runtime / Shared Modules

| Module | Owner | Purpose | Status |
|---|---|---|---|
| `_shared/catalogLoader.ts` | AI Studio | Loads products and aliases for edge resolver | Patched for production `product_aliases` schema |
| `_shared/resolveInboundAtEdge.ts` | AI Studio | Runs resolver at edge ingest time | Working after alias schema patch |
| `_shared/runtime/resolveProductUtterance.ts` | AI Studio | Product resolver runtime | Working; clarification state validated |
| `_shared/erpInboxBridge/processErpInboundRow.ts` | AI Studio | Converts ERP WhatsApp row into Studio inbound row | Working |
| `_shared/erpInboxBridge/mapErpWhatsAppMessage.ts` | AI Studio | Maps ERP schema to Studio schema | Working |

## Confirmed DB Operation Concepts

| Operation | Owner | Purpose | Status |
|---|---|---|---|
| Insert into `whatsapp_inbound_messages` | AI Studio | Store normalized inbound message | Working |
| Create WhatsApp sales order draft | AI Studio/Central boundary | Creates reviewable draft only | Working |
| Record operator decision | AI Studio/Central boundary | Audit confirm/reject/alternative | Working |
| `public.is_team_member(uuid)` | Shared auth | RLS gate for team views | Working after role mapping |

## Future Required APIs

| Future Function/RPC | Owner | Purpose | Status |
|---|---|---|---|
| `promote_whatsapp_draft_to_sales_order` | Central | Convert approved draft to live SO through Golden Pipeline | Not built |
| `create_proforma_invoice_from_sales_order` | Central | PI generation | Not built |
| `generate_final_invoice` | Central | Billing/final invoice | Not built |
| `generate_eway_bill_payload` | Central | E-way bill data generation | Not built |
| `create_label_request` | Labelling | Trigger label creation from Central | Not built |
| `print_label_job` | Labelling | Printer bridge job | Not built |
| `gatekeeper_verify_dispatch` | Central/Labelling | Final exit verification | Not built |
| `publish_catalogue_collection` | AI Studio | Publish collection/export link | Partly built/needs verification |

## Deployment Commands

### AI Studio Bridge

```bash
npx supabase functions deploy whatsapp-studio-inbox-bridge --project-ref tcxvcatsqqertcnycuop --no-verify-jwt
```

### Secret Update

```bash
npx supabase secrets set BRIDGE_CRON_SECRET="$(cat ~/.oasis_bridge_cron_secret.txt)" BRIDGE_ENABLED=false --project-ref tcxvcatsqqertcnycuop
```

## Mandatory Pre-Deploy Checks

1. Confirm repo path.
2. Confirm function name.
3. Confirm project ref.
4. Confirm no legacy webhook redeploy.
5. Confirm secret values are not pasted into logs.
6. Confirm `BRIDGE_ENABLED=false` unless controlled live ingest is intended.

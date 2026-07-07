# Cross-Application Backlog and Final Takeover Instructions

## 1. Current Takeover Point

The system has crossed the live WhatsApp-to-draft proof path.

Confirmed:

```txt
legacy whatsapp-webhook restored
public.whatsapp_messages receives inbound messages when provider is working
whatsapp-studio-inbox-bridge deployed and working
whatsapp_inbound_messages populated
resolver_status = resolved
resolver_result_json populated
Operator Inbox visible after RLS fix
alternative selection persisted
confirm decision persisted
whatsapp_sales_order_drafts row created
```

Remaining immediate task:

```txt
Record one final fresh E2E evidence packet after webhook recovery and before scheduled polling.
```

## 2. What Not To Rebuild

Do not rebuild:

- `whatsapp-studio-inbox-bridge`
- resolver runtime foundation
- `whatsapp_inbound_messages` insertion path
- Operator Inbox visibility path
- operator decision audit path
- WhatsApp sales order draft creation path

## 3. What Is Still Not Built

- Live Sales Order promotion from WhatsApp draft.
- Golden Pipeline-backed SO creation from approved draft.
- Final invoice generation.
- E-way bill generation.
- Full Gatekeeper exit control.
- Warehouse segmentation.
- Full labelling hardware bridge.
- Full catalogue PDF variant generation.
- Full 62-screen production validation.

## 4. Bridge Mode Decision

### Current Recommended Mode

```txt
Manual development mode
BRIDGE_ENABLED=false
No cron
Controlled dry-run/live-run only
```

### Scheduled Polling Requirements

Before enabling scheduled polling:

1. Record final E2E evidence.
2. Confirm webhook is stable.
3. Confirm Operator Inbox display.
4. Confirm draft creation.
5. Confirm cursor/backlog policy.
6. Rotate dev secrets if needed.
7. Approve cron cadence.

## 5. Backlog Policy

The bridge cursor was intentionally advanced near current time.

Meaning:

- Old messages remain in `public.whatsapp_messages`.
- Old messages have not been deleted.
- Old messages have not all been imported to Studio.
- Historical backfill can be performed later in controlled batches.

Recommended for go-forward testing:

```txt
current-only live operation
```

## 6. Phase Gate

Do not move to Phase 2 dependency expansion until Phase 1 admin UI stability is validated.

Known Phase 1 cleanup reminder:

```txt
AdminFinance modal layering must be checked against AdminHelpSidebar FAB.
Expected modal tiers:
backdrop = z-[180]
content = z-[190]
```

## 7. Next Execution Order

1. Final live E2E evidence.
2. Document final bridge mode.
3. Document cursor/backlog strategy.
4. Final secret hygiene confirmation.
5. Screen registry validation.
6. API/database/access ledgers update from actual repo state.
7. Phase 1 UI closeout.
8. Phase 2 expansion:
   - draft-to-SO promotion
   - warehouse segmentation
   - finance documents
   - Gatekeeper
   - Labelling integration

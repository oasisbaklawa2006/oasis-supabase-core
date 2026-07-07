# Current System Status Ledger

## Status Summary

The WhatsApp-to-Studio path has been repaired and validated through bridge, resolver, Operator Inbox, alternative selection, operator audit, and sales order draft creation.

The legacy WhatsApp webhook is reported restored and working. A final fresh E2E evidence packet should still be captured and stored in `FINAL_E2E_EVIDENCE_TEMPLATE.md`.

## Confirmed Working

### WhatsApp Studio Inbox Bridge

Function:

```txt
whatsapp-studio-inbox-bridge
```

Project:

```txt
tcxvcatsqqertcnycuop
```

Confirmed behaviour:

- Dry-run works.
- Live ingest works.
- Cursor advances.
- Duplicate protection appears functional.
- `BRIDGE_ENABLED=false` blocks live ingestion.
- `BRIDGE_ENABLED=true` permits controlled ingestion.
- `BRIDGE_CRON_SECRET` authorization works.
- Bridge writes normalized rows into `whatsapp_inbound_messages`.
- Bridge preserves ERP metadata in `raw_payload`.
- Legacy `whatsapp-webhook` was not redeployed from AI Studio.

### Resolver

Confirmed after product alias schema patch:

```txt
resolver_status = resolved
resolver_result_json = populated
```

Validated example:

```txt
Input: Hi send 50 kg pyramid
Action: ask_clarification
Confidence band: LOW
Quantity extracted: 50
Alternatives populated
```

### Operator Inbox

Confirmed:

- RLS/team-role access fixed for `purecocoa@live.in`.
- Operator Inbox displays live bridge-ingested rows.
- Clarification alternatives are visible.
- Operator selected `Cashew Pyramid`.
- Confirm created a reviewable draft.

### Operator Decision Audit

Confirmed latest decision path:

```txt
select_alternative -> OAS-AS-BKL-0006 / Cashew Pyramid
confirm -> draft linked
```

### Sales Order Draft Creation

Confirmed latest draft:

```txt
message_body: Hi send 50 kg pyramid
resolved_sku: OAS-AS-BKL-0006
resolved_product_name: Cashew Pyramid
confidence_band: LOW
operator_decision: alternative_selected
status: UNDER_REVIEW
quantity: 50
```

### RLS / Role Access

Confirmed:

```txt
purecocoa@live.in -> is_team_member = true
admin@oasisbaklawa.com -> is_team_member = true
dinesh_mutreja@yahoo.co.in -> is_team_member = false
```

## Confirmed Not Active / Intentionally Blocked

- Scheduled bridge cron is not enabled.
- Live Sales Order promotion is not built and must remain blocked.
- Full historical WhatsApp backlog has not been imported.
- Bridge is intended to remain disabled unless testing or explicit scheduled polling is approved.

## Current Bridge Strategy

The bridge cursor was advanced near current time to avoid flooding the Operator Inbox with May/June backlog messages.

Historical WhatsApp messages remain in `public.whatsapp_messages`.

## Current Remaining Handover Work

1. Record final fresh E2E proof after webhook recovery.
2. Decide scheduled polling vs manual development mode.
3. Document final cursor/backlog policy.
4. Complete Phase 1 admin UI stability closeout.
5. Build formal promotion path from draft to live Sales Order through Golden Pipeline.

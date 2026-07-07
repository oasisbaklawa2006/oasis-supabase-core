# Final WhatsApp Studio E2E Evidence

Recorded: 2026-07-07
Supabase project: tcxvcatsqqertcnycuop
Bridge function: whatsapp-studio-inbox-bridge
Legacy webhook function: whatsapp-webhook

## Executive Result

PASS.

The recovered WhatsApp webhook is receiving fresh inbound messages into the legacy ERP table. The Studio bridge sees post-cursor ERP rows, duplicate protection works, cursor advancement works, Studio inbox rows are created, resolver execution succeeds, Operator Inbox clarification/confirmation works, operator audit is written, and WhatsApp sales order drafts are created.

## Confirmed Flow

WhatsApp message
-> legacy whatsapp-webhook
-> public.whatsapp_messages
-> whatsapp-studio-inbox-bridge
-> public.whatsapp_inbound_messages
-> resolver_result_json
-> Operator Inbox
-> public.whatsapp_operator_decisions
-> public.whatsapp_sales_order_drafts

## Legacy ERP Webhook Evidence

Fresh inbound rows were received in public.whatsapp_messages after webhook recovery.

Latest handover test message:

- ERP row id: a5475b59-1826-43d0-a3b1-3569f15564e6
- direction: inbound
- message_type: text
- content: 10 kg cashew pyramid handover test
- provider: whatsapp
- status: received
- failure_reason: null
- message_timestamp: 2026-07-07 11:58:56
- created_at: 2026-07-07 11:59:00.872947

Post-recovery order message used for draft proof:

- ERP row id: 773a21cc-0fbe-4a7a-bb0d-66a69f14a257
- direction: inbound
- message_type: text
- content: Send 10 kg cashew pyramid
- provider: whatsapp
- status: received
- message_timestamp: 2026-07-07 10:46:28
- created_at: 2026-07-07 10:46:32.075766

## Bridge Dry-Run Evidence

Manual bridge dry-run after webhook recovery:

- ok: true
- dry_run: true
- run_id: 4445dd72-eb44-48d9-9ef5-d5c44c1c041b
- cursor_before: 2026-07-06T23:50:54.1858+00:00
- rows_read: 4

Rows previewed:

- LIVE TEST 0707 WEBHOOK RESTORED
- LIVE TEST 0707 WEBHOOK RESTORED
- Send 10 kg cashew pyramid
- 10 kg cashew pyramid handover test

## Bridge State Evidence

Bridge state after controlled run:

- last_erp_cursor: 2026-07-07 11:58:56+00
- last_erp_row_id: a5475b59-1826-43d0-a3b1-3569f15564e6
- last_run_at: 2026-07-07 12:02:14.472+00
- last_run_rows_read: 4
- last_run_rows_ingested: 0
- last_run_rows_duplicate: 4
- last_run_rows_skipped: 0
- last_run_rows_failed: 0
- last_error: null

Interpretation: PASS. Rows were already present in Studio inbox, so the bridge correctly treated them as duplicates and advanced cursor without failure.

## Studio Inbox Evidence

Fresh post-recovery rows exist in public.whatsapp_inbound_messages.

Latest handover test:

- id: 07cd28bf-bf52-4476-a9eb-47d2e28deac6
- sender_phone: 919891162212
- message_body: 10 kg cashew pyramid handover test
- received_at: 2026-07-07 11:58:56+00
- resolver_status: resolved
- has_resolver_result: true
- created_at: 2026-07-07 11:59:01.518257+00
- resolver_action: ask_clarification
- confidence_band: LOW

Order message used for draft proof:

- id: d5faa97b-5279-489a-9156-7cfc5dc6cfd8
- sender_phone: 919891162212
- message_body: Send 10 kg cashew pyramid
- received_at: 2026-07-07 10:46:28+00
- resolver_status: resolved
- has_resolver_result: true
- created_at: 2026-07-07 10:46:32.206987+00
- resolver_action: ask_clarification
- confidence_band: LOW

Interpretation: ask_clarification is expected for ambiguous product-family messages such as “cashew pyramid”.

## Sales Order Draft Evidence

The post-recovery message Send 10 kg cashew pyramid was resolved through Operator Inbox and converted into a WhatsApp sales order draft.

- draft id: a5dfc472-5701-4c15-8d89-6bcfbc9309aa
- source: whatsapp_inbound
- source_message_id: d5faa97b-5279-489a-9156-7cfc5dc6cfd8
- sender_phone: 919891162212
- customer_name: Dinesh Mutreja
- message_body: Send 10 kg cashew pyramid
- resolved_product_id: da4372b9-e1b3-4b17-bdd0-278bd636ab9a
- resolved_sku: OAS-AS-BKL-0006
- resolved_product_name: Cashew Pyramid
- confidence_band: LOW
- operator_decision: alternative_selected
- status: UNDER_REVIEW
- quantity: 10
- created_by: 27b47613-8004-46c6-9fe7-6dcc6c76bb01
- created_at: 2026-07-07 10:54:21.312803+00

## Operator Decision Audit Evidence

The operator confirmation audit row exists in public.whatsapp_operator_decisions.

- audit id: 3cf2d0ce-c52a-4ad9-9aa3-c24dacce4985
- source_message_id: d5faa97b-5279-489a-9156-7cfc5dc6cfd8
- action: confirm
- sku: OAS-AS-BKL-0006
- product_name: Cashew Pyramid
- confidence_band: LOW
- whatsapp_sales_order_draft_id: a5dfc472-5701-4c15-8d89-6bcfbc9309aa
- decided_by: 27b47613-8004-46c6-9fe7-6dcc6c76bb01
- decided_at: 2026-07-07 10:54:21.312803+00

## Live Schema Corrections

- public.whatsapp_sales_order_drafts uses quantity, not order_quantity.
- public.whatsapp_operator_decisions uses decided_at, not created_at.
- public.whatsapp_operator_decisions uses action, not decision_type.
- public.whatsapp_operator_decisions uses whatsapp_sales_order_draft_id, not draft_id.

## Final Status

- Legacy WhatsApp webhook: PASS
- ERP inbound persistence: PASS
- Bridge dry-run: PASS
- Bridge controlled execution: PASS
- Bridge duplicate protection: PASS
- Bridge cursor advancement: PASS
- Studio inbox persistence: PASS
- Resolver execution: PASS
- Resolver result JSON: PASS
- Operator clarification path: PASS
- Operator decision audit: PASS
- Sales order draft creation: PASS
- Scheduled bridge polling: OFF by design
- Live Sales Order promotion: NOT BUILT by design

## Handover Decision

The system is ready for handover in manual bridge mode.

Recommended final mode:

BRIDGE_ENABLED=false

Reason: manual mode prevents accidental backlog ingestion while the next development engine takes over. Scheduled polling should be enabled only after an explicit cursor/backfill decision.

## Non-Negotiable Warning

Do not redeploy or modify whatsapp-webhook from AI Studio. That function belongs to the legacy WhatsApp/ERP callback path and is currently working.

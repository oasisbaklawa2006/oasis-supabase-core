# APP_CENTRAL_INTENT.md

# Oasis Baklawa Central System

## Current Verified Status — 2026-07-06

- `oasis-supabase-core` repository has been created and pushed.
- `oasis-supabase-core` is currently a partial backend extraction: it contains the AI Studio Supabase folder and bridge source, but live Supabase has additional legacy/Central functions not yet imported or ownership-classified.
- Supabase project: `tcxvcatsqqertcnycuop`.
- Manual deployment from `oasis-supabase-core` has been validated for `whatsapp-studio-inbox-bridge`.
- `whatsapp-studio-inbox-bridge` is ACTIVE v17.
- `BRIDGE_CRON_SECRET` has been rotated.
- Dry-run with new bridge secret succeeded.
- `BRIDGE_ENABLED=false` must remain the safe default.
- Legacy `whatsapp-webhook` remains untouched and must not be deployed casually.
- Supabase GitHub integration may point to `oasis-supabase-core`, but production auto-deploy must remain OFF until full backend reconciliation is complete.
- Latest bridge/resolver SQL verification succeeded: message `Hi send 50 kg pyramid` was ingested, `resolver_status=resolved`, `resolver_result_json` populated, `order_quantity=50`, `confidence_band=LOW`, `clarification_required=true`.
- Next technical validation: confirm Operator Inbox UI displays the resolved low-confidence/clarification row.


## 1. Core Intent

Oasis Baklawa Central is the operational, administrative, financial, warehouse, logistics, compliance, and governance backbone of the business.

Central converts customer demand into controlled execution and must prevent wrong, missing, unpaid, unapproved, or undocumented dispatches.

## 2. Core Modules

Central owns:

- Customer and buyer operations.
- Sales orders.
- Sales order drafts review.
- Proforma invoices.
- Billing/final invoice engine.
- E-way bill generation.
- Payment verification and variance handling.
- Warehouse segmentation.
- Packing & Assembly.
- Ready Goods Store.
- Third Party Goods Store.
- Dispatch planning.
- Gatekeeper exit verification.
- Internal ticket raising.
- Manager/admin approvals.
- CMD TV live monitoring.
- WhatsApp operator workflows.

## 3. Warehouse Segmentation

Central must enforce strict isolation between:

1. Packing & Assembly.
2. Ready Goods Store.
3. Third Party Goods Store.

Every stock movement must record source, destination, product, quantity, actor, timestamp, reason, and approval where required.

## 4. Financial & Document Processing

Central must control:

- SO creation.
- PI creation.
- Billing.
- Final invoice.
- E-way bill.
- Payment status.
- Payment variance.
- Credit deviation.
- Discount deviation.

Billing and dispatch must be blocked if required finance gates are not passed.

## 5. Gatekeeper System

Gatekeeper is the final exit-control system.

It must catch and halt:

- Wrong products.
- Missing products.
- Extra products.
- Unpaid orders.
- Unapproved payment variance.
- Missing invoice.
- Missing e-way bill.
- Wrong customer/address.
- Label mismatch.
- Warehouse release failure.

Gatekeeper override must be audited and manager-approved.

## 6. CMD TV Dashboard

The CMD dashboard is view-only and should show:

- Minute-by-minute order inflow.
- Live sales generation.
- Active dispatches.
- Finance holds.
- Warehouse holds.
- Gatekeeper blocks.
- Delayed dispatches.
- Department bottlenecks.

## 7. Internal Ticket System

Central must include staff error and issue triage:

- Ticket creation.
- Department routing.
- Order/product/customer linkage.
- SLA timer.
- Severity.
- Resolution.
- Closure audit.

## 8. Approvals

Approvals required for:

- Sales order exceptions.
- Payment variance.
- Discount/price override.
- Inventory adjustment.
- Warehouse correction.
- Dispatch override.
- Gatekeeper override.
- Manual order promotion.
- Expired/near-expiry movement.

## 9. WhatsApp Operator Integration

Current architecture:

1. Legacy `whatsapp-webhook` receives Meta traffic.
2. ERP stores messages.
3. `whatsapp-studio-inbox-bridge` reads ERP rows.
4. Bridge writes `whatsapp_inbound_messages`.
5. Resolver produces product/quantity interpretation.
6. Operator Inbox reviews.
7. Sales order draft can be created.
8. Draft readiness gates must pass.
9. Live SO promotion remains a separate governed step.

## 10. Current Central Backlog

- Full warehouse segmentation.
- Gatekeeper exit control.
- Complete financial document engine.
- CMD dashboard.
- Internal ticket system.
- Draft-to-live SO promotion through Golden Pipeline.
- Phase 1 UI stability closeout before Phase 2 expansion.

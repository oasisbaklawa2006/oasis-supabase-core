# APP_LABELLING_INTENT.md

# Oasis Labelling / Trace System

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

Oasis Trace/Labelling is the physical tracking, barcode, sticker, printer, batch, packaging, store-transfer, dispatch, and Gatekeeper label backbone.

It bridges digital product/order truth with physical product movement.

## 2. Owned Domains

Labelling owns:

- Barcode generation.
- Tracking identifiers.
- Label templates.
- Printer-compatible layouts.
- Label queue.
- Batch labels.
- Processing-stage labels.
- Assembly labels.
- Packaging labels.
- Store transit labels.
- Dispatch labels.
- Gatekeeper scan labels.
- Reprint audit.

Labelling does not own product truth or order truth. It consumes approved data from AI Studio and Central.

## 3. Inputs From AI Studio

- Product ID.
- SKU.
- Product name.
- Net weight.
- Gross weight.
- Pack size.
- Ingredients.
- Allergens.
- Nutrition data.
- FSSAI block.
- Legal metrology fields.
- Storage condition.
- Shelf life.
- Export fields.
- Approved label dataset version.

## 4. Inputs From Central

- Sales order.
- Order line.
- Product allocation.
- Batch/lot.
- Warehouse segment.
- Packing task.
- Dispatch ID.
- Gatekeeper requirement.
- Invoice/e-way bill context.
- Customer/address/transport details.

## 5. Label Types

- Product master label.
- Batch label.
- Processing-stage label.
- Assembly-stage label.
- Packing-stage label.
- Ready Goods Store label.
- Third Party Goods label.
- Store transfer label.
- Order allocation label.
- Dispatch carton label.
- Export carton label.
- Gatekeeper verification label.
- Reprint label.

## 6. Hardware and Formats

Support should include:

- Thermal barcode printers.
- Sticker printers.
- PDF fallback.
- HTML print fallback.
- ZPL/EPL/TSPL where needed.
- QR and barcode output.
- Template versioning.

## 7. Governance

No label may print from draft product data.

Reprints must require:

- Original label reference.
- Reason.
- Requesting user.
- Approval where required.
- Reprint count.
- Audit log.

## 8. Current Labelling Backlog

- Create dedicated `oasis-trace` repo if not already active.
- Inject full `.ai-intent/`.
- Build template registry.
- Build label queue.
- Build printer compatibility layer.
- Build Central and AI Studio data pulls.
- Build Gatekeeper label scan integration.

# APP_AI_STUDIO_INTENT.md

# Oasis AI Studio System

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

Oasis AI Studio is the catalogue generation, product intelligence, media processing, compliance dataset, resolver, and catalogue-distribution engine.

It converts basic mobile product inputs into approved catalogue truth.

## 2. Owned Domains

AI Studio owns:

- Product master editing.
- Product media.
- Hero images.
- Product aliases.
- Product resolver runtime.
- Product feature extraction.
- Product descriptions/copy.
- Packaging metadata.
- Legal metrology fields.
- FSSAI label datasets.
- Retail/wholesale/export catalogue variants.
- WhatsApp-ready PDFs.
- Catalogue publication state.

AI Studio does not own dispatch, finance, invoice, or warehouse execution.

## 3. Mobile Photo to Hero Asset Pipeline

Required stages:

1. Raw photo upload.
2. Product association.
3. Quality check.
4. Background cleanup.
5. Lighting correction.
6. Hero image generation.
7. Square catalogue image generation.
8. Close-up image generation.
9. Packaging/lifestyle variants where approved.
10. Human review.
11. Approval.
12. Publication.

Generated images must preserve real product texture, shape, count, colour, packaging design, and visual truth.

## 4. Product Intelligence

AI Studio must manage:

- Product ID.
- SKU.
- Product name.
- Category/subcategory.
- Product family.
- Piece weight.
- Pieces per kg.
- Pack size.
- Storage condition.
- Shelf life.
- Ingredients.
- Allergens.
- Legal fields.
- Export fields.
- Alias vocabulary.
- Resolver data.

## 5. Compliance & Label Data

AI Studio must generate structured datasets for:

- FSSAI fields.
- Nutrition panel.
- Legal metrology.
- Net/gross weight.
- Batch/lot placeholders.
- Shelf life.
- Storage condition.
- Allergen declaration.
- Export label variants.

Compliance data must remain reviewable and versioned.

## 6. Distribution Layer

AI Studio must generate:

- Dynamic frontend catalogue data.
- Public catalogue collections.
- Retail PDF.
- Wholesale PDF.
- Export PDF.
- WhatsApp product cards.
- WhatsApp catalogue PDFs.
- Resolver runtime exports.

## 7. WhatsApp Resolver

The resolver maps unstructured text to catalogue product candidates and quantity.

Current verified example:

- Input: `Hi send 50 kg pyramid`
- Quantity: `50`
- Status: `resolved`
- Confidence band: `LOW`
- Result: clarification required due multiple pyramid products.
- `resolver_result_json` populated.

## 8. Current AI Studio Backlog

- Operator Inbox UI visibility validation for bridge-ingested rows.
- Show failed/low-confidence/unresolved rows instead of hiding them.
- Add diagnostic filters: All / Resolved / Failed / Pending / Needs Clarification.
- Complete catalogue publication hardening.
- Complete PDF variants.
- Complete compliance dataset approval flow.
- Do not enable bridge cron until UI validation passes.

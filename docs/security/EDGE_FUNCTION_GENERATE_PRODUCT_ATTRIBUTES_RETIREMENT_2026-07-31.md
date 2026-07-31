# `generate-product-attributes` Retirement Record

Date: 2026-07-31
Procedure: Edge Function remediation 3 of 8

## Decision

The function is retired rather than rebuilt.

The previous implementation returned fixed GST/HSN, shelf-life, allergen, ingredient and nutrition suggestions from minimal product-name matching. Those outputs were not backed by approved product master data, recipe records, laboratory evidence or authorized tax review. The production function was also configured without platform JWT verification and had live-to-repository drift.

## Repository disposition

The canonical repository source is now a fail-closed tombstone:

- every request returns HTTP `410 Gone`;
- no product, tax, ingredient, allergen, nutrition or shelf-life suggestion is produced;
- no CORS access is granted;
- no secret, database or external provider is used;
- the replacement route is identified as the authenticated `catalogue-ai-copy` workflow, which must use verified operator-supplied facts and human review.

## Deployment control

This function remains excluded from `supabase/config.toml` and all preview deployment paths. Deployment or deletion of the live version requires a dedicated production change with runtime verification. Broad Edge Function deployment remains prohibited.

## Closure

Procedure 3 repository remediation is complete when this tombstone, retirement record and governance checks are merged. Production runtime retirement remains part of final controlled runtime certification and must not be inferred from repository state alone.

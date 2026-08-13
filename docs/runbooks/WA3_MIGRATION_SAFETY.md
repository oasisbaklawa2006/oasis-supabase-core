# WA-3 migration safety and recovery

Migration `20260813170000_wa3_clarification_failsafe.sql` follows Core's forward-only migration policy. It is validated by a clean zero-state replay and rollback-only pgTAP fixtures; it must not be reversed with an improvised destructive down-migration.

## Existing-data compatibility

- New `potential_order_id` linkage is nullable, so existing generic Sales Order Draft rows remain valid.
- Existing generic drafts without a potential-order link retain their canonical readiness and promotion RPC behavior.
- Only drafts explicitly linked to `whatsapp_potential_orders` receive the additional WA-3 field-readiness gate.
- Existing WhatsApp quantity values are retained. Only the executable default is removed; future unknown quantities must remain null/unresolved.
- New evidence, resolution and clarification tables do not rewrite existing source records.

## Deployment and recovery

Before an approved deployment, record a database recovery point and migration owner. Apply through the repository's approval-gated migration workflow, then verify migration history, RLS/grants, clarification reconciliation and draft promotion contracts.

If application behavior must be withdrawn, first disable WA-3 application exposure while preserving captured evidence. If a schema defect is discovered, restore from the confirmed recovery point or ship a reviewed forward-only corrective migration. Do not drop evidence/audit tables or remove immutable lineage as a rollback shortcut.

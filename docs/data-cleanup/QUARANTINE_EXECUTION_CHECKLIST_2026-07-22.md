# Quarantine execution checklist — 2026-07-22

This checklist gates any production cleanup execution.

## Preconditions

- [ ] Run `supabase/verification/20260722_cleanup_candidate_verification.sql`.
- [ ] Confirm expected counts remain stable or explain drift.
- [ ] Export candidate IDs and row snapshots outside the database.
- [ ] Confirm no open deployment or migration is modifying products, orders, or auth users.
- [ ] Review the product readiness rule, including mandatory image and usable selling price.
- [ ] Confirm all retained administrators and service accounts are excluded from user candidates.

## Quarantine tranche

- [ ] Apply only the snapshot-and-quarantine migration.
- [ ] Verify candidate product rows exist in `cleanup_archive.product_snapshot_20260722`.
- [ ] Verify quarantined products are `is_active = false` and `visible_in_catalog = false`.
- [ ] Verify order candidates were snapshotted but not status-mutated.
- [ ] Verify auth-user candidates were snapshotted but not deleted or disabled.

## Post-quarantine validation

- [ ] Product catalogue count and customer projection match the retained set.
- [ ] AI Studio can still read retained products and associated media.
- [ ] Central order, finance, and approval pages load without foreign-key errors.
- [ ] Trace scans, production jobs, inventory, and packing references remain intact.
- [ ] No retained order references a quarantined product unexpectedly.
- [ ] No retained user lost required role or membership access.

## Hard-delete gate

Hard deletion must be a separate migration and may include only records with zero operational, finance, Trace, catalogue, approval, and audit dependencies. It must include a rollback or documented restore procedure using the archive snapshots.

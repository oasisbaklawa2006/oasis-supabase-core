# MACRO INVENTORY + FACTORY RUNTIME MISSION

Authority: Central #554 Leap 4. Base Core main 11a0a709640082023a0f647c5b0557b0b4906b6e.

This is a substantive Core implementation tranche, not an audit-only PR. Reuse existing deployed Points82–90 authority and useful code/evidence from open Core #243/#248/#250-family work. Do not duplicate stock truth.

Deliver canonical backend runtime for:
1. inventory command facts and cross-store isolation
2. reservation concurrency/idempotency and shortage derivation
3. canonical lot/batch position authority with bin/rack/shelf binding
4. expiry/mfg/best-before lineage where authoritative data exists
5. deterministic FEFO/FIFO candidate selection with fail-closed exclusion of quarantine/damaged/expired stock
6. atomic lot allocation to reservations with advisory locking/idempotency
7. put-away/GRN posting to lot positions and aggregate balance reconciliation
8. production department queues and shortage demands
9. production start/pause/complete, targets/allocation, wastage/rejection/shortage/blocker/QH
10. RGS/3PGS/P&A transfer/acceptance boundaries without parallel stock ledgers
11. server contracts/tests that Central can bind to directly.

IMPORTANT SERIALIZATION: Finance macro Core #255 is concurrently active. Build in parallel, but do not merge before #255 production release/verification if this tranche includes migrations. Census all open migration timestamps before assigning final timestamps; rebase/retimestamp once at merge boundary, not repeatedly. Multiple logically related contiguous migrations in this one PR are acceptable.

Exit only when full clean replay/pgTAP/schema governance/scanners are green and runtime semantics are complete. Do not stop at documenting gaps.

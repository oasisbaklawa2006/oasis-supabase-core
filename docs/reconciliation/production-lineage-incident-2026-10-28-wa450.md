# Production lineage incident — WA-450 D3/D4 generated ledger versions

-- production-lineage-incident-approved: WA-450 production preflight reconciliation for authorized D3/D4 direct applies; source SQL and migration history remain unchanged.

## Scope

The authorized direct Supabase applies for the merged WA-450 D3 and D4 migrations were recorded by Supabase with generated ledger versions `20261028055454` and `20261028055458`. The canonical source files remain `20261027120000_wa450_d3_governed_customer_identity_anchor.sql` and `20261027130000_wa450_d4_order_correction_ambiguity_gate.sql`.

## Evidence

- D3 source `20261027120000` maps to production ledger version `20261028055454`.
- D4 source `20261027130000` maps to production ledger version `20261028055458`.
- The two generated versions are recorded in the remote-history ledger as direct authorized applies.
- The two canonical versions are recorded as `represented_remote` in the canonical-lineage ledger.
- No migration SQL, schema, data, or production state is changed by this reconciliation; it only records the source-to-ledger mapping required by the protected preflight.

## Release boundary

This incident record authorizes reconciliation of these two already-applied WA-450 versions only. It does not authorize unrelated migrations, preview changes, branch deletion, or deployment bypasses.

# Macro Finance Runtime Authority

This branch is the single Core implementation tranche for the Finance-control runtime gaps that block end-to-end Appverse completion.

It must reuse existing canonical Core authority rather than duplicate it, including credit exposure, payment/final-invoice facts, commercial adjustments, complaint remedies, finance-exit facts, wallet/credit and dispatch-clearance authority.

The tranche must deliver the remaining governed operational surfaces needed by Central Finance: company AR ageing, portfolio exposure, governed ledger-dispute raise/resolve, reusable credit/debit-note and refund authority where not already exposed by existing commercial-adjustment contracts, and the hold/release/reversal/second-approval contracts required by the Finance control UI.

All writes must be auditable, role/AAL2 governed where appropriate, idempotent, tenant-safe, and compatible with existing commercial/dispatch authority. No shadow ledgers, no duplicate monetary truth, no direct client table mutation.

Core migration serialization and protected production-release rules remain mandatory. Original Points 77–81 are traceability IDs; this tranche is judged by the complete Finance user journey rather than PR count.

## Delivered migrations

| Timestamp | Scope |
|-----------|--------|
| `20260907140000` | Points 77–81: AR ageing, portfolio exposure, ledger disputes, holds/releases/second approval, finance adjustments, Central projection |
| `20260907141000` | Annex A1: provider-neutral payment gateway payable intents, webhook evidence, canonical `order_payments` settlement |
| `20260907142000` | Annex A2: bank/settlement import, deterministic auto-match, reconciliation queue, Tally-compatible projection |

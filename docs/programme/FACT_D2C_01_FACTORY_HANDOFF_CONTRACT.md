# FACT-D2C-01 — Core retail factory handoff contract (proposal only)

**Status:** design-only, not deployed, not approved as runtime contract. Cross-reference Central [#685](https://github.com/oasisbaklawa2006/Oasis-Baklawa-Central/issues/685), [draft #686](https://github.com/oasisbaklawa2006/Oasis-Baklawa-Central/pull/686), Gifting #2, Core #561/#562.

## Existing authority to preserve

- Core retail order/guest identity/quote/payment contracts in Core #562; do not duplicate `retail_orders`, `retail_customers`, `retail_payment_intents` or payment event tables.
- Core #561 commerce settings remain fail-closed. Checkout is not approved for production. A payment intent, client receipt, quote reservation window or even a paid order **does not** attest physical inventory reservation.
- Existing Core RGS/3PGS/Production/P&A and Trace custody are authoritative. No B2B wholesale fulfilment route for a retail order, no fabricated B2B company or invoice, no direct browser stock mutation.

## Proposed authoritative input and output

Core-only service RPC/transaction (name provisional): `retail_factory_intake_request_v1(retail_order_id, expected_order_version, idempotency_key)`. Must be invoked by a scoped backend principal, not a website browser, and must reject anonymous, stale, cross-customer, or unauthorized calls. It returns a **status receipt**, not an immediate promise of shipment.

Receipt fields: `retail_order_id`, `order_version`, `intake_id`, `intake_status` (HOLD / READY_FOR_PLANNING / ACCEPTED_FOR_EXECUTION), `reason_code`, `payment_evidence_ref`, `stock_allocation_evidence_ref`, `planning_evidence_ref`, `dispatch_sla_evidence_ref`, `source='D2C_RETAIL'`, `created_at`, `last_transition_at`. Sensitive customer and recipient details must be role-scoped and not copied into audit/log text.

No status can advance to ACCEPTED_FOR_EXECUTION without: current accepted immutable order/version; verified and amount-matched prepaid payment (or **future** separately approved COD authority); approved and serviceable shipping/promise policy; real atomic stock allocation or governed shortage/production dependency; and authorized Core inventory/P&A custody contract.

## Required invariants

1. Unique business key `(retail_order_id, order_version, operation)`; repeated requests and webhook replays return the original receipt without creating new stock claims/jobs.
2. Serialized/concurrent requests cannot oversell the same lot/quantity. Reservation must be atomic and expiring/releasable under explicit approved policy. A *reservation window field* alone is not stock reservation.
3. Order changes, cancellation/refund, late payment and partial fulfilment are versioned; do not silently delete previous receipt. Any prior claims are reconciled before replan. Customer cancellation rules remain business-policy blocked.
4. One source of truth for available, allocated, QC-held, rejected, in-transit, assembled and dispatched quantities. Never decrement stock from the Central client.
5. Source channel does not confer urgency; priority derives from server-backed courier cutoff, promised dispatch date and exceptions. Unknown SLA remains UNKNOWN.
6. Retail demand route: ready retail stock → pick/pack; P&A-required → existing assembly engine; production shortage → existing RGS/production/accepted receipt → P&A. Food/components may flow RGS/3PGS to P&A without turning the order into wholesale RGS fulfilment.
7. Finance auto-release is limited to *independently verified prepaid* and approved policy; COD remains HOLD pending owner decision.
8. Gate release remains independent of retail payment, courier label and Dispatch status. No 'dispatched' status before gate custody.
9. All state changes record actor/service identity, idempotency key, previous/new state, order version, evidence refs and timestamp; append-only audit.
10. Tenant/customer PII isolation, privilege checks and negative tests are required for every entry point. No retail token may be accepted as B2B identity.

## Required tests before runtime implementation

| Test | Expected result |
| --- | --- |
| Prepaid, matched webhook, approved stock | Single planning receipt; never implicit dispatch |
| Payment pending/failed, forged 'paid' client flag | HOLD; zero stock or job changes |
| Same event replayed / two concurrent workers | One intake and one allocation |
| Insufficient or QC-blocked stock | HOLD or governed shortage demand; no oversell |
| P&A components unavailable | 3PGS/RGS shortage; no fabricated stock |
| COD without approved policy | HOLD |
| Expired quote or changed order version | Reject stale request; reconcile old claim |
| Late payment after reservation expiry | Hold for revalidation; no stale allocation |
| Partial shipment and subsequent retry | Accurate residuals; no duplicate parcel |
| Gate denied / offline scan / rejected QC | Not dispatched; auditable recovery |
| Unauthorized consumer / B2B principal / cross-tenant | Denied with no data leak |
| B2B standard golden order | Identical behavior to current main |

## Implementation dependency gate

Before writing a migration or RPC: reconcile **current main and open Core #561/#562** (including their dependency/merge status), locate canonical stock allocation and assembly authority, and verify Core migration chronology. Do not create parallel retail checkout tables, fake stock allocation evidence, or an alternative dispatch ledger. If no compatible inventory contract exists, propose the minimum forward-only Core extension in a *separate* reviewed PR with pgTAP and race tests. Central and Gifting remain consumers of Core receipts.

## Certification boundary

This document proves only the design checkpoint. It does **not** establish a merged Core migration, actual stock reservation, a live retail factory order, a successful payment-provider sandbox test, or physical scanner/gate UAT. Production activation and protected merges require their separate approvals.

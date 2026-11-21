# FACT-D2C-01 — Core source/schema reconciliation and implementation gate

**21 Nov 2026.** This is a read-only source audit. It does not certify deployment or create a factory transaction.

## Verified default-branch schema

Source: `supabase/migrations/20261119200000_retail_orders_identity_payments_v1.sql`.

| Field/table | Verified meaning | Factory consequence |
| --- | --- | --- |
| `retail_orders.id` | UUID retail order identity | Retain; never map to B2B order id |
| `retail_orders.customer_id` | Retail customer identity, separate from B2B company | No B2B account/credit impersonation |
| `retail_orders.quote_id` | Unique quote reference | Preserve commercial version/snapshot |
| `retail_orders.idempotency_key` | Unique per customer | Existing order creation idempotency is **not** factory-intake idempotency |
| `retail_orders.status` | `pending_payment`, `paid`, `cancelled` | No built-in factory-accepted state |
| `retail_orders.snapshot` | JSONB commercial snapshot | Inspect/validate exact SKU, quantities, delivery and gift details before contract mapping; do not guess structure |
| `retail_orders.reservation_expires_at` | Timestamp for a *reservation window* | Does **not** prove physical allocation |
| `retail_orders.stock_reservation_enforced` | CHECK constrained to `false` | Cannot legally set true without reviewed forward-only migration |
| `retail_orders.paid_after_reservation_expiry` | Explicit late-payment indicator | Force revalidation before allocation |
| `retail_payment_intents` | Provider association, amount/currency, captured state | Verify amount and event lineage; do not trust UI paid flag |
| `retail_payment_events` | Append-only, provider-event-id unique, recorded outcomes including mismatch | Only validated applied events can contribute to payment evidence; not sufficient alone for stock |
| `retail_serviceable_pincodes`, `retail_shipping_fee_slabs` | Configuration tables | No invented PIN/rate/dispatch promise |
| `retail_customers`, `retail_sessions` | Phone-verified retail identity | Customer and recipient PII role separation |

**Existing retail checkout source**: `supabase/functions/_shared/retailCheckout.ts`, `supabase/functions/retail-checkout`, and `supabase/functions/razorpay-webhook`. Existing tests: `supabase/tests/retail_orders_identity_payments_v1.test.sql` and `scripts/uat/retail-checkout-local-sandbox-e2e.ts`. Reuse them.

## Confirmed missing *contract*, not necessarily a production incident

1. No proven Core factory intake receipt / status attached to `retail_orders` in the inspected migration.
2. No physical inventory allocation enforced by that migration. An expiry timestamp is not a claim.
3. No authoritative `order_version` field in `retail_orders`; factory contract must define a durable version/fingerprint from immutable accepted snapshot or a governed version table.
4. No confirmed retail parcel dispatch and gate custody contract in the inspected retail migration.
5. Core #561 and #562 are closed, but **closed alone does not establish merged/deployed status**. Verify merge SHA, migration ledger and preview before relying on them.

## Required minimum Core implementation, in safe order

**Gate 1 — read projection (nonmutating):** Design a service-authorized, fail-closed readiness query from the existing retail order and verified payment evidence. Return `HOLD` when payment, shipping/serviceability, source snapshot, reservation or policy evidence is missing. It must never return `STOCK_ALLOCATED` merely because `status='paid'`.

**Gate 2 — inventory authority:** Locate the existing Core lot-level inventory reservation and release mechanism, its role/custody model and concurrent locking semantics. Reuse it if compatible; otherwise propose the smallest forward-only allocation extension, with tests for concurrent buyers, expired reservation, QC holds and rollback.

**Gate 3 — durable exactly-once intake:** Append-only event/receipt with unique `(retail_order_id, version, operation)`, replays returning original result. No P&A job creation until real stock or governed shortage proof exists.

**Gate 4 — existing factory routing:** Central Order Pool reads a Core projection; P&A and RGS/3PGS continue using existing authorities; retail parcel/gate contracts reviewed separately. No B2B dispatch mutations reused by assumption.

**Gate 5 — hosted UAT and physical certification:** Real provider sandbox, printer/scanner/gate acceptance, payment exceptions and B2B golden-order regressions.

## Non-negotiable regression cases

- Forged `paid` browser flag, mismatched Razorpay amount, late paid event: HOLD.
- Two simultaneous prepaid retail orders for the last available lot: at most one valid allocation.
- Same event replay / two workers: one receipt and one downstream job.
- Cancelled/changed retail order: no stale job; allocated stock reconciled.
- Missing serviceable PIN/rate/SLA: no fabricated shipping promise.
- COD: HOLD until explicit owner-approved policy.
- B2B existing order-to-gate: unchanged.
- Cross-customer or B2B principal: no retail PII leakage or mutation.

**Release posture:** NO-GO. This file is a schema-derived checkpoint, not an implementation of Gates 1–5. No migrations or functions changed.

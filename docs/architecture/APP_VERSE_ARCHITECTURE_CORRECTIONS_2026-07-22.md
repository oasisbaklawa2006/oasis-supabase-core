# Oasis App-Verse Architecture Corrections — 2026-07-22

Status: Authoritative correction record for PR #6

This document supersedes conflicting statements in the draft architecture baseline until those documents are consolidated. It records decisions validated against the live Supabase schema and the customer application implementation.

## 1. Operational lifecycle is not generic ecommerce

The canonical execution path is:

Product
→ Published Offer
→ Buyer / Company
→ Order
→ Order Line
→ Commercial / Finance Release
→ Production Requirement
→ Production
→ Assembly
→ Packing
→ Packed Ready
→ Dispatch Readiness
→ Dispatch / Gate Exit
→ Delivery / Closure

Assembly and Packing are separate operational boundaries.

- Assembly confirms required product components or order composition are brought together.
- Packing is the controlled floor process that places approved order-line quantities into physical packaging/cartons.
- Packed Ready means packing is complete and customer-safe packed quantities may be exposed.
- Dispatch readiness and physical dispatch remain separate states.

No future agent or implementation may collapse Assembly, Packing, Packed Ready and Dispatch into one generic fulfilment state.

## 2. Physical packing identity paths

`public.packing_lists` does not contain `order_id`.

Valid order lineage is resolved through either:

- `packing_lists.dispatch_id → dispatches.order_id`, or
- `packing_lists.order_item_id → order_items.order_id`.

Cleanup and dependency audits must check both paths.

The 2026-07-22 archived-order verification returned zero linked packing rows through both paths. No restoration was required.

## 3. Support-ticket lifecycle is part of the business spine

Customer and operational exceptions must not be modelled only as notes or WhatsApp messages.

Canonical support lifecycle:

Ticket Raised
→ Classified
→ Assigned
→ Acknowledged
→ Investigation / Action
→ Waiting on Customer or Internal Team
→ Resolved
→ Confirmed / Reopened
→ Closed

Ticket identity, ownership, status history, SLA timestamps, linked customer/company/order/product/dispatch references and audit evidence are governed data.

The Customer App may create and read customer-safe ticket projections. Central owns operational triage and resolution. Supabase Core owns canonical schema, RLS and governed commands. Trace may contribute physical evidence but does not own ticket truth.

## 4. Command and realtime telemetry

Command dashboards and TV boards are first-class operational consumers.

`cmd_realtime_telemetry_view` or its governed successor belongs in the operational read-model registry. It must provide a safe, derived command picture rather than allowing dashboards to query broad operational tables independently.

Required telemetry families include:

- order and approval queues;
- production requirement and execution state;
- assembly and packing progress;
- packed-ready and dispatch-readiness queues;
- scan, handover and gate exceptions;
- unresolved tickets and SLA risk;
- WhatsApp accountability / zero-loss signals;
- cross-department blockers and stale-work alerts.

Telemetry is a projection. It must never become an independent writable source of operational truth.

## 5. Product publication authority is staged

Target authority:

- AI Studio owns product editorial content, media workflow and publication approval.
- Central owns commercial eligibility and operational availability.
- Supabase Core owns the governed publication contract.

Current production reality:

- `published_products_v1()` uses operational publication flags.
- 9 products are currently published.
- 0 of those 9 currently have an approved `catalogue_ai_studio_drafts` row.

Therefore a mandatory AI Studio `INNER JOIN` is prohibited today because it would remove the entire public catalogue.

Migration rule:

1. Approved AI Studio content is preferred when available.
2. Legacy approved product content remains an explicit fallback during migration.
3. Coverage and parity must be measured.
4. Mandatory AI approval may be enforced only after an agreed coverage threshold and rollback plan.

## 6. RC-03 is implemented as a composition, not one oversized payload

The original RC-03 specification described a monolithic order-status payload with nested line summaries.

The accepted v1 implementation is split into:

- `customer_order_status_v1()` — order-level customer-safe progress, payment stage, dates and post-dispatch tracking;
- `customer_order_items_v1()` — company-isolated order-line identity, ordered quantity, pack/weight information and packed quantity only after Packed Ready.

The Customer App composes these two governed contracts.

This is an intentional CQRS/read-model decision, not an implementation defect.

Fields such as `statusMessage`, `nextExpectedStep`, `dispatchedAt`, `deliveredAt`, customer-action flags and Trace-derived delivery evidence remain future additive contract work. They must not be fabricated from unavailable data.

## 7. Customer-safe packed quantity rule

`actual_packed_qty` must remain hidden while an order is `assembled` or `packing`.

It may be exposed only when order status is:

- `packed_ready`;
- `cleared_for_dispatch`;
- `dispatched`.

This prevents customers treating fluctuating floor scans as a completed fulfilment commitment.

## 8. Buyer pricing contract includes purchase constraints

`buyer_product_prices_v1()` now includes:

- minimum order quantity;
- minimum order UOM;
- order increment;
- order increment UOM.

Precedence:

1. latest applicable B2B `product_moq_rules` row;
2. product-level MOQ/increment fields;
3. legacy product MOQ fields;
4. safe increment fallback of 1 where no governed increment exists.

Displayed pricing and constraints remain informational. A future order-submission command must revalidate price, MOQ and increment atomically.

## 9. Authentication cleanup safety

Future user quarantine or deletion candidates must include an account-age guard:

```sql
auth.users.created_at < now() - interval '24 hours'
```

The guard protects incomplete OTP, email-confirmation, Google, Apple, WhatsApp/msg91 and other multi-stage registrations.

The 2026-07-22 archived-user verification found zero users created inside the preceding 24-hour risk window.

## 10. Governed read-model registry

Current customer contracts:

- `published_products_v1()`
- `buyer_product_prices_v1()`
- `customer_order_status_v1()`
- `customer_order_items_v1()`

Required operational/customer contracts still to be designed include:

- public/tokenized tracking;
- customer support tickets;
- order submission and validation;
- delivery/closure evidence;
- dispatch readiness;
- inventory availability;
- command realtime telemetry.

All new consumers must use governed projections, RPCs or server endpoints and must not query raw operational tables from browser code.
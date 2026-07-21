# Oasis Customer Contract Registry

Status: Active architecture registry

This registry prevents deployed customer clients from depending on raw tables or silently changing payloads.

## Versioning rules

1. Contract names carry a major version suffix, for example `_v1`.
2. Existing output columns are not removed, renamed or given incompatible types within the same major version.
3. Additive nullable fields may be introduced only with updated contract tests and consumer compatibility evidence.
4. Authorization may become stricter within a major version; it must never become broader without explicit security review.
5. A new major version is required for incompatible shape, meaning or authorization changes.
6. Deprecated contracts remain available until all known consumers migrate and an announced retirement gate is satisfied.
7. Every contract records owner, consumers, authorization, source authority, production state and replacement path.

## Active contracts

| Contract | Major | State | Primary owner | Consumers | Authorization | Purpose |
|---|---:|---|---|---|---|---|
| `published_products_v1()` | 1 | Production | Supabase Core contract; AI Studio editorial target authority | Customer App | Anonymous and authenticated governed execution | Public customer-safe catalogue |
| `buyer_product_prices_v1()` | 1 | Production | Central commercial rules through Supabase Core | Customer App | Approved authenticated buyer linked to active/non-frozen company | Buyer selling price, tax, MOQ and increment |
| `customer_order_status_v1()` | 1 | Production | Central order truth through Supabase Core | Customer App | Approved authenticated buyer; own company only | Order-level customer-safe progress |
| `customer_order_items_v1()` | 1 | Production | Central order-line truth through Supabase Core | Customer App | Approved authenticated buyer; own company only | Customer-safe order details and post-packing quantity |

## Contract composition decisions

### Customer order workspace v1

The customer order workspace is composed from:

- `customer_order_status_v1()`
- `customer_order_items_v1()`

The split is intentional. It avoids a large nested status payload, permits independent testing and keeps order summary reads separate from order-line detail reads.

## Known v1 limitations

### Published products

- Runtime publication still depends on operational flags.
- Approved AI Studio editorial coverage is not yet sufficient for mandatory enforcement.
- Editorial-source migration must preserve legacy fallback until measured parity.

### Buyer pricing

- Only positive approved B2B price rows are returned.
- Missing or zero prices are excluded rather than represented as `approval_required` or `temporarily_unavailable` statuses.
- Order submission must revalidate price, MOQ and increment.

### Order status

- Delivery evidence is not yet available in the projection.
- Customer-safe narrative messages and next-step guidance are not yet governed fields.
- Tracking appears only after dispatch.

### Order items

- Reliable line-price snapshots are not present in the current source table and are not fabricated.
- Packed quantity is hidden until `packed_ready`, `cleared_for_dispatch` or `dispatched`.

## Planned contracts

| Candidate | Intended purpose | Gate before implementation |
|---|---|---|
| `public_tracking_v1` | Tokenized narrow shipment tracking | Trace evidence, anti-enumeration design and expiry rules |
| `customer_support_tickets_v1` | Customer-owned ticket list/detail | Canonical ticket lifecycle and RLS ownership |
| `submit_customer_order_v1` | Governed order-intent submission | Atomic price/MOQ/increment revalidation and idempotency |
| `customer_delivery_status_v1` | Delivery/closure evidence | Canonical delivery evidence and partial-delivery semantics |
| `dispatch_readiness_v1` | Safe operational dispatch queue | Central/Trace ownership reconciliation |
| `inventory_availability_v1` | Customer-safe availability signal | Reservation semantics and anti-oversell rules |
| `cmd_realtime_telemetry_v1` | Command/TV operational telemetry | Metrics ownership, freshness SLA and restricted-field review |

## Deprecation procedure

A contract may be deprecated only when:

- replacement contract exists and is production-validated;
- all repository consumers are inventoried;
- migration instructions are published;
- telemetry shows no remaining production calls for the agreed observation window;
- rollback is documented;
- removal occurs through a reviewed forward migration.

## Prohibited consumer behavior

Customer browser code must not:

- query raw product, pricing, profile, company, order, order-item, payment, dispatch, packing or Trace tables;
- use service-role credentials;
- supply arbitrary company/user IDs to obtain another buyer's data;
- infer unavailable values or silently fall back to draft/internal tables;
- depend on undocumented columns beyond this registry.
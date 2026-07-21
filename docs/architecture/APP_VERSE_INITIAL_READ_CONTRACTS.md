# Oasis App-Verse Initial Read Contracts

Status: Draft, non-executable contract specification

These are the first three cross-application read contracts required to build the Customer App beside Central without stretching or mutating the current operational system.

They define consumer-safe outputs only. No view, function, API, migration, grant, policy or generated type is created by this document.

## Contract rules

1. Consumers receive only fields needed for their experience.
2. Internal operational columns are not exposed merely because they exist.
3. Contract outputs are stable and versioned independently from internal table layouts.
4. Every contract applies canonical RLS or explicit server-side authorization.
5. Null and unavailable states are explicit; frontends must not invent values.
6. Read models never grant write authority.
7. Monetary values include currency and effective context.
8. Dates use timezone-aware timestamps.

---

# RC-01: Published Product Contract

## Purpose

Provide the Customer App and approved internal consumers with customer-safe, publication-approved product content.

## Proposed contract name

`published_products_v1`

The implementation may be a governed view, RPC or server endpoint. The name is conceptual until a reviewed backend tranche selects the mechanism.

## Consumers

- Customer App: primary consumer
- Central: customer-service and catalogue reference
- Trace: limited identity/label reference only, preferably through a narrower execution contract

## Source authority

- Product identity and lifecycle: AI Studio-owned product master
- Media and editorial content: AI Studio
- Commercial price: excluded from this contract and supplied by RC-02
- Operational stock quantities: excluded

## Required output

```ts
type PublishedProductV1 = {
  productId: string;
  sku: string;
  name: string;
  shortDescription: string | null;
  longDescription: string | null;
  categoryId: string | null;
  categoryName: string | null;
  subcategoryId: string | null;
  subcategoryName: string | null;
  brand: string | null;
  unitOfMeasure: string | null;
  netQuantity: number | null;
  netQuantityUnit: string | null;
  dietaryTags: string[];
  allergenSummary: string[];
  storageSummary: string | null;
  shelfLifeSummary: string | null;
  heroMediaUrl: string | null;
  galleryMediaUrls: string[];
  thumbnailUrl: string | null;
  catalogueBadges: string[];
  publicationStatus: "published";
  publishedAt: string;
  contentVersion: number;
};
```

## Inclusion rule

A product is returned only when all of the following are true:

- canonical product is active;
- publication approval is valid;
- customer visibility is enabled;
- required customer-safe identity fields are present;
- publication has not been withdrawn or expired.

## Excluded fields

- cost price
- supplier terms
- margin
- internal approval notes
- formulation details not approved for publication
- internal production category codes
- raw storage paths
- unpublished media
- staff-only tags
- stock quantities
- service-role metadata

## Failure behavior

- Missing optional content returns `null` or an empty array.
- Missing mandatory publication fields excludes the product rather than returning a misleading partial product.
- The consumer may show a truthful unavailable state; it must not fall back to draft tables.

## Acceptance evidence

- unpublished and inactive products are absent;
- approved product appears once by canonical `productId`;
- no internal-only field is exposed;
- gallery order is deterministic;
- anonymous access, when enabled, receives only public products;
- authenticated buyers receive the same product identity, with pricing supplied separately.

---

# RC-02: Buyer Pricing Contract

## Purpose

Return the effective price and purchase constraints a particular authenticated buyer/company is allowed to see for a published product.

## Proposed contract name

`buyer_product_prices_v1`

## Consumers

- Customer App: product cards, product detail, cart and quick order
- Central: customer-service verification and parity checks

## Source authority

- Price governance, MOQ, company eligibility and commercial rules: Central
- Product identity: canonical product master
- Authentication/company membership: Supabase Core

## Required input context

- authenticated user identity derived server-side;
- active company membership derived server-side;
- optional product IDs or catalogue scope;
- effective timestamp defaults to current server time.

The caller must not be allowed to supply an arbitrary target `user_id` or `company_id` to obtain another buyer's prices.

## Required output

```ts
type BuyerProductPriceV1 = {
  productId: string;
  companyId: string;
  currency: string;
  unitPrice: number | null;
  taxMode: "inclusive" | "exclusive" | "not_applicable" | "unknown";
  minimumOrderQuantity: number | null;
  orderIncrement: number | null;
  maximumOrderQuantity: number | null;
  priceStatus: "available" | "approval_required" | "not_eligible" | "temporarily_unavailable";
  effectiveFrom: string | null;
  effectiveUntil: string | null;
  entitlementVersion: number;
  reasonCode: string | null;
};
```

## Selection priority

The implementation must define deterministic precedence, for example:

1. company-and-product specific entitlement;
2. company segment/product entitlement;
3. approved buyer-class/product entitlement;
4. governed default published price;
5. no eligible price.

Exact precedence requires verification against the current schema before implementation.

## Security rules

- identity and company context are derived from the authenticated session;
- suspended, rejected or unapproved buyers do not receive restricted prices;
- anonymous users receive no buyer-specific price;
- price history, costs, margins and other companies' entitlements remain hidden;
- results are read-only and cannot be used to bypass order validation.

## Order validation rule

The displayed price is informational until `submit_order` revalidates the active entitlement, quantity rules, currency and effective period atomically. The frontend must never be the authority for accepted order pricing.

## Failure behavior

- no eligible price returns `priceStatus` with `unitPrice: null`;
- authorization failure returns no data, not a public fallback price unless an explicit public price contract exists;
- expired entitlement is not silently reused.

## Acceptance evidence

- two companies with different entitlements receive their own prices only;
- caller cannot request another company by ID;
- expired and suspended entitlements fail closed;
- MOQ and increments match order-command validation;
- no cost or margin fields are exposed.

---

# RC-03: Customer Order Status Contract

## Purpose

Provide a truthful, customer-safe projection of order progress without exposing raw finance, production, inventory, employee, security or scan records.

## Proposed contract name

`customer_order_status_v1`

## Consumers

- Customer App: order list, order detail and tracking
- Central: customer-service parity and support
- Public tracking surface: a narrower tokenized subset only

## Source authority

- commercial and operational order state: Central
- physical dispatch, scan and gate evidence: Trace
- customer-safe projection rules: Supabase Core contract jointly governed by Central and Trace ownership boundaries

## Required output

```ts
type CustomerOrderStatusV1 = {
  orderId: string;
  orderNumber: string;
  companyId: string;
  submittedAt: string;
  updatedAt: string;
  displayStatus:
    | "received"
    | "under_review"
    | "approved"
    | "on_hold"
    | "in_production"
    | "packing"
    | "ready_for_dispatch"
    | "dispatched"
    | "delivered"
    | "partially_delivered"
    | "cancelled"
    | "exception";
  statusMessage: string | null;
  nextExpectedStep: string | null;
  estimatedDispatchAt: string | null;
  dispatchedAt: string | null;
  deliveredAt: string | null;
  trackingReference: string | null;
  carrierName: string | null;
  lineSummary: Array<{
    orderLineId: string;
    productId: string;
    productNameSnapshot: string;
    orderedQuantity: number;
    fulfilledQuantity: number | null;
    lineStatus: string;
  }>;
  customerActionRequired: boolean;
  customerActionCode: string | null;
  statusVersion: number;
};
```

## Projection principles

- The displayed status is derived from governed source states and evidence.
- Customer status is never independently editable.
- Internal queue names, employee identities, finance notes, fraud controls, production bottleneck details, exact stock positions and security exceptions are excluded.
- An operational exception is translated into a safe, truthful customer message without exposing restricted detail.
- A dispatch status is not shown until required physical evidence exists.
- Delivery is not inferred solely from a planned date.

## Example status mapping

| Internal evidence | Customer display status |
|---|---|
| submitted order intent accepted as canonical order | `received` |
| commercial/finance review active | `under_review` |
| required approvals complete, execution not started | `approved` |
| governed hold prevents progress | `on_hold` |
| released production requirement active | `in_production` |
| packing/cartonisation active | `packing` |
| dispatch ready and release conditions met | `ready_for_dispatch` |
| gate exit or equivalent governed dispatch evidence recorded | `dispatched` |
| governed delivery closure evidence | `delivered` or `partially_delivered` |
| governed cancellation | `cancelled` |
| customer-safe exception requiring communication/action | `exception` |

The exact source-state mapping must be validated against existing Central and Trace schemas before implementation.

## Public tracking subset

Public tracking must require an opaque tracking token or equivalent protected reference and return fewer fields:

- order/tracking reference masked as appropriate;
- display status;
- last safe update time;
- carrier/tracking reference when authorized for display;
- no company profile, prices, line-level commercial detail or internal identifiers.

## Security rules

- authenticated users may see only orders belonging to their authorized company membership;
- staff access is separately governed;
- public tracking cannot enumerate orders;
- raw scan payloads, coordinates, employee identities and internal evidence remain hidden;
- the projection is read-only.

## Failure behavior

- conflicting internal evidence produces `exception` or retains the last proven state; it must not claim progress that is not evidenced;
- missing Trace evidence does not block earlier truthful Central states;
- unavailable ETA returns `null`, not a fabricated date.

## Acceptance evidence

- buyer from company A cannot read company B orders;
- each order appears once;
- status transitions are monotonic unless an explicit governed reversal/correction exists;
- `dispatched` requires physical evidence;
- restricted internal fields are absent;
- public tracking resists enumeration and returns only the narrow subset.

---

# Implementation escalation gate

Before any of these contracts becomes executable:

1. inventory current source tables, functions and frontend queries across all repositories;
2. map existing fields to each contract and label gaps;
3. select view, RPC or Edge Function mechanism per contract;
4. define RLS/grants and negative tests;
5. implement in Supabase Core only through new forward migrations;
6. validate in disposable PostgreSQL;
7. connect one read-only consumer behind a feature flag;
8. compare against the existing Central experience before cutover.

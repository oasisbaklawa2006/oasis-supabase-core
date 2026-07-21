# Customer Read Contract Reality Map

Status: documentation-only discovery artifact. No database object, policy, grant, application code, or deployment is changed by this document.

## Classification key

- **Existing** — directly represented in the current generated schema.
- **Derivable** — can be produced from current fields or joins without inventing new operational truth.
- **Missing** — no confirmed canonical field or relation yet.
- **Conflicting** — more than one candidate source exists and authority is unclear.
- **Unsafe** — source exists but must not be exposed directly to customers.

## Evidence boundary

This first pass uses the generated Supabase types committed in Central and AI Studio. Generated types are evidence of repository assumptions, not proof that every object is present or correctly secured in live production. Runtime verification and RLS inspection remain mandatory before implementation.

---

# 1. `published_products_v1`

## Candidate sources

Primary candidate: `public.products`.

Supporting candidates:

- `public.product_media`
- `public.catalogue_ai_studio_drafts`
- `public.catalogues`
- `public.catalogue_products`
- category fields on `products`

## Field mapping

| Contract field | Candidate source | Classification | Notes |
|---|---|---|---|
| `product_id` | `products.id` | Existing | Canonical immutable identifier candidate. |
| `sku` | `products.sku` | Existing | Must remain stable after publication. |
| `name` | `products.product_name` | Existing | Customer display name may later prefer approved catalogue title only when governance is explicit. |
| `short_name` | `products.short_name` | Existing | Optional. |
| `short_description` | `products.short_description` or approved `catalogue_ai_studio_drafts.short_description` | Conflicting | Product master and approved editorial copy both exist. Publication authority must be defined. |
| `long_description` | `products.description` or approved `catalogue_ai_studio_drafts.long_description` | Conflicting | Do not expose draft copy. |
| `category` | `products.category` | Existing | Text field; no confirmed canonical category FK on the product row in this pass. |
| `subcategory` | `products.subcategory` | Existing | Text field. |
| `hero_image_url` | `products.hero_image_url` | Existing | Requires storage visibility and publication safety review. |
| `media` | `product_media` by `product_id` | Derivable | Only approved/published media should be included. Current `status` can support filtering, but accepted status values need verification. |
| `pack_size` | `products.pack_size` | Existing | Customer-facing interpretation must be standardised. |
| `primary_uom` | `products.primary_uom` | Existing | Required for quantity interpretation. |
| `net_weight_g` | `products.net_weight_g` | Existing | Optional by product type. |
| `pieces_per_pack` | `products.pcs_per_pack` | Existing | Optional. |
| `pieces_per_carton` | `products.pcs_per_carton` | Existing | Buyer-facing only where commercially appropriate. |
| `storage_instructions` | `products.storage_instructions` | Existing | Suitable after editorial review. |
| `shelf_life_days` | `products.shelf_life_days`, frozen/post-processing variants | Conflicting | One universal shelf-life field is insufficient for multi-condition products. Contract needs a structured shelf-life model or a governed display string. |
| `temperature_requirement` | `products.temperature_requirement` | Existing | Customer-safe after normalisation. |
| `is_active` | `products.is_active` | Existing | Necessary but not sufficient for publication. |
| `is_catalogue_ready` | `products.is_catalogue_ready` | Existing | Strong publication prerequisite candidate. |
| `publication_status` | product flags plus approved catalogue/editorial state | Derivable | No single confirmed publication authority. |
| `catalogue_memberships` | `catalogue_products` joined to `catalogues` | Derivable | AI Studio types include these tables, while its current production capability contract has previously treated governed catalogue persistence as absent. Live verification is essential. |
| `public_slug` | `catalogues.public_slug` for catalogue, no confirmed product slug | Missing | Product detail routes currently need a safe ID/SKU strategy or a new immutable product slug. |

## Unsafe fields that must not enter the customer projection

Exclude operational and commercially sensitive fields such as:

- internal source documents and source notes
- import confidence
- operational notes
- private-label internal costs
- pricing notes
- internal approval actors
- unpublished AI drafts and prompts
- BOM data
- production department internals

## Current readiness

**Readiness: partial.**

A basic published-product projection is feasible from existing product and media fields. The blockers are not basic product data; they are publication authority, editorial-copy precedence, media status semantics, product slugs, and shelf-life normalisation.

---

# 2. `buyer_product_prices_v1`

## Candidate sources

- price fields directly on `products`
- `product_pricing_rules`
- Central pricing slabs and buyer/company assignment fields
- B2B application assigned price tier

## Field mapping

| Contract field | Candidate source | Classification | Notes |
|---|---|---|---|
| `buyer_company_id` | authenticated user's canonical company membership | Derivable | Membership authority must be resolved through canonical identity, not request input alone. |
| `product_id` | `products.id` / `product_pricing_rules.product_id` | Existing | Stable join key. |
| `currency` | `product_pricing_rules.currency` or `products.currency` | Conflicting | Rule-level currency should likely take precedence. |
| `unit_price` | approved `product_pricing_rules.calculated_price` or product B2B fields | Conflicting | Multiple price stores exist. Direct product fields and rule tables can disagree. |
| `base_price` | `product_pricing_rules.base_price` | Existing | Must normally remain hidden if only final buyer price is needed. |
| `discount_percent` | `product_pricing_rules.discount_percent` | Existing | Exposure depends on catalogue policy. |
| `tax_rate` | `product_pricing_rules.gst_rate` or `products.gst_rate` | Conflicting | Rule-level validity and price-channel precedence must be defined. |
| `tax_inclusive` | `product_pricing_rules.tax_inclusive` | Existing | Required to display truthful totals. |
| `uom` | `product_pricing_rules.uom`, product B2B UOM, or primary UOM | Conflicting | Pricing unit must be explicit and must not be inferred from display pack alone. |
| `price_channel` | `product_pricing_rules.price_channel` | Existing | Must match buyer/customer channel. |
| `price_type` | `product_pricing_rules.price_type` | Existing | Needs controlled enum semantics. |
| `valid_from` | `product_pricing_rules.valid_from` | Existing | Null handling needs definition. |
| `valid_until` | `product_pricing_rules.valid_until` | Existing | Expired rules must fail closed. |
| `approval_status` | `product_pricing_rules.approval_status` | Existing | Only approved rules may feed the projection. |
| `buyer_tier` | `b2b_applications.assigned_price_tier` and pricing slab structures | Derivable / Conflicting | Application assignment is not necessarily the final canonical company-level pricing assignment. |
| `minimum_order` | `product_moq_rules` or Central `moq_rules` | Conflicting | Two separate MOQ models are visible across generated schemas. Authority must be consolidated before customer exposure. |
| `availability` | inventory/reservation projection | Missing from this contract pass | Price must not falsely imply availability. Availability should remain a separate read model or explicit nullable field. |

## Unsafe fields

Never expose directly:

- internal margin or cost basis
- approval actors and notes
- private-label costs
- company credit limits
- finance verification details
- prices for other buyers or tiers
- unrestricted rule-table rows

## Current readiness

**Readiness: blocked for direct production use, but feasible after authority resolution.**

The ecosystem has enough price data to calculate a buyer price. The principal risk is that there are several overlapping price and MOQ sources. A customer projection must choose one deterministic precedence order and fail closed when no approved rule applies.

Recommended precedence candidate for later validation:

1. approved company-specific rule
2. approved buyer-tier rule
3. approved channel rule
4. approved product default
5. no price returned

Do not fall back silently to MRP or a stale B2B field.

---

# 3. `customer_order_status_v1`

## Candidate sources

Primary candidate: `orders`.

Supporting sources:

- `order_items`
- dispatch records and packing lists
- Trace scan/dispatch events
- payment state, only as a safe summary
- tracking token and public tracking route

## Field mapping

| Contract field | Candidate source | Classification | Notes |
|---|---|---|---|
| `order_id` | `orders.id` | Existing | Canonical internal identifier. |
| `order_number` | `orders.order_number` | Existing | Customer display identifier. |
| `company_id` | `orders.company_id` | Existing | Must be enforced by RLS or a SECURITY DEFINER read function using `auth.uid()`. |
| `submitted_at` | `orders.created_at` | Existing | Semantics should be confirmed: creation versus formal submission. |
| `overall_status` | `orders.status` | Existing but unsafe raw | Internal status values should be mapped to a controlled customer enum. |
| `payment_status` | `orders.payment_status` / `payment_cleared` | Existing but sensitive | Expose only a simple customer-safe summary where appropriate. |
| `estimated_dispatch_date` | `orders.estimated_despatch_date` or `system_estimated_date` | Conflicting | Human-confirmed date should take precedence over system estimate. |
| `requested_dispatch_date` | `orders.requested_dispatch_date` | Existing | Customer-entered/requested date, not a promise. |
| `tracking_number` | `orders.tracking_number` | Existing | Reveal only after dispatch and only to authorised customer. |
| `public_tracking_token` | `orders.tracking_token` | Existing but security-sensitive | Treat as a bearer capability; never expose in broad lists or logs. |
| `courier_name` | `orders.courier_name` | Existing | Customer-safe after dispatch. |
| `item_count` | count of `order_items` | Derivable | Aggregate only. |
| `total_quantity` | sum of `order_items.quantity` | Derivable | UOM ambiguity means this may be misleading across mixed items. Prefer item count or line summaries. |
| `line_statuses` | `order_items.production_status` | Existing but unsafe raw | Map to a small customer vocabulary; do not expose department/task internals. |
| `packed_status` | `order_items.actual_packed_qty`, packing lists, dispatch records | Derivable | Must use one authoritative readiness rule. |
| `dispatch_status` | dispatch/packing data plus Trace evidence | Derivable / Conflicting | Central may describe planned dispatch while Trace records physical execution. Trace evidence should win for physical milestones. |
| `gate_exit_at` | Trace gate scan event | Missing from confirmed Central schema pass | Requires Trace contract mapping. |
| `delivery_status` | courier integration or explicit closure evidence | Missing / Derivable | Do not equate gate exit with delivery. |
| `customer_timeline` | mapped business events from Central and Trace | Missing as one canonical projection | Existing fields can populate initial milestones, but a durable event model is preferable. |

## Required customer status vocabulary

Internal statuses should be mapped into a stable external vocabulary such as:

- `RECEIVED`
- `UNDER_REVIEW`
- `APPROVED`
- `IN_PRODUCTION`
- `PACKING`
- `READY_FOR_DISPATCH`
- `DISPATCHED`
- `DELIVERED`
- `ON_HOLD`
- `CANCELLED`

The mapping must be explicit, versioned, and tested. Unknown internal statuses must not be guessed; they should return `UNDER_REVIEW` or an explicit safe fallback with internal alerting.

## Unsafe fields

Exclude:

- finance verifier identity
- payment proof URLs
- rejection notes not intended for the buyer
- parser confidence
- WhatsApp provider IDs
- duplicate-detection internals
- internal clarification flags and operational notes
- department-level production detail
- security/gate evidence beyond safe milestones

## Current readiness

**Readiness: partial.**

A simple order summary and tracking view is feasible today from Central fields. A truthful end-to-end timeline is not yet safe until physical milestones are sourced from Trace and internal states are mapped into a governed customer vocabulary.

---

# Cross-contract findings

## Confirmed strengths

- Stable product, order, company, and order-line identifiers exist.
- Product master already contains substantial catalogue-ready data.
- Media, pricing-rule, MOQ, catalogue, order, payment, packing, and tracking-related structures are represented across generated schemas.
- Central already contains buyer onboarding and company linkage.

## Principal conflicts

1. Product editorial truth exists in both product master fields and governed AI catalogue drafts.
2. Pricing exists both directly on products and in pricing-rule structures.
3. MOQ logic exists in more than one model.
4. Catalogue persistence appears in AI Studio generated types while recent application capability checks have treated governed catalogue persistence as unavailable in canonical production.
5. Order operational status and physical execution status are not yet separated into Central-planned versus Trace-observed truth.
6. Generated types differ between repositories and PostgREST versions, indicating schema snapshots are not being consumed from one canonical generated artifact.

## Immediate implementation consequence

Do not create customer views yet.

The next gate is a read-only live verification in canonical Supabase to determine:

- which candidate tables and columns actually exist
- whether catalogue and pricing-rule tables are present in production
- current RLS/grants
- accepted status values
- relationship cardinality
- data completeness and conflict rates
- Trace's physical milestone tables and links to Central orders

Only after that verification should a migration be proposed for any projection.

# Recommended next tranche

Create a read-only verification pack containing:

1. object existence queries
2. column and constraint inventory
3. RLS and grant inventory
4. status-value frequency queries
5. null/completeness checks
6. duplicate/conflict checks for price and MOQ sources
7. order-to-dispatch-to-scan linkage checks

The verification pack must contain SELECT-only SQL and must not be executed against production without explicit approval.
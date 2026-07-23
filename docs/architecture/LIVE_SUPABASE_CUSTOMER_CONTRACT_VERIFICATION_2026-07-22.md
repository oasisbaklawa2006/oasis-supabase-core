# Live Supabase Customer Contract Verification — 2026-07-22

## Scope

SELECT-only verification against canonical project `tcxvcatsqqertcnycuop` (`oasis-baklawa`, ap-south-1). No DDL, migration, RLS, grant, function, policy, or data write was performed.

## Object existence

Present base tables:

- `products`
- `product_media`
- `catalogue_ai_studio_drafts`
- `product_pricing_rules`
- `product_moq_rules`
- `moq_rules`
- `companies`
- `orders`
- `order_items`
- `dispatches`
- `packing_lists`

Absent from the live schema:

- `catalogues`
- `catalogue_products`
- `company_users`
- `stock_units`
- `scan_events`
- `published_products_v1`
- `buyer_product_prices_v1`
- `customer_order_status_v1`

This confirms that the three proposed customer contracts are not yet implemented as live views or tables.

## RLS posture

RLS is enabled on all verified source tables. Policy counts observed:

| Table | Policies |
|---|---:|
| products | 1 |
| product_media | 2 |
| catalogue_ai_studio_drafts | 4 |
| product_pricing_rules | 2 |
| product_moq_rules | 2 |
| moq_rules | 2 |
| companies | 6 |
| orders | 21 |
| order_items | 6 |
| dispatches | 3 |
| packing_lists | 1 |

RLS being enabled does not by itself prove that a customer-safe projection exists. Policy semantics must be reviewed before any customer frontend is connected directly.

## Live product readiness

Observed product population:

- total products: 368
- active products: 260
- visible in catalogue: 226
- marked catalogue-ready: 13
- products with an image: 302
- missing SKU: 0
- missing name: 0

Interpretation:

- Basic catalogue browsing can be supported from current data.
- `visible_in_catalog` and `is_catalogue_ready` conflict materially: 226 products are visible, but only 13 are catalogue-ready.
- Publication authority is therefore unresolved and must be defined before exposing a production customer catalogue.

## Product model conflicts

The live `products` table contains overlapping legacy and newer fields, including:

- `name` and `product_name`
- `image_url` and `hero_image_url`
- `shelf_life` and `shelf_life_days`
- `gst_percentage` and `gst_rate`
- `wholesale_price`, `price_wholesale`, `price_b2b`, `price_horeca`, `price_special`, `base_price`, `price_bulk`
- `moq`, `moq_packs`, `moq_value`, `moq_uom`, `moq_text`

A customer contract must resolve these into one deterministic field per concept. Raw table exposure is not acceptable.

## Pricing readiness

Observed pricing-rule population:

- total rules: 124
- approved rules: 115
- rules missing both base and calculated price: 36
- expired rules: 1

Interpretation:

- A governed pricing engine is partially present.
- Approved status alone is insufficient because some approved or existing rows may still have no usable amount.
- Buyer pricing is further complicated by product-level price columns and company-level `price_tier` and `discount_percentage`.
- `buyer_product_prices_v1` must choose one precedence order and reject ambiguous prices rather than silently selecting one.

## MOQ readiness

MOQ exists in three places:

1. product-level columns on `products`
2. `product_moq_rules`
3. `moq_rules`

This is a live conflict, not only a repository-history concern. The customer contract must define one authority and one fallback sequence before order submission is enabled.

## Order and tracking readiness

Observed order population:

- total orders: 138
- distinct order statuses: 13
- orders missing company link: 1
- orders with tracking number: 3
- orders with actual dispatch date: 0

Observed dispatch population:

- total dispatches: 0

Interpretation:

- Customer order-history and basic order-status views are possible now.
- Physical dispatch truth is not established in the live `dispatches` table.
- Existing order tracking is mostly order-field based rather than backed by dispatch records.
- No live `stock_units` or `scan_events` object exists in canonical Supabase, so Trace physical milestones cannot yet be projected from canonical backend evidence.

## Contract verdicts

### `published_products_v1`

Status: **implementable only after publication-rule decision**.

Safe source candidates:

- `products`
- `product_media`
- latest published `catalogue_ai_studio_drafts`

Blocking decisions:

- `visible_in_catalog` versus `is_catalogue_ready`
- `name` versus `product_name`
- `image_url` versus `hero_image_url`
- product description versus published AI Studio description

### `buyer_product_prices_v1`

Status: **not safe to implement until precedence is frozen**.

Potential inputs:

- `product_pricing_rules`
- product price columns
- `companies.price_tier`
- `companies.discount_percentage`

Blocking decisions:

- pricing source precedence
- approval and validity filtering
- handling missing calculated price
- tax-inclusive versus tax-exclusive display
- MOQ authority

### `customer_order_status_v1`

Status: **safe for a limited order-status projection, not full physical tracking**.

Safe current inputs:

- `orders`
- `order_items`
- customer-owned company relationship

Not yet reliable:

- dispatch completion
- carton completion
- gate exit
- scan timeline
- delivered milestone

## Recommended next implementation tranche

Do not create all three views together.

Proceed in this order:

1. Define and approve the product publication rule.
2. Implement `published_products_v1` as read-only projection.
3. Add contract tests and anonymous/authenticated access tests.
4. Define pricing precedence separately.
5. Implement buyer pricing only after ambiguity checks pass.
6. Implement a limited `customer_order_status_v1` using order truth only.
7. Extend tracking after Trace-to-core physical event wiring exists.

## Safety conclusion

The live database is sufficiently mature for a read-only customer catalogue pilot, but not for unrestricted raw-table wiring. The safest first production capability is a narrow published-product projection with explicit publication rules and no customer write path.

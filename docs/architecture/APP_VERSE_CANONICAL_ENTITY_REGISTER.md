# Oasis App-Verse Canonical Entity Register

Status: Draft architecture contract

This register defines the shared business spine used to wire Customer App, Central, AI Studio and Trace through the canonical Supabase backend.

## Entity principles

- One canonical identifier follows an entity across applications.
- Human-readable names, phone numbers, mutable SKUs and local UI keys are not integration identifiers.
- Each entity has one lifecycle owner and one system of record.
- Other applications consume projections, commands or events instead of recreating the entity.
- State transitions must be auditable and fail closed.

## Identity spine

| Entity | Canonical identity | Lifecycle owner | Primary readers | Primary writers | Notes |
|---|---|---|---|---|---|
| Auth user | Supabase Auth UUID | Supabase Core | All apps | Supabase Auth/governed admin flows | Authentication identity only; not a complete business profile |
| User profile | `user_id` linked to Auth UUID | Supabase Core | All apps subject to RLS | Self-service profile command and authorized staff command | Must not duplicate authentication secrets |
| Company | `company_id` UUID | Central business governance, schema in Supabase Core | Customer App, Central, AI Studio where needed | Authorized Central/company onboarding commands | Commercial account identity |
| Company membership | `membership_id` plus `user_id` and `company_id` | Supabase Core authorization contract | All apps | Governed membership command | Role and company context must not be inferred from email domains |
| Role/permission assignment | Canonical assignment ID | Supabase Core | All apps | Authorized security/admin command | Application access derives from canonical assignments |

## Product and publishing spine

| Entity | Canonical identity | Lifecycle owner | Primary readers | Primary writers | Minimum lifecycle |
|---|---|---|---|---|---|
| Product | `product_id` UUID | AI Studio | All apps | AI Studio governed authoring | draft → review → approved → published/active → retired |
| SKU | Stable governed SKU linked to `product_id` | AI Studio | Central, Customer App, Trace | AI Studio governed command | SKU is a business reference, not the primary integration key |
| Product media | `media_id` UUID | AI Studio | Customer App, Central | AI Studio media workflow | uploaded → reviewed → approved → published/retired |
| Catalogue | `catalogue_id` UUID | AI Studio | Customer App, Central | AI Studio | draft → review → published → withdrawn |
| Catalogue item/offer | `catalogue_item_id` UUID linking catalogue and product | AI Studio for content; Central for commercial eligibility where applicable | Customer App, Central | Governed publication/pricing commands | Separates editorial placement from transaction pricing |
| Label content definition | `label_content_id` UUID | AI Studio | Trace, Central | AI Studio approval workflow | Physical printing remains Trace-owned |

## Commercial spine

| Entity | Canonical identity | Lifecycle owner | Primary readers | Primary writers | Minimum lifecycle |
|---|---|---|---|---|---|
| Buyer eligibility | `buyer_eligibility_id` or governed company state | Central | Customer App, Central | Central approval command | pending → approved/restricted/rejected/suspended |
| Price entitlement | `price_entitlement_id` UUID | Central | Customer App, Central | Central pricing command | effective-dated, company/segment/product scoped |
| Cart | `cart_id` UUID | Customer App experience, canonical persistence in Supabase Core | Customer App | Customer App within owner/company RLS | open → submitted/abandoned/expired |
| Order intent | `order_intent_id` UUID | Customer App until submission | Customer App, Central | Customer App submit command | draft → submitted → accepted/rejected/converted |
| Order | `order_id` UUID | Central | Customer App, Central, Trace by approved reference | Central governed command, initially created atomically from accepted intent | received → under review → approved/held/rejected → execution → dispatched → closed/cancelled |
| Order line | `order_line_id` UUID linked to `order_id` and `product_id` | Central | Customer App, Central, Trace where required | Central order command | Quantity, UOM and commercial snapshot are immutable after defined approval boundary except by governed revision |
| Commercial approval | `commercial_approval_id` UUID | Central | Central; Customer App receives safe status | Authorized Central command | pending → approved/rejected/revoked |
| Finance release | `finance_release_id` UUID | Central | Central; Customer App receives safe status | Authorized finance command | pending → released/held/rejected/revoked |

## Execution and traceability spine

| Entity | Canonical identity | Lifecycle owner | Primary readers | Primary writers | Minimum lifecycle |
|---|---|---|---|---|---|
| Production requirement | `production_requirement_id` UUID linked to order/order line | Central | Central, Trace | Central orchestration command | planned → released → in progress → completed/short/ cancelled |
| Inventory reservation | `reservation_id` UUID | Central | Central; Customer App receives availability only | Central inventory command | requested → reserved/partial/failed → consumed/released |
| Stock unit/lot | `stock_unit_id` UUID | Trace | Trace, Central | Trace | created → available → allocated → packed/dispatched/consumed/quarantined |
| Carton | `carton_id` UUID | Trace | Trace, Central | Trace | open → sealed → assigned → dispatched → exception/closed |
| Dispatch bundle | `dispatch_bundle_id` UUID | Trace for physical composition; Central for readiness authorization | Trace, Central, Customer App safe projection | Trace composition command plus Central readiness command | building → ready → released → exited → delivered/exception |
| Scan event | `scan_event_id` UUID | Trace | Trace, Central; Customer App via projection | Trace only through governed scan command | Append-only; correction occurs by compensating event, not rewrite |
| Print event | `print_event_id` UUID | Trace | Trace, Central audit | Trace | printed/reprinted/failed with printer, template and actor evidence |
| Gate movement | `gate_movement_id` UUID | Trace | Trace, Central, Customer App safe projection | Trace authorized gate command | pending → verified → exited/rejected/exception |
| Delivery/closure | `closure_id` UUID or governed terminal event | Central commercial closure with Trace evidence input | All relevant apps | Governed Central closure command | delivered/part-delivered/returned/cancelled/closed with reason |

## Cross-entity rules

1. `order_line.product_id` always references the canonical product, while the order line stores an approved commercial description/price snapshot for historical truth.
2. Physical entities must retain lineage to the relevant order, order line, production requirement and dispatch bundle where applicable.
3. Customer-visible status is a projection, not a separately writable customer status field.
4. Scan, print and gate evidence is append-only.
5. State corrections use explicit revision or compensating-event records.
6. All commands record actor, source application, timestamp and correlation ID.
7. Cross-app links use canonical IDs and never rely solely on free text.

## Canonical business event envelope

Every important transition should be representable as:

```text
business_event_id
entity_type
entity_id
event_type
occurred_at
actor_user_id
source_app
correlation_id
causation_id
payload_version
payload
```

Initial event families:

- `product.approved`
- `product.published`
- `order_intent.submitted`
- `order.accepted`
- `commercial.approved`
- `finance.released`
- `production.released`
- `inventory.reserved`
- `carton.sealed`
- `dispatch.ready`
- `gate.exited`
- `delivery.closed`

This register does not authorize creation of any table or event infrastructure. Implementation requires a separate reviewed Supabase Core tranche.

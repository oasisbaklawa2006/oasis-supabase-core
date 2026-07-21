# Oasis App-Verse Ownership and Wiring Baseline

Status: Draft architecture baseline
Date: 2026-07-21
Scope: Oasis-Baklawa-Central, oasis-ai-studio, oasis-trace, oasis-supabase-core, oasis-baklawa customer application

## 1. Purpose

This document establishes the safe target boundary for the Oasis application ecosystem. It is documentation-only and does not authorize production deployment, schema change, route removal, migration movement, or application rewrites.

The operating principle is:

> Stabilise first, define ownership second, wire narrow contracts third, move read paths before write paths, and retire legacy paths only after measured parity.

## 2. Repository ownership

### oasis-baklawa — Customer Application

Primary responsibility:
- public discovery and premium product presentation
- buyer registration, onboarding and approval visibility
- catalogue, product detail, favourites and repeat ordering
- cart, quick order and governed order submission
- buyer account, addresses, documents and support
- customer-visible order history and tracking
- public legal, privacy, shipping and policy content

Must not own:
- product master approval
- commercial or finance release
- production execution
- stock allocation
- physical scan events
- dispatch completion
- direct operational-table mutation

### Oasis-Baklawa-Central — Enterprise Control Plane

Primary responsibility:
- client and sales operations
- commercial, price, credit and finance approval
- order governance and operational queues
- production orchestration and inventory coordination
- packing, dispatch readiness and exception management
- WhatsApp accountability and zero-loss monitoring
- command dashboards, TV boards, audit and staff administration

Must not own long-term:
- public storefront presentation
- customer catalogue UX
- duplicate trace-event truth
- independent production database migrations

### oasis-ai-studio — Product Intelligence and Publishing

Primary responsibility:
- product creation and structured product master authoring
- product content, aliases, media and AI-assisted copy
- catalogue composition and product selection
- label content preparation
- approval, publishing readiness and data correction

Must not own:
- buyer order execution
- finance approval
- inventory mutation
- dispatch or scan-event truth

### oasis-trace — Physical Chain of Custody

Primary responsibility:
- production lot and stock-unit identity
- carton identity and carton membership
- barcode and QR identity
- dispatch bundles and shipping labels
- print logs, reprints and reprint reasons
- scan events, handovers, gate movement and trace history

Must not own:
- buyer pricing
- commercial approval
- product editorial truth
- customer authentication

### oasis-supabase-core — Canonical Backend Authority

Exclusive responsibility:
- production database migrations
- schemas, tables, constraints and indexes
- RLS, grants and database security
- triggers, shared functions and governed RPCs
- Edge Functions and server-side integration contracts
- generated database types
- seed, migration and RLS test infrastructure
- production deployment records

Application repositories may contain frontend contract tests and read-only schema references, but must not become independent production database authorities.

## 3. Canonical business spine

The shared lifecycle is:

Product
→ Published Offer
→ Buyer / Company
→ Order
→ Order Line
→ Commercial Approval
→ Production Requirement
→ Stock Unit
→ Carton
→ Dispatch
→ Scan Event
→ Delivery / Closure

Identity spine:

auth.users
→ canonical user profile
→ company membership
→ role / permission resolution
→ application-specific access

Each entity must have:
- one canonical ID
- one system of record
- one lifecycle authority
- explicit readers and writers
- an audit trail
- stable cross-application references

## 4. Wiring strategy

### Layer 1 — Shared identity

All applications use the same Supabase Auth identity. Authorization remains app-specific but resolves from canonical profile, membership and role records.

### Layer 2 — Shared IDs

Applications share canonical entity IDs, not page logic or copied components. The same order_id, product_id, stock_unit_id, carton_id and dispatch_id must flow across applications.

### Layer 3 — Governed read models

Customer and dashboard surfaces should read narrow projections instead of broad operational tables. Initial target contracts:
- published_product_view
- buyer_price_view
- customer_order_status_view
- public_tracking_view
- dispatch_readiness_view
- inventory_availability_view

### Layer 4 — Governed commands

Sensitive transitions should use validated RPCs or Edge Functions, for example:
- publish_product()
- submit_order()
- approve_order()
- release_finance()
- reserve_inventory()
- create_dispatch_bundle()
- record_gate_scan()

Each command must validate actor, current state and transition; write audit evidence; return canonical IDs; and fail atomically.

### Layer 5 — Durable business events

Initial event transport may be a canonical database table rather than a separate message broker.

Suggested contract:
- id
- entity_type
- entity_id
- event_type
- actor_user_id
- occurred_at
- source_app
- correlation_id
- payload

Representative events:
- product.published
- order.submitted
- order.approved
- finance.released
- production.allocated
- carton.closed
- dispatch.ready
- gate.exited
- delivery.closed

## 5. Escalation ladder

### Level 0 — Freeze and baseline
Achievement: exact repository, deployment and database baseline is recorded.
Result: known recovery point and reliable before/after comparison.

### Level 1 — Ownership contract
Achievement: every domain, route, table and write path has one primary owner.
Result: duplication and prohibited ownership become visible.

### Level 2 — Canonical entity contract
Achievement: product, buyer, order, stock unit, carton, dispatch and scan IDs and lifecycles are defined.
Result: applications can integrate without accidental joins or duplicate identities.

### Level 3 — Read contracts
Achievement: narrow, versioned projections exist for customer and operational reads.
Result: read-only integration becomes possible with low risk.

### Level 4 — Shadow writes
Achievement: new channels submit intents while the existing operational path remains authoritative.
Result: real workflow evidence without immediate replacement risk.

### Level 5 — Controlled writes
Achievement: a restricted cohort uses governed commands with audit evidence.
Result: validated production use under limited exposure.

### Level 6 — Dual run
Achievement: old and new paths operate together and outputs reconcile for an agreed period.
Result: evidence for safe cutover.

### Level 7 — Primary path and retirement
Achievement: the new path becomes default; the legacy path is disabled only after dependency proof.
Result: reduced duplication and lower operating complexity.

## 6. Safe parallel work

The following may proceed without stretching current production applications:
- architecture and ownership documentation
- read-only repository and dependency audit
- customer UI prototyping with mock data
- shared TypeScript contract definitions
- read-only route, network and console baselining
- contract, migration and RLS test-harness work
- Figma/Stitch design work outside production repositories

The following must not be parallelised against the same live foundation:
- authentication redesign and role redesign
- RLS changes and broad frontend query rewrites
- order-state redesign and finance-state redesign
- inventory identity changes and Trace scan-identity changes
- customer cutover and deletion of Central customer routes
- migration consolidation and dependent schema development

## 7. Customer application extraction sequence

1. Static premium shell using mock contracts.
2. Read-only published catalogue and product detail.
3. Shared authentication, profile and company membership.
4. Cart and order-intent submission.
5. Customer-visible order status.
6. Public tracking projection from Central and Trace.
7. Cohort rollout: internal buyers → selected B2B → selected HORECA → all approved buyers.
8. Central customer routes become legacy links, then redirects, then are retired after parity.

## 8. Non-stretch tranche rules

Every implementation tranche must:
- touch one business domain
- introduce at most one new write path
- avoid unrelated refactors
- avoid schema deletion and migration amendment
- start read-only where possible
- use a feature flag before enabling writes
- document rollback
- preserve the existing path until parity is proven
- include exact-SHA verification before production deployment

## 9. Immediate first deliverables

1. Repository ownership matrix.
2. Canonical entity and lifecycle register.
3. Cross-repository table/RPC/Edge Function dependency inventory.
4. Customer application mock contract package.
5. Initial read-model specifications for published products, buyer pricing and customer order status.
6. Runtime baseline and risk register for Central, AI Studio and Trace.

## 10. Explicit non-authorization

This document does not authorize:
- pushing the frozen P1 security branch
- deploying any migration
- changing production RLS
- moving current customer routes
- deleting application code or tables
- merging this branch without review

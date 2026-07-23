# Recoverable Production Data Cleanup Plan

Date: 2026-07-22
Status: Draft / not applied

## Objective

Retain only materially useful products, orders, and users while preserving auditability and preventing cascading damage to catalogue, pricing, inventory, production, Trace, finance, and authentication records.

## Current classification

### Products
- Total: 368
- Keep: 300
- Cleanup candidates: 68

Keep rule:
- readiness score >= 8/10
- customer image mandatory
- usable selling price mandatory

Readiness dimensions:
1. product name
2. SKU
3. category/subcategory
4. customer description
5. image
6. pack or weight definition
7. storage instruction
8. shelf life
9. usable selling price
10. active and visible

### Orders
- Total: 138
- Keep: 110
- Cleanup candidates: 28
- Empty: 27
- Duplicate: 1
- Waste: 0

Keep rule:
- has order items, payment, dispatch, or other business evidence
- is not marked duplicate
- is not marked waste

### Users
- Total auth users: 92
- Keep: 52
- Orphan candidates: 40

Keep rule:
- linked profile, role, B2B application, Trace profile, audit activity, order activity, or catalogue activity

## Why immediate hard deletion is unsafe

The candidate records are referenced by many tables, including:
- catalogue drafts and versions
- product media, pricing, MOQ and variants
- inventory and production records
- order items, payments, documents and status history
- Trace and dispatch records
- audit and authentication records

Several foreign keys use RESTRICT or NO ACTION. Others use CASCADE and would erase useful historical detail if parent records were deleted blindly.

## Approved execution model

### Stage 1 — Snapshot
Create immutable cleanup snapshots containing:
- source record JSON
- classification score
- reason for inclusion
- dependency summary
- captured timestamp

### Stage 2 — Quarantine
Products:
- set `is_active = false`
- set `visible_in_catalog = false`
- retain source rows and dependencies

Orders:
- move only empty or duplicate records into an archive table after dependency verification
- do not relabel genuine historical orders as waste

Users:
- do not delete auth users until every public-schema reference is cleared or safely archived
- disable access first where supported

### Stage 3 — Zero-dependency hard delete
Hard-delete only rows that:
- are already snapshotted
- have no business, audit, finance, Trace, inventory, production, catalogue, or auth dependency
- pass a final count reconciliation

### Stage 4 — Validation
Re-run:
- product counts and catalogue projection checks
- order and order-item integrity checks
- auth/profile/role integrity checks
- RLS and grant checks
- Central, AI Studio and Trace smoke tests

## Non-negotiable safeguards

- no `TRUNCATE`
- no blanket `CASCADE`
- no deletion of finance or audit evidence
- no deletion of users with any role or activity
- no deletion of products referenced by retained orders or operational records
- rollback data must exist before destructive SQL runs

## Next implementation artifact

A migration should create cleanup snapshot tables and populate candidate registries only. Hard-delete SQL must remain a separate migration and must be generated from the verified zero-dependency subset.
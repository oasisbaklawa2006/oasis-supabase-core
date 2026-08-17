# RGS + Production Reconciliation Matrix

Live checklist for the RGS (Ready Goods Store) + six Production department closure
across `oasis-supabase-core`, `oasis-baklawa-central`, `oasis-trace`, and
`oasis-ai-studio`. Not a final deliverable — updated as work proceeds.

Branch: `claude/rgs-production-operations-closure-wbugie` (all four repos).

## Status legend

`READY` / `READY_PHYSICAL_UAT` / `DEFERRED_BY_SCOPE` / `TRUE_BUSINESS_DECISION` / `BLOCKED_EXTERNAL` / `IN_PROGRESS`

## A. Phase Zero census (complete)

Full evidence-first audit of all four repos completed 2026-08-17. Key findings:

- **Two parallel inventory models** coexisted in Core: a schema-rich, RPC-empty
  legacy "execution-OS" model, and a narrowly-scoped, RPC-governed "B2B v1" model
  (receiving → putaway → GRN) sharing the same `inventory_movements` /
  `inventory_stock_balances` ledger. No third model was created; the legacy model
  is now the one being completed with governed RPCs (section C below).
- **Four inconsistent department vocabularies** existed simultaneously:
  `products.production_department` CHECK enum, `is_staff_role()` RBAC strings
  (internally inconsistent — `PROD_DATES` with no matching `HOD_DATES`, but
  `HOD_DRAGEES` with no matching `PROD_DRAGEES`), the standalone `ols_departments`
  lookup table (Trace repo), and free-text `production_jobs.department` /
  `product_bom.source_department` with no constraint at all.
- **Production → RGS handoff was the weakest link**: `production_rgs_transfers`
  was a single boolean-flag table with no state machine.
- Central's `ReadyGoodsStore.tsx` was deliberately read-only, explicitly waiting
  on governed Core RPCs before any write path could be wired in.
- Central also runs a **direct-write Production Handheld (PHH) app** in real use,
  architecturally parallel to and inconsistent with a newer, better-designed but
  unvalidated governed execution-board stack.
- Trace (`oasis-trace`) has a real, tested barcode/label/carton domain model, but
  the cross-repo contract Central/Core would call is explicitly marked "Not built"
  in Trace's own `API_AND_EDGE_FUNCTION_REGISTRY.md`.
- Six fully-built, completely unreferenced RGS components exist at
  `oasis-baklawa-central/src/components/rgs/*` (`StockCheckEngine.tsx` in
  particular duplicates much of `ReadyGoodsStore.tsx` + PHH, with an
  auto-post-on-load side effect the newer surfaces deliberately avoid).

Full per-repo detail is in the census transcripts (not persisted verbatim here to
avoid duplicating ~50KB of agent output); this matrix carries the decisions made
from them forward.

## B. Canonical department taxonomy — READY (Core)

Migration: `supabase/migrations/20260817090000_rgs_department_taxonomy.sql`
Tests: `supabase/tests/rgs_department_taxonomy.test.sql` (18 assertions, passing)

| Legacy value | Canonical department | Decision basis |
|---|---|---|
| `arabic_sweets` | `ARABIC_SWEETS` | direct match |
| `dragees` | `CHOCOLATES_CONFECTIONERY` | No repository evidence of an independently operated Dragees floor beyond a role name (`HOD_DRAGEES` with no matching `PROD_DRAGEES`). Dragees are a coated-confectionery product line; the handover's canonical six-department list has no separate Dragees department. Existing `dragees` product rows are **not rewritten** — the CHECK constraint still accepts the value; only the *mapping* is canonical. |
| `chocolates_confectionery` | `CHOCOLATES_CONFECTIONERY` | direct match |
| `fusion_sweets` | `FUSION_SWEETS` | direct match |
| `seasoned_nuts_mixes` | `SEASONED_NUTS_MIXES` | direct match |
| `bakery` | `BAKERY_SEMI_PREPARED` | Bakery & Semi-Prepared collapsed into one department per handover; no repository evidence of a distinct semi-prepared production floor. |
| `dates` (new) | `DATES` | `PROD_DATES` role already existed with no department value it could ever select — this closes that gap. `HOD_DATES` role added to match. |

Implementation: `production_departments` master table + `canonical_production_department()`
pure mapping function + `role_canonical_department()` / `user_canonical_department()`
for RBAC scoping + trigger-maintained `canonical_department` column on
`production_jobs` and `daily_production_logs`. The `products_production_department_check`
CHECK constraint was widened (not narrowed) to also accept `dates`/`semi_prepared`.

**Not yet done**: Central's role/permission constants (`src/lib/auth-routing.ts`,
`adminModuleAccess.ts`) and the six `FactoryTVModule` routes still reference the
old department strings directly; TV/handheld wiring (section F) must consume
`canonical_department` / `role_canonical_department()` rather than re-deriving
its own department list.

## C. Governed Core authority — READY (Core)

Migration: `supabase/migrations/20260817100000_rgs_production_governed_authority.sql`
Tests: `supabase/tests/rgs_production_governed_authority.test.sql` (42 assertions, passing)

Reused existing tables (no third inventory model): `inventory_reservations`,
`inventory_stock_balances` (+`picked_qty` bucket), `inventory_movements`
(+`stock_picked`/`stock_unpicked`/`stock_issued` movement types),
`production_jobs` (+`reservation_id`/`requested_by`/`correlation_id`/
`canonical_department`), `production_rgs_transfers` (extended into a full
declared/dispatched/received/accepted state machine). New tables:
`production_departments`, `production_job_outputs` (append-only, idempotent
output ledger), `rgs_issue_events` (outward custody + acknowledgement).

Governed RPCs (all `SECURITY DEFINER`, advisory-lock + optimistic-version CAS
on stock balances, correlation-id idempotent, RPC-only mutation — direct
`INSERT`/`UPDATE`/`DELETE` on the governed tables is revoked from `authenticated`):

| RPC | Action |
|---|---|
| `reserve_rgs_stock` | RGS demand intake + atomic allocation against available stock |
| `release_rgs_reservation` | Governed release of reserved quantity |
| `create_production_shortage_demand` | Routes the **exact** unreserved shortage to Production; DB-unique-indexed against duplication per reservation+department |
| `start_production_job` | Department-scoped job start |
| `record_production_output` | Append-only, correlation-id-deduplicated output entries |
| `declare_production_ready` | Production status only — does not touch RGS stock |
| `dispatch_production_to_rgs` | Production → RGS custody transfer begins — does not touch RGS stock |
| `record_rgs_receipt` | Physical arrival at RGS — does not create stock |
| `accept_rgs_production_receipt` | **Only** action that posts to permanent RGS stock; posts exactly `accepted_qty`, once |
| `pick_rgs_reservation` | Reserved → picked bucket |
| `issue_rgs_stock` | Reserved/picked → fulfilled, creates outward custody record |
| `acknowledge_rgs_issue` | Receiver acknowledgement; quantity mismatch recorded as explicit variance |

Quantity truth validated against the golden scenario (declared 50.0 / dispatched
49.8 / accepted 49.5 / variance 0.3, all preserved distinctly, RGS stock
increases by exactly 49.5) — see `rgs_production_governed_authority.test.sql`
scenario E.

Validation method: no live Supabase project was available in this environment,
so a full local PostgreSQL 16 replica was built by replaying the production
baseline dump (`20260723161256_legacy_role_authority_baseline.sql`) plus all 54
post-baseline migrations, then pgTAP was installed and both new test files were
run against it (60 new assertions), plus the full pre-existing suite (705 tests
total, zero regressions), plus the repo's own `check-canonical-authority.sh`,
`check-migration-governance.sh`, `verify-production-migration-ledger-regression.sh`
and `verify-production-migration-overlay.sh` governance scripts.

**Not yet done**: `supabase test db` / `supabase db lint` via the pinned Supabase
CLI (not installable in this environment — no Docker daemon) — flagged as
`READY_PHYSICAL_UAT` for the real CI runner, not a gap in the SQL itself.

## D. Central wiring to canonical Core authority — READY

`ReadyGoodsStore.tsx` was read-only by design, waiting on exactly the RPCs in
section C. Now wired: "Allocate & route shortage" calls `reserve_rgs_stock`
then `create_production_shortage_demand` for the exact remainder; "Record
receipt" / "Accept into RGS stock" call `record_rgs_receipt` then
`accept_rgs_production_receipt`. The demand queue deliberately stays sourced
from `b2b_order_availability`/`order_items` (real B2B commercial context
Central already computes there) — the two inventory models are bridged at the
point an operator acts (a reservation is created on demand), not by picking
one model over the other.

The direct-write PHH path (`OperationsController.tsx` + `components/phh/*`)
is rewired onto the governed RPCs across all three tabs (intake accept/reject,
execution start/pause/resume/stage/complete, quick-log ad-hoc production) —
this was a hard dependency, not optional cleanup, since section C's migration
revokes direct writes on `production_jobs` / `production_rgs_transfers`.
Also fixed in the same pass: PHH's completion handler used to post to
`factory_inventory` at production-*completion* time (before RGS ever received
anything); `accept_rgs_production_receipt` now owns that projection, at
acceptance time, with the accepted (not declared) quantity. A department-
taxonomy mismatch this surfaced (`HOD_DEPARTMENT_MAP`/`DEPARTMENTS` using
legacy lowercase strings against canonical-coded jobs) is also fixed.

The six orphaned `src/components/rgs/*` components (see census) are triaged as
**RETIRED** — `StockCheckEngine.tsx`'s auto-post-on-load behavior is
incompatible with the governed, explicit-action model built in section C, and
none are reachable from any route today. No code was deleted (out of scope
for this pass); they remain orphaned and should not be resurrected without
reconciling that incompatibility first.

## E. RGS PC — 18 canonical capability audit

Per-capability reuse/harden/build-new decision against the Central census.
Status legend as in the header.

| # | Capability | Existing screen | Decision | Status |
|---|---|---|---|---|
| 1 | Command Centre | `ReadyGoodsStore.tsx` (`/admin/ready-goods`) doubles as this; no dedicated 5-second-glance command centre exists | REUSE demand queue + HARDEN with a metrics-first landing view | `IN_PROGRESS` |
| 2 | Incoming Demand | `ReadyGoodsStore.tsx` demand queue (order_items) | REUSE, now governed (section D) | `READY` |
| 3 | Demand Detail | `ReadyGoodsStore.tsx` "Demand and custody detail" panel | REUSE, now governed | `READY` |
| 4 | Inventory Match | `ReadyGoodsStore.tsx` shortage computation vs `b2b_order_availability` | REUSE | `READY` |
| 5 | Active Fulfilment | Same panel; reservation lifecycle now visible via `rgs_day_close_exceptions` view | REUSE + minor UI surfacing of reservation status | `IN_PROGRESS` |
| 6 | Production Demand Planner | No dedicated planner UI; `create_production_shortage_demand` is invoked inline per demand row today, not from a standalone SKU-wise planning board | BUILD — SKU-wise consolidated demand view (handover §16) not yet built | `DEFERRED_BY_SCOPE` |
| 7 | Department Demand Detail | Per-department Production TV (`FactoryTVModule`) shows this already, read-only | REUSE (see section F) | `READY` |
| 8 | Production Inward Queue | `InventoryReceiving.tsx` (`/admin/inventory-receiving`) is the mature, RPC-governed B2B inward flow; RGS's own inward is the `record_rgs_receipt`/`accept_rgs_production_receipt` pair now wired into `ReadyGoodsStore.tsx` | REUSE both — B2B inward for supplier/B2B receipts, RGS panel for Production→RGS receipts | `READY` |
| 9 | Weighing & Acceptance | `accept_rgs_production_receipt` accept/reject/hold UI in `ReadyGoodsStore.tsx`; no scale/device integration | REUSE software path; device integration is `READY_PHYSICAL_UAT` | `IN_PROGRESS` |
| 10 | Coding & Tagging | `LabelCommandCenter.tsx` — payload/JSON preview only, explicitly no print/device execution | REUSE payload generation; device execution `READY_PHYSICAL_UAT` (see section on Trace) | `DEFERRED_BY_SCOPE` |
| 11 | Ready Stock | `inventory_stock_balances` is now the live, governed stock-on-hand ledger; no dedicated "stock position" screen exists yet (`InventoryCommandCenter.tsx` is B2B-store-scoped, not RGS-specific) | BUILD a thin RGS stock-position view over `inventory_stock_balances` | `DEFERRED_BY_SCOPE` |
| 12 | Product Stock Detail | Same gap as #11, per-SKU drill-down | BUILD | `DEFERRED_BY_SCOPE` |
| 13 | Picking | `pick_rgs_reservation` RPC exists (section C) but has no Central UI yet | BUILD a pick action in the reservation/allocation view | `DEFERRED_BY_SCOPE` |
| 14 | Ready / Pickup | `issue_rgs_stock` RPC exists but has no Central UI yet | BUILD | `DEFERRED_BY_SCOPE` |
| 15 | Handover | `acknowledge_rgs_issue` RPC exists but has no Central UI yet | BUILD | `DEFERRED_BY_SCOPE` |
| 16 | Day Closing | `rgs_day_close_exceptions` view exists (section C) but has no Central UI yet | BUILD a day-close screen reading that view | `DEFERRED_BY_SCOPE` |
| 17 | Exceptions / Variances | Variance is captured on `production_rgs_transfers` (declared/dispatched/received/accepted) and surfaced in `ReadyGoodsStore.tsx`'s transfer cards; no standalone exceptions board | REUSE data, BUILD a dedicated board later | `IN_PROGRESS` |
| 18 | Reports / Audit | `inventory_movements` is a complete governed audit ledger (section C); no reporting UI over it yet | BUILD | `DEFERRED_BY_SCOPE` |

**Net**: 7 of 18 capabilities are `READY` (reused existing screens, now governed), 4 are `IN_PROGRESS` (existing screen + minor surfacing work), 7 are genuinely new UI (`DEFERRED_BY_SCOPE`) that were correctly identified as gaps rather than duplicated — all of them already have their governing RPC/view in Core (section C), so building them is UI-only work against an existing contract, not new backend design.

## F. Production TV / handheld — READY (largely pre-existing, now taxonomy-correct)

`FactoryTVModule.tsx` (6 department routes) and `OperationsController.tsx`/PHH
were both already real and working per the census; PHH is now rewired onto
governed RPCs (section D) and both consume the canonical department taxonomy
(section B) rather than ad hoc strings. `AssemblyTV.tsx`/`DispatchTV.tsx` are
self-labelled "not yet evidence-validated" in-code — unchanged in this pass,
flagged `READY_PHYSICAL_UAT` pending that validation, not a gap this pass
introduced.

## G–K. Remaining scope

Not started in this pass: RGS TV reconciliation between the bespoke
`ReadyGoodsTV.tsx` and the generic `?display=tv` execution-board mode (census
flagged both existing, not reconciled with each other); the six numbered
production-department-specific execution metadata fields (Arabic Sweets
tray/bake/syrup stage, Chocolates & Confectionery tempering/coating,
Fusion Sweets recipe/cooking, Seasoned Nuts roast/seasoning profile, Dates
variety/grade/filling, Bakery & Semi-Prepared dough/bake/freeze) — the common
PHH shell exists and is governed, but none of these department-specific
fields are captured yet; Trace/label device integration beyond the existing
payload-preview stage; P&A/outlet/internal demand linkage into
`reserve_rgs_stock` (only B2B/order_items is wired so far); the 7 new UI
screens from section E; day-close UI; support/escalation deep-linking;
Central-side Playwright coverage for any of the above. Tracked as follow-on
work on this same branch — not silently dropped.

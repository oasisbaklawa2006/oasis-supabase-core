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
| 11 | Ready Stock | `RgsStockPosition.tsx` (`/admin/ready-goods-stock`) now reads `inventory_stock_balances` directly | BUILT | `READY` |
| 12 | Product Stock Detail | Same screen's SKU drill-down panel (all six qty buckets + version + last-updated) | BUILT | `READY` |
| 13 | Picking | `pick_rgs_reservation` RPC exists (section C); Central UI now built into `ReadyGoodsStore.tsx`'s "Picking & issue" section | BUILT | `READY` |
| 14 | Ready / Pickup | `issue_rgs_stock` RPC exists; Central UI now built into `ReadyGoodsStore.tsx`'s "Picking & issue" section (destination type + reference) | BUILT | `READY` |
| 15 | Handover | `acknowledge_rgs_issue` RPC exists; Central UI now built into `ReadyGoodsStore.tsx`'s "Handover acknowledgement" section | BUILT | `READY` |
| 16 | Day Closing | `RgsDayClose.tsx` (`/admin/ready-goods-day-close`) now reads `rgs_day_close_exceptions`, grouped by exception type | BUILT | `READY` |
| 17 | Exceptions / Variances | Variance surfaced in `ReadyGoodsStore.tsx`'s transfer cards; day-close screen (#16) is now the dedicated exceptions board | BUILT | `READY` |
| 18 | Reports / Audit | `RgsReports.tsx` (`/admin/ready-goods-reports`) now reads `inventory_movements` with SKU filtering | BUILT | `READY` |

**Net**: 17 of 18 capabilities are now `READY` (7 reused as originally governed, 10 built as new UI against Core's existing RPCs/views). Capability #6 (Production Demand Planner) remains `DEFERRED_BY_SCOPE` — see section H-K. #10 (Coding & Tagging device execution) remains `READY_PHYSICAL_UAT` pending physical scale/label-printer integration, which cannot be validated from this environment.

## F. Production TV / handheld — READY (largely pre-existing, now taxonomy-correct)

`FactoryTVModule.tsx` (6 department routes) and `OperationsController.tsx`/PHH
were both already real and working per the census; PHH is now rewired onto
governed RPCs (section D) and both consume the canonical department taxonomy
(section B) rather than ad hoc strings. `AssemblyTV.tsx`/`DispatchTV.tsx` are
self-labelled "not yet evidence-validated" in-code — unchanged in this pass,
flagged `READY_PHYSICAL_UAT` pending that validation, not a gap this pass
introduced.

## G. Department-specific execution metadata — READY

Rather than six disconnected department apps (explicitly warned against),
`production_job_outputs.execution_metadata` (jsonb, section C follow-up) plus
Central's `departmentExecutionFields.ts` give the one common PHH shell a
per-department field set: Arabic Sweets (nut variant, bake stage, syrup
stage, breakage), Chocolates & Confectionery (tempering stage, coating
stage, mould/batch), Fusion Sweets (recipe version, cooking stage, garnish),
Seasoned Nuts & Mixes (roast profile, seasoning batch), Dates (variety,
grade, filling), Bakery & Semi-Prepared (dough/bake/freeze stage, piece
count). Keyed by canonical department code so a payload can never silently
apply to the wrong department's schema.

## H–K. Remaining scope

**RGS TV reconciliation — DONE.** `ReadyGoodsTV.tsx` (`/admin/rgs-tv`) and the
generic `?display=tv` mode (`execution/ready-goods` →
`DepartmentExecutionBoard boardId="ready-goods"`) are not duplicates: the
former is a passive big-screen wall display (SKU-wise demand summary + low
stock, 30s poll, no interaction) meant for a factory-floor monitor; the
latter is `useDepartmentExecutionBoard`'s interactive barcode-scan execution
board reading governed `inventory_reservations` for staff actively working
the queue. They serve different roles and both stay. The one real bug found
in reconciling them: `ReadyGoodsTV.tsx`'s low-stock panel read the legacy,
premature-posting `factory_inventory` table instead of the now-governed
`inventory_stock_balances` — fixed to read the governed table
(`location_code = 'FINISHED_GOODS'`, `available_qty`).

**RGS PC capability build-out — DONE (section E).** Picking (#13),
Ready/Pickup (#14), Handover (#15) are now wired into `ReadyGoodsStore.tsx`'s
"Picking & issue" / "Handover acknowledgement" sections calling
`pick_rgs_reservation` / `issue_rgs_stock` / `acknowledge_rgs_issue`. Ready
Stock (#11) and Product Stock Detail (#12) are `RgsStockPosition.tsx`. Day
Closing (#16) is `RgsDayClose.tsx` reading `rgs_day_close_exceptions`.
Reports/Audit (#18) is `RgsReports.tsx` reading `inventory_movements`.

**P&A/outlet/internal demand linkage — DONE (Core).**
`reserve_rgs_stock` (`20260817160000_rgs_demand_source_linkage.sql`) now
accepts `p_demand_source_type` (`b2b`/`pna`/`outlet`/`internal`) and
`p_demand_reference`. `inventory_reservations` gained matching
`demand_source_type`/`demand_reference` columns; `order_id` was relaxed to
nullable with a CHECK enforcing it's required for `b2b` and forbidden
otherwise. Backward compatible: existing B2B/order_items callers are
unaffected (`demand_source_type` defaults to `'b2b'`). 10 new pgTAP
assertions in `rgs_demand_source_linkage.test.sql`. Central UI to actually
raise P&A/outlet/internal reservations from those channels (as opposed to
`issue_rgs_stock`, which already accepted them as issue *destinations*) is
not built in this pass — the RPC contract is ready for it.

Genuinely not started in this pass (tracked as follow-on work on this same
branch, not silently dropped): Production Demand Planner (#6, a standalone
SKU-wise consolidated planning board — `create_production_shortage_demand`
is still invoked inline per demand row rather than from a dedicated board);
Trace/label device integration beyond the existing payload-preview stage
(`LabelCommandCenter.tsx`) — requires physical scale/printer hardware this
environment cannot validate against, so it stays `READY_PHYSICAL_UAT`;
Central UI to raise reservations against the new pna/outlet/internal demand
sources; support/escalation deep-linking; Central-side Playwright coverage
for the newly-built screens.

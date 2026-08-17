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

## D. Central wiring to canonical Core authority — IN_PROGRESS

`ReadyGoodsStore.tsx` is currently read-only by design, waiting on exactly the
RPCs in section C. Next: wire its allocation/shortage/accept actions to the new
RPCs, and reconcile/retire the direct-write PHH path (`OperationsController.tsx`
+ `components/phh/JobExecutionTab.tsx`) which currently writes `production_jobs`
/ `factory_inventory` / `production_rgs_transfers` directly — now blocked by
`REVOKE INSERT, UPDATE, DELETE` in section C's migration, so this is a **hard
dependency**, not optional cleanup: the PHH app will fail its writes once this
migration ships until it is rewired to the governed RPCs.

The six orphaned `src/components/rgs/*` components (see census) are triaged as
**RETIRED** — `StockCheckEngine.tsx`'s auto-post-on-load behavior is
incompatible with the governed, explicit-action model built in section C, and
none are reachable from any route today.

## E–K. Remaining scope

Not started yet in this pass: RGS PC 18-capability audit/reuse, six Production
department shells, RGS/Production TV completion, RGS/Production handheld
completion, Trace/label integration, P&A/B2B/outlet linkage wiring, day-close UI,
support/escalation deep-linking, Central-side tests (Playwright), CI on the
Central/Core PRs. Tracked as follow-on work in this same branch.

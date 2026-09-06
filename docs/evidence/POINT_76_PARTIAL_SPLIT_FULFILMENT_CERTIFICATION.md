# POINT76 — Partial / Split Fulfilment Canonical Closure

**Workstation:** POINT76 (original #459 — partial / split fulfilment)  
**Repository:** `oasis-supabase-core` (canonical Core backend)  
**Core main audited:** `8e73d94fe83545ee3a84ea8b6ccbd0701e23de66`  
**Certification branch:** `cursor/point76-partial-split-fulfilment-6619`  
**Active migration train:** `#209→#215→#226→#228` — **no new migration added**  
**Production writes:** FORBIDDEN — certification is local pgTAP + existing merged authority only  

## Verdict

**CODE_COMPLETE (Point76 split-fulfilment evidence lane)** — existing deployed authority is sufficient for census + behavioral closure. One bounded test/evidence PR only.

**NOT programme-cleared.** `PR merged != Point76 cleared` until runtime split-fulfilment evidence is certified on exact-head CI and reviewed by `dineshmutrejabackup-cmd`. Stop before merge/production approval.

## 1. Exact Core main SHA

`8e73d94fe83545ee3a84ea8b6ccbd0701e23de66` — `POINT20 — Canonical shared event ledger closure (census + behavioral pgTAP) (#202)`

## 2. Census — partial / split fulfilment constructs

| Construct | Canonical surface | Role in split fulfilment |
|---|---|---|
| Commercial ordered quantity | `order_items.quantity` | Immutable commercial source; versioned only via `amend_sales_order_commercial_v1` (Point75) |
| Per-leg commitment | `b2b_dispatch_consignment_lines.selected_qty` | Operator-selected quantity per dispatch leg |
| Immutable SO snapshot on leg | `b2b_dispatch_consignment_lines.original_order_qty` | Always equals full SO line qty, never the leg qty |
| Production/packing progression | `accepted_ready_qty`, `packed_qty`, `loaded_qty` | Monotonic progress chain toward physical dispatch |
| Physical fulfilment | `b2b_dispatch_consignment_lines.dispatched_qty` | Cumulative physically-dispatched truth per leg |
| Residual truth | `b2b_dispatch_so_line_fulfilment` view | `original_order_qty`, `cumulative_dispatched_qty`, `approved_closed_qty`, `residual_qty` |
| Governed residual close | `b2b_dispatch_residual_closures` | Finance/customer-evidenced write-off of unfulfilled demand |
| Split-leg entry | `create_b2b_dispatch_consignment` | Multiple consignments per order; oversubscription fail-closed |
| Allocation guard | `validate_b2b_dispatch_line_allocation` trigger | Serialised cross-leg cap; cancelled legs excluded |
| Identity guard | `protect_b2b_dispatch_line_identity` trigger | `original_order_qty` / `selected_qty` immutable post-commit |
| Multiple shipments | `b2b_dispatch_shipments`, `create_b2b_dispatch_shipment` | One shipment record per consignment leg |
| Factory handoff partials | `declare_b2b_dispatch_source_handoff` + acceptance RPCs | Partial source acceptance across multiple handoffs (Point87–98 lane) |
| RGS reservation partials | `inventory_reservations.fulfilled_qty` | Factory/RGS lane — not Point76 owner |
| P&A 3PGS partials | `b2b_assembly_3pgs_requirements.fulfilled_qty` | Factory/P&A lane — not Point76 owner |
| Finance clearance | `b2b_dispatch_releases`, `can_verify_b2b_dispatch_finance` | Commercial/finance gate before dispatch execution view clears |
| Audit provenance | `b2b_dispatch_events` | Append-only custody/audit history |

## 3. Problem-path audit

| Risk | Finding | Evidence |
|---|---|---|
| Order marked complete after partial shipment with lost residual | **No unsafe path found** | `b2b_dispatch_so_line_fulfilment.residual_qty` remains > 0 until `cumulative_dispatched_qty + approved_closed_qty` reaches `original_order_qty` |
| Residual demand lost | **Guarded** | Residual closure requires `customer_evidence_ref` + `finance_adjustment_ref` + management role |
| Double-count across split legs | **Fail-closed** | `create_b2b_dispatch_consignment` + allocation trigger reject oversubscription; idempotent `correlation_id` replay |
| Split dispatch without finance clearance | **Structurally gated** | `can_verify_b2b_dispatch_finance`; execution view collapses to HOLD without release |
| Mutating ordered qty to represent fulfilment | **Fail-closed** | `original_order_qty` immutable; `order_items.quantity` unchanged; direct commercial mutation forbidden once versioned |
| Commercial amendment after operations entered | **Fail-closed (Point75 boundary)** | `SALES_ORDER_ALREADY_ENTERED_OPERATIONS` once consignment lines exist |

## 4. Scope separation

| Lane | Owner | Point76 relationship |
|---|---|---|
| Point75 commercial amendment/cancel/substitute | `amend_sales_order_commercial_v1` | Tested only as boundary — blocked after fulfilment ops start |
| Point87–98 factory/dispatch execution | FACT handoff/acceptance RPCs, RGS, P&A | Censused, not duplicated |
| Finance refund/credit-note authority | Finance exit / invoice windows | Residual closure references finance adjustment; no credit-note RPC added |

## 5. Behavioral certification flows

| Flow | Strike evidence | Result |
|---|---|---|
| Ordered vs fulfilled vs residual qty | `point76_partial_split_fulfilment_closure.test.sql` §C | PASS (local pgTAP) |
| Multiple governed fulfilment legs | Same §C (18 + 12 of 30) | PASS |
| Idempotent replay | Same §D | PASS |
| No double-count / oversubscription | Same §D | PASS |
| Completion only at zero residual | Same §C (`30\|30\|0`) | PASS |
| Residual closure with finance evidence | Same §E | PASS |
| Commercial source preservation | Same §C + §F | PASS |
| Cancelled leg reallocation | Same §G | PASS |

**Strike command (local):**

```bash
supabase test db supabase/tests/point76_partial_split_fulfilment_closure.test.sql
```

**Result:** 37/37 PASS on exact-head replay against Core main migrations.

## 6. Prerequisite gaps

**None identified requiring new migration SQL.** All Point76 behavioural claims are provable against existing `b2b_dispatch_*` contract (`20260804103000`), consignment creation RPC (`20260822140000`), and shipment-scoped authority (`20260822131000`).

## 7. Gate state

| Gate | Status |
|---|---|
| Census complete | PASS |
| Behavioral pgTAP (local exact-head) | PASS (37/37) |
| New migration SQL | NOT REQUIRED (train `#209→#215→#226→#228` preserved) |
| CI clean replay | Pending PR CI |
| Owner review (`dineshmutrejabackup-cmd`) | NOT STARTED |
| Programme Point76 cleared | **NO** |

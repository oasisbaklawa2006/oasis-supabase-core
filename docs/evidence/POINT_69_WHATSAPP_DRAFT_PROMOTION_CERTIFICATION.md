# POINT69 — Approved WhatsApp Draft → Canonical Live Order Closure

**Workstation:** POINT69 (original Point 69 — approved WhatsApp draft → canonical live order)  
**Repository:** `oasis-supabase-core` (canonical Core backend)  
**Core main audited:** `8e73d94fe83545ee3a84ea8b6ccbd0701e23de66`  
**Certification branch:** `cursor/point69-whatsapp-draft-promotion-certification-f4ed`  
**Stage-2 TEXT authority:** sufficient; no dependency on protected WA media #203  
**Production writes:** FORBIDDEN — certification is local pgTAP + existing merged authority only  

## Verdict

**CODE_COMPLETE (Point69 live-order promotion lane)** with consolidated exact-head pgTAP strike evidence over existing governed promotion authority. **No migration added** — existing `promote_sales_order_draft_to_order_governed_v1` and wrappers are sufficient.

**NOT programme-cleared.** Stop before merge/production approval. Runtime cross-channel certification remains Mission Control gate.

## Promotion chain census (approval-ready draft → live order)

| Stage | Canonical surface | Authority |
|---|---|---|
| Eligible draft state | `UNDER_REVIEW` + `company_id` + persisted readiness dimensions | `validate_sales_order_draft_readiness`, server-owned readiness only |
| Human approval entry | `approve_sales_order_draft_for_so_atomic` | WA-2 inbox reader + `wa.draft.promote` + AAL2 |
| Governed promotion core | `promote_sales_order_draft_to_order_governed_v1` | CORE-B `#112`, service-role execute privilege |
| Autonomous promotion (separate) | `whatsapp_promote_autonomous_sales_order_draft_v1` | CORE-B `#112`, `core-b:autonomy:` key prefix only |
| Actor / AAL2 | `is_whatsapp_inbox_reader`, `has_whatsapp_permission('wa.draft.promote')`, `wa2_sales_order_drafts_write_guard` | WA-2 `#58`, step-up on terminal promote |
| Line preflight | `sales_order_draft_lines` FOR UPDATE + valid product/qty check | Promotion core inline |
| WA-3 commercial preflight | `wa3_draft_promotion_readiness` trigger when `potential_order_id` linked | WA-3 `#59` |
| SO-number allocation | `sales_order_creation_scopes` (`WHATSAPP_DRAFT_PROMOTION`) → `assign_order_number_on_insert` → `allocate_commercial_document_number_v1('SO')` | `#226` creation-scope hardening |
| Order write | `INSERT INTO orders` (`order_origin='WHATSAPP'`) | Governed core only |
| Order lines write | `INSERT INTO order_items` from draft lines | Governed core only |
| Financial restore | `restore_order_financials` | Post-line materialization |
| Commercial version | `create_sales_order_commercial_version_v1(..., 'WHATSAPP_DRAFT_PROMOTION', 'wa-draft:'||draft_id)` | Pre-factory SO commercial authority |
| `promoted_order_id` linkage | `UPDATE sales_order_drafts SET promoted_order_id` before status → `APPROVED_FOR_SO` | Governed core |
| Potential-order conversion | `transition_whatsapp_potential_order(..., 'CONVERTED', ...)` requires existing `promoted_order_id` + `APPROVED_FOR_SO` | WA-1/WA-2 lifecycle (post-promotion, not inline) |
| Operational audit | `sales_order_draft_audit_log` (`APPROVE`), `audit_logs` (`WA_DRAFT_PROMOTED_TO_SO`) | Governed core |
| Idempotent replay | Early return when `promoted_order_id IS NOT NULL` → `already_promoted=true` | Governed core FOR UPDATE lock |
| Failure / rollback | Single transaction; validation exceptions before order insert; blocked drafts remain `UNDER_REVIEW` | pgTAP FLOW3–6 |

### Risk surface audit (no unsafe route found on main)

| Risk | Mitigation evidence |
|---|---|
| Promote unapproved/ambiguous draft | `DRAFT_NOT_READY` for non-`UNDER_REVIEW`; WA-3 trigger for linked potential orders |
| Partial order creation | Order insert only after line/readiness preflight; failure leaves `promoted_order_id` null |
| Double-promote | `FOR UPDATE` + `promoted_order_id` early return; pgTAP FLOW2 |
| Lose WhatsApp provenance | `order_origin='WHATSAPP'`; commercial version `wa-draft:{id}` reference |
| Bypass canonical SO allocator | `WHATSAPP_DRAFT_PROMOTION` scope required; direct scope mint denied |
| Draft/order inconsistency | Atomic status + `promoted_order_id` + audit in same transaction |
| Human bypass of AAL2 | `WA2_DRAFT_PROMOTE_REQUIRED` without AAL2; pgTAP FLOW5 |
| Direct core bypass | `promote_*` EXECUTE revoked from authenticated; pgTAP FLOW9 |

### Boundaries (out of scope, not absorbed)

| Lane | Separation |
|---|---|
| Point68 review/correction | `submit_sales_order_draft_for_review_atomic`, `update_sales_order_draft_operator_final` — no `orders` insert |
| CORE-B autonomous policy | `whatsapp_promote_autonomous_sales_order_draft_v1` — separate wrapper, `core-b:autonomy:` key |
| Point70 intake routing | `capture_whatsapp_potential_order`, packet/case routing — upstream of promotion |
| Point72 source/dedupe | `whatsapp_potential_orders` fingerprint/lineage — not modified here |
| Point75 amendments | Post-order amendment authority — not entered |

## Required certification flows

| Flow | Strike evidence | Result |
|---|---|---|
| 1. Human-approved promotion → live SO | `20260906120000_point69_whatsapp_draft_promotion_certification.sql` FLOW1 | PASS (local pgTAP) |
| 2. Idempotent replay | Same file FLOW2 | PASS |
| 3. Forged extraction key denied | Same file FLOW3 | PASS |
| 4. Unapproved status denied | Same file FLOW4 | PASS |
| 5. AAL2 / wa.draft.promote required | Same file FLOW5 | PASS |
| 6. WA-3 unresolved dimensions blocked | Same file FLOW6 + `20260813170002_wa3_blocker_closure.sql` | PASS |
| 7. Commercial version + audit trail | Same file FLOW7 | PASS |
| 8. Authority census contracts | Same file FLOW8 | PASS |
| 9. Direct core bypass denied | Same file FLOW9 | PASS |
| 10. CORE-B wrapper isolated | Same file FLOW10 + `20260823110000_whatsapp_autonomy_core_b.sql` TEST 19 | PASS |

## Local runtime strike command

```sh
supabase db reset --local
supabase test db supabase/tests/20260906120000_point69_whatsapp_draft_promotion_certification.sql
```

## Boundaries honored

- No protected WA corpus #203 access.
- No new migration or competing schema authority.
- No Central UI changes.
- No production mutation.
- Synthetic fixtures only.

## Gate state

| Gate | State |
|---|---|
| Core authority present on main | YES (reused; not duplicated) |
| Point69 consolidated pgTAP | YES (this branch) |
| Migration required | **NO** |
| PR merge | **NOT REQUESTED** — review by `dineshmutrejabackup-cmd` |
| Production approval / deployment | **BLOCKED / NOT PERFORMED** |
| Programme stage cleared | **NO** (`PR MERGED != STAGE CLEARED`) |

Return to Mission Control for Point69 programme gate review after PR human approval.

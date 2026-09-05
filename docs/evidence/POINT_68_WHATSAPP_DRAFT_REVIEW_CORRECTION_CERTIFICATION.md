# POINT68 — WhatsApp Draft Review / Correction Canonical Closure

**Workstation:** POINT68 (original Point 68 — draft review / correction)  
**Repository:** `oasis-supabase-core` (canonical Core backend)  
**Core main audited:** `049950fb5f7c681c5cbcc58f0d2d7825075a52d7`  
**Certification branch:** `cursor/point68-draft-review-certification-7e94`  
**Stage-2 TEXT authority:** sufficient for this lane; no dependency on media #188  
**Production writes:** FORBIDDEN — certification is local pgTAP + existing merged authority only  

## Verdict

**CODE_COMPLETE (Point68 review/correction lane)** with one smallest Core-owned guard repair and consolidated exact-head pgTAP strike evidence.

**NOT programme-cleared.** Stop before merge/production approval. Point69 live-order promotion lane not entered.

## Chain census (interpreted packet → approval-ready)

| Stage | Canonical surface | Authority |
|---|---|---|
| Inbound capture | `ingest_whatsapp_inbound_message`, `whatsapp_inbound_messages` | WA-1 `#59` lineage |
| Stitch / packet | `stitch_whatsapp_messages_atomic`, `whatsapp_message_packets` | WA-4 pgTAP |
| TEXT interpretation | `whatsapp_packet_ai_interpretations`, CORE-A `whatsapp_evaluate_and_materialize_order_autonomy` | `#111`, Stage-2 TEXT (#186) |
| Potential order | `capture_whatsapp_potential_order`, `whatsapp_potential_orders` | WA-1 / WA-3 |
| Ambiguity / clarification | `whatsapp_order_field_evidence`, `whatsapp_order_field_resolutions`, `answer_whatsapp_order_clarification`, `wa3_draft_promotion_readiness` | WA-3 `#59` |
| Draft materialization | `sales_order_drafts`, `sales_order_draft_lines`, CORE-B autonomous draft path | `#112` |
| Operator correction (case) | `record_whatsapp_operator_correction`, `whatsapp_operator_case_corrections` | `#168` operator workspace |
| Human review submit | `submit_sales_order_draft_for_review_atomic` | Sprint-9 baseline RPC |
| Operator final correction | `update_sales_order_draft_operator_final` | Sprint-9 baseline RPC |
| Approval-ready state | `UNDER_REVIEW` + persisted readiness dimensions | Server-owned readiness only |
| Point69 boundary (out of scope) | `approve_sales_order_draft_for_so_atomic` → `promote_sales_order_draft_to_order_governed_v1` | CORE-B `#112`, service-role core |

### Idempotency / supersession semantics

- Extraction version binding: `extraction_request_key` enforced on submit/update/approve RPCs.
- Operator line corrections supersede via `operator_quantity` / `operator_line_snapshot` without erasing AI snapshot immutables.
- CORE-A correction supersession preserved in governed facts (`20260823100000_whatsapp_autonomy_core_a.sql` TEST 5).
- Operator workspace case corrections supersede with auditable lineage (`20260901005001_whatsapp_operator_workspace_acceptance.sql`).

### AAL2 / staff authority

- `wa.draft.promote` requires step-up (`requires_step_up=true`); enforced by `wa2_sales_order_drafts_write_guard` + `wa3_draft_promotion_readiness`.
- `wa.draft.manage` gates draft mutation; inbox reader role gate on review RPCs via `is_whatsapp_inbox_reader`.
- Strike: `20260813160000_wa2_whatsapp_identity_rbac.sql`, `20260813210000_wa7_whatsapp_release_certification.sql`.

## Required certification flows (Stage-2 TEXT)

| Flow | Strike evidence | Result |
|---|---|---|
| 1. Correct draft accepted unchanged | `20260905120000_point68_whatsapp_draft_review_correction_certification.sql` FLOW1 | PASS (local pgTAP) |
| 2. Operator correction persists / supersedes | Same file FLOW2 + CORE-A TEST 5 + operator workspace acceptance | PASS |
| 3. Unresolved ambiguity fails closed | Same file FLOW3 + `20260813170002_wa3_blocker_closure.sql` | PASS |
| 4. Wrong sender/customer cannot silently bridge | Same file FLOW4 + `20260820140000_whatsapp_case_potential_order_bridge_fix.sql` | PASS |
| 5. Repeated review/correction replay-safe | Same file FLOW5 + operator workspace idempotency tests | PASS |
| 6. Review lane separated from Point69 promotion | Same file FLOW6 (`submit`/`update` have no `orders` insert; promotion core service-role-only) | PASS |

## Smallest Core-owned delta (this workstation)

**Root cause found during exact-head certification:** `wa2_guard_sales_order_draft_write()` used invalid `tg_table_name` and PL/pgSQL evaluated cross-table `NEW.*` fields, causing authenticated review/correction RPCs to fail closed.

**Repair:** `20260905120000_point68_wa2_draft_review_guard_fix.sql` — nested `TG_TABLE_NAME` branches; no new RPCs; no Point69 promotion changes.

**Certification harness:** `20260905120000_point68_whatsapp_draft_review_correction_certification.sql` (28/28 pgTAP on local clean replay).

## Local runtime strike command

```sh
supabase db reset --local
supabase test db supabase/tests/20260905120000_point68_whatsapp_draft_review_correction_certification.sql
```

Observed on branch HEAD: `All tests successful. Files=1, Tests=28, Result: PASS`

## Boundaries honored

- No WA media #188 overlap.
- No Point69 implementation or promotion semantics change.
- No Central UI changes.
- No production mutation.
- No raw historical PII committed.

## Gate state

| Gate | State |
|---|---|
| Core authority present on main | YES (reused; not duplicated) |
| Point68 consolidated pgTAP | YES (this branch) |
| WA-2 guard repair for review RPC runtime | YES (this branch) |
| PR merge | **NOT REQUESTED** |
| Production approval / deployment | **BLOCKED / NOT PERFORMED** |
| Programme stage cleared | **NO** (`PR MERGED != STAGE CLEARED`) |

Return to Mission Control for Point68 programme gate review after PR human approval.

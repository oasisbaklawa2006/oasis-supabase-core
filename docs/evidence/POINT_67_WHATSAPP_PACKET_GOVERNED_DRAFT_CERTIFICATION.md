# POINT67 — WhatsApp Packet → Governed Draft Canonical Closure

**Workstation:** POINT67 (original Point 67 — packet → governed draft)  
**Repository:** `oasis-supabase-core` (canonical Core backend)  
**Core main audited:** `9c93fc32edb65ece2b125e787046e0c001d29b47`  
**Certification branch:** `cursor/point67-packet-draft-certification-4f7f`  
**Migration policy:** No new migration while Point36 production release train is serialized  
**Protected corpus:** NOT accessed — synthetic fixtures only  
**Production writes:** FORBIDDEN — certification is local pgTAP + existing merged authority only  

## Verdict

**CODE_COMPLETE (Point67 packet→draft lane)** with consolidated exact-head pgTAP strike evidence on existing Core authority (CORE-A `#111`, CORE-B `#112`). No backend schema gap requiring a competing migration was found.

**NOT programme-cleared.** Stop before merge/production approval. `PR merged != Point67 cleared` until live-provider/runtime packet→draft evidence is certified.

## 1. Core main SHA and contract ancestry

```
9c93fc32edb65ece2b125e787046e0c001d29b47
```

Latest main commit: `POINT37-CORE — canonical FSSAI / label-compliance product authority (#215)`

| Predecessor | Authority consumed | Status |
|---|---|---|
| Point65 grouping (#238) | `stitch_whatsapp_messages_atomic`, `capture_whatsapp_commercial_fragment`, packet revision / correction linkage | Separate lane; CORE-A/B ancestry re-verified on rebased main |
| Point66 identity (#242/#247) | `whatsapp_resolve_governed_customer`, sender≠customer, three-role identity model | Consumed by CORE-A; adversarial relay covered in FLOW7; CORE-A pgTAP 87/87 PASS on rebased main |
| CORE-A autonomy | `whatsapp_evaluate_and_materialize_order_autonomy`, `whatsapp_resolve_governed_product_line` | Primary evaluation + governed facts |
| CORE-B draft execution | `whatsapp_execute_autonomous_order_draft_v1`, `sales_order_drafts` materialization | Primary draft creation |

| Downstream (out of scope) | Boundary |
|---|---|
| Point68 review/correction | `submit_sales_order_draft_for_review_atomic`, `update_sales_order_draft_operator_final` — not invoked by draft orchestrator |
| Point69 promotion | `approve_sales_order_draft_for_so_atomic`, `promote_sales_order_draft_to_order_governed_v1` — draft-only tests use `p_attempt_promotion=false` |

## 2. Packet → draft path census

| Stage | Canonical surface | Key semantics |
|---|---|---|
| Packet revision | `whatsapp_message_packets`, `whatsapp_messages.packet_id`, `whatsapp_packet_ai_interpretations` | Append-only interpretation bound to packet |
| Original message IDs | `whatsapp_packet_ai_interpretations.provider_message_ids` | Preserved in interpretation and draft `ai_draft_snapshot` |
| Customer identity | `whatsapp_resolve_governed_customer` → `governed_facts.customer.company_id` | Explicit candidate precedence; no sender==customer shortcut |
| SKU / alias resolution | `whatsapp_resolve_governed_product_line` | Exact SKU, name, alias, knowledge snapshot; invented SKU fails closed |
| Quantity / UOM / carton | `whatsapp_resolve_governed_product_line`, `customer_validate_order_quantity_v1` | Evidence-proven quantity only; no default quantity=1 |
| Corrections / supersession | `whatsapp_order_autonomy_decisions` + `whatsapp_autonomy_decision_is_current` | Later interpretation supersedes; stale decision rejected |
| Ambiguity state | `autonomy_outcome = CLARIFICATION_REQUIRED` | Unresolved cases remain governed cases; zero drafts |
| Draft idempotency key | `extraction_request_key = 'core-b:autonomy:' || decision_id` | Deterministic; replay-safe |
| Commercial version / attribution | `ai_draft_snapshot`, `sales_order_draft_audit_log` | CORE_B_AUTONOMY source; governed_facts provenance |
| AI / provider boundary | `whatsapp_packet_ai_interpretations` (append-only), service-role orchestration | AI interpretation is advisory; draft only from governed facts |

## 3. Adversarial path audit

| Risk | Finding | Evidence |
|---|---|---|
| Invent SKU/qty/customer | Fail-closed at CORE-A evaluation | FLOW4 (invented SKU), FLOW3 (missing qty), FLOW7 (relay sender) |
| Default quantity=1 | No executable fallback in resolver or orchestrator source | FLOW3, FLOW11, FLOW12 |
| Promote unresolved ambiguity | `CLARIFICATION_REQUIRED` creates zero drafts | FLOW3, FLOW4, FLOW5 |
| Lose later corrections | Stale decision rejected with `stale_autonomy_decision_superseded` | FLOW6 |
| Duplicate drafts on replay | One active draft per packet; idempotent replay | FLOW2, `idx_sales_order_drafts_packet_active` |
| Bypass governed identity | Employee relay uses explicit GST candidate, not sender authorization | FLOW7 |
| Write order directly | Draft-only path records zero `PROMOTED` events | FLOW8 |
| Point68/69 bleed | Orchestrator has no embedded review/approval RPCs | FLOW9 |

## 4. Required certification flows

| Flow | Strike evidence | Result |
|---|---|---|
| 1. AUTO_ELIGIBLE → governed draft | `20260906130000_point67_whatsapp_packet_draft_certification.sql` FLOW1 | PASS (41/41 local pgTAP) |
| 2. Idempotent replay | Same file FLOW2 | PASS |
| 3. Missing quantity fail-closed | Same file FLOW3 | PASS |
| 4. Invented SKU fail-closed | Same file FLOW4 | PASS |
| 5. Non-order intent excluded | Same file FLOW5 | PASS |
| 6. Interpretation supersession | Same file FLOW6 | PASS |
| 7. Sender≠customer on draft | Same file FLOW7 | PASS |
| 8. Point69 boundary (no promotion) | Same file FLOW8 | PASS |
| 9. Point68 boundary (no review RPC) | Same file FLOW9 | PASS |
| 10. Provider message ID provenance | Same file FLOW10 | PASS |
| 11. No quantity=1 fallback | Same file FLOW11 | PASS |
| 12. AI quantity without evidence | Same file FLOW12 | PASS |

## 5. Local runtime strike command

```sh
supabase db reset --local
supabase test db supabase/tests/20260906130000_point67_whatsapp_packet_draft_certification.sql
```

Observed on branch HEAD: `All tests successful. Files=1, Tests=41, Result: PASS`

## 6. Boundaries honored

- No migration while protected release train is serialized.
- No protected corpus, provider sends, or production mutation.
- No Point68 review/correction implementation.
- No Point69 order promotion semantics change.
- No Central UI changes.

## 7. Gate state

| Gate | State |
|---|---|
| Code / pgTAP evidence (this PR) | **COMPLETE** |
| CI migration replay | Pending PR CI |
| Live-provider packet→draft runtime certification | **NOT CLEARED** |
| Programme Point67 stage | **NOT CLEARED** |

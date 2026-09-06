# POINT65 — Fragmented WhatsApp Message Grouping Canonical Closure

**Workstation:** POINT65 (original Point 65 — fragmented message grouping)  
**Repository:** `oasis-supabase-core` (canonical Core backend)  
**Core main audited:** `8e73d94fe83545ee3a84ea8b6ccbd0701e23de66`  
**Certification branch:** `cursor/point65-fragmented-grouping-certification-922f`  
**Migration lane:** BLOCKED while `#209→#215→#226→#228` active — test/evidence only  
**Production writes:** FORBIDDEN — certification is local pgTAP + existing merged authority only  

## Verdict

**CODE_COMPLETE (Point65 grouping lane)** with consolidated exact-head pgTAP strike evidence on synthetic fixtures. No new migration; no protected corpus; no schema delta required.

**NOT programme-cleared.** `PR merged != Point65 cleared` until live-provider/runtime fragmentation evidence is certified. Stop before merge/production approval.

## 1. Core main SHA

```
8e73d94fe83545ee3a84ea8b6ccbd0701e23de66
```

(`POINT20 — Canonical shared event ledger closure (#202)`)

## 2. Census — active grouping surfaces

| Surface | Canonical object | Grouping key | Idempotency / replay |
|---|---|---|---|
| Inbound message identity | `whatsapp_messages`, `whatsapp_inbound_messages` | `provider_message_id` unique | Provider retry → `23505` / existing row return |
| Contact / conversation scope | `whatsapp_contacts`, `sender_key` (WA4) | Normalized phone per contact | Cross-contact fail-closed |
| Temporal stitch window | `stitch_whatsapp_messages_atomic(contact_id, message_ids[], window_seconds)` | Per-contact + `message_timestamp` within window (default 300s) | Exact replay returns existing `packet_id`; partial/conflicting → `WA_PACKET_PARTIAL_OR_CONFLICTING_REPLAY` |
| Stitch packet builder | `whatsapp_message_packets` | Open packet within window boundary | Advisory lock per contact; `fragment_count` + `packet_sequence` |
| Explicit conversation continuation | `capture_whatsapp_commercial_fragment(..., p_conversation_key)` | Explicit `conversation_key` (provider id of anchor) | **No time-proximity inference** — missing key = isolated packet |
| Reply / correction linkage | `capture_whatsapp_commercial_fragment(..., p_correction_of_source_message_id)` | Reply source must exist in same packet | `correction_of_source_message_id` immutable |
| Media reference fragments | `whatsapp_commercial_evidence.evidence_kind`, stitch `message_type` | Chronological append only | Media state via `complete_whatsapp_media_processing` (append-only) |
| Packet revision / dispatch | `whatsapp_packet_ai_dispatch_jobs` | `packet_revision` per new inbound evidence | Correction restitch bumps revision; replay does not |
| Cross-packet clarification | `whatsapp_clarification_answer_evidence`, `whatsapp_correlate_clarification_answer` | Governed case-context continuation (separate from stitch) | Fail-closed on 0 or >1 compatible clarifications |
| Deleted / system messages | Immutable evidence tables + audit triggers | No overwrite of captured evidence | `WA1_AUDIT_IMMUTABLE` on evidence mutation |
| Order intent grouping (commercial) | `whatsapp_commercial_packets` → `whatsapp_potential_orders` | Explicit packet + sender boundary | `source_fingerprint` unique; replay idempotent |
| Replay / dedup | Provider indexes + RPC early-return | `provider_message_id` | WA4 returns existing evidence; stitch returns existing packet |

### Prior strike evidence (retained, not duplicated)

| Dimension | Strike file | Tests |
|---|---|---|
| Atomic stitch authority | `20260816120000_wa_atomic_packet_authority.sql` | 23 |
| WA4 multimessage multimodal | `20260813180000_wa4_multimessage_multimodal.sql` | 27 |
| Correction restitch + dispatch revision | `20260822100000_whatsapp_packet_ai_dispatch_outbox.sql` | 30 |
| Cross-packet clarification lineage | `20260822110000_whatsapp_cross_packet_clarification_lineage.sql` | 27 |
| Noncommercial media (no invented evidence) | `20260829070000_wa_noncommercial_media_completion.sql` | 19 |

## 3. Path analysis — grouping integrity

| Risk | Finding | Authority |
|---|---|---|
| Split one commercial instruction into unrelated cases | **Mitigated** — temporal stitch appends within window; WA4 requires explicit `conversation_key` for continuation | `stitch_whatsapp_messages_atomic`, `capture_whatsapp_commercial_fragment` |
| Merge unrelated conversations | **Fail-closed** — `WA_PACKET_MESSAGE_SCOPE_MISMATCH`, `WA4_PACKET_BOUNDARY_MISMATCH` | Atomic + WA4 pgTAP |
| Lose later corrections | **Mitigated** — correction appends to same packet; `correction_of_source_message_id` retained | WA4 + dispatch outbox pgTAP |
| Infer missing content | **Fail-closed** — grouping preserves `original_body` / stitched raw text; no SKU/qty extraction at grouping layer | POINT65 boundary tests |
| Depend on protected historical corpus | **Not required** — all certification uses synthetic `86500000-*` fixtures | This workstation |
| Time-proximity merges distinct orders | **Prevented at WA4** — comment + behavior: "time proximity alone is not a commercial correlation key" | `20260813180000_wa4_multimessage_multimodal.sql` |

## 4. Separation from adjacent lanes

| Lane | Scope | Point65 boundary |
|---|---|---|
| **Point66** sender / original-customer identity | `whatsapp_case_identity`, sender resolution | Grouping uses `contact_id` / `sender_key` as provided — no identity inference |
| **Point67** packet → commercial draft extraction | `sales_order_drafts`, CORE-B materialization | Not exercised; `order_id` remains null at grouping layer |
| **Point68** draft review / correction | `submit_sales_order_draft_for_review_atomic`, operator corrections | Out of scope; grouping stops at packet/evidence |
| **#203** protected historical media | Live corpus certification | Explicitly excluded |

## 5. Required certification flows (synthetic fixtures)

| Flow | Scenario | Strike evidence | Result |
|---|---|---|---|
| FLOW1 | Fragmented text + media references | `20260906120000_point65_whatsapp_fragmented_grouping_certification.sql` | PASS |
| FLOW2 | WA4 explicit conversation-key grouping | Same file | PASS |
| FLOW3 | Correction / supersession linkage | Same file + `20260822100000_whatsapp_packet_ai_dispatch_outbox.sql` | PASS |
| FLOW4 | Intervening non-order (stitch chronology vs WA4 isolation) | Same file | PASS |
| FLOW5 | Session / timeout boundary | Same file + `20260816120000_wa_atomic_packet_authority.sql` | PASS |
| FLOW6 | Duplicate replay idempotency | Same file | PASS |
| FLOW7 | Cross-sender / cross-conversation isolation | Same file | PASS |
| BOUNDARY | No SKU/qty/customer inference at grouping layer | Same file | PASS |

## 6. Local runtime strike command

```sh
supabase db reset --local
supabase test db supabase/tests/20260906120000_point65_whatsapp_fragmented_grouping_certification.sql
```

## 7. Boundaries honored

- No protected historical corpus access.
- No new migration while `#209→#215→#226→#228` active.
- No production mutation.
- No Point66/67/68 scope expansion.
- No raw historical PII committed.

## 8. Remaining gate (programme clearance)

Point65 requires **live-provider/runtime fragmentation evidence** after PR merge. Synthetic pgTAP closure is necessary but not sufficient for programme-stage clearance.

# POINT66 — WhatsApp Sender / Original-Customer Identity Canonical Closure

**Workstation:** POINT66 (original Point 66 — sender / original-customer identity)  
**Repository:** `oasis-supabase-core` (canonical Core backend)  
**Core main audited:** `8e73d94fe83545ee3a84ea8b6ccbd0701e23de66`  
**Certification branch:** `cursor/point66-sender-identity-certification-13ca`  
**Migration policy:** No new migration while `#209→#215→#226→#228` is active  
**Protected corpus:** NOT accessed — synthetic fixtures only  
**Production writes:** FORBIDDEN — certification is local pgTAP + existing merged authority only  

## Verdict

**CODE_COMPLETE (Point66 identity resolution lane)** with consolidated exact-head pgTAP strike evidence on existing Core authority. No backend schema gap requiring a competing migration was found.

**NOT programme-cleared.** Stop before merge/production approval. Live-provider/runtime identity evidence (edge webhook fuzzy-linking retirement) remains a separate certification gate.

## 1. Core main SHA

```
8e73d94fe83545ee3a84ea8b6ccbd0701e23de66
```

Latest main commit: `POINT20 — Canonical shared event ledger closure (census + behavioral pgTAP) (#202)`

## 2. Identity surface census

### Ingress / provider sender

| Surface | Key columns / primitives | Role |
|---|---|---|
| `whatsapp_contacts` | `phone_number`, `customer_name`, `company_name` | Provider contact row — **not** commercial customer |
| `whatsapp_inbound_messages` | `sender_phone`, `sender_name`, `provider_message_id` | Raw inbound capture |
| `whatsapp_messages` | `contact_id`, `packet_id`, `provider_message_id` | Stitched traffic bound to contact |
| `sender_key` | `lower(regexp_replace(sender_phone, '\D', '', 'g'))` | Canonical binding primitive across WA-1/4/5/7 |

**Note:** No `sender_id` column. Binding is `sender_phone` → normalized `sender_key` → `contact_id`.

### Three-role case identity model

| Surface | Key columns | Role |
|---|---|---|
| `whatsapp_case_identities` | `identity_role`, `party_type`, `party_id`, `resolution_status` | **SUBMITTING_SENDER**, **ORIGINAL_COMMUNICATOR**, **COMMERCIAL_CUSTOMER** |
| `whatsapp_case_recipient_authorizations` | `identity_id`, `disclosure_scope`, `verification_method` | Outbound/clarification authority per identity |
| `whatsapp_case_events` | `event_type`, `correlation_key`, `metadata` | Append-only audit provenance |
| `whatsapp_case_manual_assignments` | `customer_segment`, `assigned_sales_user_id` | Manual queue when identity unresolved |
| `whatsapp_operator_case_corrections` | `correction_field`, `prior_value`, `corrected_value` | Governed operator override ledger |

### WA-3 commercial field authority

| Surface | Key columns | Role |
|---|---|---|
| `whatsapp_order_field_resolutions` | `field_key` (incl. `client_identity`), `resolution_state` | Governed field authority |
| `whatsapp_order_field_evidence` | `candidate_value`, `extraction_state`, `confidence` | Append-only evidence |
| `whatsapp_order_clarification_tasks` | `field_key`, `status` | Human clarification queue |

### Disclosure / sender authorization

| Surface | Key columns | Role |
|---|---|---|
| `whatsapp_sender_commercial_authorizations` | `contact_id`, `company_id`, `identity_evidence`, `status` | Time-bounded sender→company disclosure (not customer proof) |

### Contact→company links (governed resolution paths)

| Surface | Match method | Fail-closed behavior |
|---|---|---|
| `companies` | `gst_number`, `business_name`, `phone` | P0 explicit `company_id` → P1 GST → P2 name → P3 WA-6 auth → P4 phone |
| `b2b_applications` | `contact_phone`, `mobile_number` | Phone match only when no explicit candidate |
| `delivery_addresses` | `contact_phone` | Secondary phone path |
| `users` | `phone`, `company_id` | Employee relay detection |

### Canonical identity RPCs

| RPC | Authority |
|---|---|
| `whatsapp_resolve_governed_customer(contact_id, candidate)` | Deterministic resolver; employee-relay safe; explicit candidate precedence |
| `whatsapp_confirm_case_identity(case_id, company_id, …)` | Human confirmation of SUBMITTING_SENDER + COMMERCIAL_CUSTOMER |
| `whatsapp_confirm_original_communicator(case_id, party_type, …)` | Separate confirmation of forwarded original customer |
| `whatsapp_case_potential_order_id(case_id)` | Fail-closed case↔potential-order bridge bounded by `sender_key` |
| `bridge_whatsapp_case_identity_to_wa3()` | Event trigger: CASE_IDENTITY_CONFIRMED → WA-3 `client_identity` evidence |
| `evaluate_whatsapp_order_readiness(potential_order_id)` | Blocks commercial authority when `client_identity` unresolved |

## 3. Problematic path analysis

### Governed DB layer (fail-closed by design)

| Risk pattern | Status | Evidence |
|---|---|---|
| Sender == customer assumption | **Mitigated** | Three-role model; separate RPCs; CORE-A adversarial tests |
| Auto-link by fuzzy name/phone/email | **Partially mitigated** | Resolver returns `AMBIGUOUS` on multiple phone matches; explicit candidate required for employee relay |
| Original customer lost after forward | **Mitigated** | `whatsapp_confirm_original_communicator` with `FORWARDED_MESSAGE` method |
| Cross-company reassignment without audit | **Mitigated** | `whatsapp_case_events` + `whatsapp_operator_case_corrections`; bridge bounded by `sender_key` |
| Unresolved identity reaches draft/order authority | **Mitigated** | `evaluate_whatsapp_order_readiness` + `wa3_draft_promotion_readiness` trigger |

### Legacy edge ingress (governance gap — out of Point66 pgTAP scope)

| Risk pattern | Location | Status |
|---|---|---|
| Fuzzy `ilike` company name match | `whatsapp-webhook/index.ts` | **OPEN** — documented in `WA_E2E_MISSION_CONTROL_AUDIT.md`; requires runtime retirement |
| Shadow company auto-creation | `whatsapp-webhook/index.ts` | **OPEN** — bypasses governed RPC chain |
| GST suffix fuzzy match | `whatsapp-webhook/index.ts` | **OPEN** |

**Point66 conclusion:** Canonical DB authority is sufficient for synthetic behavioral closure. Live ingress fuzzy-linking is a **runtime certification prerequisite**, not a migration blocker.

## 4. Separation from adjacent points

| Point | Scope | Point66 boundary |
|---|---|---|
| **Point65** (#238 grouping) | Message grouping / packet stitching | Identity ledger has no grouping columns; separate workstream |
| **Point66** (this lane) | Sender / original-customer identity | Three-role model, governed resolver, manual confirmation |
| **Point67** (packet→draft) | Commercial extraction / draft creation | Identity confirmation RPC distinct from `submit_sales_order_draft_for_review_atomic` |
| **Point68** (#203 review) | Draft review / correction | FLOW4 wrong-sender bridge revalidated here at identity layer |

## 5. Required certification flows

| Flow | Strike evidence | Result |
|---|---|---|
| 1. Census — identity authority surfaces | `20260906083600_point66_whatsapp_sender_identity_certification.sql` CENSUS | PASS (local pgTAP) |
| 2. `sender_key` normalization | Same file FLOW1 | PASS |
| 3. Employee relay sender≠customer | Same file FLOW2 + `20260823100000_whatsapp_autonomy_core_a.sql` ADVERSARIAL 11 | PASS |
| 4. Forwarded original customer preserved | Same file FLOW3 | PASS |
| 5. Explicit manual company resolution + WA-3 bridge | Same file FLOW4 | PASS |
| 6. Ambiguous shared-phone fail-closed | Same file FLOW5 | PASS |
| 7. Cross-sender bridge refused | Same file FLOW6 + `20260820140000_whatsapp_case_potential_order_bridge_fix.sql` | PASS |
| 8. Identity confirmation idempotency + audit | Same file FLOW7 | PASS |
| 9. Unresolved `client_identity` blocks readiness | Same file FLOW8 + `20260813170002_wa3_blocker_closure.sql` | PASS |
| 10. Point65/67 boundary separation | Same file BOUNDARY | PASS |

## 6. Local runtime strike command

```sh
supabase db reset --local
supabase test db supabase/tests/20260906083600_point66_whatsapp_sender_identity_certification.sql
```

Observed on branch HEAD: `All tests successful. Files=1, Tests=34, Result: PASS`

## 7. Boundaries honored

- No protected historical corpus access.
- No new Supabase migration SQL.
- No production mutation.
- No Point65 grouping implementation.
- No Point67 draft creation/promotion changes.
- No Point68 review-lane duplication beyond cross-validated wrong-sender bridge.
- No Central UI changes.

## 8. Gate state

| Gate | State |
|---|---|
| Code merged | PENDING (PR open) |
| Clean replay green | PENDING (CI) |
| pgTAP green (Point66 harness) | **PASS** (local 34/34) |
| Production ledger verified | NOT IN SCOPE |
| Live-provider identity evidence | **NOT CLEARED** |
| Programme Point66 cleared | **NO** — `PR MERGED != STAGE CLEARED` |

## 9. Reviewer request

Request review from `dineshmutrejabackup-cmd`. **STOP before merge.**
